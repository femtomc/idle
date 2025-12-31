const std = @import("std");
const tissue = @import("tissue");

const hooks = struct {
    const stop = @import("hooks/stop.zig");
    const pre_compact = @import("hooks/pre_compact.zig");
    const session_start = @import("hooks/session_start.zig");
};

const usage =
    \\Usage: idle <command>
    \\
    \\Hooks:
    \\  stop           Stop hook (alice review gate)
    \\  pre-compact    Pre-compact hook
    \\  session-start  Session start hook
    \\
    \\Commands:
    \\  issues         List alice-review issues
    \\  doctor         Check environment
    \\  version        Show version
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

    if (std.mem.eql(u8, command, "stop")) {
        return hooks.stop.run(allocator);
    } else if (std.mem.eql(u8, command, "pre-compact")) {
        return hooks.pre_compact.run(allocator);
    } else if (std.mem.eql(u8, command, "session-start")) {
        return hooks.session_start.run(allocator);
    } else if (std.mem.eql(u8, command, "issues")) {
        return runIssues(allocator);
    } else if (std.mem.eql(u8, command, "doctor")) {
        return runDoctor(allocator);
    } else if (std.mem.eql(u8, command, "version")) {
        try writeStdout("idle 2.0.0\n");
        return 0;
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "-h")) {
        try writeStdout(usage);
        return 0;
    } else {
        try writeStderr("Unknown command\n");
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

fn runIssues(allocator: std.mem.Allocator) !u8 {
    const store_dir = tissue.store.discoverStoreDir(allocator) catch {
        try writeStderr("No .tissue store\n");
        return 1;
    };
    defer allocator.free(store_dir);

    var store = tissue.store.Store.open(allocator, store_dir) catch {
        try writeStderr("Failed to open store\n");
        return 1;
    };
    defer store.deinit();

    const count = store.countOpenIssuesByTag("alice-review") catch 0;
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Open alice-review issues: {}\n", .{count}) catch "Error\n";
    try writeStdout(msg);
    return 0;
}

fn runDoctor(allocator: std.mem.Allocator) !u8 {
    _ = allocator;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    w.writeAll("idle doctor\n\n") catch {};

    // Check claude
    var claude_child = std.process.Child.init(&.{ "claude", "--version" }, std.heap.page_allocator);
    const claude_ok = claude_child.spawnAndWait() catch null;
    if (claude_ok != null and claude_ok.?.Exited == 0) {
        w.writeAll("✓ claude\n") catch {};
    } else {
        w.writeAll("✗ claude (required for alice)\n") catch {};
    }

    // Check tissue
    var tissue_child = std.process.Child.init(&.{ "tissue", "--version" }, std.heap.page_allocator);
    const tissue_ok = tissue_child.spawnAndWait() catch null;
    if (tissue_ok != null and tissue_ok.?.Exited == 0) {
        w.writeAll("✓ tissue\n") catch {};
    } else {
        w.writeAll("✗ tissue (required)\n") catch {};
    }

    try writeStdout(fbs.getWritten());
    return 0;
}
