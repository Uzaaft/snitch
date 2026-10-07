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

fn writeReportToBuffer(profiler: *snitch.Profiler, storage: []u8, options: snitch.ReportOptions) ![]const u8 {
    var report_writer: std.Io.Writer = .fixed(storage);
    try profiler.writeReport(&report_writer, options);
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

test "zones and calls accept a source location" {
    var profiler = snitch.Profiler.init(std.testing.io, std.testing.allocator);
    defer profiler.deinit();

    const call_value = profiler.measureCall(@src(), returnsSeven, .{});
    try std.testing.expectEqual(@as(u8, 7), call_value);

    var zone = profiler.zone(@src());
    zone.end();
}

fn measuredHelper(profiler: *snitch.Profiler) std.builtin.SourceLocation {
    const here = @src();
    var zone = profiler.zone(here);
    zone.end();
    return here;
}

test "source location labels name the function, file and line" {
    // The timing table lists every zone; the memory table only lists zones
    // that allocated.
    if (!snitch.timing_enabled) {
        return;
    }

    var profiler = snitch.Profiler.init(std.testing.io, std.testing.allocator);
    defer profiler.deinit();

    const location = measuredHelper(&profiler);

    var report_storage: [4_096]u8 = undefined;
    const report = try writeReportToBuffer(&profiler, &report_storage, .{});

    var label_storage: [128]u8 = undefined;
    const label = try std.fmt.bufPrint(&label_storage, "measuredHelper ({s}:{d})", .{ location.file, location.line });
    try expectContains(report, label);
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

    try profiler.printReport(.{});
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
    const report = try writeReportToBuffer(&profiler, &report_storage, .{});

    if (!snitch.enabled) {
        try std.testing.expectEqual(@as(usize, 0), report.len);
        return;
    }

    try expectContains(report, "[snitch] 1 zone\n");

    if (!snitch.timing_enabled and !snitch.memory_enabled) {
        try expectContains(report, "Both snitch-timing and snitch-memory are disabled, so there is nothing to show.");
        try expectNotContains(report, "| Zone");
        return;
    }

    try expectContains(report, "| Zone");
    try expectContains(report, " P50 |");
    try expectContains(report, " P99 |");
    try expectContains(report, "report-zone");

    if (snitch.timing_enabled) {
        try expectContains(report, "Timing per call");
    } else {
        try expectNotContains(report, "Timing per call");
    }

    if (snitch.memory_enabled) {
        try expectContains(report, "Memory allocated per call");
        try expectContains(report, " Allocs/call |");
        try expectContains(report, "96 B");
    } else {
        try expectNotContains(report, "Memory allocated per call");
        try expectNotContains(report, "Allocs/call");
    }
}

test "report max rows truncates sorted sections" {
    if (!snitch.enabled) {
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
    const report = try writeReportToBuffer(&profiler, &report_storage, .{ .max_rows = 1 });

    const truncation_note = "(showing the top 1 of 2 zones)";
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(report, truncation_note));
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
    try std.testing.expectEqual(@as(u8, 7), snitch.measureCall(@src(), returnsSeven, .{}));

    if (!snitch.enabled) {
        return;
    }

    const profiler = snitch.defaultProfiler().?;
    var report_storage: [4_096]u8 = undefined;
    const report = try writeReportToBuffer(profiler, &report_storage, .{});

    try expectContains(report, "[snitch] 3 zones\n");
    try expectNotContains(report, "before-start");
    if (snitch.timing_enabled) {
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
