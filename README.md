# hotpath-zig

`hotpath-zig` is a Zig 0.15.2 profiling helper inspired by [pawurb/hotpath-rs](https://github.com/pawurb/hotpath-rs).

The design goal is simple: keep instrumentation calls in your codebase permanently, then decide at build time whether they do real work.

When `snitch` is disabled, profiler APIs stay available and compile to no-op inline paths. When enabled, the profiler collects timing and allocator activity and prints a sorted ASCII report.

## Build Flags

`build.zig` accepts these options:

| Flag | Default | Meaning |
| --- | --- | --- |
| `-Dsnitch` | `false` | Master switch for instrumentation. |
| `-Dsnitch-timing` | `true` | Enable timing metrics section. |
| `-Dsnitch-memory` | `true` | Enable allocation metrics sections. |
| `-Dsnitch-percentile` | `85` | Percentile column (`1..100`). |
| `-Dsnitch-max-rows` | `0` | Rows per section (`0` means unlimited). |

Deprecated compatibility alias: `-Dhotpath=true` also enables `snitch`.

Notes:

1. `snitch-timing` and `snitch-memory` only matter when `snitch=true`.
2. Invalid percentile values (`0` or `>100`) fail the build.
3. If `snitch=true` and both metric groups are disabled, report output explains that nothing is enabled.

## Quick Start

```zig
const std = @import("std");
const hotpath = @import("hotpath");

fn handler(id: usize) u64 {
    return @intCast(id *% 17);
}

pub fn main() !void {
    var profiler = hotpath.Profiler.init(std.heap.page_allocator);
    defer profiler.deinit();

    // Use this allocator in code you want memory attribution for.
    const tracked_allocator = profiler.allocator();

    {
        var zone = profiler.zone("db-query");
        defer zone.end();

        const payload = try tracked_allocator.alloc(u8, 256);
        defer tracked_allocator.free(payload);
    }

    _ = hotpath.measureCall(&profiler, "handler", handler, .{@as(usize, 5)});

    _ = hotpath.measureCallHere(&profiler, handler, .{@as(usize, 7)}, @src());

    _ = hotpath.measureBlockHere(&profiler, struct {
        fn run() void {}
    }.run, @src());

    try hotpath.writeReportStdout(&profiler, 4_096);
}
```

On Zig 0.15.x, callsite helpers require explicit `@src()`.

## Report Semantics

Each enabled section is sorted by `Total` descending and shows:

1. `Calls`
2. `Avg`
3. `Pxx` where `xx` is `snitch-percentile`
4. `Total`
5. `% Total`

Timing section title:

1. `snitch-timing - Function execution time metrics.`

Memory sections:

1. `snitch-memory-bytes - Cumulative allocation bytes during each function call.`
2. `snitch-memory-count - Allocation call count during each function call.`

Memory metrics are computed from allocations made through `profiler.allocator()`. If code allocates with a different allocator, those bytes and allocation counts are intentionally not attributed. Allocation counters are profiler-wide, so overlapping concurrent zones can include each other's allocations.

If `snitch-max-rows` is non-zero, each section is truncated independently after sorting and the report prints a truncation note.

## Logging

Scoped logger: `snitch`.

Important log cases:

1. `info`: report requested with zero measured zones.
2. `warn`: `snitch` enabled while both metric groups are disabled.
3. `info`: section rows truncated by `snitch-max-rows`.

## Local Commands

Run demo (default config):

```bash
zig build run
```

Run demo with profiling enabled:

```bash
zig build -Dsnitch=true run
```

Run example program under `example/main.zig`:

```bash
zig build -Dsnitch=true example
```

Run test matrix:

```bash
zig build test
```

## Using From Another `build.zig`

```zig
const hotpath_dep = b.dependency("hotpath-zig", .{
    .target = target,
    .optimize = optimize,
    .snitch = b.option(bool, "snitch", "Enable profiling") orelse false,
    .snitch_timing = b.option(bool, "snitch-timing", "Enable timing metrics") orelse true,
    .snitch_memory = b.option(bool, "snitch-memory", "Enable memory metrics") orelse true,
    .snitch_percentile = b.option(u8, "snitch-percentile", "Report percentile") orelse 85,
    .snitch_max_rows = b.option(usize, "snitch-max-rows", "Max rows per report section") orelse 0,
});

exe.root_module.addImport("hotpath", hotpath_dep.module("hotpath"));
```
