const std = @import("std");

const SnitchModule = struct {
    module: *std.Build.Module,
    options_module: *std.Build.Module,
};

const SnitchConfig = struct {
    enabled: bool,
    timing_enabled: bool,
    memory_enabled: bool,
    percentile: u8,
    max_rows: usize,
};

fn createSnitchModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    config: SnitchConfig,
) SnitchModule {
    const build_options = b.addOptions();
    build_options.addOption(bool, "snitch", config.enabled);
    build_options.addOption(bool, "snitch_timing", config.timing_enabled);
    build_options.addOption(bool, "snitch_memory", config.memory_enabled);
    build_options.addOption(u8, "snitch_percentile", config.percentile);
    build_options.addOption(usize, "snitch_max_rows", config.max_rows);
    const options_module = build_options.createModule();

    const module = b.createModule(.{
        .root_source_file = b.path("src/snitch.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = options_module },
        },
    });

    return .{
        .module = module,
        .options_module = options_module,
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const snitch_enabled = b.option(bool, "snitch", "Enable snitch instrumentation") orelse
        b.option(bool, "hotpath", "Deprecated alias for -Dsnitch") orelse
        false;

    const snitch_timing_enabled = b.option(bool, "snitch-timing", "Enable snitch timing metrics") orelse
        b.option(bool, "snitch_timing", "Enable snitch timing metrics") orelse
        true;

    const snitch_memory_enabled = b.option(bool, "snitch-memory", "Enable snitch memory metrics") orelse
        b.option(bool, "snitch_memory", "Enable snitch memory metrics") orelse
        true;

    const snitch_percentile = b.option(u8, "snitch-percentile", "Percentile shown in reports (1-100)") orelse
        b.option(u8, "snitch_percentile", "Percentile shown in reports (1-100)") orelse
        85;

    if (snitch_percentile == 0 or snitch_percentile > 100) {
        std.log.err(
            "snitch-percentile must be between 1 and 100, got {d}",
            .{snitch_percentile},
        );
        std.process.exit(1);
    }

    const snitch_max_rows = b.option(usize, "snitch-max-rows", "Max rows per report section (0 = unlimited)") orelse
        b.option(usize, "snitch_max_rows", "Max rows per report section (0 = unlimited)") orelse
        0;

    const selected_config = SnitchConfig{
        .enabled = snitch_enabled,
        .timing_enabled = snitch_timing_enabled,
        .memory_enabled = snitch_memory_enabled,
        .percentile = snitch_percentile,
        .max_rows = snitch_max_rows,
    };

    const selected = createSnitchModule(
        b,
        target,
        optimize,
        selected_config,
    );
    _ = b.addModule("hotpath", .{
        .root_source_file = b.path("src/snitch.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = selected.options_module },
        },
    });

    const library_root_module = b.createModule(.{
        .root_source_file = b.path("src/snitch.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = selected.options_module },
        },
    });

    const library = b.addLibrary(.{
        .name = "hotpath",
        .linkage = .static,
        .root_module = library_root_module,
    });
    b.installArtifact(library);

    const demo_root_module = b.createModule(.{
        .root_source_file = b.path("src/demo.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hotpath", .module = selected.module },
        },
    });

    const demo = b.addExecutable(.{
        .name = "hotpath-demo",
        .root_module = demo_root_module,
    });
    b.installArtifact(demo);

    const run_demo = b.addRunArtifact(demo);
    if (b.args) |args| {
        run_demo.addArgs(args);
    }
    const run_step = b.step("run", "Run the demo");
    run_step.dependOn(&run_demo.step);

    const example_root_module = b.createModule(.{
        .root_source_file = b.path("example/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hotpath", .module = selected.module },
        },
    });

    const example_program = b.addExecutable(.{
        .name = "hotpath-example",
        .root_module = example_root_module,
    });
    b.installArtifact(example_program);

    const run_example = b.addRunArtifact(example_program);
    if (b.args) |args| {
        run_example.addArgs(args);
    }
    const example_step = b.step("example", "Run the example program from example/main.zig");
    example_step.dependOn(&run_example.step);

    const tests_off_module = createSnitchModule(b, target, optimize, .{
        .enabled = false,
        .timing_enabled = false,
        .memory_enabled = false,
        .percentile = 95,
        .max_rows = 0,
    });
    const tests_off_root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hotpath", .module = tests_off_module.module },
        },
    });
    const tests_off = b.addTest(.{
        .name = "tests-hotpath-off",
        .root_module = tests_off_root_module,
    });
    const run_tests_off = b.addRunArtifact(tests_off);

    const tests_on_module = createSnitchModule(b, target, optimize, .{
        .enabled = true,
        .timing_enabled = true,
        .memory_enabled = true,
        .percentile = 95,
        .max_rows = 0,
    });
    const tests_on_root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hotpath", .module = tests_on_module.module },
        },
    });
    const tests_on = b.addTest(.{
        .name = "tests-hotpath-on",
        .root_module = tests_on_root_module,
    });
    const run_tests_on = b.addRunArtifact(tests_on);

    const tests_timing_only_module = createSnitchModule(b, target, optimize, .{
        .enabled = true,
        .timing_enabled = true,
        .memory_enabled = false,
        .percentile = 95,
        .max_rows = 0,
    });
    const tests_timing_only_root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hotpath", .module = tests_timing_only_module.module },
        },
    });
    const tests_timing_only = b.addTest(.{
        .name = "tests-hotpath-timing-only",
        .root_module = tests_timing_only_root_module,
    });
    const run_tests_timing_only = b.addRunArtifact(tests_timing_only);

    const tests_memory_only_module = createSnitchModule(b, target, optimize, .{
        .enabled = true,
        .timing_enabled = false,
        .memory_enabled = true,
        .percentile = 95,
        .max_rows = 0,
    });
    const tests_memory_only_root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hotpath", .module = tests_memory_only_module.module },
        },
    });
    const tests_memory_only = b.addTest(.{
        .name = "tests-hotpath-memory-only",
        .root_module = tests_memory_only_root_module,
    });
    const run_tests_memory_only = b.addRunArtifact(tests_memory_only);

    const tests_groups_disabled_module = createSnitchModule(b, target, optimize, .{
        .enabled = true,
        .timing_enabled = false,
        .memory_enabled = false,
        .percentile = 95,
        .max_rows = 0,
    });
    const tests_groups_disabled_root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hotpath", .module = tests_groups_disabled_module.module },
        },
    });
    const tests_groups_disabled = b.addTest(.{
        .name = "tests-hotpath-groups-disabled",
        .root_module = tests_groups_disabled_root_module,
    });
    const run_tests_groups_disabled = b.addRunArtifact(tests_groups_disabled);

    const tests_limited_rows_module = createSnitchModule(b, target, optimize, .{
        .enabled = true,
        .timing_enabled = true,
        .memory_enabled = true,
        .percentile = 95,
        .max_rows = 1,
    });
    const tests_limited_rows_root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hotpath", .module = tests_limited_rows_module.module },
        },
    });
    const tests_limited_rows = b.addTest(.{
        .name = "tests-hotpath-limited-rows",
        .root_module = tests_limited_rows_root_module,
    });
    const run_tests_limited_rows = b.addRunArtifact(tests_limited_rows);

    const test_step = b.step("test", "Run tests across snitch compile-time configurations");
    test_step.dependOn(&run_tests_off.step);
    test_step.dependOn(&run_tests_on.step);
    test_step.dependOn(&run_tests_timing_only.step);
    test_step.dependOn(&run_tests_memory_only.step);
    test_step.dependOn(&run_tests_groups_disabled.step);
    test_step.dependOn(&run_tests_limited_rows.step);
}
