const std = @import("std");
const tissue = @import("tissue");

/// Discover and open the tissue store
pub fn openStore(allocator: std.mem.Allocator) !tissue.store.Store {
    const store_dir = tissue.store.discoverStoreDir(allocator) catch {
        return error.StoreNotFound;
    };
    defer allocator.free(store_dir);

    return tissue.store.Store.open(allocator, store_dir);
}

/// Get the first ready issue (highest priority, most recently updated)
pub fn getFirstReady(allocator: std.mem.Allocator) !?tissue.store.Issue {
    var store = try openStore(allocator);
    defer store.deinit();

    const ready = try store.listReadyIssues();
    defer {
        for (ready[1..]) |*issue| issue.deinit(allocator);
        allocator.free(ready);
    }

    if (ready.len == 0) return null;

    // Return first issue (don't deinit it - caller owns it)
    return ready[0];
}

/// List all ready issues
pub fn listReady(allocator: std.mem.Allocator) ![]tissue.store.Issue {
    var store = try openStore(allocator);
    defer store.deinit();

    return store.listReadyIssues();
}

/// Fetch a specific issue by ID
pub fn fetchIssue(allocator: std.mem.Allocator, id: []const u8) !tissue.store.Issue {
    var store = try openStore(allocator);
    defer store.deinit();

    return store.fetchIssue(id);
}

/// Update issue status
pub fn updateStatus(allocator: std.mem.Allocator, id: []const u8, new_status: []const u8) !void {
    var store = try openStore(allocator);
    defer store.deinit();

    try store.updateIssue(id, .{ .status = new_status });
}

/// Format an issue for display
pub fn formatIssue(allocator: std.mem.Allocator, issue: *const tissue.store.Issue) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.print("ID: {s}\n", .{issue.id});
    try writer.print("Title: {s}\n", .{issue.title});
    try writer.print("Status: {s}\n", .{issue.status});
    try writer.print("Priority: {d}\n", .{issue.priority});

    if (issue.tags.len > 0) {
        try writer.writeAll("Tags: ");
        for (issue.tags, 0..) |tag, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll(tag);
        }
        try writer.writeByte('\n');
    }

    if (issue.body.len > 0) {
        try writer.writeAll("\n");
        try writer.writeAll(issue.body);
        try writer.writeByte('\n');
    }

    return buf.toOwnedSlice(allocator);
}
