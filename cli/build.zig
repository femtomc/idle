const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // =========================================================================
    // Dependencies from build.zig.zon
    // =========================================================================

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

    // =========================================================================
    // SQLite (built from zawinski's vendored copy)
    // =========================================================================

    const sqlite_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    sqlite_mod.addIncludePath(zawinski_dep.path("vendor/sqlite"));
    sqlite_mod.addCSourceFile(.{
        .file = zawinski_dep.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_ENABLE_JSON1",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
        },
    });
    const sqlite = b.addLibrary(.{
        .name = "sqlite3",
        .root_module = sqlite_mod,
        .linkage = .static,
    });
    sqlite.linkLibC();

    // =========================================================================
    // idle library module (our core logic)
    // =========================================================================

    const lib_mod = b.addModule("idle", .{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zawinski", .module = zawinski_mod },
            .{ .name = "tissue", .module = tissue_mod },
        },
    });
    lib_mod.addIncludePath(zawinski_dep.path("vendor/sqlite"));

    // =========================================================================
    // Executable: idle-hook
    // =========================================================================

    const exe = b.addExecutable(.{
        .name = "idle-hook",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "idle", .module = lib_mod },
                .{ .name = "zawinski", .module = zawinski_mod },
                .{ .name = "tissue", .module = tissue_mod },
            },
        }),
    });
    exe.root_module.addIncludePath(zawinski_dep.path("vendor/sqlite"));
    exe.linkLibrary(sqlite);

    b.installArtifact(exe);

    // =========================================================================
    // Run step
    // =========================================================================

    const run_step = b.step("run", "Run idle-hook");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // =========================================================================
    // Test step
    // =========================================================================

    const lib_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    lib_tests.linkLibrary(sqlite);
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
}
