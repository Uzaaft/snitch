const std = @import("std");
const snitch = @import("snitch");

fn busyLoop(iterations: usize) u64 {
    var checksum: u64 = 0;
    var index: usize = 0;

    while (index < iterations) : (index += 1) {
        checksum +%= @as(u64, @intCast(index *% 17));
    }

    return checksum;
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

pub fn main(init: std.process.Init) !void {
    snitch.start(init.io, std.heap.page_allocator);
    defer snitch.finish(.{});

    const tracked_allocator = snitch.allocator();

    var run_index: usize = 0;
    while (run_index < 2_000) : (run_index += 1) {
        {
            const zone = snitch.zone("busy-loop");
            defer zone.end();
            _ = busyLoop(600 + run_index);
        }

        {
            const zone = snitch.zone("alloc-work");
            defer zone.end();
            _ = try allocationWork(tracked_allocator, 128 + (run_index % 128));
        }
    }

    const checksum = snitch.measureCall("single-call", busyLoop, .{80_000});
    _ = try snitch.measureCall("alloc-single-call", allocationWork, .{ tracked_allocator, @as(usize, 24_000) });

    {
        const zone = snitch.zone(@src());
        defer zone.end();
        _ = busyLoop(40_000);
    }

    std.debug.print("snitch enabled: {any}, checksum: {d}\n", .{ snitch.enabled, checksum });
}
