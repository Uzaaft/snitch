const std = @import("std");
const hotpath = @import("hotpath");

fn returnsSeven() u8 {
    return 7;
}

fn burnCpu(iterations: usize) u64 {
    var total: u64 = 0;
    var index: usize = 0;

    while (index < iterations) : (index += 1) {
        total +%= @as(u64, @intCast(index *% 31));
    }

    return total;
}

fn writeReportToBuffer(profiler: *hotpath.Profiler, storage: []u8) ![]const u8 {
    var report_stream = std.io.fixedBufferStream(storage);
    try profiler.writeReport(report_stream.writer());
    return report_stream.getWritten();
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) {
        return 0;
    }

    var count: usize = 0;
    var offset: usize = 0;

    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |match_index| {
        count += 1;
        offset = match_index + needle.len;
    }

    return count;
}

test "measureCall returns wrapped value" {
    var profiler = hotpath.Profiler.init(std.testing.allocator);
    defer profiler.deinit();

    const value = hotpath.measureCall(&profiler, "returnsSeven", returnsSeven, .{});
    try std.testing.expectEqual(@as(u8, 7), value);
}

test "callsite helper APIs return wrapped values" {
    var profiler = hotpath.Profiler.init(std.testing.allocator);
    defer profiler.deinit();

    const call_value = hotpath.measureCallHere(&profiler, returnsSeven, .{}, @src());
    try std.testing.expectEqual(@as(u8, 7), call_value);

    const block_value = hotpath.measureBlockHere(&profiler, struct {
        fn run() u8 {
            return 9;
        }
    }.run, @src());
    try std.testing.expectEqual(@as(u8, 9), block_value);

    var zone = hotpath.zoneHere(&profiler, @src());
    zone.end();
}

test "callsite helper labels include file and line" {
    if (!hotpath.enabled or hotpath.report_max_rows != 0) {
        return;
    }

    if (!hotpath.timing_enabled and !hotpath.memory_enabled) {
        return;
    }

    var profiler = hotpath.Profiler.init(std.testing.allocator);
    defer profiler.deinit();

    const call_location = @src();
    _ = hotpath.measureCallHere(&profiler, returnsSeven, .{}, call_location);

    const block_location = @src();
    _ = hotpath.measureBlockHere(&profiler, struct {
        fn run() u8 {
            return 11;
        }
    }.run, block_location);

    const zone_location = @src();
    var zone = hotpath.zoneHere(&profiler, zone_location);
    zone.end();

    var report_storage: [4_096]u8 = undefined;
    const report = try writeReportToBuffer(&profiler, &report_storage);

    const call_label = std.fmt.comptimePrint("{s}:{d}", .{ call_location.file, call_location.line });
    const block_label = std.fmt.comptimePrint("{s}:{d}", .{ block_location.file, block_location.line });
    const zone_label = std.fmt.comptimePrint("{s}:{d}", .{ zone_location.file, zone_location.line });

    try expectContains(report, call_label);
    try expectContains(report, block_label);
    try expectContains(report, zone_label);
}

test "zone start and end compiles and runs" {
    var profiler = hotpath.Profiler.init(std.testing.allocator);
    defer profiler.deinit();

    var zone = profiler.zone("simple-zone");
    zone.end();
}

test "calling convention reflects compile-time enable flag" {
    const write_report_stdout_info = @typeInfo(@TypeOf(hotpath.writeReportStdout)).@"fn";

    if (hotpath.enabled) {
        try std.testing.expectEqual(std.builtin.CallingConvention.auto, write_report_stdout_info.calling_convention);
        return;
    }

    try std.testing.expectEqual(std.builtin.CallingConvention.@"inline", write_report_stdout_info.calling_convention);
}

test "disabled mode keeps no-op surface" {
    if (hotpath.enabled) {
        return;
    }

    try std.testing.expectEqual(@as(usize, 0), @sizeOf(hotpath.Zone));

    var profiler = hotpath.Profiler.init(std.testing.allocator);
    defer profiler.deinit();

    const allocator = profiler.allocator();
    const payload = try allocator.alloc(u8, 8);
    allocator.free(payload);

    var zone = profiler.zone("disabled-zone");
    zone.end();

    try hotpath.writeReportStdout(&profiler, 128);
}

test "writeReport output respects compile-time config" {
    var profiler = hotpath.Profiler.init(std.testing.allocator);
    defer profiler.deinit();

    const tracked_allocator = profiler.allocator();

    {
        var zone = profiler.zone("report-zone");
        defer zone.end();

        _ = burnCpu(40_000);

        if (hotpath.memory_enabled) {
            const payload = try tracked_allocator.alloc(u8, 96);
            defer tracked_allocator.free(payload);
            payload[0] = 1;
        }
    }

    var report_storage: [4_096]u8 = undefined;
    const report = try writeReportToBuffer(&profiler, &report_storage);

    if (!hotpath.enabled) {
        try std.testing.expectEqual(@as(usize, 0), report.len);
        return;
    }

    try expectContains(report, "[snitch] zones=1");

    if (!hotpath.timing_enabled and !hotpath.memory_enabled) {
        try expectContains(report, "snitch is enabled, but both snitch-timing and snitch-memory are disabled.");
        try expectNotContains(report, "| Metric");
        return;
    }

    const timing_percentile_header = std.fmt.comptimePrint("P{d} ns", .{hotpath.percentile_target});
    const memory_bytes_percentile_header = std.fmt.comptimePrint("P{d} bytes", .{hotpath.percentile_target});
    const memory_count_percentile_header = std.fmt.comptimePrint("P{d} allocs", .{hotpath.percentile_target});

    try expectContains(report, "| Metric");
    try expectContains(report, "report-zone");

    if (hotpath.timing_enabled) {
        try expectContains(report, "snitch-timing - Function execution time metrics.");
        try expectContains(report, timing_percentile_header);
    } else {
        try expectNotContains(report, "snitch-timing - Function execution time metrics.");
        try expectNotContains(report, timing_percentile_header);
    }

    if (hotpath.memory_enabled) {
        try expectContains(report, "snitch-memory-bytes - Cumulative allocation bytes during each function call.");
        try expectContains(report, "snitch-memory-count - Allocation call count during each function call.");
        try expectContains(report, memory_bytes_percentile_header);
        try expectContains(report, memory_count_percentile_header);
    } else {
        try expectNotContains(report, "snitch-memory-bytes - Cumulative allocation bytes during each function call.");
        try expectNotContains(report, "snitch-memory-count - Allocation call count during each function call.");
        try expectNotContains(report, memory_bytes_percentile_header);
        try expectNotContains(report, memory_count_percentile_header);
    }
}

test "report max rows truncates sorted sections" {
    if (!hotpath.enabled or hotpath.report_max_rows == 0) {
        return;
    }

    if (!hotpath.timing_enabled or !hotpath.memory_enabled) {
        return;
    }

    var profiler = hotpath.Profiler.init(std.testing.allocator);
    defer profiler.deinit();

    const tracked_allocator = profiler.allocator();

    {
        var zone = profiler.zone("heavy-zone");
        defer zone.end();

        const payload = try tracked_allocator.alloc(u8, 16_384);
        defer tracked_allocator.free(payload);

        var index: usize = 0;
        while (index < payload.len) : (index += 1) {
            payload[index] = @intCast(index % 251);
        }

        _ = burnCpu(90_000);
    }

    {
        var zone = profiler.zone("light-zone");
        defer zone.end();

        const payload = try tracked_allocator.alloc(u8, 64);
        defer tracked_allocator.free(payload);
        payload[0] = 1;

        _ = burnCpu(1_000);
    }

    var report_storage: [8_192]u8 = undefined;
    const report = try writeReportToBuffer(&profiler, &report_storage);

    const truncation_note = "(truncated 1 rows, set -Dsnitch-max-rows=0 for all rows)";
    try std.testing.expectEqual(@as(usize, 3), countOccurrences(report, truncation_note));
    try expectContains(report, "heavy-zone");
    try expectNotContains(report, "light-zone");
}
