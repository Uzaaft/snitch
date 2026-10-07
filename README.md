# snitch

A small profiler for Zig 0.17, inspired by [pawurb/hotpath-rs](https://github.com/pawurb/hotpath-rs).

Instrumentation calls stay in your code permanently, and a build flag decides whether they do anything. With snitch off, every call is inlined to a no-op. With snitch on, it records execution time and allocations per zone and prints a sorted report.

## Usage

Start the process-wide profiler once in `main`. `finish` prints the report to stderr when `main` returns.

```zig
const std = @import("std");
const snitch = @import("snitch");

fn handler(id: usize) u64 {
    return @intCast(id *% 17);
}

pub fn main(init: std.process.Init) !void {
    snitch.start(init.io, init.gpa);
    defer snitch.finish(.{});

    {
        const zone = snitch.zone("db-query");
        defer zone.end();

        // Allocations through this allocator count towards memory metrics.
        const tracked_allocator = snitch.allocator();
        const payload = try tracked_allocator.alloc(u8, 256);
        defer tracked_allocator.free(payload);
    }

    _ = snitch.measureCall("handler", handler, .{@as(usize, 5)});

    // Pass @src() instead of a string to label a zone with the calling
    // function, file and line: "main (main.zig:26)".
    const here = snitch.zone(@src());
    defer here.end();
}
```

`measureCall` takes the same names as `zone`. Zig cannot capture a caller's location implicitly, so `@src()` has to be passed explicitly.

Zones started before `start` or after `finish` are ignored, so libraries can add zones without requiring the application to use snitch.

### Separate profilers

To keep separate sets of metrics, create a `Profiler` yourself. It has the same functions as methods:

```zig
var profiler = snitch.Profiler.init(io, allocator);
defer profiler.deinit();

const zone = profiler.zone("db-query");
zone.end();
_ = profiler.measureCall("handler", handler, .{@as(usize, 5)});

try profiler.printReport(.{}); // or profiler.writeReport(writer, .{})
```

## Build flags

| Flag | Default | Meaning |
| --- | --- | --- |
| `-Dsnitch` | `false` | Turn instrumentation on. |
| `-Dsnitch-timing` | `true` | Record execution time. |
| `-Dsnitch-memory` | `true` | Record allocations. |

The timing and memory flags only matter when `-Dsnitch=true`.

## Using snitch as a dependency

```zig
const snitch_dep = b.dependency("snitch", .{
    .target = target,
    .optimize = optimize,
    .snitch = b.option(bool, "snitch", "Enable profiling") orelse false,
    .@"snitch-timing" = b.option(bool, "snitch-timing", "Enable timing metrics") orelse true,
    .@"snitch-memory" = b.option(bool, "snitch-memory", "Enable memory metrics") orelse true,
});

exe.root_module.addImport("snitch", snitch_dep.module("snitch"));
```

## The report

```
[snitch] 2 zones

Timing per call
+-------------+-------+---------+---------+---------+---------+---------+---------+---------+
| Zone        | Calls |     Avg |     P50 |     P95 |     P99 |     Max |   Total | % Total |
+-------------+-------+---------+---------+---------+---------+---------+---------+---------+
| alloc-work  | 2,000 | 3.31 us | 3.07 us | 5.38 us | 9.47 us | 48.9 us | 6.62 ms |  70.88% |
| busy-loop   | 2,000 | 1.36 us | 1.33 us | 2.34 us | 2.43 us | 4.53 us | 2.72 ms |  29.12% |
+-------------+-------+---------+---------+---------+---------+---------+---------+---------+

Memory allocated per call
+-------------+-------+-------+-------+-------+-------+-------+---------+-------------+---------+
| Zone        | Calls |   Avg |   P50 |   P95 |   P99 |   Max |   Total | Allocs/call | % Total |
+-------------+-------+-------+-------+-------+-------+-------+---------+-------------+---------+
| alloc-work  | 2,000 | 190 B | 191 B | 249 B | 255 B | 255 B | 372 KiB |        1.00 | 100.00% |
+-------------+-------+-------+-------+-------+-------+-------+---------+-------------+---------+
```

The timing table lists every zone. The memory table lists only zones that allocated through the tracked allocator. Both are sorted by `Total`, highest first.

To show only the biggest zones, pass `.{ .max_rows = 20 }` to `finish`, `printReport` or `writeReport`. Each table then shows its top rows and notes how many it left out.

Percentiles come from a fixed-size histogram per label, so memory use stays flat no matter how many times a zone runs. A percentile may read up to 1/64 (about 1.6%) above the true value; averages and totals are exact.

Memory metrics count allocations made through `snitch.allocator()` or `Profiler.allocator()` on the thread that ran the zone, so zones running concurrently on other threads don't pollute each other. End each zone on the thread that started it.

Recording a zone is lock-free and costs about 50 ns, most of it reading the clock twice. Zones much shorter than that are mostly measuring snitch itself.

If snitch is on but both metric groups are off, the report says so instead of printing tables.

## Development

```bash
zig build run                 # run example/main.zig with snitch off
zig build run -Dsnitch=true   # run it with snitch on
zig build test                # run the tests in every build configuration
```
