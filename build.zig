const std = @import("std");

const Config = struct {
    enabled: bool,
    timing_enabled: bool = true,
    memory_enabled: bool = true,
    percentile: u8 = 85,
    max_rows: usize = 0,
};

fn addOptionsModule(b: *std.Build, config: Config) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(bool, "snitch", config.enabled);
    options.addOption(bool, "snitch_timing", config.timing_enabled);
    options.addOption(bool, "snitch_memory", config.memory_enabled);
    options.addOption(u8, "snitch_percentile", config.percentile);
    options.addOption(usize, "snitch_max_rows", config.max_rows);
    return options.createModule();
}

fn createSnitchModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    config: Config,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/snitch.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = addOptionsModule(b, config) },
        },
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const config = Config{
        .enabled = b.option(bool, "snitch", "Enable instrumentation") orelse false,
        .timing_enabled = b.option(bool, "snitch-timing", "Enable timing metrics") orelse true,
        .memory_enabled = b.option(bool, "snitch-memory", "Enable allocation metrics") orelse true,
        .percentile = b.option(u8, "snitch-percentile", "Percentile shown in reports (1-100)") orelse 85,
        .max_rows = b.option(usize, "snitch-max-rows", "Max rows per report section (0 = unlimited)") orelse 0,
    };

    if (config.percentile == 0 or config.percentile > 100) {
        std.log.err("snitch-percentile must be between 1 and 100, got {d}", .{config.percentile});
        std.process.exit(1);
    }

    const snitch = b.addModule("snitch", .{
        .root_source_file = b.path("src/snitch.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = addOptionsModule(b, config) },
        },
    });

    const example = b.addExecutable(.{
        .name = "snitch-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "snitch", .module = snitch },
            },
        }),
    });
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    run_example.addPassthruArgs();
    const run_step = b.step("run", "Run the example program");
    run_step.dependOn(&run_example.step);

    // Every test runs once per configuration, since most code paths are
    // selected at compile time.
    const test_configs = [_]struct { name: []const u8, config: Config }{
        .{ .name = "off", .config = .{ .enabled = false } },
        .{ .name = "on", .config = .{ .enabled = true, .percentile = 95 } },
        .{ .name = "timing-only", .config = .{ .enabled = true, .memory_enabled = false, .percentile = 95 } },
        .{ .name = "memory-only", .config = .{ .enabled = true, .timing_enabled = false, .percentile = 95 } },
        .{ .name = "groups-disabled", .config = .{ .enabled = true, .timing_enabled = false, .memory_enabled = false } },
        .{ .name = "limited-rows", .config = .{ .enabled = true, .max_rows = 1 } },
    };

    const test_step = b.step("test", "Run tests across all compile-time configurations");
    for (test_configs) |test_config| {
        const tests = b.addTest(.{
            .name = b.fmt("tests-snitch-{s}", .{test_config.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tests.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "snitch", .module = createSnitchModule(b, target, optimize, test_config.config) },
                },
            }),
        });
        test_step.dependOn(&b.addRunArtifact(tests).step);

        const unit_tests = b.addTest(.{
            .name = b.fmt("unit-snitch-{s}", .{test_config.name}),
            .root_module = createSnitchModule(b, target, optimize, test_config.config),
        });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }
}
