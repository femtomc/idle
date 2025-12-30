const std = @import("std");

/// Orchestration bounds - enforced mechanically
pub const MAX_DEPTH: u32 = 3;
pub const MAX_WORKERS: u32 = 10;
pub const CHARLIE_TIMEOUT: u32 = 60;
pub const BOB_TIMEOUT: u32 = 300;

/// Agent types that can be spawned
pub const AgentType = enum {
    charlie,
    bob,

    pub fn fromString(s: []const u8) ?AgentType {
        if (std.mem.eql(u8, s, "charlie")) return .charlie;
        if (std.mem.eql(u8, s, "bob")) return .bob;
        return null;
    }

    pub fn model(self: AgentType) []const u8 {
        return switch (self) {
            .charlie => "haiku",
            .bob => "sonnet",
        };
    }

    pub fn defaultTimeout(self: AgentType) u32 {
        return switch (self) {
            .charlie => CHARLIE_TIMEOUT,
            .bob => BOB_TIMEOUT,
        };
    }

    pub fn tools(self: AgentType) []const u8 {
        return switch (self) {
            .charlie => "WebSearch,WebFetch,Read,Bash",
            .bob => "WebSearch,WebFetch,Bash,Read,Write",
        };
    }
};

/// Task contract schema
pub const TaskContract = struct {
    task_id: []const u8,
    parent_id: []const u8,
    depth: u32,
    query: []const u8,
    deliverable: []const u8,
    topic: []const u8,
    // Optional fields
    acceptance_criteria: ?[]const []const u8 = null,
};

/// Spawn result
pub const SpawnResult = enum {
    success,
    depth_exceeded,
    invalid_contract,
    spawn_failed,
};

/// Validate a task contract
pub fn validateContract(json: []const u8) !?TaskContract {
    // Simple JSON parsing - extract required fields
    const task_id = extractString(json, "\"task_id\"") orelse return null;
    const parent_id = extractString(json, "\"parent_id\"") orelse return null;
    const depth = extractNumber(json, "\"depth\"") orelse return null;
    const query = extractString(json, "\"query\"") orelse return null;
    const deliverable = extractString(json, "\"deliverable\"") orelse return null;
    const topic = extractString(json, "\"topic\"") orelse return null;

    return TaskContract{
        .task_id = task_id,
        .parent_id = parent_id,
        .depth = depth,
        .query = query,
        .deliverable = deliverable,
        .topic = topic,
    };
}

/// Check if spawn is allowed given current depth
pub fn checkDepthLimit(agent: AgentType, current_depth: u32) SpawnResult {
    switch (agent) {
        .bob => {
            if (current_depth >= MAX_DEPTH) {
                return .depth_exceeded;
            }
        },
        .charlie => {
            // charlie can always be spawned (it's a leaf)
        },
    }
    return .success;
}

/// Build the claude command for spawning an agent
pub fn buildSpawnCommand(
    allocator: std.mem.Allocator,
    agent: AgentType,
    task_json: []const u8,
    timeout: u32,
    prompt: []const u8,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.print(
        "timeout {d} claude -p --model {s} --agent {s} --tools \"{s}\" --append-system-prompt 'Task contract: {s}' \"{s}\"",
        .{
            timeout,
            agent.model(),
            @tagName(agent),
            agent.tools(),
            task_json,
            prompt,
        },
    );

    return buf.toOwnedSlice(allocator);
}

/// Execute agent spawn
pub fn spawn(
    allocator: std.mem.Allocator,
    agent: AgentType,
    task_json: []const u8,
    timeout: ?u32,
    background: bool,
) !SpawnResult {
    // Validate contract
    const contract = try validateContract(task_json) orelse {
        return .invalid_contract;
    };

    // Check depth limit
    const depth_check = checkDepthLimit(agent, contract.depth);
    if (depth_check != .success) {
        return depth_check;
    }

    // Build prompt based on agent type
    const prompt = switch (agent) {
        .charlie => "Execute this task and post results to jwz.",
        .bob => "Orchestrate this task.",
    };

    // Build command
    const effective_timeout = timeout orelse agent.defaultTimeout();
    const cmd = try buildSpawnCommand(allocator, agent, task_json, effective_timeout, prompt);
    defer allocator.free(cmd);

    // Execute
    const suffix: []const u8 = if (background) " &" else "";
    var full_cmd: std.ArrayListUnmanaged(u8) = .empty;
    defer full_cmd.deinit(allocator);
    try full_cmd.appendSlice(allocator, cmd);
    try full_cmd.appendSlice(allocator, suffix);

    var child = std.process.Child.init(&.{ "sh", "-c", full_cmd.items }, allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    if (!background) {
        const term = try child.wait();
        if (term.Exited != 0) {
            return .spawn_failed;
        }
    }

    return .success;
}

// ============================================================================
// Helper functions (shared with event_parser)
// ============================================================================

fn extractString(json: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, json, key) orelse return null;
    const after_key = json[key_pos + key.len ..];

    const colon_pos = std.mem.indexOf(u8, after_key, ":") orelse return null;
    const after_colon = after_key[colon_pos + 1 ..];

    var start: usize = 0;
    while (start < after_colon.len and (after_colon[start] == ' ' or after_colon[start] == '\t' or after_colon[start] == '\n')) {
        start += 1;
    }

    if (start >= after_colon.len) return null;
    if (after_colon[start] != '"') return null;
    start += 1;

    var end = start;
    var escape_next = false;
    while (end < after_colon.len) {
        if (escape_next) {
            escape_next = false;
        } else if (after_colon[end] == '\\') {
            escape_next = true;
        } else if (after_colon[end] == '"') {
            break;
        }
        end += 1;
    }

    return after_colon[start..end];
}

fn extractNumber(json: []const u8, key: []const u8) ?u32 {
    const key_pos = std.mem.indexOf(u8, json, key) orelse return null;
    const after_key = json[key_pos + key.len ..];

    const colon_pos = std.mem.indexOf(u8, after_key, ":") orelse return null;
    const after_colon = after_key[colon_pos + 1 ..];

    var start: usize = 0;
    while (start < after_colon.len and (after_colon[start] == ' ' or after_colon[start] == '\t' or after_colon[start] == '\n')) {
        start += 1;
    }

    if (start >= after_colon.len) return null;

    var end = start;
    while (end < after_colon.len and after_colon[end] >= '0' and after_colon[end] <= '9') {
        end += 1;
    }

    if (end == start) return null;

    return std.fmt.parseInt(u32, after_colon[start..end], 10) catch null;
}

// ============================================================================
// Tests
// ============================================================================

test "validateContract: valid contract" {
    const json =
        \\{"task_id":"t-001","parent_id":"root","depth":1,"query":"test query","deliverable":"findings","topic":"work:run-123"}
    ;
    const contract = try validateContract(json);
    try std.testing.expect(contract != null);
    try std.testing.expectEqualStrings("t-001", contract.?.task_id);
    try std.testing.expectEqual(@as(u32, 1), contract.?.depth);
}

test "validateContract: missing field returns null" {
    const json =
        \\{"task_id":"t-001","depth":1}
    ;
    const contract = try validateContract(json);
    try std.testing.expect(contract == null);
}

test "checkDepthLimit: bob at max depth fails" {
    const result = checkDepthLimit(.bob, 3);
    try std.testing.expectEqual(SpawnResult.depth_exceeded, result);
}

test "checkDepthLimit: bob under max depth succeeds" {
    const result = checkDepthLimit(.bob, 2);
    try std.testing.expectEqual(SpawnResult.success, result);
}

test "checkDepthLimit: charlie always succeeds" {
    const result = checkDepthLimit(.charlie, 10);
    try std.testing.expectEqual(SpawnResult.success, result);
}

test "AgentType: correct models" {
    try std.testing.expectEqualStrings("haiku", AgentType.charlie.model());
    try std.testing.expectEqualStrings("sonnet", AgentType.bob.model());
}

test "AgentType: correct timeouts" {
    try std.testing.expectEqual(@as(u32, 60), AgentType.charlie.defaultTimeout());
    try std.testing.expectEqual(@as(u32, 300), AgentType.bob.defaultTimeout());
}
