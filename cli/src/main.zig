const std = @import("std");
const idle = @import("idle");
const zawinski = @import("zawinski");

const hooks = struct {
    const stop = @import("hooks/stop.zig");
    const subagent_stop = @import("hooks/subagent_stop.zig");
    const pre_tool_use = @import("hooks/pre_tool_use.zig");
    const pre_compact = @import("hooks/pre_compact.zig");
    const session_start = @import("hooks/session_start.zig");
};

const usage =
    \\Usage: idle-hook <command> [options]
    \\
    \\Hooks:
    \\  stop           Stop hook (core loop mechanism)
    \\  subagent-stop  Subagent stop hook (alice second-opinion gate)
    \\  pre-tool-use   Pre-tool-use hook (safety guardrails)
    \\  pre-compact    Pre-compact hook (recovery anchors)
    \\  session-start  Session start hook (agent awareness)
    \\
    \\Commands:
    \\  status         Show loop status (JSON or human-readable)
    \\  doctor         Check environment dependencies
    \\  emit           Post structured message to jwz
    \\  spawn          Spawn a subagent (enforces limits)
    \\  worktree       Manage git worktrees for issues
    \\  version        Show version information
    \\
    \\Exit codes:
    \\  0  Allow/success
    \\  1  Error
    \\  2  Block (hook rejects, inject reason)
    \\
;

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try writeStderr(usage);
        return 1;
    }

    const command = args[1];

    // Hooks
    if (std.mem.eql(u8, command, "stop")) {
        return hooks.stop.run(allocator);
    } else if (std.mem.eql(u8, command, "subagent-stop")) {
        return hooks.subagent_stop.run(allocator);
    } else if (std.mem.eql(u8, command, "pre-tool-use")) {
        return hooks.pre_tool_use.run(allocator);
    } else if (std.mem.eql(u8, command, "pre-compact")) {
        return hooks.pre_compact.run(allocator);
    } else if (std.mem.eql(u8, command, "session-start")) {
        return hooks.session_start.run(allocator);
    }
    // Commands
    else if (std.mem.eql(u8, command, "status")) {
        return runStatus(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "doctor")) {
        return runDoctor(allocator);
    } else if (std.mem.eql(u8, command, "emit")) {
        return runEmit(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "spawn")) {
        return runSpawn(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "worktree")) {
        return runWorktree(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "version")) {
        try writeStdout("idle-hook 0.1.0\n");
        return 0;
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try writeStdout(usage);
        return 0;
    } else {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Unknown command: {s}\n\n", .{command}) catch "Unknown command\n\n";
        try writeStderr(msg);
        try writeStderr(usage);
        return 1;
    }
}

fn writeStdout(msg: []const u8) !void {
    var buf: [65536]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    try writer.interface.writeAll(msg);
    try writer.interface.flush();
}

fn writeStderr(msg: []const u8) !void {
    var buf: [65536]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buf);
    try writer.interface.writeAll(msg);
    try writer.interface.flush();
}

fn runStatus(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    const json_output = for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) break true;
    } else false;

    // Use zawinski directly
    const store_dir = zawinski.store.discoverStoreDir(allocator) catch {
        if (json_output) {
            try writeStdout("{\"status\":\"idle\"}\n");
        } else {
            try writeStdout("No active loop (no .zawinski found)\n");
        }
        return 0;
    };
    defer allocator.free(store_dir);

    var store = zawinski.store.Store.open(allocator, store_dir) catch {
        if (json_output) {
            try writeStdout("{\"status\":\"idle\"}\n");
        } else {
            try writeStdout("No active loop\n");
        }
        return 0;
    };
    defer store.deinit();

    // Get latest message from loop:current topic
    const messages = store.listMessages("loop:current", 1) catch {
        if (json_output) {
            try writeStdout("{\"status\":\"idle\"}\n");
        } else {
            try writeStdout("No active loop\n");
        }
        return 0;
    };
    defer {
        for (messages) |*m| m.deinit(allocator);
        allocator.free(messages);
    }

    if (messages.len == 0) {
        if (json_output) {
            try writeStdout("{\"status\":\"idle\"}\n");
        } else {
            try writeStdout("No active loop\n");
        }
        return 0;
    }

    const state_json = messages[0].body;

    if (json_output) {
        try writeStdout(std.mem.trim(u8, state_json, " \t\n\r"));
        try writeStdout("\n");
    } else {
        // Parse and display
        var parsed = idle.parseEvent(allocator, state_json) catch null;
        defer if (parsed) |*p| p.deinit();

        if (parsed) |p| {
            const state = p.state;
            if (state.stack.len == 0) {
                try writeStdout("No active loop\n");
            } else {
                const frame = state.stack[state.stack.len - 1];
                var buf: [1024]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&buf);
                const w = fbs.writer();
                w.print("Mode: {s}\n", .{@tagName(frame.mode)}) catch {};
                w.print("Iteration: {}/{}\n", .{ frame.iter, frame.max }) catch {};
                if (frame.issue_id) |id| {
                    w.print("Issue: {s}\n", .{id}) catch {};
                }
                if (frame.worktree_path) |path| {
                    w.print("Worktree: {s}\n", .{path}) catch {};
                }
                try writeStdout(fbs.getWritten());
            }
        } else {
            try writeStdout("Could not parse loop state\n");
        }
    }

    return 0;
}

fn runDoctor(allocator: std.mem.Allocator) !u8 {
    const checks = try idle.doctor.runChecks(allocator);
    defer {
        for (checks) |*c| {
            _ = c; // Check doesn't need deallocation
        }
        allocator.free(checks);
    }

    const output = try idle.doctor.formatResults(allocator, checks);
    defer allocator.free(output);

    try writeStdout(output);

    return if (idle.doctor.allRequiredPresent(checks)) 0 else 1;
}

fn runEmit(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    // Parse: emit <topic> <role> <action> [--task-id ID] [--status S] [--confidence C] [--summary TEXT]
    if (args.len < 3) {
        try writeStderr("Usage: idle-hook emit <topic> <role> <action> [options]\n");
        return 1;
    }

    const topic = args[0];
    const role = idle.emit.Role.fromString(args[1]) orelse {
        try writeStderr("Invalid role. Must be: alice, bob, charlie, loop\n");
        return 1;
    };
    const action = idle.emit.Action.fromString(args[2]) orelse {
        try writeStderr("Invalid action.\n");
        return 1;
    };

    var task_id: ?[]const u8 = null;
    var status: ?idle.emit.Status = null;
    var confidence: ?idle.emit.Confidence = null;
    var summary: ?[]const u8 = null;

    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--task-id") and i + 1 < args.len) {
            task_id = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--status") and i + 1 < args.len) {
            status = idle.emit.Status.fromString(args[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--confidence") and i + 1 < args.len) {
            confidence = idle.emit.Confidence.fromString(args[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--summary") and i + 1 < args.len) {
            summary = args[i + 1];
            i += 1;
        }
    }

    idle.emit.emit(allocator, topic, role, action, task_id, status, confidence, summary) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Failed to emit: {s}\n", .{@errorName(err)}) catch "Failed to emit\n";
        try writeStderr(msg);
        return 1;
    };

    return 0;
}

fn runSpawn(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    // Parse: spawn <agent-type> <task-json> [--timeout N] [--background]
    if (args.len < 2) {
        try writeStderr("Usage: idle-hook spawn <charlie|bob> <task-json> [--timeout N] [--background]\n");
        return 1;
    }

    const agent = idle.spawn.AgentType.fromString(args[0]) orelse {
        try writeStderr("Invalid agent type. Must be: charlie, bob\n");
        return 1;
    };
    const task_json = args[1];

    var timeout: ?u32 = null;
    var background = false;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--timeout") and i + 1 < args.len) {
            timeout = std.fmt.parseInt(u32, args[i + 1], 10) catch null;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--background")) {
            background = true;
        }
    }

    const result = idle.spawn.spawn(allocator, agent, task_json, timeout, background) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Spawn failed: {s}\n", .{@errorName(err)}) catch "Spawn failed\n";
        try writeStderr(msg);
        return 1;
    };

    return switch (result) {
        .success => 0,
        .depth_exceeded => blk: {
            try writeStderr("Error: MAX_DEPTH exceeded\n");
            break :blk 1;
        },
        .invalid_contract => blk: {
            try writeStderr("Error: Invalid task contract\n");
            break :blk 1;
        },
        .spawn_failed => blk: {
            try writeStderr("Error: Spawn failed\n");
            break :blk 1;
        },
    };
}

fn runWorktree(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    // Parse: worktree <create|land|cleanup> <issue-id> [--base REF]
    if (args.len < 2) {
        try writeStderr("Usage: idle-hook worktree <create|land|cleanup> <issue-id> [--base REF]\n");
        return 1;
    }

    const subcommand = args[0];
    const issue_id = args[1];

    var base_ref: ?[]const u8 = null;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--base") and i + 1 < args.len) {
            base_ref = args[i + 1];
            i += 1;
        }
    }

    const result = if (std.mem.eql(u8, subcommand, "create"))
        idle.worktree.create(allocator, issue_id, base_ref) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Worktree create failed: {s}\n", .{@errorName(err)}) catch "Failed\n";
            try writeStderr(msg);
            return 1;
        }
    else if (std.mem.eql(u8, subcommand, "land"))
        idle.worktree.land(allocator, issue_id, base_ref) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Worktree land failed: {s}\n", .{@errorName(err)}) catch "Failed\n";
            try writeStderr(msg);
            return 1;
        }
    else if (std.mem.eql(u8, subcommand, "cleanup"))
        idle.worktree.cleanup(allocator, issue_id) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Worktree cleanup failed: {s}\n", .{@errorName(err)}) catch "Failed\n";
            try writeStderr(msg);
            return 1;
        }
    else {
        try writeStderr("Unknown subcommand. Use: create, land, cleanup\n");
        return 1;
    };

    return switch (result) {
        .success => 0,
        .already_exists => blk: {
            try writeStdout("Worktree already exists\n");
            break :blk 0;
        },
        .not_found => blk: {
            try writeStderr("Worktree not found\n");
            break :blk 1;
        },
        .dirty => blk: {
            try writeStderr("Worktree has uncommitted changes\n");
            break :blk 1;
        },
        .merge_failed => blk: {
            try writeStderr("Merge failed\n");
            break :blk 1;
        },
        .push_failed => blk: {
            try writeStderr("Push failed\n");
            break :blk 1;
        },
        .error_state => blk: {
            try writeStderr("Error\n");
            break :blk 1;
        },
    };
}

test {
    std.testing.refAllDecls(@This());
}
