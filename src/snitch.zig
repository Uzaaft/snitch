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
//! - `-Dsnitch-percentile`: percentile column in reports, 1-100 (default `85`).
//! - `-Dsnitch-max-rows`: rows per report section, `0` for all (default `0`).
//!
//! # Notes
//!
//! - Zone labels are comptime strings.
//! - The `*Here` variants label zones with the caller's file and line. Pass
//!   `@src()` explicitly; Zig cannot capture the caller's location for you.
//! - Memory metrics count allocations made through `snitch.allocator()` (or
//!   `Profiler.allocator()`) on the thread that ran the zone. End a zone on the thread that started it.
//! - Percentiles come from a fixed-size histogram and may read up to 1/64
//!   (about 1.6%) above the true value. Averages and totals are exact.
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
//!     defer snitch.finish(); // prints the report to stderr
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
//!     _ = snitch.measureCall("handler", handler, .{ arg1, arg2 });
//!     _ = snitch.measureCallHere(handler, .{ arg1, arg2 }, @src());
//!     _ = snitch.measureBlockHere(struct {
//!         fn run() void {}
//!     }.run, @src());
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

/// Percentile shown in report columns, set via `-Dsnitch-percentile`.
pub const percentile_target = build_options.snitch_percentile;

/// Maximum rows printed per section, set via `-Dsnitch-max-rows`.
pub const report_max_rows = build_options.snitch_max_rows;

comptime {
    if (percentile_target == 0 or percentile_target > 100) {
        @compileError("snitch_percentile must be between 1 and 100");
    }
}

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

    /// Start a zone. Call `end` on the result to record it.
    pub fn zone(self: *Profiler, comptime label: []const u8) callconv(callingConvention()) Zone {
        if (comptime !enabled) {
            return .{};
        }

        return .{
            .profiler = self,
            .label_index = labelIndex(label),
            .start_alloc_bytes = thread_alloc_bytes,
            .start_alloc_calls = thread_alloc_calls,
            .start = if (timing_enabled) .now(self.io, .awake) else {},
        };
    }

    /// Like `zone`, labeled with the caller's file and line.
    pub fn zoneHere(
        self: *Profiler,
        comptime source_location: std.builtin.SourceLocation,
    ) callconv(callingConvention()) Zone {
        return self.zone(comptimeSourceLabel(source_location));
    }

    /// Call `function` with `args`, measure it, and return its result.
    pub fn measureCall(
        self: *Profiler,
        comptime label: []const u8,
        function: anytype,
        args: anytype,
    ) callconv(callingConvention()) @TypeOf(@call(.auto, function, args)) {
        var measurement = self.zone(label);
        defer measurement.end();
        return @call(.auto, function, args);
    }

    /// Like `measureCall`, labeled with the caller's file and line.
    pub fn measureCallHere(
        self: *Profiler,
        function: anytype,
        args: anytype,
        comptime source_location: std.builtin.SourceLocation,
    ) callconv(callingConvention()) @TypeOf(@call(.auto, function, args)) {
        return self.measureCall(comptimeSourceLabel(source_location), function, args);
    }

    /// Run `block`, measure it, and return its result.
    pub fn measureBlock(
        self: *Profiler,
        comptime label: []const u8,
        block: anytype,
    ) callconv(callingConvention()) @TypeOf(block()) {
        var measurement = self.zone(label);
        defer measurement.end();
        return block();
    }

    /// Like `measureBlock`, labeled with the caller's file and line.
    pub fn measureBlockHere(
        self: *Profiler,
        block: anytype,
        comptime source_location: std.builtin.SourceLocation,
    ) callconv(callingConvention()) @TypeOf(block()) {
        return self.measureBlock(comptimeSourceLabel(source_location), block);
    }

    /// Write the report to stderr.
    pub fn printReport(self: *Profiler) callconv(callingConvention()) !void {
        if (comptime !enabled) {
            return;
        }

        var buffer: [4_096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(self.io, &buffer);
        try self.writeReport(&stderr_writer.interface);
        try stderr_writer.interface.flush();
    }

    /// Write the report as ASCII tables.
    pub fn writeReport(self: *Profiler, writer: *std.Io.Writer) callconv(callingConvention()) !void {
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

        try writeReportEntries(self.base_allocator, writer, entries[0..entry_count]);
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

const Section = struct {
    title: []const u8,
    unit: []const u8,
    enabled: bool,
    /// Which histogram of a slot this section reads.
    field: []const u8,
};

const sections = [_]Section{
    .{ .title = "snitch-timing - Execution time per call.", .unit = "ns", .enabled = timing_enabled, .field = "timing" },
    .{ .title = "snitch-memory-bytes - Bytes allocated per call.", .unit = "bytes", .enabled = memory_enabled, .field = "alloc_bytes" },
    .{ .title = "snitch-memory-count - Allocations per call.", .unit = "allocs", .enabled = memory_enabled, .field = "alloc_calls" },
};

const Row = struct {
    label: []const u8,
    calls: u64,
    avg: u64,
    percentile: u64,
    total: u64,

    fn moreTotalFirst(_: void, lhs: Row, rhs: Row) bool {
        if (lhs.total != rhs.total) {
            return lhs.total > rhs.total;
        }
        return std.mem.lessThan(u8, lhs.label, rhs.label);
    }
};

const column_count = 6;
const max_label_width = 40;

fn writeReportEntries(gpa: std.mem.Allocator, writer: *std.Io.Writer, entries: []const LabeledSlot) !void {
    try writer.print("[snitch] zones={d}\n\n", .{entries.len});

    if (entries.len == 0) {
        try writer.writeAll("(no measurements)\n");
        return;
    }

    if (!timing_enabled and !memory_enabled) {
        try writer.writeAll("snitch is enabled, but both snitch-timing and snitch-memory are disabled.\n");
        return;
    }

    const rows = try gpa.alloc(Row, entries.len);
    defer gpa.free(rows);

    var first = true;
    inline for (sections) |section| {
        if (section.enabled) {
            if (!first) {
                try writer.writeByte('\n');
            }
            first = false;

            var section_total: u128 = 0;
            for (entries, rows) |entry, *row| {
                const histogram = &@field(entry.slot, section.field);
                const calls = histogram.count();
                const total = @atomicLoad(u64, &histogram.total, .monotonic);
                row.* = .{
                    .label = entry.label,
                    .calls = calls,
                    .avg = if (calls == 0) 0 else total / calls,
                    .percentile = if (calls == 0) 0 else histogram.percentile(calls, percentile_target),
                    .total = total,
                };
                section_total += total;
            }

            std.sort.pdq(Row, rows, {}, Row.moreTotalFirst);
            try writeTable(writer, section, rows, section_total);
        }
    }
}

fn writeTable(writer: *std.Io.Writer, comptime section: Section, rows: []const Row, section_total: u128) !void {
    const header = [column_count][]const u8{
        "Metric",
        "Calls",
        "Avg " ++ section.unit,
        std.fmt.comptimePrint("P{d} {s}", .{ percentile_target, section.unit }),
        "Total " ++ section.unit,
        "% Total",
    };
    const visible = if (report_max_rows == 0) rows else rows[0..@min(rows.len, report_max_rows)];

    var widths: [column_count]usize = undefined;
    for (&widths, header) |*width, cell| {
        width.* = cell.len;
    }
    widths[5] = "100.00%".len;
    for (visible) |row| {
        widths[0] = @max(widths[0], @min(max_label_width, row.label.len));
        widths[1] = @max(widths[1], std.fmt.count("{d}", .{row.calls}));
        widths[2] = @max(widths[2], std.fmt.count("{d}", .{row.avg}));
        widths[3] = @max(widths[3], std.fmt.count("{d}", .{row.percentile}));
        widths[4] = @max(widths[4], std.fmt.count("{d}", .{row.total}));
    }

    try writer.print("{s}\n", .{section.title});
    try writeSeparator(writer, widths);
    try writeRow(writer, widths, header);
    try writeSeparator(writer, widths);

    for (visible) |row| {
        var label_buffer: [max_label_width]u8 = undefined;
        var buffers: [column_count][32]u8 = undefined;
        try writeRow(writer, widths, .{
            truncateLabel(row.label, &label_buffer),
            try std.fmt.bufPrint(&buffers[1], "{d}", .{row.calls}),
            try std.fmt.bufPrint(&buffers[2], "{d}", .{row.avg}),
            try std.fmt.bufPrint(&buffers[3], "{d}", .{row.percentile}),
            try std.fmt.bufPrint(&buffers[4], "{d}", .{row.total}),
            try formatPercent(row.total, section_total, &buffers[5]),
        });
    }
    try writeSeparator(writer, widths);

    if (visible.len < rows.len) {
        try writer.print(
            "(showing {d} of {d} rows; build with -Dsnitch-max-rows=0 to show all)\n",
            .{ visible.len, rows.len },
        );
    }
}

fn writeSeparator(writer: *std.Io.Writer, widths: [column_count]usize) !void {
    for (widths) |width| {
        try writer.writeByte('+');
        try writer.splatByteAll('-', width + 2);
    }
    try writer.writeAll("+\n");
}

/// The label column is left-aligned; the numeric columns are right-aligned.
fn writeRow(writer: *std.Io.Writer, widths: [column_count]usize, cells: [column_count][]const u8) !void {
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

fn formatPercent(part: u64, whole: u128, buffer: []u8) ![]const u8 {
    if (whole == 0) {
        return "0.00%";
    }

    const ratio = @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(whole));
    return std.fmt.bufPrint(buffer, "{d:.2}%", .{ratio * 100.0});
}

fn comptimeSourceLabel(comptime source_location: std.builtin.SourceLocation) []const u8 {
    return std.fmt.comptimePrint("{s}:{d}", .{ source_location.file, source_location.line });
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
pub fn finish() callconv(callingConvention()) void {
    if (!default_started.load(.acquire)) {
        return;
    }

    default_profiler.printReport() catch {};
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

/// Start a zone on the process-wide profiler. Call `end` on the result.
pub fn zone(comptime label: []const u8) callconv(callingConvention()) Zone {
    if (comptime !enabled) {
        return .{};
    }

    const profiler = defaultProfiler() orelse return .inactive;
    return profiler.zone(label);
}

/// Like `zone`, labeled with the caller's file and line.
pub fn zoneHere(comptime source_location: std.builtin.SourceLocation) callconv(callingConvention()) Zone {
    return zone(comptimeSourceLabel(source_location));
}

/// Call `function` with `args`, measure it on the process-wide profiler, and
/// return its result.
pub fn measureCall(
    comptime label: []const u8,
    function: anytype,
    args: anytype,
) callconv(callingConvention()) @TypeOf(@call(.auto, function, args)) {
    var measurement = zone(label);
    defer measurement.end();
    return @call(.auto, function, args);
}

/// Like `measureCall`, labeled with the caller's file and line.
pub fn measureCallHere(
    function: anytype,
    args: anytype,
    comptime source_location: std.builtin.SourceLocation,
) callconv(callingConvention()) @TypeOf(@call(.auto, function, args)) {
    return measureCall(comptimeSourceLabel(source_location), function, args);
}

/// Run `block`, measure it on the process-wide profiler, and return its result.
pub fn measureBlock(
    comptime label: []const u8,
    block: anytype,
) callconv(callingConvention()) @TypeOf(block()) {
    var measurement = zone(label);
    defer measurement.end();
    return block();
}

/// Like `measureBlock`, labeled with the caller's file and line.
pub fn measureBlockHere(
    block: anytype,
    comptime source_location: std.builtin.SourceLocation,
) callconv(callingConvention()) @TypeOf(block()) {
    return measureBlock(comptimeSourceLabel(source_location), block);
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
