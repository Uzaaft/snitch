//! Snitch is a tiny profiling helper for code you suspect is on the hot path.
//!
//! Keep instrumentation calls in source code all the time. Build flags decide
//! whether those calls collect metrics or collapse to inline no-op code.
//!
//! # Build Flags
//!
//! Configure these from `build.zig`:
//!
//! - `-Dsnitch=true`: master switch.
//! - `-Dsnitch-timing=true|false`: timing metrics group.
//! - `-Dsnitch-memory=true|false`: allocation metrics group.
//! - `-Dsnitch-percentile=95`: percentile column used in reports.
//! - `-Dsnitch-max-rows=20`: max rows per section (`0` means unlimited).
//!
//! The deprecated alias `-Dhotpath=true` is still accepted in `build.zig`.
//!
//! # Usage Notes
//!
//! - `zone`, `measureCall`, and `measureBlock` use `comptime` labels.
//! - `zoneHere`, `measureCallHere`, and `measureBlockHere` require explicit
//!   `@src()` on Zig 0.15.
//! - Memory metrics only track allocations made through `profiler.allocator()`.
//! - Allocation counters are profiler-wide, so overlapping concurrent zones can
//!   include each other's allocations.
//!
//! # Example
//!
//! ```zig
//! const hotpath = @import("hotpath");
//! const std = @import("std");
//!
//! var profiler = hotpath.Profiler.init(std.heap.page_allocator);
//! defer profiler.deinit();
//!
//! const tracked_allocator = profiler.allocator();
//!
//! var zone = profiler.zone("db-query");
//! defer zone.end();
//!
//! _ = hotpath.measureCall(&profiler, "handler", handlerFn, .{ arg1, arg2 });
//! _ = hotpath.measureCallHere(&profiler, handlerFn, .{ arg1, arg2 }, @src());
//! _ = hotpath.measureBlockHere(&profiler, struct {
//!     fn run() void {}
//! }.run, @src());
//!
//! const payload = try tracked_allocator.alloc(u8, 256);
//! defer tracked_allocator.free(payload);
//!
//! try hotpath.writeReportStdout(&profiler, 4_096);
//! ```
const std = @import("std");
const build_options = @import("build_options");
const log = std.log.scoped(.snitch);

/// True when instrumentation is enabled with `-Dsnitch=true`.
pub const enabled = build_options.snitch;

/// True when timing metrics are enabled under the master snitch flag.
pub const timing_enabled = enabled and build_options.snitch_timing;

/// True when memory metrics are enabled under the master snitch flag.
pub const memory_enabled = enabled and build_options.snitch_memory;

/// Percentile shown in report columns, set via `-Dsnitch-percentile`.
pub const percentile_target = build_options.snitch_percentile;

/// Maximum rows printed per section, set via `-Dsnitch-max-rows`.
pub const report_max_rows = build_options.snitch_max_rows;

comptime {
    if (percentile_target == 0 or percentile_target > 100) {
        @compileError("snitch_percentile must be between 1 and 100");
    }
}

const enabled_impl = struct {
    const AllocationSnapshot = struct {
        bytes: u64,
        calls: u64,
    };

    const TrackingAllocator = struct {
        parent: std.mem.Allocator,
        total_allocated_bytes: u64 = 0,
        total_allocation_calls: u64 = 0,

        fn init(parent: std.mem.Allocator) TrackingAllocator {
            return .{ .parent = parent };
        }

        fn allocator(self: *TrackingAllocator) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .remap = remap,
                    .free = free,
                },
            };
        }

        fn snapshot(self: *const TrackingAllocator) AllocationSnapshot {
            return .{
                .bytes = @atomicLoad(u64, &self.total_allocated_bytes, .seq_cst),
                .calls = @atomicLoad(u64, &self.total_allocation_calls, .seq_cst),
            };
        }

        fn record(self: *TrackingAllocator, bytes: u64, calls: u64) void {
            if (bytes > 0) {
                _ = @atomicRmw(u64, &self.total_allocated_bytes, .Add, bytes, .seq_cst);
            }

            if (calls > 0) {
                _ = @atomicRmw(u64, &self.total_allocation_calls, .Add, calls, .seq_cst);
            }
        }

        fn recordGrowth(self: *TrackingAllocator, old_len: usize, new_len: usize) void {
            if (new_len <= old_len) {
                return;
            }

            const growth = new_len - old_len;
            std.debug.assert(growth <= std.math.maxInt(u64));
            self.record(@intCast(growth), 1);
        }

        fn alloc(
            context: *anyopaque,
            len: usize,
            alignment: std.mem.Alignment,
            return_address: usize,
        ) ?[*]u8 {
            const self: *TrackingAllocator = @ptrCast(@alignCast(context));
            const pointer = self.parent.rawAlloc(len, alignment, return_address);

            if (pointer != null) {
                std.debug.assert(len <= std.math.maxInt(u64));
                self.record(@intCast(len), 1);
            }

            return pointer;
        }

        fn resize(
            context: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            return_address: usize,
        ) bool {
            const self: *TrackingAllocator = @ptrCast(@alignCast(context));
            const resized = self.parent.rawResize(memory, alignment, new_len, return_address);

            if (resized) {
                self.recordGrowth(memory.len, new_len);
            }

            return resized;
        }

        fn remap(
            context: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            return_address: usize,
        ) ?[*]u8 {
            const self: *TrackingAllocator = @ptrCast(@alignCast(context));
            const pointer = self.parent.rawRemap(memory, alignment, new_len, return_address);

            if (pointer != null) {
                self.recordGrowth(memory.len, new_len);
            }

            return pointer;
        }

        fn free(
            context: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            return_address: usize,
        ) void {
            const self: *TrackingAllocator = @ptrCast(@alignCast(context));
            self.parent.rawFree(memory, alignment, return_address);
        }
    };

    const Sample = struct {
        calls: u64 = 0,
        total_ns: u128 = 0,
        total_alloc_bytes: u128 = 0,
        total_alloc_calls: u128 = 0,
        durations_ns: std.ArrayList(u64) = .{},
        alloc_bytes_values: std.ArrayList(u64) = .{},
        alloc_call_values: std.ArrayList(u64) = .{},

        fn averagePerCall(total: u128, calls: u64) u64 {
            std.debug.assert(calls > 0);
            const average = total / calls;
            std.debug.assert(average <= std.math.maxInt(u64));
            return @intCast(average);
        }

        fn observe(
            self: *Sample,
            allocator: std.mem.Allocator,
            elapsed_ns: u64,
            alloc_bytes: u64,
            alloc_calls: u64,
        ) !void {
            std.debug.assert(elapsed_ns <= std.math.maxInt(u64));

            self.calls += 1;

            if (timing_enabled) {
                try self.durations_ns.append(allocator, elapsed_ns);
                self.total_ns += elapsed_ns;
            }

            if (memory_enabled) {
                try self.alloc_bytes_values.append(allocator, alloc_bytes);
                try self.alloc_call_values.append(allocator, alloc_calls);
                self.total_alloc_bytes += alloc_bytes;
                self.total_alloc_calls += alloc_calls;
            }
        }

        fn averageDurationNs(self: Sample) u64 {
            if (!timing_enabled) {
                return 0;
            }

            return averagePerCall(self.total_ns, self.calls);
        }

        fn averageAllocBytes(self: Sample) u64 {
            if (!memory_enabled) {
                return 0;
            }

            return averagePerCall(self.total_alloc_bytes, self.calls);
        }

        fn averageAllocCalls(self: Sample) u64 {
            if (!memory_enabled) {
                return 0;
            }

            return averagePerCall(self.total_alloc_calls, self.calls);
        }

        fn deinit(self: *Sample, allocator: std.mem.Allocator) void {
            self.durations_ns.deinit(allocator);
            self.alloc_bytes_values.deinit(allocator);
            self.alloc_call_values.deinit(allocator);
            self.* = undefined;
        }
    };

    const MetricTableRow = struct {
        label: []const u8,
        calls: u64,
        avg: u64,
        p85: u64,
        total: u64,
        total_exact: u128,
    };

    const TableWidths = struct {
        metric: usize,
        calls: usize,
        avg: usize,
        p85: usize,
        total: usize,
        percent_total: usize,
    };

    const MetricKind = enum {
        timing,
        alloc_bytes,
        alloc_count,
    };

    /// Stateful profiler that aggregates timing and allocation metrics by zone.
    pub const ProfilerType = struct {
        base_allocator: std.mem.Allocator,
        tracking_allocator_state: TrackingAllocator,
        mutex: std.Thread.Mutex = .{},
        metrics: std.StringHashMapUnmanaged(Sample) = .{},

        /// Initialize a profiler with the allocator used for internal storage.
        pub fn init(base_allocator: std.mem.Allocator) callconv(callingConvention()) ProfilerType {
            return .{
                .base_allocator = base_allocator,
                .tracking_allocator_state = TrackingAllocator.init(base_allocator),
            };
        }

        /// Allocator to use from instrumented code when memory metrics are needed.
        pub fn allocator(self: *ProfilerType) callconv(callingConvention()) std.mem.Allocator {
            if (memory_enabled) {
                return self.tracking_allocator_state.allocator();
            }

            return self.base_allocator;
        }

        /// Release all internal metric storage.
        pub fn deinit(self: *ProfilerType) callconv(callingConvention()) void {
            var iterator = self.metrics.iterator();
            while (iterator.next()) |entry| {
                self.base_allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(self.base_allocator);
            }

            self.metrics.deinit(self.base_allocator);
            self.* = undefined;
        }

        /// Start a labeled profiling zone.
        pub fn zone(self: *ProfilerType, comptime label: []const u8) callconv(callingConvention()) ZoneType {
            std.debug.assert(label.len > 0);

            const alloc_snapshot = if (memory_enabled)
                self.tracking_allocator_state.snapshot()
            else
                AllocationSnapshot{ .bytes = 0, .calls = 0 };

            return .{
                .profiler = self,
                .label = label,
                .start_ns = std.time.nanoTimestamp(),
                .start_alloc_bytes = alloc_snapshot.bytes,
                .start_alloc_calls = alloc_snapshot.calls,
                .finished = false,
            };
        }

        /// Write the profiling report in an ASCII table format.
        pub fn writeReport(self: *ProfilerType, writer: anytype) callconv(callingConvention()) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const row_count = self.metrics.count();
            try writer.print("[snitch] zones={d}\n\n", .{row_count});

            if (row_count == 0) {
                log.info("report requested with zero measured zones", .{});
                try writer.writeAll("(no measurements)\n");
                return;
            }

            if (!timing_enabled and !memory_enabled) {
                log.warn("snitch enabled but both metric groups are disabled", .{});
                try writer.writeAll("snitch is enabled, but both snitch-timing and snitch-memory are disabled.\n");
                return;
            }

            const metric_rows = try self.base_allocator.alloc(MetricTableRow, row_count);
            defer self.base_allocator.free(metric_rows);

            const timing_percentile_header = std.fmt.comptimePrint("P{d} ns", .{percentile_target});
            const alloc_bytes_percentile_header = std.fmt.comptimePrint("P{d} bytes", .{percentile_target});
            const alloc_count_percentile_header = std.fmt.comptimePrint("P{d} allocs", .{percentile_target});

            if (timing_enabled) {
                try renderMetricSection(
                    self,
                    writer,
                    metric_rows,
                    .timing,
                    "snitch-timing - Function execution time metrics.",
                    "Avg ns",
                    timing_percentile_header,
                    "Total ns",
                );
            }

            if (memory_enabled) {
                if (timing_enabled) {
                    try writer.writeByte('\n');
                }

                try renderMetricSection(
                    self,
                    writer,
                    metric_rows,
                    .alloc_bytes,
                    "snitch-memory-bytes - Cumulative allocation bytes during each function call.",
                    "Avg bytes",
                    alloc_bytes_percentile_header,
                    "Total bytes",
                );
                try writer.writeByte('\n');

                try renderMetricSection(
                    self,
                    writer,
                    metric_rows,
                    .alloc_count,
                    "snitch-memory-count - Allocation call count during each function call.",
                    "Avg allocs",
                    alloc_count_percentile_header,
                    "Total allocs",
                );
            }
        }

        fn record(
            self: *ProfilerType,
            label: []const u8,
            elapsed_ns: u64,
            alloc_bytes: u64,
            alloc_calls: u64,
        ) void {
            std.debug.assert(label.len > 0);
            std.debug.assert(elapsed_ns <= std.math.maxInt(u64));

            self.mutex.lock();
            defer self.mutex.unlock();

            const get_or_put = self.metrics.getOrPut(self.base_allocator, label) catch |err| {
                @panic(@errorName(err));
            };

            if (!get_or_put.found_existing) {
                const owned_label = self.base_allocator.dupe(u8, label) catch |err| {
                    @panic(@errorName(err));
                };

                get_or_put.key_ptr.* = owned_label;
                get_or_put.value_ptr.* = .{};
            }

            get_or_put.value_ptr.observe(
                self.base_allocator,
                elapsed_ns,
                alloc_bytes,
                alloc_calls,
            ) catch |err| {
                @panic(@errorName(err));
            };
        }
    };

    /// Handle representing an in-progress zone measurement.
    pub const ZoneType = struct {
        profiler: *ProfilerType,
        label: []const u8,
        start_ns: i128,
        start_alloc_bytes: u64,
        start_alloc_calls: u64,
        finished: bool,

        /// Finish a zone and commit its sample into profiler aggregates.
        pub fn end(self: *ZoneType) callconv(callingConvention()) void {
            std.debug.assert(!self.finished);

            const now_ns = std.time.nanoTimestamp();
            const elapsed_ns = now_ns - self.start_ns;
            std.debug.assert(elapsed_ns >= 0);
            std.debug.assert(elapsed_ns <= std.math.maxInt(u64));

            const alloc_bytes, const alloc_calls = if (memory_enabled) blk: {
                const alloc_snapshot = self.profiler.tracking_allocator_state.snapshot();
                std.debug.assert(alloc_snapshot.bytes >= self.start_alloc_bytes);
                std.debug.assert(alloc_snapshot.calls >= self.start_alloc_calls);

                break :blk .{
                    alloc_snapshot.bytes - self.start_alloc_bytes,
                    alloc_snapshot.calls - self.start_alloc_calls,
                };
            } else .{ 0, 0 };

            self.profiler.record(self.label, @intCast(elapsed_ns), alloc_bytes, alloc_calls);
            self.finished = true;
        }
    };

    pub fn measureCall(
        profiler: *ProfilerType,
        comptime label: []const u8,
        function: anytype,
        args: anytype,
    ) callconv(callingConvention()) @TypeOf(@call(.auto, function, args)) {
        var measurement_zone = profiler.zone(label);
        defer measurement_zone.end();

        return @call(.auto, function, args);
    }

    pub fn measureBlock(
        profiler: *ProfilerType,
        comptime label: []const u8,
        block: anytype,
    ) callconv(callingConvention()) @TypeOf(block()) {
        var measurement_zone = profiler.zone(label);
        defer measurement_zone.end();

        return block();
    }

    fn writeMetricTable(
        writer: anytype,
        title: []const u8,
        rows: []const MetricTableRow,
        total_exact: u128,
        avg_header: []const u8,
        p85_header: []const u8,
        total_header: []const u8,
    ) !void {
        try writer.writeAll(title);
        try writer.writeByte('\n');

        const visible_rows = limitRows(rows);
        const widths = computeTableWidths(visible_rows, avg_header, p85_header, total_header);
        try writeSeparator(writer, widths);
        try writeHeader(writer, widths, avg_header, p85_header, total_header);
        try writeSeparator(writer, widths);

        for (visible_rows) |row| {
            try writeMetricRow(writer, widths, row, total_exact);
        }

        try writeSeparator(writer, widths);

        if (visible_rows.len < rows.len) {
            const hidden_rows = rows.len - visible_rows.len;
            log.info("section truncated: showing {d} of {d} rows", .{ visible_rows.len, rows.len });
            try writer.print(
                "(truncated {d} rows, set -Dsnitch-max-rows=0 for all rows)\n",
                .{hidden_rows},
            );
        }
    }

    fn renderMetricSection(
        self: *ProfilerType,
        writer: anytype,
        rows: []MetricTableRow,
        comptime kind: MetricKind,
        title: []const u8,
        avg_header: []const u8,
        p85_header: []const u8,
        total_header: []const u8,
    ) !void {
        const total_exact = collectMetricRows(self, rows, kind);
        std.sort.heap(MetricTableRow, rows, {}, metricRowLessThan);
        try writeMetricTable(writer, title, rows, total_exact, avg_header, p85_header, total_header);
    }

    fn collectMetricRows(
        self: *ProfilerType,
        rows: []MetricTableRow,
        comptime kind: MetricKind,
    ) u128 {
        var total_exact: u128 = 0;
        var row_index: usize = 0;
        var iterator = self.metrics.iterator();

        while (iterator.next()) |entry| {
            const sample = entry.value_ptr.*;
            std.debug.assert(sample.calls > 0);
            std.debug.assert(row_index < rows.len);

            const metric_row: MetricTableRow = switch (kind) {
                .timing => .{
                    .label = entry.key_ptr.*,
                    .calls = sample.calls,
                    .avg = sample.averageDurationNs(),
                    .p85 = percentileNearestRank(self.base_allocator, sample.durations_ns.items, percentile_target),
                    .total = saturatingToU64(sample.total_ns),
                    .total_exact = sample.total_ns,
                },
                .alloc_bytes => .{
                    .label = entry.key_ptr.*,
                    .calls = sample.calls,
                    .avg = sample.averageAllocBytes(),
                    .p85 = percentileNearestRank(self.base_allocator, sample.alloc_bytes_values.items, percentile_target),
                    .total = saturatingToU64(sample.total_alloc_bytes),
                    .total_exact = sample.total_alloc_bytes,
                },
                .alloc_count => .{
                    .label = entry.key_ptr.*,
                    .calls = sample.calls,
                    .avg = sample.averageAllocCalls(),
                    .p85 = percentileNearestRank(self.base_allocator, sample.alloc_call_values.items, percentile_target),
                    .total = saturatingToU64(sample.total_alloc_calls),
                    .total_exact = sample.total_alloc_calls,
                },
            };

            rows[row_index] = metric_row;
            total_exact += metric_row.total_exact;
            row_index += 1;
        }

        std.debug.assert(row_index == rows.len);
        return total_exact;
    }

    fn limitRows(rows: []const MetricTableRow) []const MetricTableRow {
        if (report_max_rows == 0) {
            return rows;
        }

        return rows[0..@min(rows.len, report_max_rows)];
    }

    fn computeTableWidths(
        rows: []const MetricTableRow,
        avg_header: []const u8,
        p85_header: []const u8,
        total_header: []const u8,
    ) TableWidths {
        const max_metric_width = 40;

        var widths = TableWidths{
            .metric = "Metric".len,
            .calls = "Calls".len,
            .avg = avg_header.len,
            .p85 = p85_header.len,
            .total = total_header.len,
            .percent_total = "% Total".len,
        };

        for (rows) |row| {
            widths.metric = @max(widths.metric, @min(max_metric_width, row.label.len));
            widths.calls = @max(widths.calls, decimalDigits(row.calls));
            widths.avg = @max(widths.avg, decimalDigits(row.avg));
            widths.p85 = @max(widths.p85, decimalDigits(row.p85));
            widths.total = @max(widths.total, decimalDigits(row.total));
        }

        widths.percent_total = @max(widths.percent_total, "100.00%".len);
        return widths;
    }

    fn metricRowLessThan(_: void, lhs: MetricTableRow, rhs: MetricTableRow) bool {
        if (lhs.total_exact != rhs.total_exact) {
            return lhs.total_exact > rhs.total_exact;
        }

        return std.mem.lessThan(u8, lhs.label, rhs.label);
    }

    fn writeSeparator(writer: anytype, widths: TableWidths) !void {
        try writer.writeByte('+');
        try writeRepeated(writer, '-', widths.metric + 2);
        try writer.writeByte('+');
        try writeRepeated(writer, '-', widths.calls + 2);
        try writer.writeByte('+');
        try writeRepeated(writer, '-', widths.avg + 2);
        try writer.writeByte('+');
        try writeRepeated(writer, '-', widths.p85 + 2);
        try writer.writeByte('+');
        try writeRepeated(writer, '-', widths.total + 2);
        try writer.writeByte('+');
        try writeRepeated(writer, '-', widths.percent_total + 2);
        try writer.writeAll("+\n");
    }

    fn writeHeader(
        writer: anytype,
        widths: TableWidths,
        avg_header: []const u8,
        p85_header: []const u8,
        total_header: []const u8,
    ) !void {
        try writer.writeAll("| ");
        try writeCellLeft(writer, "Metric", widths.metric, false);
        try writer.writeAll(" | ");
        try writeCellRight(writer, "Calls", widths.calls);
        try writer.writeAll(" | ");
        try writeCellRight(writer, avg_header, widths.avg);
        try writer.writeAll(" | ");
        try writeCellRight(writer, p85_header, widths.p85);
        try writer.writeAll(" | ");
        try writeCellRight(writer, total_header, widths.total);
        try writer.writeAll(" | ");
        try writeCellRight(writer, "% Total", widths.percent_total);
        try writer.writeAll(" |\n");
    }

    fn writeMetricRow(
        writer: anytype,
        widths: TableWidths,
        row: MetricTableRow,
        total_exact: u128,
    ) !void {
        var calls_buffer: [32]u8 = undefined;
        var avg_buffer: [32]u8 = undefined;
        var p85_buffer: [32]u8 = undefined;
        var total_buffer: [32]u8 = undefined;
        var percent_buffer: [32]u8 = undefined;

        const calls_text = std.fmt.bufPrint(&calls_buffer, "{d}", .{row.calls}) catch unreachable;
        const avg_text = std.fmt.bufPrint(&avg_buffer, "{d}", .{row.avg}) catch unreachable;
        const p85_text = std.fmt.bufPrint(&p85_buffer, "{d}", .{row.p85}) catch unreachable;
        const total_text = std.fmt.bufPrint(&total_buffer, "{d}", .{row.total}) catch unreachable;
        const percent_text = formatPercent(row.total_exact, total_exact, &percent_buffer);

        try writer.writeAll("| ");
        try writeCellLeft(writer, row.label, widths.metric, true);
        try writer.writeAll(" | ");
        try writeCellRight(writer, calls_text, widths.calls);
        try writer.writeAll(" | ");
        try writeCellRight(writer, avg_text, widths.avg);
        try writer.writeAll(" | ");
        try writeCellRight(writer, p85_text, widths.p85);
        try writer.writeAll(" | ");
        try writeCellRight(writer, total_text, widths.total);
        try writer.writeAll(" | ");
        try writeCellRight(writer, percent_text, widths.percent_total);
        try writer.writeAll(" |\n");
    }

    fn formatPercent(part: u128, whole: u128, buffer: *[32]u8) []const u8 {
        if (whole == 0) {
            return "0.00%";
        }

        const ratio = @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(whole));
        const percent = ratio * 100.0;
        return std.fmt.bufPrint(buffer, "{d:.2}%", .{percent}) catch unreachable;
    }

    fn percentileNearestRank(
        allocator: std.mem.Allocator,
        values: []const u64,
        percentile: u8,
    ) u64 {
        std.debug.assert(percentile <= 100);

        if (values.len == 0) {
            return 0;
        }

        const sorted = allocator.dupe(u64, values) catch |err| {
            @panic(@errorName(err));
        };
        defer allocator.free(sorted);

        std.sort.heap(u64, sorted, {}, std.sort.asc(u64));

        const percentile_usize: usize = percentile;
        std.debug.assert(values.len <= (std.math.maxInt(usize) - 99) / 100);
        var rank = (values.len * percentile_usize + 99) / 100;
        if (rank == 0) {
            rank = 1;
        }
        if (rank > values.len) {
            rank = values.len;
        }

        return sorted[rank - 1];
    }

    fn saturatingToU64(value: u128) u64 {
        std.debug.assert(value <= std.math.maxInt(u128));
        std.debug.assert(std.math.maxInt(u64) <= std.math.maxInt(u128));

        if (value > std.math.maxInt(u64)) {
            return std.math.maxInt(u64);
        }

        return @intCast(value);
    }

    fn writeCellLeft(writer: anytype, text: []const u8, width: usize, truncate: bool) !void {
        std.debug.assert(width > 0);

        if (text.len <= width) {
            try writer.writeAll(text);
            try writeRepeated(writer, ' ', width - text.len);
            return;
        }

        if (!truncate or width <= 3) {
            try writer.writeAll(text[0..width]);
            return;
        }

        const preserved_len = width - 3;
        try writer.writeAll(text[0..preserved_len]);
        try writer.writeAll("...");
    }

    fn writeCellRight(writer: anytype, text: []const u8, width: usize) !void {
        std.debug.assert(width > 0);

        if (text.len >= width) {
            try writer.writeAll(text);
            return;
        }

        try writeRepeated(writer, ' ', width - text.len);
        try writer.writeAll(text);
    }

    fn writeRepeated(writer: anytype, byte: u8, count: usize) !void {
        var index: usize = 0;
        while (index < count) : (index += 1) {
            try writer.writeByte(byte);
        }
    }

    fn decimalDigits(value: u64) usize {
        var digits: usize = 1;
        var remaining = value;

        while (remaining >= 10) {
            remaining /= 10;
            digits += 1;
        }

        return digits;
    }
};

const disabled_impl = struct {
    /// API-compatible no-op profiler used when snitch is disabled.
    pub const ProfilerType = struct {
        base_allocator: std.mem.Allocator,

        pub fn init(base_allocator: std.mem.Allocator) callconv(callingConvention()) ProfilerType {
            return .{ .base_allocator = base_allocator };
        }

        pub fn allocator(self: *ProfilerType) callconv(callingConvention()) std.mem.Allocator {
            return self.base_allocator;
        }

        pub fn deinit(self: *ProfilerType) callconv(callingConvention()) void {
            _ = self;
        }

        pub fn zone(self: *ProfilerType, comptime label: []const u8) callconv(callingConvention()) ZoneType {
            _ = self;
            _ = label;
            return .{};
        }

        pub fn writeReport(self: *ProfilerType, writer: anytype) callconv(callingConvention()) !void {
            _ = self;
            _ = writer;
        }
    };

    pub const ZoneType = struct {
        pub fn end(self: *ZoneType) callconv(callingConvention()) void {
            _ = self;
        }
    };

    pub fn measureCall(
        profiler: *ProfilerType,
        comptime label: []const u8,
        function: anytype,
        args: anytype,
    ) callconv(callingConvention()) @TypeOf(@call(.auto, function, args)) {
        _ = profiler;
        _ = label;
        return @call(.auto, function, args);
    }

    pub fn measureBlock(
        profiler: *ProfilerType,
        comptime label: []const u8,
        block: anytype,
    ) callconv(callingConvention()) @TypeOf(block()) {
        _ = profiler;
        _ = label;
        return block();
    }
};

/// Inline in disabled mode so instrumentation calls compile away.
fn callingConvention() std.builtin.CallingConvention {
    return if (!enabled) .@"inline" else .auto;
}

const implementation = if (enabled) enabled_impl else disabled_impl;

/// Primary profiling handle.
pub const Profiler = implementation.ProfilerType;

/// Active measurement zone handle.
pub const Zone = implementation.ZoneType;

/// Measure a function call and return the wrapped function result.
pub const measureCall = implementation.measureCall;

/// Measure an arbitrary block and return the block result.
pub const measureBlock = implementation.measureBlock;

/// Start a zone using the callsite file and line as the label.
pub fn zoneHere(
    profiler: *Profiler,
    comptime source_location: std.builtin.SourceLocation,
) callconv(callingConvention()) Zone {
    return profiler.zone(comptimeSourceLabel(source_location));
}

/// Measure a call using the callsite file and line as the label.
pub fn measureCallHere(
    profiler: *Profiler,
    function: anytype,
    args: anytype,
    comptime source_location: std.builtin.SourceLocation,
) callconv(callingConvention()) @TypeOf(@call(.auto, function, args)) {
    return measureCall(profiler, comptimeSourceLabel(source_location), function, args);
}

/// Measure a block using the callsite file and line as the label.
pub fn measureBlockHere(
    profiler: *Profiler,
    block: anytype,
    comptime source_location: std.builtin.SourceLocation,
) callconv(callingConvention()) @TypeOf(block()) {
    return measureBlock(profiler, comptimeSourceLabel(source_location), block);
}

/// Convenience helper for writing the report directly to stdout.
pub fn writeReportStdout(
    profiler: *Profiler,
    comptime buffer_size: usize,
) callconv(callingConvention()) !void {
    if (comptime !enabled) {
        return;
    }

    if (comptime buffer_size == 0) {
        @compileError("buffer_size must be greater than zero");
    }

    var stdout_buffer: [buffer_size]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    try profiler.writeReport(&stdout_writer.interface);
    try stdout_writer.end();
}

fn comptimeSourceLabel(comptime source_location: std.builtin.SourceLocation) []const u8 {
    return std.fmt.comptimePrint(
        "{s}:{d}",
        .{ source_location.file, source_location.line },
    );
}
