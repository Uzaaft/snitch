# snitch

A small profiler for Zig 0.17, inspired by [pawurb/hotpath-rs](https://github.com/pawurb/hotpath-rs).

Instrumentation calls stay in your code permanently, and a build flag decides whether they do anything. With snitch off, every call is inlined to a no-op. With snitch on, it records execution time and allocations per zone and prints a sorted report.

## Installation

### With the package manager

```sh
zig fetch --save git+https://github.com/Uzaaft/snitch
```

```zig
// build.zig
const snitch_dep = b.dependency("snitch", .{
    .target = target,
    .optimize = optimize,
    .snitch = b.option(bool, "snitch", "Enable profiling") orelse false,
});
exe.root_module.addImport("snitch", snitch_dep.module("snitch"));

// Optional: adds `zig build snitch-layout`, see "Struct layout" below.
@import("snitch").addLayoutStep(b, exe.root_module);
```

Forward `snitch-timing` and `snitch-memory` the same way if you want them as flags in your build, for example `.@"snitch-timing" = b.option(bool, "snitch-timing", "Enable timing metrics") orelse true`.

### By copying the file

Copy `src/snitch.zig` into your project and import it with `@import("snitch.zig")`. It reads its settings from a `build_options` module, which your `build.zig` provides:

```zig
// build.zig
const options = b.addOptions();
options.addOption(bool, "snitch", b.option(bool, "snitch", "Enable profiling") orelse false);
options.addOption(bool, "snitch_timing", true);
options.addOption(bool, "snitch_memory", true);
exe.root_module.addImport("build_options", options.createModule());

// Optional: adds `zig build snitch-layout`, see "Struct layout" below.
@import("src/snitch.zig").addLayoutStep(b, exe.root_module);
```

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

End every zone before calling `finish`, including zones on other threads. Debug and ReleaseSafe builds panic if one is still open; other builds don't check.

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

## Struct layout

A separate build step prints the memory layout of every struct and union in the files or folders you choose, including private and nested ones. It needs no changes to your code, and your program is never modified. Add it to `build.zig` with `addLayoutStep`, as shown under Installation, then pass files or folders, relative to the build root:

```sh
zig build snitch-layout -Dsnitch-layout=src/model.zig,src/net
```

```
[snitch] layout of 1 type

+-------------+---------------+------+-------+---------+-----------+
| Type        | Kind          | Size | Align | Padding | Best size |
+-------------+---------------+------+-------+---------+-----------+
| main.Header | extern struct | 40 B |     8 |    18 B |      24 B |
+-------------+---------------+------+-------+---------+-----------+

main.Header
+--------------+------+--------+------+-------+---------------+
| Field        | Type | Offset | Size | Align | Padding after |
+--------------+------+--------+------+-------+---------------+
| is_retry     | bool |      0 |  1 B |     1 |           7 B |
| sequence     | u64  |      8 |  8 B |     8 |               |
| kind         | u8   |     16 |  1 B |     1 |           7 B |
| timestamp_ns | u64  |     24 |  8 B |     8 |               |
| length       | u32  |     32 |  4 B |     4 |           4 B |
+--------------+------+--------+------+-------+---------------+
```

Types are sorted by padding, and types with padding get a field-by-field breakdown. `Best size` is the size with fields ordered by alignment. It is only shown for `extern` structs: Zig already reorders the fields of ordinary structs, so their padding is usually just what alignment requires at the end.

The step copies the module's sources into the build cache, appends a list of the found types to each scanned file, and compiles and runs a small probe against the copy with the module's target, optimize mode and imports. Types created by generic functions, like `ArrayList(Order)`, and types declared inside function bodies are skipped. The files must be inside the module's root folder.

## Development

```bash
zig build run                 # run example/main.zig with snitch off
zig build run -Dsnitch=true   # run it with snitch on
zig build test                # run the tests in every build configuration
zig build snitch-layout -Dsnitch-layout=example   # struct layouts in the example
```
