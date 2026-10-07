//! Snitch is a small profiler for code you suspect is on the hot path.
//!
//! Instrumentation calls stay in your source permanently. Build flags decide
//! whether they record metrics or compile down to nothing.
//!
//! # Build flags
//!
//! - `-Dsnitch`: master switch (default `false`).
//! - `-Dsnitch-timing`: record execution time (default `true`).
//! - `-Dsnitch-memory`: record allocations (default `true`).
//!
//! # Notes
//!
//! - Name a zone with a comptime string, or with `@src()` to label it with the
//!   calling function, file and line. Zig cannot capture the caller's location
//!   implicitly, so `@src()` has to be passed.
//! - Memory metrics count allocations made through `snitch.allocator()` (or
//!   `Profiler.allocator()`) on the thread that ran the zone. End a zone on
//!   the thread that started it.
//! - Percentiles come from a fixed-size histogram and may read up to 1/64
//!   (about 1.6%) above the true value. Averages, totals and maxima are exact.
//! - A program can use at most 1024 distinct zone labels.
//!
//! # Example
//!
//! ```zig
//! const std = @import("std");
//! const snitch = @import("snitch");
//!
//! pub fn main(init: std.process.Init) !void {
//!     snitch.start(init.io, init.gpa);
//!     defer snitch.finish(.{}); // prints the report to stderr
//!
//!     {
//!         var zone = snitch.zone("db-query");
//!         defer zone.end();
//!
//!         const tracked_allocator = snitch.allocator();
//!         const payload = try tracked_allocator.alloc(u8, 256);
//!         defer tracked_allocator.free(payload);
//!     }
//!
//!     var here = snitch.zone(@src()); // labeled like "main (main.zig:42)"
//!     defer here.end();
//!
//!     _ = snitch.measureCall("handler", handler, .{ arg1, arg2 });
//! }
//! ```
const std = @import("std");
const build_options = @import("build_options");

/// True when instrumentation is enabled with `-Dsnitch=true`.
pub const enabled = build_options.snitch;

/// True when snitch is enabled and timing metrics are on.
pub const timing_enabled = enabled and build_options.snitch_timing;

/// True when snitch is enabled and memory metrics are on.
pub const memory_enabled = enabled and build_options.snitch_memory;

/// How a report is laid out.
pub const ReportOptions = struct {
    /// Rows per table, sorted by total; `0` shows every zone.
    max_rows: usize = 0,
};

/// Upper bound on distinct zone labels in one program.
const max_labels = 1024;

// Allocation counters for the current thread. A zone reads them when it
// starts and ends, so allocations on other threads never leak into it.
// Every profiler shares them, so a zone also counts allocations made on
// its thread through a different profiler's allocator.
threadlocal var thread_alloc_bytes: u64 = 0;
threadlocal var thread_alloc_calls: u64 = 0;

const TrackingAllocator = struct {
    parent: std.mem.Allocator,

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

    fn record(bytes: usize) void {
        thread_alloc_bytes +%= bytes;
        thread_alloc_calls +%= 1;
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
            record(len);
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

        if (resized and new_len > memory.len) {
            record(new_len - memory.len);
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

        if (pointer != null and new_len > memory.len) {
            record(new_len - memory.len);
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

/// Process-wide list of zone labels. Each label is registered on first use
/// and its index picks the profiler slot that stores its metrics.
const registry = struct {
    var lock: std.atomic.Mutex = .unlocked;
    var names: [max_labels][]const u8 = undefined;
    var len: std.atomic.Value(u32) = .init(0);

    fn register(name: []const u8) u32 {
        while (!lock.tryLock()) {
            std.atomic.spinLoopHint();
        }
        defer lock.unlock();

        const count = len.load(.monotonic);
        for (names[0..count], 0..) |existing, index| {
            if (std.mem.eql(u8, existing, name)) {
                return @intCast(index);
            }
        }

        if (count == max_labels) {
            @panic(std.fmt.comptimePrint("snitch supports at most {d} distinct zone labels", .{max_labels}));
        }

        names[count] = name;
        len.store(count + 1, .release);
        return count;
    }

    fn labels() []const []const u8 {
        return names[0..len.load(.acquire)];
    }
};

/// Index of `label` in the registry. Only the first call for each label
/// takes the registry lock; later calls read a cached value.
fn labelIndex(comptime label: []const u8) u32 {
    const unregistered = std.math.maxInt(u32);
    // Referencing `label` makes this a distinct type, and so a distinct
    // static, for every label.
    const cache = struct {
        const name = label;
        var index: std.atomic.Value(u32) = .init(unregistered);
    };

    const cached = cache.index.load(.monotonic);
    if (cached != unregistered) {
        return cached;
    }

    const index = registry.register(label);
    cache.index.store(index, .monotonic);
    return index;
}

/// Fixed-size, lock-free histogram of u64 values.
///
/// Values below 128 get one bucket each. Each power of two above that is
/// split into 64 buckets, so a percentile read from a bucket's upper bound
/// is at most 1/64 (about 1.6%) above the true value.
const Histogram = struct {
    const sub_bits = 7;
    const sub_count = 1 << sub_bits;
    const half_count = sub_count / 2;
    const bucket_count = sub_count + (64 - sub_bits) * half_count;

    buckets: [bucket_count]u64 = @splat(0),
    total: u64 = 0,
    max: u64 = 0,

    fn bucketIndex(value: u64) usize {
        if (value < sub_count) {
            return @intCast(value);
        }

        const shift = std.math.log2_int(u64, value) - (sub_bits - 1);
        const mantissa: usize = @intCast(value >> shift);
        return sub_count + (@as(usize, shift) - 1) * half_count + (mantissa - half_count);
    }

    fn bucketUpperBound(index: usize) u64 {
        if (index < sub_count) {
            return index;
        }

        const offset = index - sub_count;
        const shift: u6 = @intCast(offset / half_count + 1);
        const mantissa: u64 = offset % half_count + half_count;
        return (mantissa << shift) | ((@as(u64, 1) << shift) - 1);
    }

    fn observe(self: *Histogram, value: u64) void {
        _ = @atomicRmw(u64, &self.buckets[bucketIndex(value)], .Add, 1, .monotonic);

        // Skipping no-op updates avoids contended atomics on the common
        // paths: zones that allocate nothing, and values below the max.
        if (value != 0) {
            _ = @atomicRmw(u64, &self.total, .Add, value, .monotonic);
        }
        if (value > @atomicLoad(u64, &self.max, .monotonic)) {
            _ = @atomicRmw(u64, &self.max, .Max, value, .monotonic);
        }
    }

    fn count(self: *const Histogram) u64 {
        var sum: u64 = 0;
        for (&self.buckets) |*bucket| {
            sum += @atomicLoad(u64, bucket, .monotonic);
        }
        return sum;
    }

    /// Nearest-rank percentile, reported as the upper bound of the bucket
    /// holding it and capped at the largest value seen.
    fn percentile(self: *const Histogram, samples: u64, target: u8) u64 {
        std.debug.assert(samples > 0);
        const rank = @max(1, (samples * target + 99) / 100);

        var seen: u64 = 0;
        for (&self.buckets, 0..) |*bucket, index| {
            seen += @atomicLoad(u64, bucket, .monotonic);
            if (seen >= rank) {
                return @min(bucketUpperBound(index), @atomicLoad(u64, &self.max, .monotonic));
            }
        }

        // Buckets only grow, so `samples` (counted earlier) is always reached.
        unreachable;
    }
};

const TimingHistogram = if (timing_enabled) Histogram else void;
const MemoryHistogram = if (memory_enabled) Histogram else void;

/// Metrics for one label.
const Slot = struct {
    timing: TimingHistogram = if (timing_enabled) .{} else {},
    alloc_bytes: MemoryHistogram = if (memory_enabled) .{} else {},
    alloc_calls: MemoryHistogram = if (memory_enabled) .{} else {},

    /// Number of recorded zones, or 0 when no metric group is enabled.
    fn calls(self: *const Slot) u64 {
        if (timing_enabled) return self.timing.count();
        if (memory_enabled) return self.alloc_calls.count();
        return 0;
    }
};

/// Disabled builds inline every call so instrumentation compiles away.
fn callingConvention() std.builtin.CallingConvention {
    return if (!enabled) .@"inline" else .auto;
}

/// Collects metrics per zone label. Most programs can use the process-wide
/// profiler through `start`, `zone` and `finish` instead of creating one.
///
/// When snitch is disabled, every method is an inlined no-op.
pub const Profiler = struct {
    io: std.Io,
    base_allocator: std.mem.Allocator,
    tracking_allocator_state: TrackingAllocator,
    slots: if (enabled) [max_labels]?*Slot else void,

    /// Create a profiler. `io` provides the clock; `base_allocator` holds
    /// the profiler's own storage and must be thread-safe if zones end on
    /// several threads.
    pub fn init(io: std.Io, base_allocator: std.mem.Allocator) callconv(callingConvention()) Profiler {
        return .{
            .io = io,
            .base_allocator = base_allocator,
            .tracking_allocator_state = .{ .parent = base_allocator },
            .slots = if (enabled) @splat(null) else {},
        };
    }

    /// Free all recorded metrics.
    pub fn deinit(self: *Profiler) callconv(callingConvention()) void {
        if (enabled) {
            for (self.slots) |maybe_slot| {
                if (maybe_slot) |slot| {
                    self.base_allocator.destroy(slot);
                }
            }
        }

        self.* = undefined;
    }

    /// Allocator whose allocations count towards memory metrics. Use it in the
    /// code you are measuring.
    pub fn allocator(self: *Profiler) callconv(callingConvention()) std.mem.Allocator {
        if (memory_enabled) {
            return self.tracking_allocator_state.allocator();
        }

        return self.base_allocator;
    }

    /// Start a zone named by `name`: a string, or `@src()` to use the caller's
    /// function, file and line. Call `end` on the result to record it.
    pub fn zone(self: *Profiler, comptime name: anytype) callconv(callingConvention()) Zone {
        if (comptime !enabled) {
            return .{};
        }

        return .{
            .profiler = self,
            .label_index = labelIndex(zoneLabel(name)),
            .start_alloc_bytes = thread_alloc_bytes,
            .start_alloc_calls = thread_alloc_calls,
            .start = if (timing_enabled) .now(self.io, .awake) else {},
        };
    }

    /// Call `function` with `args` inside a zone named by `name`, and return
    /// its result.
    pub fn measureCall(
        self: *Profiler,
        comptime name: anytype,
        function: anytype,
        args: anytype,
    ) callconv(callingConvention()) @TypeOf(@call(.auto, function, args)) {
        var measurement = self.zone(name);
        defer measurement.end();
        return @call(.auto, function, args);
    }

    /// Write the report to stderr.
    pub fn printReport(self: *Profiler, options: ReportOptions) callconv(callingConvention()) !void {
        if (comptime !enabled) {
            return;
        }

        var buffer: [4_096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(self.io, &buffer);
        try self.writeReport(&stderr_writer.interface, options);
        try stderr_writer.interface.flush();
    }

    /// Write the report as ASCII tables.
    pub fn writeReport(self: *Profiler, writer: *std.Io.Writer, options: ReportOptions) callconv(callingConvention()) !void {
        if (comptime !enabled) {
            return;
        }

        const labels = registry.labels();
        const entries = try self.base_allocator.alloc(LabeledSlot, labels.len);
        defer self.base_allocator.free(entries);

        var entry_count: usize = 0;
        for (labels, 0..) |label, index| {
            const slot = @atomicLoad(?*Slot, &self.slots[index], .acquire) orelse continue;
            entries[entry_count] = .{ .label = label, .slot = slot };
            entry_count += 1;
        }

        try writeReportEntries(self.base_allocator, writer, entries[0..entry_count], options);
    }

    /// Slot for a label index, created on first use. Racing threads may
    /// both allocate one; the loser frees its copy.
    fn slotFor(self: *Profiler, index: u32) *Slot {
        const target = &self.slots[index];
        if (@atomicLoad(?*Slot, target, .acquire)) |existing| {
            return existing;
        }

        const created = self.base_allocator.create(Slot) catch |err| {
            @panic(@errorName(err));
        };
        created.* = .{};

        if (@cmpxchgStrong(?*Slot, target, null, created, .acq_rel, .acquire)) |winner| {
            self.base_allocator.destroy(created);
            return winner.?;
        }

        return created;
    }

    fn record(self: *Profiler, label_index: u32, elapsed_ns: u64, alloc_bytes: u64, alloc_calls: u64) void {
        const target = self.slotFor(label_index);

        if (timing_enabled) {
            target.timing.observe(elapsed_ns);
        }

        if (memory_enabled) {
            target.alloc_bytes.observe(alloc_bytes);
            target.alloc_calls.observe(alloc_calls);
        }
    }
};

/// A measurement in progress. Call `end` exactly once, on the thread that
/// started it.
pub const Zone = if (enabled) struct {
    /// Null for zones started before `snitch.start`; ending them does nothing.
    profiler: ?*Profiler,
    label_index: u32,
    start_alloc_bytes: u64,
    start_alloc_calls: u64,
    start: if (timing_enabled) std.Io.Timestamp else void,
    finished: bool = false,

    const inactive: Zone = .{
        .profiler = null,
        .label_index = 0,
        .start_alloc_bytes = 0,
        .start_alloc_calls = 0,
        .start = undefined,
    };

    /// Stop measuring and record the sample.
    pub fn end(self: *Zone) void {
        std.debug.assert(!self.finished);
        const profiler = self.profiler orelse return;

        const elapsed_ns: u64 = if (timing_enabled) blk: {
            const now = std.Io.Timestamp.now(profiler.io, .awake);
            const elapsed = self.start.durationTo(now).toNanoseconds();
            std.debug.assert(elapsed >= 0);
            break :blk @intCast(elapsed);
        } else 0;

        profiler.record(
            self.label_index,
            elapsed_ns,
            thread_alloc_bytes -% self.start_alloc_bytes,
            thread_alloc_calls -% self.start_alloc_calls,
        );
        self.finished = true;
    }
} else struct {
    pub inline fn end(_: *Zone) void {}
};

// ---------------------------------------------------------------------------
// Report

const LabeledSlot = struct {
    label: []const u8,
    slot: *const Slot,
};

const Unit = enum { time, bytes };

const Row = struct {
    label: []const u8,
    calls: u64,
    avg: u64,
    p50: u64,
    p95: u64,
    p99: u64,
    max: u64,
    total: u64,
    /// Average allocation calls per zone; only shown in the memory table.
    allocs_per_call: f64,

    fn fromHistogram(label: []const u8, histogram: *const Histogram) Row {
        const calls = histogram.count();
        const total = @atomicLoad(u64, &histogram.total, .monotonic);
        if (calls == 0) {
            return .{ .label = label, .calls = 0, .avg = 0, .p50 = 0, .p95 = 0, .p99 = 0, .max = 0, .total = total, .allocs_per_call = 0 };
        }

        return .{
            .label = label,
            .calls = calls,
            .avg = total / calls,
            .p50 = histogram.percentile(calls, 50),
            .p95 = histogram.percentile(calls, 95),
            .p99 = histogram.percentile(calls, 99),
            .max = @atomicLoad(u64, &histogram.max, .monotonic),
            .total = total,
            .allocs_per_call = 0,
        };
    }

    fn moreTotalFirst(_: void, lhs: Row, rhs: Row) bool {
        if (lhs.total != rhs.total) {
            return lhs.total > rhs.total;
        }
        return std.mem.lessThan(u8, lhs.label, rhs.label);
    }
};

const max_label_width = 40;
const cell_capacity = max_label_width;
const timing_columns = [_][]const u8{ "Zone", "Calls", "Avg", "P50", "P95", "P99", "Max", "Total", "% Total" };
const memory_columns = [_][]const u8{ "Zone", "Calls", "Avg", "P50", "P95", "P99", "Max", "Total", "Allocs/call", "% Total" };

fn writeReportEntries(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    entries: []const LabeledSlot,
    options: ReportOptions,
) !void {
    try writer.print("[snitch] {d} zone{s}\n", .{ entries.len, if (entries.len == 1) "" else "s" });

    if (entries.len == 0) {
        return;
    }

    if (!timing_enabled and !memory_enabled) {
        try writer.writeAll("Both snitch-timing and snitch-memory are disabled, so there is nothing to show.\n");
        return;
    }

    const rows = try gpa.alloc(Row, entries.len);
    defer gpa.free(rows);

    if (timing_enabled) {
        for (entries, rows) |entry, *row| {
            row.* = .fromHistogram(entry.label, &entry.slot.timing);
        }
        try writer.writeAll("\nTiming per call\n");
        try writeTable(writer, .time, &timing_columns, rows, options);
    }

    if (memory_enabled) {
        // Zones that allocated nothing would only add rows of zeros.
        var allocating: usize = 0;
        for (entries) |entry| {
            const row: Row = .fromHistogram(entry.label, &entry.slot.alloc_bytes);
            if (row.total == 0) continue;
            const allocs = @atomicLoad(u64, &entry.slot.alloc_calls.total, .monotonic);
            rows[allocating] = row;
            rows[allocating].allocs_per_call = @as(f64, @floatFromInt(allocs)) / @as(f64, @floatFromInt(row.calls));
            allocating += 1;
        }

        try writer.writeAll("\nMemory allocated per call\n");
        if (allocating == 0) {
            try writer.writeAll("(no zone allocated through the tracked allocator)\n");
        } else {
            try writeTable(writer, .bytes, &memory_columns, rows[0..allocating], options);
        }
    }
}

fn writeTable(
    writer: *std.Io.Writer,
    comptime unit: Unit,
    comptime header: []const []const u8,
    rows: []Row,
    options: ReportOptions,
) !void {
    const column_count = header.len;
    const Cells = [column_count][]const u8;
    const Buffers = [column_count][cell_capacity]u8;

    std.sort.pdq(Row, rows, {}, Row.moreTotalFirst);
    const visible = if (options.max_rows == 0) rows else rows[0..@min(rows.len, options.max_rows)];

    var grand_total: u128 = 0;
    for (rows) |row| {
        grand_total += row.total;
    }

    var widths: [column_count]usize = undefined;
    for (&widths, header) |*width, cell| {
        width.* = cell.len;
    }
    for (visible) |row| {
        var buffers: Buffers = undefined;
        for (&widths, try rowCells(unit, column_count, row, grand_total, &buffers)) |*width, cell| {
            width.* = @max(width.*, cell.len);
        }
    }

    try writeSeparator(writer, &widths);
    try writeRow(writer, &widths, header);
    try writeSeparator(writer, &widths);
    for (visible) |row| {
        var buffers: Buffers = undefined;
        const cells: Cells = try rowCells(unit, column_count, row, grand_total, &buffers);
        try writeRow(writer, &widths, &cells);
    }
    try writeSeparator(writer, &widths);

    if (visible.len < rows.len) {
        try writer.print(
            "(showing the top {d} of {d} zones)\n",
            .{ visible.len, rows.len },
        );
    }
}

fn rowCells(
    comptime unit: Unit,
    comptime column_count: usize,
    row: Row,
    grand_total: u128,
    buffers: *[column_count][cell_capacity]u8,
) ![column_count][]const u8 {
    const format = switch (unit) {
        .time => formatDuration,
        .bytes => formatBytes,
    };

    var cells: [column_count][]const u8 = undefined;
    cells[0] = truncateLabel(row.label, buffers[0][0..max_label_width]);
    cells[1] = try formatCount(row.calls, &buffers[1]);
    cells[2] = try format(row.avg, &buffers[2]);
    cells[3] = try format(row.p50, &buffers[3]);
    cells[4] = try format(row.p95, &buffers[4]);
    cells[5] = try format(row.p99, &buffers[5]);
    cells[6] = try format(row.max, &buffers[6]);
    cells[7] = try format(row.total, &buffers[7]);
    if (unit == .bytes) {
        cells[8] = try std.fmt.bufPrint(&buffers[8], "{d:.2}", .{row.allocs_per_call});
    }
    cells[column_count - 1] = try formatPercent(row.total, grand_total, &buffers[column_count - 1]);
    return cells;
}

fn writeSeparator(writer: *std.Io.Writer, widths: []const usize) !void {
    for (widths) |width| {
        try writer.writeByte('+');
        try writer.splatByteAll('-', width + 2);
    }
    try writer.writeAll("+\n");
}

/// The zone column is left-aligned; the numeric columns are right-aligned.
fn writeRow(writer: *std.Io.Writer, widths: []const usize, cells: []const []const u8) !void {
    for (cells, widths, 0..) |cell, width, column| {
        if (column == 0) {
            try writer.print("| {s:<[1]} ", .{ cell, width });
        } else {
            try writer.print("| {s:>[1]} ", .{ cell, width });
        }
    }
    try writer.writeAll("|\n");
}

fn truncateLabel(label: []const u8, buffer: *[max_label_width]u8) []const u8 {
    if (label.len <= max_label_width) {
        return label;
    }

    const kept = max_label_width - "...".len;
    @memcpy(buffer[0..kept], label[0..kept]);
    @memcpy(buffer[kept..], "...");
    return buffer;
}

/// Scale `value` to the largest unit it reaches and print three significant
/// digits, e.g. "1.23 ms" or "456 KiB".
fn formatScaled(value: u64, comptime units: []const []const u8, comptime step: f64, buffer: []u8) ![]const u8 {
    if (value < step) {
        return std.fmt.bufPrint(buffer, "{d} {s}", .{ value, units[0] });
    }

    var scaled: f64 = @floatFromInt(value);
    var unit_index: usize = 0;
    // Stepping up at 999.5 keeps rounding from printing "1000 us".
    while (scaled >= step - 0.5 and unit_index + 1 < units.len) {
        scaled /= step;
        unit_index += 1;
    }

    if (scaled < 9.995) {
        return std.fmt.bufPrint(buffer, "{d:.2} {s}", .{ scaled, units[unit_index] });
    }
    if (scaled < 99.95) {
        return std.fmt.bufPrint(buffer, "{d:.1} {s}", .{ scaled, units[unit_index] });
    }
    return std.fmt.bufPrint(buffer, "{d:.0} {s}", .{ scaled, units[unit_index] });
}

fn formatDuration(ns: u64, buffer: []u8) std.fmt.BufPrintError![]const u8 {
    return formatScaled(ns, &.{ "ns", "us", "ms", "s" }, 1000, buffer);
}

fn formatBytes(bytes: u64, buffer: []u8) std.fmt.BufPrintError![]const u8 {
    return formatScaled(bytes, &.{ "B", "KiB", "MiB", "GiB", "TiB" }, 1024, buffer);
}

/// Integer with thousands separators, e.g. "1,234,567".
fn formatCount(value: u64, buffer: []u8) std.fmt.BufPrintError![]const u8 {
    var digits_buffer: [20]u8 = undefined;
    const digits = try std.fmt.bufPrint(&digits_buffer, "{d}", .{value});

    var len: usize = 0;
    for (digits, 0..) |digit, index| {
        if (index > 0 and (digits.len - index) % 3 == 0) {
            buffer[len] = ',';
            len += 1;
        }
        buffer[len] = digit;
        len += 1;
    }
    return buffer[0..len];
}

fn formatPercent(part: u64, whole: u128, buffer: []u8) ![]const u8 {
    if (whole == 0) {
        return "0.00%";
    }

    const ratio = @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(whole));
    return std.fmt.bufPrint(buffer, "{d:.2}%", .{ratio * 100.0});
}

/// Zone label for `name`: the string itself, or "function (file:line)" for
/// a source location from `@src()`.
fn zoneLabel(comptime name: anytype) []const u8 {
    const Name = @TypeOf(name);
    if (Name == std.builtin.SourceLocation) {
        return std.fmt.comptimePrint("{s} ({s}:{d})", .{ name.fn_name, name.file, name.line });
    }

    const label: []const u8 = switch (@typeInfo(Name)) {
        .pointer => name,
        else => @compileError("zone name must be a string or @src(), found " ++ @typeName(Name)),
    };
    if (label.len == 0) {
        @compileError("zone name must not be empty");
    }
    return label;
}

// ---------------------------------------------------------------------------
// Process-wide profiler

var default_profiler: Profiler = undefined;
var default_started: std.atomic.Value(bool) = .init(false);

/// Start the process-wide profiler. Call it once, before any zones you want
/// recorded; zones started earlier are ignored. `base_allocator` must be
/// thread-safe if zones end on several threads.
pub fn start(io: std.Io, base_allocator: std.mem.Allocator) callconv(callingConvention()) void {
    std.debug.assert(!default_started.load(.monotonic));
    default_profiler = .init(io, base_allocator);
    default_started.store(true, .release);
}

/// Print the process-wide profiler's report to stderr, then free it. Call it
/// after every zone has ended, typically with `defer` right after `start`.
pub fn finish(options: ReportOptions) callconv(callingConvention()) void {
    if (!default_started.load(.acquire)) {
        return;
    }

    default_profiler.printReport(options) catch {};
    stop();
}

/// Free the process-wide profiler without printing a report.
pub fn stop() callconv(callingConvention()) void {
    if (!default_started.swap(false, .acq_rel)) {
        return;
    }

    default_profiler.deinit();
}

/// The process-wide profiler, or null before `start` and after `finish`.
pub fn defaultProfiler() callconv(callingConvention()) ?*Profiler {
    return if (default_started.load(.acquire)) &default_profiler else null;
}

/// Allocator whose allocations count towards the process-wide profiler's
/// memory metrics. Panics if called before `start`.
pub fn allocator() callconv(callingConvention()) std.mem.Allocator {
    const profiler = defaultProfiler() orelse @panic("snitch.allocator() called before snitch.start()");
    return profiler.allocator();
}

/// Start a zone on the process-wide profiler, named by a string or `@src()`.
/// Call `end` on the result.
pub fn zone(comptime name: anytype) callconv(callingConvention()) Zone {
    if (comptime !enabled) {
        return .{};
    }

    const profiler = defaultProfiler() orelse return .inactive;
    return profiler.zone(name);
}

/// Call `function` with `args` inside a process-wide zone named by `name`,
/// and return its result.
pub fn measureCall(
    comptime name: anytype,
    function: anytype,
    args: anytype,
) callconv(callingConvention()) @TypeOf(@call(.auto, function, args)) {
    var measurement = zone(name);
    defer measurement.end();
    return @call(.auto, function, args);
}

test "histogram buckets cover u64 and bound the error at 1/64" {
    var value: u64 = 0;
    while (value < 4_096) : (value += 1) {
        const upper = Histogram.bucketUpperBound(Histogram.bucketIndex(value));
        try std.testing.expect(upper >= value);
        try std.testing.expect(upper - value <= value / 64);
    }

    var shift: u6 = 12;
    while (shift < 63) : (shift += 1) {
        for ([_]u64{ @as(u64, 1) << shift, (@as(u64, 1) << shift) + 12_345, (@as(u64, 1) << (shift + 1)) - 1 }) |sample| {
            const upper = Histogram.bucketUpperBound(Histogram.bucketIndex(sample));
            try std.testing.expect(upper >= sample);
            try std.testing.expect(upper - sample <= sample / 64);
        }
    }

    try std.testing.expectEqual(Histogram.bucket_count - 1, Histogram.bucketIndex(std.math.maxInt(u64)));
    try std.testing.expectEqual(std.math.maxInt(u64), Histogram.bucketUpperBound(Histogram.bucket_count - 1));
}

test "histogram percentile uses nearest rank" {
    const histogram = try std.testing.allocator.create(Histogram);
    defer std.testing.allocator.destroy(histogram);
    histogram.* = .{};

    for (1..101) |value| {
        histogram.observe(value);
    }

    try std.testing.expectEqual(@as(u64, 100), histogram.count());
    try std.testing.expectEqual(@as(u64, 5_050), histogram.total);
    try std.testing.expectEqual(@as(u64, 1), histogram.percentile(100, 1));
    try std.testing.expectEqual(@as(u64, 95), histogram.percentile(100, 95));
    try std.testing.expectEqual(@as(u64, 100), histogram.percentile(100, 100));

    histogram.observe(1_000_000);
    const p100 = histogram.percentile(101, 100);
    try std.testing.expectEqual(@as(u64, 1_000_000), p100);
}

fn labelSlot(profiler: *Profiler, comptime label: []const u8) *const Slot {
    return profiler.slots[labelIndex(label)].?;
}

test "a label used at several call sites shares one slot" {
    if (!timing_enabled and !memory_enabled) return;

    var profiler = Profiler.init(std.testing.io, std.testing.allocator);
    defer profiler.deinit();

    var first = profiler.zone("shared-label");
    first.end();
    var second = profiler.zone("shared-" ++ "label");
    second.end();
    var other = profiler.zone("other-label");
    other.end();

    try std.testing.expectEqual(@as(u64, 2), labelSlot(&profiler, "shared-label").calls());
    try std.testing.expectEqual(@as(u64, 1), labelSlot(&profiler, "other-label").calls());
}

test "zones only count allocations made on their own thread" {
    if (!memory_enabled) return;

    var profiler = Profiler.init(std.testing.io, std.testing.allocator);
    defer profiler.deinit();
    const tracked = profiler.allocator();

    var measurement = profiler.zone("thread-local-allocs");

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(parent: std.mem.Allocator) !void {
            const noise = try parent.alloc(u8, 4_096);
            parent.free(noise);
        }
    }.run, .{tracked});
    thread.join();

    const own = try tracked.alloc(u8, 10);
    tracked.free(own);
    measurement.end();

    const slot = labelSlot(&profiler, "thread-local-allocs");
    try std.testing.expectEqual(@as(u64, 10), slot.alloc_bytes.total);
    try std.testing.expectEqual(@as(u64, 1), slot.alloc_calls.total);
}

test "concurrent zones are all recorded" {
    if (!timing_enabled and !memory_enabled) return;

    var profiler = Profiler.init(std.testing.io, std.heap.smp_allocator);
    defer profiler.deinit();

    const thread_count = 8;
    const zones_per_thread = 10_000;
    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, struct {
            fn run(p: *Profiler) void {
                for (0..zones_per_thread) |_| {
                    var measurement = p.zone("concurrent");
                    measurement.end();
                }
            }
        }.run, .{&profiler});
    }
    for (threads) |thread| {
        thread.join();
    }

    const slot = labelSlot(&profiler, "concurrent");
    try std.testing.expectEqual(@as(u64, thread_count * zones_per_thread), slot.calls());
}

test "report numbers are human readable" {
    const cases = [_]struct { format: *const fn (u64, []u8) std.fmt.BufPrintError![]const u8, value: u64, expected: []const u8 }{
        .{ .format = formatDuration, .value = 999, .expected = "999 ns" },
        .{ .format = formatDuration, .value = 1_234, .expected = "1.23 us" },
        .{ .format = formatDuration, .value = 999_700, .expected = "1.00 ms" },
        .{ .format = formatDuration, .value = 45_600_000, .expected = "45.6 ms" },
        .{ .format = formatDuration, .value = 3_000_000_000_000, .expected = "3000 s" },
        .{ .format = formatBytes, .value = 512, .expected = "512 B" },
        .{ .format = formatBytes, .value = 1_536, .expected = "1.50 KiB" },
        .{ .format = formatBytes, .value = 381_080, .expected = "372 KiB" },
        .{ .format = formatCount, .value = 7, .expected = "7" },
        .{ .format = formatCount, .value = 1_000, .expected = "1,000" },
        .{ .format = formatCount, .value = 12_345_678, .expected = "12,345,678" },
    };
    for (cases) |case| {
        var buffer: [32]u8 = undefined;
        try std.testing.expectEqualStrings(case.expected, try case.format(case.value, &buffer));
    }
}
