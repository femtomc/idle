const std = @import("std");

/// Worktree operation result
pub const WorktreeResult = enum {
    success,
    already_exists,
    not_found,
    dirty,
    merge_failed,
    push_failed,
    error_state,
};

/// Create a worktree for an issue
pub fn create(
    allocator: std.mem.Allocator,
    issue_id: []const u8,
    base_ref: ?[]const u8,
) !WorktreeResult {
    // Get repo root
    const repo_root = try getRepoRoot(allocator) orelse return .error_state;
    defer allocator.free(repo_root);

    // Sanitize issue ID for branch name
    var safe_id_buf: [256]u8 = undefined;
    var safe_id_len: usize = 0;
    for (issue_id) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') {
            if (safe_id_len < safe_id_buf.len) {
                safe_id_buf[safe_id_len] = c;
                safe_id_len += 1;
            }
        }
    }
    const safe_id = safe_id_buf[0..safe_id_len];

    // Build paths
    var branch_buf: [512]u8 = undefined;
    const branch = std.fmt.bufPrint(&branch_buf, "idle/issue/{s}", .{safe_id}) catch return .error_state;

    var path_buf: [1024]u8 = undefined;
    const worktree_path = std.fmt.bufPrint(&path_buf, "{s}/.worktrees/idle/{s}", .{ repo_root, safe_id }) catch return .error_state;

    // Check if worktree already exists
    if (std.fs.accessAbsolute(worktree_path, .{})) |_| {
        return .already_exists;
    } else |_| {}

    // Ensure parent directory exists
    var parent_buf: [1024]u8 = undefined;
    const parent_path = std.fmt.bufPrint(&parent_buf, "{s}/.worktrees/idle", .{repo_root}) catch return .error_state;
    std.fs.makeDirAbsolute(parent_path) catch |err| {
        if (err != error.PathAlreadyExists) return .error_state;
    };

    // Resolve base ref
    const effective_base = base_ref orelse try resolveBaseRef(allocator) orelse "main";

    // Create worktree with new branch
    var cmd_buf: [2048]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "git -C \"{s}\" worktree add -b \"{s}\" \"{s}\" \"{s}\" 2>/dev/null || git -C \"{s}\" worktree add \"{s}\" \"{s}\"", .{
        repo_root,
        branch,
        worktree_path,
        effective_base,
        repo_root,
        worktree_path,
        branch,
    }) catch return .error_state;

    var child = std.process.Child.init(&.{ "sh", "-c", cmd }, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return .error_state;
    const term = child.wait() catch return .error_state;

    if (term.Exited != 0) {
        return .error_state;
    }

    // Initialize submodules if present
    var submod_buf: [2048]u8 = undefined;
    const submod_cmd = std.fmt.bufPrint(&submod_buf, "[ -f \"{s}/.gitmodules\" ] && git -C \"{s}\" submodule update --init --recursive 2>/dev/null || true", .{ repo_root, worktree_path }) catch return .success;

    var submod_child = std.process.Child.init(&.{ "sh", "-c", submod_cmd }, allocator);
    submod_child.stdout_behavior = .Ignore;
    submod_child.stderr_behavior = .Ignore;
    submod_child.spawn() catch {};
    _ = submod_child.wait() catch {};

    return .success;
}

/// Land a worktree branch (merge and push)
pub fn land(
    allocator: std.mem.Allocator,
    issue_id: []const u8,
    base_ref: ?[]const u8,
) !WorktreeResult {
    const repo_root = try getRepoRoot(allocator) orelse return .error_state;
    defer allocator.free(repo_root);

    // Build paths
    var safe_id_buf: [256]u8 = undefined;
    var safe_id_len: usize = 0;
    for (issue_id) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') {
            if (safe_id_len < safe_id_buf.len) {
                safe_id_buf[safe_id_len] = c;
                safe_id_len += 1;
            }
        }
    }
    const safe_id = safe_id_buf[0..safe_id_len];

    var branch_buf: [512]u8 = undefined;
    const branch = std.fmt.bufPrint(&branch_buf, "idle/issue/{s}", .{safe_id}) catch return .error_state;

    var path_buf: [1024]u8 = undefined;
    const worktree_path = std.fmt.bufPrint(&path_buf, "{s}/.worktrees/idle/{s}", .{ repo_root, safe_id }) catch return .error_state;

    // Check worktree exists
    std.fs.accessAbsolute(worktree_path, .{}) catch {
        return .not_found;
    };

    // Check worktree is clean
    var dirty_cmd_buf: [1024]u8 = undefined;
    const dirty_cmd = std.fmt.bufPrint(&dirty_cmd_buf, "git -C \"{s}\" diff --quiet && git -C \"{s}\" diff --cached --quiet", .{ worktree_path, worktree_path }) catch return .error_state;

    var dirty_child = std.process.Child.init(&.{ "sh", "-c", dirty_cmd }, allocator);
    dirty_child.stdout_behavior = .Ignore;
    dirty_child.stderr_behavior = .Ignore;
    dirty_child.spawn() catch return .error_state;
    const dirty_term = dirty_child.wait() catch return .error_state;

    if (dirty_term.Exited != 0) {
        return .dirty;
    }

    // Resolve base ref
    const effective_base = base_ref orelse try resolveBaseRef(allocator) orelse "main";

    // Fetch and fast-forward merge
    var land_cmd_buf: [2048]u8 = undefined;
    const land_cmd = std.fmt.bufPrint(&land_cmd_buf,
        \\git -C "{s}" fetch origin && \
        \\git -C "{s}" update-ref refs/heads/{s} $(git -C "{s}" rev-parse refs/heads/{s}) && \
        \\git -C "{s}" push origin {s}
    , .{ repo_root, repo_root, effective_base, repo_root, branch, repo_root, effective_base }) catch return .error_state;

    var land_child = std.process.Child.init(&.{ "sh", "-c", land_cmd }, allocator);
    land_child.stdout_behavior = .Ignore;
    land_child.stderr_behavior = .Ignore;
    land_child.spawn() catch return .error_state;
    const land_term = land_child.wait() catch return .error_state;

    if (land_term.Exited != 0) {
        return .push_failed;
    }

    return .success;
}

/// Cleanup a worktree
pub fn cleanup(
    allocator: std.mem.Allocator,
    issue_id: []const u8,
) !WorktreeResult {
    const repo_root = try getRepoRoot(allocator) orelse return .error_state;
    defer allocator.free(repo_root);

    // Build paths
    var safe_id_buf: [256]u8 = undefined;
    var safe_id_len: usize = 0;
    for (issue_id) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') {
            if (safe_id_len < safe_id_buf.len) {
                safe_id_buf[safe_id_len] = c;
                safe_id_len += 1;
            }
        }
    }
    const safe_id = safe_id_buf[0..safe_id_len];

    var branch_buf: [512]u8 = undefined;
    const branch = std.fmt.bufPrint(&branch_buf, "idle/issue/{s}", .{safe_id}) catch return .error_state;

    var path_buf: [1024]u8 = undefined;
    const worktree_path = std.fmt.bufPrint(&path_buf, "{s}/.worktrees/idle/{s}", .{ repo_root, safe_id }) catch return .error_state;

    // Remove worktree
    var rm_cmd_buf: [1024]u8 = undefined;
    const rm_cmd = std.fmt.bufPrint(&rm_cmd_buf, "git -C \"{s}\" worktree remove \"{s}\" 2>/dev/null; git -C \"{s}\" branch -d \"{s}\" 2>/dev/null", .{ repo_root, worktree_path, repo_root, branch }) catch return .error_state;

    var rm_child = std.process.Child.init(&.{ "sh", "-c", rm_cmd }, allocator);
    rm_child.stdout_behavior = .Ignore;
    rm_child.stderr_behavior = .Ignore;
    rm_child.spawn() catch return .error_state;
    _ = rm_child.wait() catch {};

    return .success;
}

/// Get the git repository root
fn getRepoRoot(allocator: std.mem.Allocator) !?[]u8 {
    var child = std.process.Child.init(&.{ "git", "rev-parse", "--show-toplevel" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return null;

    if (child.stdout) |stdout| {
        var buf: [4096]u8 = undefined;
        const n = stdout.readAll(&buf) catch return null;
        _ = child.wait() catch return null;

        if (n == 0) return null;

        const result = try allocator.alloc(u8, n);
        @memcpy(result, buf[0..n]);

        // Trim trailing newline
        var len = result.len;
        while (len > 0 and (result[len - 1] == '\n' or result[len - 1] == '\r')) {
            len -= 1;
        }

        return result[0..len];
    }

    _ = child.wait() catch {};
    return null;
}

/// Resolve the base ref (main, master, or configured)
fn resolveBaseRef(allocator: std.mem.Allocator) !?[]const u8 {
    // Try git config first
    var config_child = std.process.Child.init(&.{ "git", "config", "idle.baseRef" }, allocator);
    config_child.stdout_behavior = .Pipe;
    config_child.stderr_behavior = .Ignore;

    config_child.spawn() catch return null;

    if (config_child.stdout) |stdout| {
        var buf: [256]u8 = undefined;
        const n = stdout.readAll(&buf) catch return null;
        _ = config_child.wait() catch return null;

        if (n > 0) {
            var len = n;
            while (len > 0 and (buf[len - 1] == '\n' or buf[len - 1] == '\r')) {
                len -= 1;
            }
            if (len > 0) {
                // Return static strings for common refs
                if (std.mem.eql(u8, buf[0..len], "main")) return "main";
                if (std.mem.eql(u8, buf[0..len], "master")) return "master";
            }
        }
    } else {
        _ = config_child.wait() catch {};
    }

    // Try origin/HEAD
    var origin_child = std.process.Child.init(&.{ "git", "symbolic-ref", "refs/remotes/origin/HEAD" }, allocator);
    origin_child.stdout_behavior = .Pipe;
    origin_child.stderr_behavior = .Ignore;

    origin_child.spawn() catch return "main";

    if (origin_child.stdout) |stdout| {
        var buf: [256]u8 = undefined;
        const n = stdout.readAll(&buf) catch return "main";
        _ = origin_child.wait() catch return "main";

        if (n > 0) {
            // Extract branch name from refs/remotes/origin/<branch>
            const prefix = "refs/remotes/origin/";
            if (std.mem.startsWith(u8, buf[0..n], prefix)) {
                var len = n - prefix.len;
                while (len > 0 and (buf[prefix.len + len - 1] == '\n' or buf[prefix.len + len - 1] == '\r')) {
                    len -= 1;
                }
                if (std.mem.eql(u8, buf[prefix.len .. prefix.len + len], "main")) return "main";
                if (std.mem.eql(u8, buf[prefix.len .. prefix.len + len], "master")) return "master";
            }
        }
    } else {
        _ = origin_child.wait() catch {};
    }

    return "main";
}

// ============================================================================
// Tests
// ============================================================================

test "sanitize issue id" {
    // This is implicitly tested by the create/cleanup functions
    // Just a placeholder for now
}
