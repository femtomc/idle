const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create root module
    const root_module = b.addModule("root", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create the executable
    const exe = b.addExecutable(.{
        .name = "idle",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    // Build step
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Test step for state machine
    const test_sm_module = b.addModule("test_state_machine", .{
        .root_source_file = b.path("src/state_machine.zig"),
        .target = target,
        .optimize = optimize,
    });

    const state_machine_tests = b.addTest(.{
        .root_module = test_sm_module,
    });

    const run_state_machine_tests = b.addRunArtifact(state_machine_tests);

    // Test step for event parser
    const test_ep_module = b.addModule("test_event_parser", .{
        .root_source_file = b.path("src/event_parser.zig"),
        .target = target,
        .optimize = optimize,
    });

    const event_parser_tests = b.addTest(.{
        .root_module = test_ep_module,
    });

    const run_event_parser_tests = b.addRunArtifact(event_parser_tests);

    // Test step for hook
    const test_hook_module = b.addModule("test_hook", .{
        .root_source_file = b.path("src/hook.zig"),
        .target = target,
        .optimize = optimize,
    });

    const hook_tests = b.addTest(.{
        .root_module = test_hook_module,
    });

    const run_hook_tests = b.addRunArtifact(hook_tests);

    // Test step for replay
    const test_replay_module = b.addModule("test_replay", .{
        .root_source_file = b.path("src/replay.zig"),
        .target = target,
        .optimize = optimize,
    });

    const replay_tests = b.addTest(.{
        .root_module = test_replay_module,
    });

    const run_replay_tests = b.addRunArtifact(replay_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_state_machine_tests.step);
    test_step.dependOn(&run_event_parser_tests.step);
    test_step.dependOn(&run_hook_tests.step);
    test_step.dependOn(&run_replay_tests.step);
}
