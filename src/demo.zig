const std = @import("std");
const hotpath = @import("hotpath");

fn cpuWork(iterations: usize) u64 {
    var total: u64 = 0;
    var index: usize = 0;

    while (index < iterations) : (index += 1) {
        total +%= @as(u64, @intCast(index));
    }

    return total;
}

fn allocationWork(allocator: std.mem.Allocator, size: usize) !u64 {
    var buffer = try allocator.alloc(u8, size);
    defer allocator.free(buffer);

    var index: usize = 0;
    while (index < buffer.len) : (index += 1) {
        buffer[index] = @intCast(index % 251);
    }

    var checksum: u64 = 0;
    for (buffer) |byte| {
        checksum +%= byte;
    }

    return checksum;
}

pub fn main() !void {
    var profiler = hotpath.Profiler.init(std.heap.page_allocator);
    defer profiler.deinit();

    const tracked_allocator = profiler.allocator();

    var run_index: usize = 0;
    while (run_index < 3_000) : (run_index += 1) {
        {
            var zone = profiler.zone("cpuWork");
            defer zone.end();
            _ = cpuWork(900 + run_index);
        }

        {
            var zone = profiler.zone("allocWork");
            defer zone.end();
            _ = try allocationWork(tracked_allocator, 128 + (run_index % 256));
        }
    }

    _ = hotpath.measureCall(&profiler, "single-call", cpuWork, .{70_000});
    _ = try hotpath.measureCall(&profiler, "alloc-single-call", allocationWork, .{ tracked_allocator, @as(usize, 32_000) });

    _ = hotpath.measureBlock(&profiler, "custom-block", struct {
        fn run() u64 {
            return cpuWork(25_000);
        }
    }.run);

    try hotpath.writeReportStdout(&profiler, 4_096);
}
