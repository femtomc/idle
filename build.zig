const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get dependency modules
    const zawinski_dep = b.dependency("zawinski", .{
        .target = target,
        .optimize = optimize,
    });
    const zawinski_mod = zawinski_dep.module("zawinski");

    const tissue_dep = b.dependency("tissue", .{
        .target = target,
        .optimize = optimize,
    });
    const tissue_mod = tissue_dep.module("tissue");

    // Library module
    const mod = b.addModule("idle", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zawinski", .module = zawinski_mod },
            .{ .name = "tissue", .module = tissue_mod },
        },
    });

    // Executable
    const exe = b.addExecutable(.{
        .name = "idle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "idle", .module = mod },
                .{ .name = "zawinski", .module = zawinski_mod },
                .{ .name = "tissue", .module = tissue_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Test step
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
