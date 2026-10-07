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
//! - `addLayoutStep` adds `zig build snitch-layout`, which prints the size,
//!   alignment and padding of the structs in chosen files; see its docs.
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
//!         const zone = snitch.zone("db-query");
//!         defer zone.end();
//!
//!         const tracked_allocator = snitch.allocator();
//!         const payload = try tracked_allocator.alloc(u8, 256);
//!         defer tracked_allocator.free(payload);
//!     }
//!
//!     const here = snitch.zone(@src()); // labeled like "main (main.zig:42)"
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

/// Safe builds count open zones so freeing a profiler too early panics with a
/// clear message instead of corrupting memory.
const track_open_zones = enabled and std.debug.runtime_safety;

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
    /// Zones started but not yet ended. Only tracked in safe builds, to catch
    /// freeing the profiler while another thread is still inside a zone.
    open_zones: if (track_open_zones) std.atomic.Value(u32) else void,

    /// Create a profiler. `io` provides the clock; `base_allocator` holds
    /// the profiler's own storage and must be thread-safe if zones end on
    /// several threads.
    pub fn init(io: std.Io, base_allocator: std.mem.Allocator) callconv(callingConvention()) Profiler {
        return .{
            .io = io,
            .base_allocator = base_allocator,
            .tracking_allocator_state = .{ .parent = base_allocator },
            .slots = if (enabled) @splat(null) else {},
            .open_zones = if (track_open_zones) .init(0) else {},
        };
    }

    /// Free all recorded metrics. Every zone must have ended.
    pub fn deinit(self: *Profiler) callconv(callingConvention()) void {
        self.assertNoOpenZones();

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

        if (track_open_zones) {
            _ = self.open_zones.fetchAdd(1, .monotonic);
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
        const measurement = self.zone(name);
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

    fn assertNoOpenZones(self: *Profiler) void {
        if (!track_open_zones) {
            return;
        }

        const open = self.open_zones.load(.acquire);
        if (open != 0) {
            std.debug.panic(
                "snitch: profiler freed while {d} zone(s) are still open; end every zone before finish, stop or deinit",
                .{open},
            );
        }
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

/// A measurement in progress. Call `end` once, on the thread that started
/// it; calling it twice records the zone twice.
pub const Zone = if (enabled) struct {
    /// Null for zones started before `snitch.start`; ending them does nothing.
    profiler: ?*Profiler,
    label_index: u32,
    start_alloc_bytes: u64,
    start_alloc_calls: u64,
    start: if (timing_enabled) std.Io.Timestamp else void,

    const inactive: Zone = .{
        .profiler = null,
        .label_index = 0,
        .start_alloc_bytes = 0,
        .start_alloc_calls = 0,
        .start = undefined,
    };

    /// Stop measuring and record the sample.
    pub fn end(self: Zone) void {
        const profiler = self.profiler orelse return;
        if (track_open_zones) {
            _ = profiler.open_zones.fetchSub(1, .release);
        }

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
    }
} else struct {
    pub inline fn end(_: Zone) void {}
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

    if (entries.len > 0) {
        try writeZoneSections(gpa, writer, entries, options);
    }
}

fn writeZoneSections(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    entries: []const LabeledSlot,
    options: ReportOptions,
) !void {
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
    try writeRowCells(writer, &widths, 1, header);
    try writeSeparator(writer, &widths);
    for (visible) |row| {
        var buffers: Buffers = undefined;
        const cells: Cells = try rowCells(unit, column_count, row, grand_total, &buffers);
        try writeRowCells(writer, &widths, 1, &cells);
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

/// The first `text_columns` columns are left-aligned text; the rest are
/// right-aligned numbers.
fn writeRowCells(writer: *std.Io.Writer, widths: []const usize, text_columns: usize, cells: []const []const u8) !void {
    for (cells, widths, 0..) |cell, width, column| {
        if (column < text_columns) {
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
// Layout

/// Memory layout of one struct or union, computed at compile time.
const TypeLayout = struct {
    name: []const u8,
    kind: []const u8,
    size: usize,
    alignment: usize,
    /// Bytes lost to padding, or null when it isn't meaningful (packed
    /// structs, unions).
    padding: ?usize,
    /// Size with fields ordered by alignment, or null when Zig chooses the
    /// order itself or the type is not a struct.
    best_size: ?usize,
    /// Runtime fields in memory order. Empty for packed structs and unions.
    fields: []const FieldLayout,
};

const FieldLayout = struct {
    name: []const u8,
    type_name: []const u8,
    offset: usize,
    size: usize,
    alignment: usize,
    /// Bytes between the end of this field and the next one, or the end of
    /// the struct.
    padding_after: usize,
};

fn describeLayout(comptime T: type) TypeLayout {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| describeStruct(T, info),
        .@"union" => |info| .{
            .name = @typeName(T),
            .kind = if (info.tag_type != null) "tagged union" else switch (info.layout) {
                .auto => "union",
                .@"extern" => "extern union",
                .@"packed" => "packed union",
            },
            .size = @sizeOf(T),
            .alignment = @alignOf(T),
            .padding = null,
            .best_size = null,
            .fields = &.{},
        },
        else => unreachable,
    };
}

fn describeStruct(comptime T: type, comptime info: std.builtin.Type.Struct) TypeLayout {
    if (info.layout == .@"packed") {
        return .{
            .name = @typeName(T),
            .kind = "packed struct",
            .size = @sizeOf(T),
            .alignment = @alignOf(T),
            .padding = null,
            .best_size = null,
            .fields = &.{},
        };
    }

    var fields: [info.field_names.len]FieldLayout = undefined;
    var count: usize = 0;
    var field_bytes: usize = 0;
    for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
        if (attrs.@"comptime" or @sizeOf(Field) == 0) continue;
        fields[count] = .{
            .name = name,
            .type_name = @typeName(Field),
            .offset = @offsetOf(T, name),
            .size = @sizeOf(Field),
            .alignment = attrs.@"align" orelse @alignOf(Field),
            .padding_after = 0,
        };
        field_bytes += @sizeOf(Field);
        count += 1;
    }

    // Zig may reorder auto-layout fields, so sort into memory order.
    std.sort.insertion(FieldLayout, fields[0..count], {}, struct {
        fn lessThan(_: void, lhs: FieldLayout, rhs: FieldLayout) bool {
            return lhs.offset < rhs.offset;
        }
    }.lessThan);

    var padding: usize = 0;
    for (fields[0..count], 0..) |*field, index| {
        const next_offset = if (index + 1 < count) fields[index + 1].offset else @sizeOf(T);
        field.padding_after = next_offset - (field.offset + field.size);
        padding += field.padding_after;
    }
    if (count > 0) {
        padding += fields[0].offset;
    }

    const final = fields[0..count].*;
    return .{
        .name = @typeName(T),
        .kind = if (info.layout == .@"extern") "extern struct" else "struct",
        .size = @sizeOf(T),
        .alignment = @alignOf(T),
        .padding = padding,
        // Ordering fields by descending alignment leaves padding only at the
        // end. Zig already does this for auto layout, so only extern structs
        // can be improved by hand.
        .best_size = if (info.layout == .@"extern") std.mem.alignForward(usize, field_bytes, @alignOf(T)) else null,
        .fields = &final,
    };
}

const layout_columns = [_][]const u8{ "Type", "Kind", "Size", "Align", "Padding", "Best size" };
const field_columns = [_][]const u8{ "Field", "Type", "Offset", "Size", "Align", "Padding after" };

/// Write layout tables for `types`, a tuple of struct and union types: a
/// summary sorted by padding, then a field-by-field breakdown of every type
/// that has padding. `zig build snitch-layout` calls this; see `addLayoutStep`.
pub fn writeLayouts(writer: *std.Io.Writer, comptime types: anytype) !void {
    const layouts = comptime describeLayouts(types);
    try writer.print("[snitch] layout of {d} type{s}\n", .{ layouts.len, if (layouts.len == 1) "" else "s" });
    if (layouts.len == 0) {
        return;
    }

    try writer.writeByte('\n');
    var summary = StringTable(layout_columns.len).init(&layout_columns);
    for (&layouts) |*item| {
        try summary.measure(try layoutCells(item, &summary.buffers));
    }
    try summary.writeHeader(writer);
    for (&layouts) |*item| {
        try summary.writeRow(writer, try layoutCells(item, &summary.buffers));
    }
    try summary.writeFooter(writer);

    for (&layouts) |*item| {
        const padding = item.padding orelse continue;
        if (padding == 0) continue;

        try writer.print("\n{s}\n", .{item.name});
        var table = StringTable(field_columns.len).init(&field_columns);
        for (item.fields) |field| {
            try table.measure(try fieldCells(field, &table.buffers));
        }
        try table.writeHeader(writer);
        for (item.fields) |field| {
            try table.writeRow(writer, try fieldCells(field, &table.buffers));
        }
        try table.writeFooter(writer);
    }
}

/// Layouts of `types`, most padding first. Types without a meaningful
/// padding figure (packed structs, unions) go last.
fn describeLayouts(comptime types: anytype) [types.len]TypeLayout {
    @setEvalBranchQuota(100_000);
    var layouts: [types.len]TypeLayout = undefined;
    for (&layouts, 0..) |*item, index| {
        item.* = describeLayout(types[index]);
    }

    std.sort.insertion(TypeLayout, &layouts, {}, struct {
        fn morePaddingFirst(_: void, lhs: TypeLayout, rhs: TypeLayout) bool {
            const lhs_padding = lhs.padding orelse return false;
            const rhs_padding = rhs.padding orelse return true;
            return lhs_padding > rhs_padding;
        }
    }.morePaddingFirst);
    return layouts;
}

fn layoutCells(item: *const TypeLayout, buffers: *[layout_columns.len][cell_capacity]u8) ![layout_columns.len][]const u8 {
    return .{
        truncateLabel(item.name, buffers[0][0..max_label_width]),
        item.kind,
        try formatBytes(item.size, &buffers[2]),
        try std.fmt.bufPrint(&buffers[3], "{d}", .{item.alignment}),
        if (item.padding) |padding| try formatBytes(padding, &buffers[4]) else "-",
        if (item.best_size) |best_size| try formatBytes(best_size, &buffers[5]) else "-",
    };
}

fn fieldCells(field: FieldLayout, buffers: *[field_columns.len][cell_capacity]u8) ![field_columns.len][]const u8 {
    return .{
        truncateLabel(field.name, buffers[0][0..max_label_width]),
        truncateLabel(field.type_name, buffers[1][0..max_label_width]),
        try std.fmt.bufPrint(&buffers[2], "{d}", .{field.offset}),
        try formatBytes(field.size, &buffers[3]),
        try std.fmt.bufPrint(&buffers[4], "{d}", .{field.alignment}),
        if (field.padding_after == 0) "" else try formatBytes(field.padding_after, &buffers[5]),
    };
}

/// Two-pass ASCII table of string cells: `measure` every row, then write.
/// The first two columns are text, the rest numbers.
fn StringTable(comptime column_count: usize) type {
    return struct {
        const Self = @This();

        header: *const [column_count][]const u8,
        widths: [column_count]usize,
        buffers: [column_count][cell_capacity]u8 = undefined,

        fn init(header: *const [column_count][]const u8) Self {
            var widths: [column_count]usize = undefined;
            for (&widths, header) |*width, cell| {
                width.* = cell.len;
            }
            return .{ .header = header, .widths = widths };
        }

        fn measure(self: *Self, cells: [column_count][]const u8) !void {
            for (&self.widths, cells) |*width, cell| {
                width.* = @max(width.*, cell.len);
            }
        }

        fn writeHeader(self: *Self, writer: *std.Io.Writer) !void {
            try writeSeparator(writer, &self.widths);
            try writeRowCells(writer, &self.widths, 2, self.header);
            try writeSeparator(writer, &self.widths);
        }

        fn writeRow(self: *Self, writer: *std.Io.Writer, cells: [column_count][]const u8) !void {
            try writeRowCells(writer, &self.widths, 2, &cells);
        }

        fn writeFooter(self: *Self, writer: *std.Io.Writer) !void {
            try writeSeparator(writer, &self.widths);
        }
    };
}

// ---------------------------------------------------------------------------
// Build integration
//
// Everything below runs at build time. `build.zig` imports this file directly
// to call `addLayoutStep`, and the build compiles this same file a second time
// as the layout generator, entering through `main`.

/// Name of the declaration the generator appends to each scanned file.
const layout_decl_name = "@\"snitch.layout_types\"";

/// Add `zig build snitch-layout`, which prints the memory layout of every
/// struct and union declared in the files or folders passed with
/// `-Dsnitch-layout`, including private and nested ones:
///
/// ```zig
/// // build.zig
/// const snitch = @import("src/snitch.zig");
/// snitch.addLayoutStep(b, exe.root_module);
/// ```
///
/// ```sh
/// zig build snitch-layout -Dsnitch-layout=src/model.zig,src/net
/// ```
///
/// The step copies the module's source tree into the build cache, appends a
/// list of the found types to each scanned file, and compiles and runs a small
/// probe against the copy. The program itself is never modified. Types made by
/// generic functions and types declared inside function bodies are skipped.
pub fn addLayoutStep(b: *std.Build, module: *std.Build.Module) void {
    addLayoutStepFrom(b, module, b.path(@src().file));
}

/// Like `addLayoutStep`, with `source` as the path of this file. Use it when
/// snitch is not part of the calling build's own sources; the `build.zig` of
/// the snitch package does this for projects that depend on it.
pub fn addLayoutStepFrom(b: *std.Build, module: *std.Build.Module, source: std.Build.LazyPath) void {
    const step = b.step("snitch-layout", "Print struct layouts for the files or folders in -Dsnitch-layout");
    const targets = b.option(
        []const u8,
        "snitch-layout",
        "Comma-separated files or folders, relative to the build root, for zig build snitch-layout",
    ) orelse {
        step.dependOn(&b.addFail("snitch-layout needs -Dsnitch-layout=<files or folders>, e.g. -Dsnitch-layout=src/model.zig,src").step);
        return;
    };

    const root_source = module.root_source_file orelse @panic("snitch.addLayoutStep: the module has no root source file");
    const root_dir = switch (root_source) {
        .src_path => |src| src.owner.path(std.fs.path.dirname(src.sub_path) orelse "."),
        else => @panic("snitch.addLayoutStep: the module's root must be a source file in the project"),
    };

    const generator = b.addExecutable(.{
        .name = "snitch-layout-generator",
        .root_module = b.createModule(.{
            .root_source_file = source,
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const generate = b.addRunArtifact(generator);
    // The generator reads sources the build system doesn't track, so rerun it
    // every time; it is fast, and the probe compile below is cached by content.
    generate.has_side_effects = true;
    generate.setCwd(b.path("."));
    generate.addDirectoryArg(root_dir);
    const generated = generate.addOutputDirectoryArg("snitch-layout");
    generate.addFileArg(source);
    var target_iterator = std.mem.tokenizeScalar(u8, targets, ',');
    while (target_iterator.next()) |target| {
        generate.addArg(std.mem.trim(u8, target, " "));
    }

    const probe_module = b.createModule(.{
        .root_source_file = generated.path(b, "snitch_layout_probe.zig"),
        .target = module.resolved_target orelse b.graph.host,
        .optimize = module.optimize orelse .Debug,
    });
    // The copied sources keep their imports, so give the probe the same ones.
    var layout_module: ?*std.Build.Module = null;
    var imports = module.import_table.iterator();
    while (imports.next()) |entry| {
        probe_module.addImport(entry.key_ptr.*, entry.value_ptr.*);
        // A file can only belong to one module, so reuse the module that
        // already wraps this file instead of creating a second one.
        if (entry.value_ptr.*.root_source_file) |imported| {
            if (sameSourceFile(imported, source)) layout_module = entry.value_ptr.*;
        }
    }
    probe_module.addImport("snitch_layout", layout_module orelse b.createModule(.{ .root_source_file = source }));

    const probe = b.addExecutable(.{ .name = "snitch-layout", .root_module = probe_module });
    step.dependOn(&b.addRunArtifact(probe).step);
}

/// Whether two source paths name the same file in the same package. Separate
/// instances of one dependency share a package hash, so compare that rather
/// than the owning `Build`.
fn sameSourceFile(a: std.Build.LazyPath, b: std.Build.LazyPath) bool {
    const a_key = sourceKey(a) orelse return false;
    const b_key = sourceKey(b) orelse return false;
    return std.mem.eql(u8, a_key[0], b_key[0]) and std.mem.eql(u8, a_key[1], b_key[1]);
}

fn sourceKey(path: std.Build.LazyPath) ?struct { []const u8, []const u8 } {
    return switch (path) {
        .src_path => |src| .{ src.owner.pkg_hash, src.sub_path },
        .dependency => |dep| .{ dep.dependency.builder.pkg_hash, dep.sub_path },
        else => null,
    };
}

/// Entry point of the layout generator that `addLayoutStep` builds from this
/// file. Not part of the profiling API.
///
/// Arguments: the module's root directory, the output directory, the path of
/// this file (never scanned), then the files or folders to scan, all relative
/// to the working directory.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 5) {
        std.debug.print("usage: {s} <module root> <output dir> <snitch.zig> <file or folder>...\n", .{args[0]});
        return error.InvalidArguments;
    }

    const cwd = std.Io.Dir.cwd();
    const root_real = try cwd.realPathFileAlloc(io, args[1], arena);
    const self_real = try cwd.realPathFileAlloc(io, args[3], arena);
    var root = try cwd.openDir(io, args[1], .{ .iterate = true });
    defer root.close(io);
    var out = try cwd.createDirPathOpen(io, args[2], .{});
    defer out.close(io);

    try copyZigTree(arena, io, root, out);

    var probe: std.ArrayList(u8) = .empty;
    try probe.appendSlice(arena,
        \\// Generated by snitch's layout step.
        \\const std = @import("std");
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    const types = .{}
    );

    for (args[4..]) |target| {
        const target_real = cwd.realPathFileAlloc(io, target, arena) catch |err| {
            std.debug.print("snitch-layout: cannot open {s}: {t}\n", .{ target, err });
            return err;
        };
        const relative = relativeTo(root_real, target_real) orelse {
            std.debug.print("snitch-layout: {s} is outside the module root {s}\n", .{ target, args[1] });
            return error.OutsideModuleRoot;
        };

        for (try zigFilesAt(arena, io, root, relative)) |file_path| {
            // Snitch's own types would only add noise.
            const file_real = try std.fs.path.join(arena, &.{ root_real, file_path });
            if (std.mem.eql(u8, file_real, self_real)) continue;

            if (try appendLayoutDecl(arena, io, out, file_path)) {
                try probe.print(arena, " ++ @import(\"{s}\").{s}", .{ file_path, layout_decl_name });
            }
        }
    }

    try probe.appendSlice(arena,
        \\;
        \\    var buffer: [4096]u8 = undefined;
        \\    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
        \\    try @import("snitch_layout").writeLayouts(&stdout.interface, types);
        \\    try stdout.interface.flush();
        \\}
        \\
    );
    try out.writeFile(io, .{ .sub_path = "snitch_layout_probe.zig", .data = probe.items });
}

/// Copy every `.zig` file under `from` to the same relative path in `to`,
/// skipping hidden directories and `zig-out`.
fn copyZigTree(arena: std.mem.Allocator, io: std.Io, from: std.Io.Dir, to: std.Io.Dir) !void {
    var walker = try from.walkSelectively(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => if (entry.basename[0] != '.' and !std.mem.eql(u8, entry.basename, "zig-out")) {
                try walker.enter(io, entry);
            },
            .file => if (std.mem.endsWith(u8, entry.basename, ".zig")) {
                const data = try from.readFileAlloc(io, entry.path, arena, .unlimited);
                if (std.fs.path.dirname(entry.path)) |dir| {
                    try to.createDirPath(io, dir);
                }
                try to.writeFile(io, .{ .sub_path = entry.path, .data = data });
            },
            else => {},
        }
    }
}

/// `path` relative to `root`, or null if it lies outside it. Both must be
/// real paths.
fn relativeTo(root: []const u8, path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, root, path)) return ".";
    if (!std.mem.startsWith(u8, path, root) or path[root.len] != std.fs.path.sep) return null;
    return path[root.len + 1 ..];
}

/// `.zig` files at `relative` inside `root`: the file itself, or every file in
/// the folder and its subfolders. Paths use `/` so they work in `@import`.
fn zigFilesAt(arena: std.mem.Allocator, io: std.Io, root: std.Io.Dir, relative: []const u8) ![]const []const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    var dir = root.openDir(io, relative, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => {
            try files.append(arena, try importPath(arena, relative));
            return files.items;
        },
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const joined = if (std.mem.eql(u8, relative, ".")) entry.path else try std.fs.path.join(arena, &.{ relative, entry.path });
        try files.append(arena, try importPath(arena, joined));
    }
    return files.items;
}

fn importPath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const copy = try arena.dupe(u8, path);
    std.mem.replaceScalar(u8, copy, '\\', '/');
    return copy;
}

/// Parse the copy of `file_path` in `out` and append a declaration listing
/// its structs and unions. Returns false if it has none.
fn appendLayoutDecl(arena: std.mem.Allocator, io: std.Io, out: std.Io.Dir, file_path: []const u8) !bool {
    const source = try out.readFileAllocOptions(io, file_path, arena, .unlimited, .of(u8), 0);
    const names = try layoutTypeNames(arena, source);
    if (names.len == 0) {
        return false;
    }

    var appended: std.ArrayList(u8) = .empty;
    try appended.appendSlice(arena, source);
    try appended.print(arena, "\n\n// Added by snitch's layout step.\npub const {s} = .{{ ", .{layout_decl_name});
    for (names, 0..) |name, index| {
        try appended.print(arena, "{s}{s}", .{ if (index == 0) "" else ", ", name });
    }
    try appended.appendSlice(arena, " };\n");
    try out.writeFile(io, .{ .sub_path = file_path, .data = appended.items });
    return true;
}

/// Names, usable from the end of the file, of every struct and union with
/// fields declared at container level in `source`: `Order`, `Outer.Inner`,
/// and `@This()` when the file itself has fields.
fn layoutTypeNames(arena: std.mem.Allocator, source: [:0]const u8) ![]const []const u8 {
    var tree = try std.zig.Ast.parse(arena, source, .{});
    defer tree.deinit(arena);

    var names: std.ArrayList([]const u8) = .empty;
    const root = tree.containerDeclRoot();
    if (hasFields(&tree, root.ast.members)) {
        try names.append(arena, "@This()");
    }
    try collectTypeNames(arena, &tree, root.ast.members, "", &names);
    return names.items;
}

fn collectTypeNames(
    arena: std.mem.Allocator,
    tree: *const std.zig.Ast,
    members: []const std.zig.Ast.Node.Index,
    prefix: []const u8,
    names: *std.ArrayList([]const u8),
) !void {
    for (members) |member| {
        const var_decl = tree.fullVarDecl(member) orelse continue;
        const init_node = var_decl.ast.init_node.unwrap() orelse continue;
        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        const container = tree.fullContainerDecl(&buffer, init_node) orelse continue;

        const name = tree.tokenSlice(var_decl.ast.mut_token + 1);
        const path = if (prefix.len == 0) name else try std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, name });
        const keyword = tree.tokenSlice(container.ast.main_token);
        const has_layout = std.mem.eql(u8, keyword, "struct") or std.mem.eql(u8, keyword, "union");
        if (has_layout and hasFields(tree, container.ast.members)) {
            try names.append(arena, path);
        }
        try collectTypeNames(arena, tree, container.ast.members, path, names);
    }
}

fn hasFields(tree: *const std.zig.Ast, members: []const std.zig.Ast.Node.Index) bool {
    for (members) |member| {
        switch (tree.nodeTag(member)) {
            .container_field_init, .container_field_align, .container_field => return true,
            else => {},
        }
    }
    return false;
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

    default_profiler.assertNoOpenZones();
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
    const measurement = zone(name);
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

    const first = profiler.zone("shared-label");
    first.end();
    const second = profiler.zone("shared-" ++ "label");
    second.end();
    const other = profiler.zone("other-label");
    other.end();

    try std.testing.expectEqual(@as(u64, 2), labelSlot(&profiler, "shared-label").calls());
    try std.testing.expectEqual(@as(u64, 1), labelSlot(&profiler, "other-label").calls());
}

test "zones only count allocations made on their own thread" {
    if (!memory_enabled) return;

    var profiler = Profiler.init(std.testing.io, std.testing.allocator);
    defer profiler.deinit();
    const tracked = profiler.allocator();

    const measurement = profiler.zone("thread-local-allocs");

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
                    const measurement = p.zone("concurrent");
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

test "safe builds count open zones" {
    if (!track_open_zones) return;

    var profiler = Profiler.init(std.testing.io, std.testing.allocator);
    defer profiler.deinit();

    const outer = profiler.zone("outer");
    const inner = profiler.zone("inner");
    try std.testing.expectEqual(@as(u32, 2), profiler.open_zones.load(.monotonic));
    inner.end();
    outer.end();
    try std.testing.expectEqual(@as(u32, 0), profiler.open_zones.load(.monotonic));

    const ignored = Zone.inactive;
    ignored.end();
    try std.testing.expectEqual(@as(u32, 0), profiler.open_zones.load(.monotonic));
}

const layout_fixtures = struct {
    pub const Loose = extern struct { flag: bool, id: u64, tag: u8 };
    pub const Tight = extern struct { id: u64, flag: bool, tag: u8 };
    pub const Auto = struct { flag: bool, id: u64, tag: u8 };
    pub const Bits = packed struct { a: bool, b: u7 };
    pub const Either = union(enum) { int: u64, none };
    pub const Group = struct {
        pub const Inner = extern struct { a: u8, b: u32 };
    };
    pub const Kind = enum { a, b };
};

test "extern struct layout reports padding and the best possible size" {
    const loose = comptime describeLayout(layout_fixtures.Loose);
    try std.testing.expectEqualStrings("extern struct", loose.kind);
    try std.testing.expectEqual(@as(usize, 24), loose.size);
    try std.testing.expectEqual(@as(?usize, 14), loose.padding);
    try std.testing.expectEqual(@as(?usize, 16), loose.best_size);
    try std.testing.expectEqual(@as(usize, 3), loose.fields.len);
    try std.testing.expectEqualStrings("flag", loose.fields[0].name);
    try std.testing.expectEqual(@as(usize, 7), loose.fields[0].padding_after);
    try std.testing.expectEqual(@as(usize, 8), loose.fields[1].offset);
    try std.testing.expectEqual(@as(usize, 7), loose.fields[2].padding_after);

    const tight = comptime describeLayout(layout_fixtures.Tight);
    try std.testing.expectEqual(@as(usize, 16), tight.size);
    try std.testing.expectEqual(@as(?usize, 6), tight.padding);
    try std.testing.expectEqual(@as(?usize, 16), tight.best_size);
}

test "auto, packed and union layouts" {
    const auto = comptime describeLayout(layout_fixtures.Auto);
    try std.testing.expectEqualStrings("struct", auto.kind);
    try std.testing.expectEqual(@sizeOf(layout_fixtures.Auto), auto.size);
    try std.testing.expectEqual(@as(?usize, null), auto.best_size);
    for (auto.fields[1..], auto.fields[0 .. auto.fields.len - 1]) |field, previous| {
        try std.testing.expect(field.offset > previous.offset);
    }

    const bits = comptime describeLayout(layout_fixtures.Bits);
    try std.testing.expectEqualStrings("packed struct", bits.kind);
    try std.testing.expectEqual(@as(?usize, null), bits.padding);

    const either = comptime describeLayout(layout_fixtures.Either);
    try std.testing.expectEqualStrings("tagged union", either.kind);
    try std.testing.expectEqual(@as(usize, 0), either.fields.len);
}

test "layout generator finds structs and unions, including private and nested ones" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const names = try layoutTypeNames(arena_state.allocator(),
        \\const std = @import("std");
        \\first: u32,
        \\pub const Public = extern struct { a: u8, b: u64 };
        \\const Private = struct {
        \\    x: u32,
        \\    const Inner = union(enum) { a: u8, b: u16 };
        \\    pub const Namespace = struct {
        \\        pub const Deep = packed struct { bits: u3 };
        \\    };
        \\};
        \\const Kind = enum { a, b };
        \\const Empty = struct {};
        \\fn Generic(comptime T: type) type { return struct { value: T }; }
        \\fn helper() void { const Local = struct { y: u8 }; _ = Local; }
    );
    const expected = [_][]const u8{ "@This()", "Public", "Private", "Private.Inner", "Private.Namespace.Deep" };
    try std.testing.expectEqual(expected.len, names.len);
    for (expected, names) |expected_name, name| {
        try std.testing.expectEqualStrings(expected_name, name);
    }
}

test "layout generator keeps target paths inside the module root" {
    const sep = std.fs.path.sep_str;
    try std.testing.expectEqualStrings(".", relativeTo(sep ++ "p" ++ sep ++ "src", sep ++ "p" ++ sep ++ "src").?);
    try std.testing.expectEqualStrings("net" ++ sep ++ "a.zig", relativeTo(sep ++ "p" ++ sep ++ "src", sep ++ "p" ++ sep ++ "src" ++ sep ++ "net" ++ sep ++ "a.zig").?);
    try std.testing.expectEqual(@as(?[]const u8, null), relativeTo(sep ++ "p" ++ sep ++ "src", sep ++ "p" ++ sep ++ "srcx" ++ sep ++ "a.zig"));
    try std.testing.expectEqual(@as(?[]const u8, null), relativeTo(sep ++ "p" ++ sep ++ "src", sep ++ "p" ++ sep ++ "lib.zig"));
}
