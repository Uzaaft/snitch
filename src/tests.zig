const std = @import("std");
const snitch = @import("snitch");

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

fn writeReportToBuffer(profiler: *snitch.Profiler, storage: []u8) ![]const u8 {
    var report_writer: std.Io.Writer = .fixed(storage);
    try profiler.writeReport(&report_writer);
    return report_writer.buffered();
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
    var profiler = snitch.Profiler.init(std.testing.io, std.testing.allocator);
    defer profiler.deinit();

    const value = profiler.measureCall("returnsSeven", returnsSeven, .{});
    try std.testing.expectEqual(@as(u8, 7), value);
}

test "callsite helper APIs return wrapped values" {
    var profiler = snitch.Profiler.init(std.testing.io, std.testing.allocator);
    defer profiler.deinit();

    const call_value = profiler.measureCallHere(returnsSeven, .{}, @src());
    try std.testing.expectEqual(@as(u8, 7), call_value);

    const block_value = profiler.measureBlockHere(struct {
        fn run() u8 {
            return 9;
        }
    }.run, @src());
    try std.testing.expectEqual(@as(u8, 9), block_value);

    var zone = profiler.zoneHere(@src());
    zone.end();
}

test "callsite helper labels include file and line" {
    if (!snitch.enabled or snitch.report_max_rows != 0) {
        return;
    }

    if (!snitch.timing_enabled and !snitch.memory_enabled) {
        return;
    }

    var profiler = snitch.Profiler.init(std.testing.io, std.testing.allocator);
    defer profiler.deinit();

    const call_location = @src();
    _ = profiler.measureCallHere(returnsSeven, .{}, call_location);

    const block_location = @src();
    _ = profiler.measureBlockHere(struct {
        fn run() u8 {
            return 11;
        }
    }.run, block_location);

    const zone_location = @src();
    var zone = profiler.zoneHere(zone_location);
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
    var profiler = snitch.Profiler.init(std.testing.io, std.testing.allocator);
    defer profiler.deinit();

    var zone = profiler.zone("simple-zone");
    zone.end();
}

test "calling convention reflects compile-time enable flag" {
    const finish_info = @typeInfo(@TypeOf(snitch.finish)).@"fn";

    if (snitch.enabled) {
        try std.testing.expectEqual(std.builtin.CallingConvention.auto, finish_info.attrs.@"callconv");
        return;
    }

    try std.testing.expectEqual(std.builtin.CallingConvention.@"inline", finish_info.attrs.@"callconv");
}

test "disabled mode keeps no-op surface" {
    if (snitch.enabled) {
        return;
    }

    try std.testing.expectEqual(@as(usize, 0), @sizeOf(snitch.Zone));

    var profiler = snitch.Profiler.init(std.testing.io, std.testing.allocator);
    defer profiler.deinit();

    const allocator = profiler.allocator();
    const payload = try allocator.alloc(u8, 8);
    allocator.free(payload);

    var zone = profiler.zone("disabled-zone");
    zone.end();

    try profiler.printReport();
}

test "writeReport output respects compile-time config" {
    var profiler = snitch.Profiler.init(std.testing.io, std.testing.allocator);
    defer profiler.deinit();

    const tracked_allocator = profiler.allocator();

    {
        var zone = profiler.zone("report-zone");
        defer zone.end();

        _ = burnCpu(40_000);

        if (snitch.memory_enabled) {
            const payload = try tracked_allocator.alloc(u8, 96);
            defer tracked_allocator.free(payload);
            payload[0] = 1;
        }
    }

    var report_storage: [4_096]u8 = undefined;
    const report = try writeReportToBuffer(&profiler, &report_storage);

    if (!snitch.enabled) {
        try std.testing.expectEqual(@as(usize, 0), report.len);
        return;
    }

    try expectContains(report, "[snitch] zones=1");

    if (!snitch.timing_enabled and !snitch.memory_enabled) {
        try expectContains(report, "snitch is enabled, but both snitch-timing and snitch-memory are disabled.");
        try expectNotContains(report, "| Metric");
        return;
    }

    const timing_percentile_header = std.fmt.comptimePrint("P{d} ns", .{snitch.percentile_target});
    const memory_bytes_percentile_header = std.fmt.comptimePrint("P{d} bytes", .{snitch.percentile_target});
    const memory_count_percentile_header = std.fmt.comptimePrint("P{d} allocs", .{snitch.percentile_target});

    try expectContains(report, "| Metric");
    try expectContains(report, "report-zone");

    if (snitch.timing_enabled) {
        try expectContains(report, "snitch-timing - Execution time per call.");
        try expectContains(report, timing_percentile_header);
    } else {
        try expectNotContains(report, "snitch-timing - Execution time per call.");
        try expectNotContains(report, timing_percentile_header);
    }

    if (snitch.memory_enabled) {
        try expectContains(report, "snitch-memory-bytes - Bytes allocated per call.");
        try expectContains(report, "snitch-memory-count - Allocations per call.");
        try expectContains(report, memory_bytes_percentile_header);
        try expectContains(report, memory_count_percentile_header);
    } else {
        try expectNotContains(report, "snitch-memory-bytes - Bytes allocated per call.");
        try expectNotContains(report, "snitch-memory-count - Allocations per call.");
        try expectNotContains(report, memory_bytes_percentile_header);
        try expectNotContains(report, memory_count_percentile_header);
    }
}

test "report max rows truncates sorted sections" {
    if (!snitch.enabled or snitch.report_max_rows == 0) {
        return;
    }

    if (!snitch.timing_enabled or !snitch.memory_enabled) {
        return;
    }

    var profiler = snitch.Profiler.init(std.testing.io, std.testing.allocator);
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

    const truncation_note = "(showing 1 of 2 rows; build with -Dsnitch-max-rows=0 to show all)";
    try std.testing.expectEqual(@as(usize, 3), countOccurrences(report, truncation_note));
    try expectContains(report, "heavy-zone");
    try expectNotContains(report, "light-zone");
}

test "process-wide profiler records zones between start and stop" {
    var ignored = snitch.zone("before-start");
    ignored.end();

    snitch.start(std.testing.io, std.testing.allocator);
    defer snitch.stop();

    {
        var zone = snitch.zone("global-zone");
        defer zone.end();

        if (snitch.memory_enabled) {
            const tracked_allocator = snitch.allocator();
            const payload = try tracked_allocator.alloc(u8, 32);
            tracked_allocator.free(payload);
        }
    }
    try std.testing.expectEqual(@as(u8, 7), snitch.measureCall("global-call", returnsSeven, .{}));
    try std.testing.expectEqual(@as(u8, 7), snitch.measureCallHere(returnsSeven, .{}, @src()));

    if (!snitch.enabled) {
        return;
    }

    const profiler = snitch.defaultProfiler().?;
    var report_storage: [4_096]u8 = undefined;
    const report = try writeReportToBuffer(profiler, &report_storage);

    try expectContains(report, "[snitch] zones=3");
    try expectNotContains(report, "before-start");
    if ((snitch.timing_enabled or snitch.memory_enabled) and snitch.report_max_rows == 0) {
        try expectContains(report, "global-zone");
        try expectContains(report, "global-call");
    }
}

test "process-wide zones are ignored after stop" {
    snitch.start(std.testing.io, std.testing.allocator);
    snitch.stop();
    try std.testing.expect(snitch.defaultProfiler() == null);

    var zone = snitch.zone("after-stop");
    zone.end();
}
