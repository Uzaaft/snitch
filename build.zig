const std = @import("std");
const snitch_build = @import("src/snitch.zig");

const Config = struct {
    enabled: bool,
    timing_enabled: bool = true,
    memory_enabled: bool = true,
};

fn addOptionsModule(b: *std.Build, config: Config) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(bool, "snitch", config.enabled);
    options.addOption(bool, "snitch_timing", config.timing_enabled);
    options.addOption(bool, "snitch_memory", config.memory_enabled);
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
    };

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

    snitch_build.addLayoutStep(b, example.root_module);

    // Every test runs once per configuration, since most code paths are
    // selected at compile time.
    const test_configs = [_]struct { name: []const u8, config: Config }{
        .{ .name = "off", .config = .{ .enabled = false } },
        .{ .name = "on", .config = .{ .enabled = true } },
        .{ .name = "timing-only", .config = .{ .enabled = true, .memory_enabled = false } },
        .{ .name = "memory-only", .config = .{ .enabled = true, .timing_enabled = false } },
        .{ .name = "groups-disabled", .config = .{ .enabled = true, .timing_enabled = false, .memory_enabled = false } },
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
