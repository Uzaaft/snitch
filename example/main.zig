const std = @import("std");
const snitch = @import("snitch");

/// A message header as it might be sent over the wire. The field order wastes
/// space; `zig build snitch-layout -Dsnitch-layout=example` shows how much.
const Header = extern struct {
    is_retry: bool,
    sequence: u64,
    kind: u8,
    timestamp_ns: u64,
    length: u32,
};

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
    // Optional row limit: zig build run -Dsnitch=true -- 3
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const max_rows = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 0;
    snitch.start(init.io, std.heap.page_allocator);
    defer snitch.finish(.{ .max_rows = max_rows });

    const tracked_allocator = snitch.allocator();

    var run_index: usize = 0;
    while (run_index < 2_000) : (run_index += 1) {
        const frame = snitch.zone("frame");
        defer frame.end();
        {
            const zone = snitch.zone("busy-loop");
            defer zone.end();
            _ = snitch.measureCall("sample", busyLoop, .{600 + run_index});
            if (run_index == 0) {
                _ = snitch.measureCall("café-render-with-a-deliberately-long-label-ééé", busyLoop, .{@as(usize, 10)});
            }
        }

        {
            const zone = snitch.zone("alloc-work");
            defer zone.end();
            _ = try snitch.measureCall("sample", allocationWork, .{ tracked_allocator, 128 + (run_index % 128) });
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
