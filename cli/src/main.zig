const std = @import("std");
const idle = @import("idle");
const zawinski = @import("zawinski");

const hooks = struct {
    const stop = @import("hooks/stop.zig");
    const pre_compact = @import("hooks/pre_compact.zig");
    const session_start = @import("hooks/session_start.zig");
};

const usage =
    \\Usage: idle <command> [options]
    \\
    \\Hooks:
    \\  stop           Stop hook (core loop mechanism, alice review)
    \\  pre-compact    Pre-compact hook (recovery anchors)
    \\  session-start  Session start hook (loop context, agent awareness)
    \\
    \\Commands:
    \\  status         Show loop status (JSON or human-readable)
    \\  doctor         Check environment dependencies
    \\  emit           Post structured message to jwz
    \\  issues         List/show issues from tissue
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
    } else if (std.mem.eql(u8, command, "issues")) {
        return runIssues(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "version")) {
        try writeStdout("idle 1.5.5\n");
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
        try writeStderr("Usage: idle emit <topic> <role> <action> [options]\n");
        return 1;
    }

    const topic = args[0];
    const role = idle.emit.Role.fromString(args[1]) orelse {
        try writeStderr("Invalid role. Must be: alice, loop\n");
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

fn runIssues(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    const tissue = @import("tissue");

    // Parse: issues [ready|show <id>] [--json]
    var json = false;
    var subcommand: []const u8 = "ready";
    var issue_id: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--json")) {
            json = true;
        } else if (std.mem.eql(u8, args[i], "ready")) {
            subcommand = "ready";
        } else if (std.mem.eql(u8, args[i], "show") and i + 1 < args.len) {
            subcommand = "show";
            i += 1;
            issue_id = args[i];
        } else if (std.mem.eql(u8, args[i], "close") and i + 1 < args.len) {
            subcommand = "close";
            i += 1;
            issue_id = args[i];
        } else if (issue_id == null and !std.mem.startsWith(u8, args[i], "-")) {
            // Bare argument - treat as issue ID for show
            issue_id = args[i];
            subcommand = "show";
        }
    }

    // Open store
    const store_dir = tissue.store.discoverStoreDir(allocator) catch {
        try writeStderr("No .tissue store found\n");
        return 1;
    };
    defer allocator.free(store_dir);

    var store = tissue.store.Store.open(allocator, store_dir) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Failed to open store: {s}\n", .{@errorName(err)}) catch "Failed to open store\n";
        try writeStderr(msg);
        return 1;
    };
    defer store.deinit();

    if (std.mem.eql(u8, subcommand, "ready")) {
        const ready_issues = store.listReadyIssues() catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Failed to list issues: {s}\n", .{@errorName(err)}) catch "Failed\n";
            try writeStderr(msg);
            return 1;
        };
        defer {
            for (ready_issues) |*issue| issue.deinit(allocator);
            allocator.free(ready_issues);
        }

        if (json) {
            try writeStdout("[");
            for (ready_issues, 0..) |issue, idx| {
                if (idx > 0) try writeStdout(",");
                var buf: [4096]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&buf);
                const w = fbs.writer();
                w.print("{{\"id\":\"{s}\",\"title\":\"{s}\",\"priority\":{d}}}", .{
                    issue.id,
                    issue.title,
                    issue.priority,
                }) catch {};
                try writeStdout(fbs.getWritten());
            }
            try writeStdout("]\n");
        } else {
            if (ready_issues.len == 0) {
                try writeStdout("No ready issues\n");
            } else {
                for (ready_issues) |issue| {
                    var buf: [256]u8 = undefined;
                    const line = std.fmt.bufPrint(&buf, "{s}  P{d}  {s}\n", .{
                        issue.id,
                        issue.priority,
                        issue.title,
                    }) catch continue;
                    try writeStdout(line);
                }
            }
        }
    } else if (std.mem.eql(u8, subcommand, "show")) {
        const id = issue_id orelse {
            try writeStderr("Usage: idle issues show <id>\n");
            return 1;
        };

        var issue = store.fetchIssue(id) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Issue not found: {s}\n", .{@errorName(err)}) catch "Not found\n";
            try writeStderr(msg);
            return 1;
        };
        defer issue.deinit(allocator);

        const output = idle.issues.formatIssue(allocator, &issue) catch {
            try writeStderr("Failed to format issue\n");
            return 1;
        };
        defer allocator.free(output);
        try writeStdout(output);
    } else if (std.mem.eql(u8, subcommand, "close")) {
        const id = issue_id orelse {
            try writeStderr("Usage: idle issues close <id>\n");
            return 1;
        };

        store.updateIssue(id, null, null, "closed", null, &.{}, &.{}) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Failed to close: {s}\n", .{@errorName(err)}) catch "Failed\n";
            try writeStderr(msg);
            return 1;
        };

        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Closed {s}\n", .{id}) catch "Closed\n";
        try writeStdout(msg);
    }

    return 0;
}

test {
    std.testing.refAllDecls(@This());
}
