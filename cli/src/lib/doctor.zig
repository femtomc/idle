const std = @import("std");

/// Check result
pub const CheckResult = enum {
    ok,
    missing,
    error_state,
};

/// Individual check
pub const Check = struct {
    name: []const u8,
    result: CheckResult,
    detail: ?[]const u8 = null,
};

/// Run all environment checks
pub fn runChecks(allocator: std.mem.Allocator) ![]Check {
    var checks: std.ArrayListUnmanaged(Check) = .empty;
    defer checks.deinit(allocator);

    // Check jwz
    try checks.append(allocator, checkCommand(allocator, "jwz", &.{ "jwz", "--version" }));

    // Check tissue
    try checks.append(allocator, checkCommand(allocator, "tissue", &.{ "tissue", "--version" }));

    // Check claude
    try checks.append(allocator, checkCommand(allocator, "claude", &.{ "claude", "--version" }));

    // Check git
    try checks.append(allocator, checkCommand(allocator, "git", &.{ "git", "--version" }));

    // Check jwz initialized
    try checks.append(allocator, checkJwzInit(allocator));

    // Check for codex (optional)
    try checks.append(allocator, checkCommand(allocator, "codex (optional)", &.{ "which", "codex" }));

    // Check for gemini (optional)
    try checks.append(allocator, checkCommand(allocator, "gemini (optional)", &.{ "which", "gemini" }));

    return checks.toOwnedSlice(allocator);
}

/// Check if a command exists and runs
fn checkCommand(allocator: std.mem.Allocator, name: []const u8, argv: []const []const u8) Check {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch {
        return .{ .name = name, .result = .missing };
    };

    const term = child.wait() catch {
        return .{ .name = name, .result = .error_state };
    };

    if (term.Exited == 0) {
        return .{ .name = name, .result = .ok };
    } else {
        return .{ .name = name, .result = .missing };
    }
}

/// Check if jwz is initialized in current directory
fn checkJwzInit(allocator: std.mem.Allocator) Check {
    _ = allocator;
    const cwd = std.fs.cwd();
    cwd.access(".jwz", .{}) catch {
        return .{ .name = "jwz initialized", .result = .missing, .detail = "Run 'jwz init' to initialize" };
    };
    return .{ .name = "jwz initialized", .result = .ok };
}

/// Format check results for display
pub fn formatResults(allocator: std.mem.Allocator, checks: []const Check) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.writeAll("idle environment check\n");
    try writer.writeAll("======================\n\n");

    var all_ok = true;
    var required_missing = false;

    for (checks) |check| {
        const icon = switch (check.result) {
            .ok => "\x1b[32m✓\x1b[0m", // green check
            .missing => blk: {
                if (std.mem.indexOf(u8, check.name, "optional") != null) {
                    break :blk "\x1b[33m-\x1b[0m"; // yellow dash
                } else {
                    required_missing = true;
                    break :blk "\x1b[31m✗\x1b[0m"; // red x
                }
            },
            .error_state => blk: {
                all_ok = false;
                break :blk "\x1b[31m!\x1b[0m"; // red bang
            },
        };

        try writer.print("  {s} {s}", .{ icon, check.name });
        if (check.detail) |d| {
            try writer.print(" ({s})", .{d});
        }
        try writer.writeByte('\n');

        if (check.result != .ok) all_ok = false;
    }

    try writer.writeByte('\n');

    if (required_missing) {
        try writer.writeAll("\x1b[31mSome required tools are missing.\x1b[0m\n");
        try writer.writeAll("Install missing tools before using idle.\n");
    } else if (all_ok) {
        try writer.writeAll("\x1b[32mAll checks passed!\x1b[0m\n");
    } else {
        try writer.writeAll("\x1b[33mSome optional tools are missing.\x1b[0m\n");
        try writer.writeAll("idle will work, but some features may be limited.\n");
    }

    return buf.toOwnedSlice(allocator);
}

/// Check if all required tools are present
pub fn allRequiredPresent(checks: []const Check) bool {
    for (checks) |check| {
        // Skip optional checks
        if (std.mem.indexOf(u8, check.name, "optional") != null) continue;

        if (check.result != .ok) return false;
    }
    return true;
}

// ============================================================================
// Tests
// ============================================================================

test "Check: format basic" {
    const allocator = std.testing.allocator;
    const checks = [_]Check{
        .{ .name = "git", .result = .ok },
        .{ .name = "jwz", .result = .missing },
        .{ .name = "codex (optional)", .result = .missing },
    };

    const output = try formatResults(allocator, &checks);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "git") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "jwz") != null);
}

test "allRequiredPresent: true when optional missing" {
    const checks = [_]Check{
        .{ .name = "git", .result = .ok },
        .{ .name = "jwz", .result = .ok },
        .{ .name = "codex (optional)", .result = .missing },
    };

    try std.testing.expect(allRequiredPresent(&checks));
}

test "allRequiredPresent: false when required missing" {
    const checks = [_]Check{
        .{ .name = "git", .result = .ok },
        .{ .name = "jwz", .result = .missing },
    };

    try std.testing.expect(!allRequiredPresent(&checks));
}
