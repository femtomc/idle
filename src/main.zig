//! idle CLI - Trace construction and session management for Claude Code
//!
//! Usage:
//!   idle trace <session_id>              Show trace for a session
//!   idle trace <session_id> --format dot Export as GraphViz
//!   idle sessions                        List recent sessions
//!   idle warnings <session_id>           Show warnings for a session
//!   idle version                         Show version

const std = @import("std");
const idle = @import("idle");

const version = "0.0.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Setup buffered stdout
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    if (args.len < 2) {
        try printUsage(stdout);
        try stdout.flush();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "trace")) {
        try cmdTrace(allocator, stdout, args[2..]);
    } else if (std.mem.eql(u8, command, "sessions")) {
        try cmdSessions(stdout, args[2..]);
    } else if (std.mem.eql(u8, command, "warnings")) {
        try cmdWarnings(allocator, stdout, args[2..]);
    } else if (std.mem.eql(u8, command, "version")) {
        try cmdVersion(stdout);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage(stdout);
    } else {
        try stdout.print("Unknown command: {s}\n\n", .{command});
        try printUsage(stdout);
        stdout.flush() catch {};
        std.process.exit(1);
    }
    try stdout.flush();
}

fn printUsage(stdout: anytype) !void {
    try stdout.writeAll(
        \\idle - Trace construction for Claude Code sessions
        \\
        \\Usage:
        \\  idle <command> [options]
        \\
        \\Commands:
        \\  trace <session_id>    Show trace for a session
        \\    -v, --verbose       Show detailed tool inputs and outputs
        \\    --format <fmt>      Output format: text (default), dot, json
        \\    --jwz <path>        Path to jwz store (auto-discovered if omitted)
        \\    --tissue <path>     Path to tissue store (auto-discovered if omitted)
        \\
        \\  sessions              List recent sessions
        \\    --limit <n>         Number of sessions to show (default: 10)
        \\
        \\  warnings <session_id> Show warnings for a session
        \\    --jwz <path>        Path to jwz store (auto-discovered if omitted)
        \\
        \\  version               Show version information
        \\  help                  Show this help message
        \\
        \\Examples:
        \\  idle trace abc123-def456
        \\  idle trace abc123-def456 -v
        \\  idle trace abc123-def456 --format dot > trace.dot
        \\  idle sessions --limit 5
        \\  idle warnings abc123-def456
        \\
    );
}

fn cmdTrace(allocator: std.mem.Allocator, stdout: anytype, args: []const []const u8) !void {
    if (args.len == 0) {
        try stdout.writeAll("Error: session_id required\n");
        stdout.flush() catch {};
        std.process.exit(1);
    }

    const session_id = args[0];
    var format: []const u8 = "text";
    var verbose: bool = false;
    var jwz_path: ?[]const u8 = null;
    var tissue_path: ?[]const u8 = null;

    // Parse options
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--format") and i + 1 < args.len) {
            i += 1;
            format = args[i];
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--jwz") and i + 1 < args.len) {
            i += 1;
            jwz_path = args[i];
        } else if (std.mem.eql(u8, arg, "--tissue") and i + 1 < args.len) {
            i += 1;
            tissue_path = args[i];
        }
    }

    // Note: Store auto-discovery is handled by Trace.build() via zawinski.store.discoverStoreDir()
    // The --jwz and --tissue flags allow explicit paths if needed

    // Build trace
    var trace_obj = try idle.Trace.build(
        allocator,
        session_id,
        jwz_path,
        tissue_path,
    );
    defer trace_obj.deinit();

    // Render output
    if (std.mem.eql(u8, format, "text")) {
        try trace_obj.renderText(stdout, .{ .verbose = verbose });
    } else if (std.mem.eql(u8, format, "dot")) {
        try trace_obj.renderDot(stdout);
    } else if (std.mem.eql(u8, format, "json")) {
        try stdout.writeAll("JSON format not yet implemented\n");
        stdout.flush() catch {};
        std.process.exit(1);
    } else {
        try stdout.print("Unknown format: {s}\n", .{format});
        stdout.flush() catch {};
        std.process.exit(1);
    }
}

fn cmdSessions(stdout: anytype, args: []const []const u8) !void {
    var limit: usize = 10;

    // Parse options
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--limit") and i + 1 < args.len) {
            i += 1;
            limit = std.fmt.parseInt(usize, args[i], 10) catch 10;
        }
    }

    // TODO: List sessions from jwz store (use limit for pagination)
    try stdout.print("Session listing not yet implemented (limit: {d}).\n", .{limit});
    try stdout.writeAll("Sessions are tracked in jwz topics: user:context:<session_id>\n");
}

fn cmdWarnings(allocator: std.mem.Allocator, stdout: anytype, args: []const []const u8) !void {
    if (args.len == 0) {
        try stdout.writeAll("Error: session_id required\n");
        try stdout.writeAll("Usage: idle warnings <session_id>\n");
        stdout.flush() catch {};
        std.process.exit(1);
    }

    const session_id = args[0];
    var jwz_path: ?[]const u8 = null;

    // Parse options
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--jwz") and i + 1 < args.len) {
            i += 1;
            jwz_path = args[i];
        }
    }

    // Import zawinski through the idle library's exposed module
    const zawinski = @import("zawinski");

    // Discover or use provided jwz store
    const store_dir = if (jwz_path) |path|
        path
    else
        zawinski.store.discoverStoreDir(allocator) catch {
            try stdout.print("No warnings found for session {s} (no jwz store found)\n", .{session_id});
            return;
        };
    defer if (jwz_path == null) allocator.free(store_dir);

    // Open store
    var store = zawinski.store.Store.open(allocator, store_dir) catch {
        try stdout.print("No warnings found for session {s} (could not open jwz store)\n", .{session_id});
        return;
    };
    defer store.deinit();

    // Build topic name: idle:warnings:{session_id}
    const topic_name = try std.fmt.allocPrint(allocator, "idle:warnings:{s}", .{session_id});
    defer allocator.free(topic_name);

    // Fetch messages from warnings topic
    const messages = store.listMessages(topic_name, 100) catch {
        try stdout.print("No warnings found for session {s}\n", .{session_id});
        return;
    };
    defer {
        for (messages) |*m| m.deinit(allocator);
        allocator.free(messages);
    }

    if (messages.len == 0) {
        try stdout.print("No warnings found for session {s}\n", .{session_id});
        return;
    }

    // Display warnings
    try stdout.print("=== Warnings for session {s} ===\n\n", .{session_id});

    for (messages, 0..) |msg, idx| {
        // Parse JSON body to extract warning and timestamp
        const parsed = std.json.parseFromSlice(
            struct { warning: []const u8, timestamp: []const u8 },
            allocator,
            msg.body,
            .{ .ignore_unknown_fields = true },
        ) catch {
            // Fallback: show raw body
            try stdout.print("[{d}] {s}\n", .{ idx + 1, msg.body });
            continue;
        };
        defer parsed.deinit();

        try stdout.print("[{d}] {s}\n    at {s}\n", .{
            idx + 1,
            parsed.value.warning,
            parsed.value.timestamp,
        });
    }

    try stdout.print("\n{d} warning(s) total\n", .{messages.len});
}

fn cmdVersion(stdout: anytype) !void {
    try stdout.print("idle {s}\n", .{version});
}

test "main compiles" {
    // Just verify the module compiles
    _ = idle;
}
