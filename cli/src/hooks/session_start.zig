const std = @import("std");
const tissue = @import("tissue");
const zawinski = @import("zawinski");
const idle = @import("idle");
const extractJsonString = idle.event_parser.extractString;

/// Session start hook - initializes infrastructure and injects context
pub fn run(allocator: std.mem.Allocator) !u8 {
    // Read hook input from stdin
    const stdin = std.fs.File.stdin();
    var buf: [4096]u8 = undefined;
    const n = try stdin.readAll(&buf);
    const input_json = buf[0..n];

    // Extract cwd and change to project directory
    const cwd_slice = extractJsonString(input_json, "\"cwd\"") orelse ".";
    std.posix.chdir(cwd_slice) catch {};

    // Initialize stores (.zawinski, .tissue)
    initializeStores(allocator) catch {};

    // Build context
    var context_buf: [32768]u8 = undefined;
    var context_stream = std.io.fixedBufferStream(&context_buf);
    const writer = context_stream.writer();

    // Inject info
    try writer.writeAll(
        \\idle: All exits require alice review. Stop hook invokes alice automatically.
        \\
    );

    // Inject ready issues from tissue
    try injectReadyIssuesTo(allocator, writer);

    // Output as JSON
    var stdout_buf: [65536]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"");
    try escapeJsonTo(stdout, context_stream.getWritten());
    try stdout.writeAll("\"}}\n");
    try stdout.flush();

    return 0;
}

fn injectReadyIssuesTo(allocator: std.mem.Allocator, writer: anytype) !void {
    const store_dir = tissue.store.discoverStoreDir(allocator) catch return;
    defer allocator.free(store_dir);

    var store = tissue.store.Store.open(allocator, store_dir) catch return;
    defer store.deinit();

    const ready_issues = store.listReadyIssues() catch return;
    defer {
        for (ready_issues) |*issue| issue.deinit(allocator);
        allocator.free(ready_issues);
    }

    if (ready_issues.len == 0) {
        try writer.writeAll("\nNo ready issues.\n");
        return;
    }

    try writer.writeAll("\n=== READY ISSUES ===\n");
    const max_display: usize = 15;
    const display_count = @min(ready_issues.len, max_display);

    for (ready_issues[0..display_count]) |issue| {
        try writer.print("{s}  P{d}  {s}\n", .{ issue.id, issue.priority, issue.title });
    }

    if (ready_issues.len > max_display) {
        try writer.print("... and {} more\n", .{ready_issues.len - max_display});
    }
    try writer.writeAll("====================\n");
}

fn initializeStores(allocator: std.mem.Allocator) !void {
    const cwd = std.fs.cwd();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_cwd = try cwd.realpath(".", &path_buf);

    // Initialize jwz store if needed
    if (cwd.access(".zawinski", .{})) |_| {} else |_| {
        const full_path = try std.fs.path.join(allocator, &.{ abs_cwd, ".zawinski" });
        defer allocator.free(full_path);
        zawinski.store.Store.init(allocator, full_path) catch |err| switch (err) {
            error.StoreAlreadyExists => {},
            else => return err,
        };
    }

    // Initialize tissue store if needed
    if (cwd.access(".tissue", .{})) |_| {} else |_| {
        const full_path = try std.fs.path.join(allocator, &.{ abs_cwd, ".tissue" });
        defer allocator.free(full_path);
        tissue.store.Store.init(allocator, full_path) catch |err| switch (err) {
            tissue.store.StoreError.StoreAlreadyExists => {},
            else => return err,
        };
    }
}

fn escapeJsonTo(writer: anytype, data: []const u8) !void {
    for (data) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}
