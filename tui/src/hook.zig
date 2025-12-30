const std = @import("std");
const sm = @import("state_machine.zig");
const ep = @import("event_parser.zig");

/// Hook input from Claude Code (JSON on stdin)
pub const HookInput = struct {
    transcript_path: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
};

/// Hook output (JSON to stdout)
pub const HookOutput = struct {
    decision: []const u8,
    reason: []const u8,
};

/// Run the stop hook logic
/// Returns exit code: 0 = allow exit, 2 = block exit
pub fn run(allocator: std.mem.Allocator) !u8 {
    // Check file-based escape hatch (.idle-disabled in cwd)
    if (std.fs.cwd().access(".idle-disabled", .{})) |_| {
        return 0;
    } else |_| {
        // File doesn't exist, continue
    }

    // Read hook input from stdin
    const stdin = std.io.getStdIn();
    var buf: [65536]u8 = undefined;
    const n = try stdin.readAll(&buf);
    const input_json = buf[0..n];

    // Parse hook input
    const hook_input = parseHookInput(input_json);

    // Get current time
    const now_ts = std.time.timestamp();

    // Read loop state from jwz
    const state_json = try readJwzState(allocator);
    defer if (state_json) |s| allocator.free(s);

    // Parse state
    var parsed_event = if (state_json) |json|
        try ep.parseEvent(allocator, json)
    else
        null;
    defer if (parsed_event) |*p| p.deinit();

    const loop_state = if (parsed_event) |*p| &p.state else null;

    // Detect completion signal from transcript
    var completion_signal: ?sm.CompletionReason = null;
    if (loop_state) |state| {
        if (state.topFrame()) |frame| {
            if (hook_input.transcript_path) |path| {
                const transcript = try readTranscript(allocator, path);
                defer if (transcript) |t| allocator.free(t);
                if (transcript) |text| {
                    completion_signal = sm.StateMachine.detectCompletionSignal(frame.mode, text);
                }
            }
        }
    }

    // Evaluate state machine
    var machine = sm.StateMachine.init(allocator);
    const result = machine.evaluate(loop_state, now_ts, completion_signal);

    // Handle result
    switch (result.decision) {
        .allow_exit => {
            // Post state update if needed
            if (result.completion_reason) |reason| {
                try postStateUpdate(allocator, loop_state, reason);
            }
            return 0;
        },
        .block_exit => {
            // Update iteration and post state
            if (result.new_iteration) |new_iter| {
                try postIterationUpdate(allocator, loop_state, new_iter);
            }

            // Build continuation message
            const frame = if (loop_state) |s| s.topFrame() else null;
            const iter = if (result.new_iteration) |i| i else if (frame) |f| f.iter else 1;
            const max = if (frame) |f| f.max else 10;

            var reason_buf: [4096]u8 = undefined;
            const reason = try std.fmt.bufPrint(&reason_buf, "[ITERATION {}/{max}] Continue working on the task. Check your progress and either complete the task or keep iterating.", .{ iter, max });

            // Output block decision
            const stdout = std.io.getStdOut().writer();
            try stdout.print("{{\"decision\":\"block\",\"reason\":\"{s}\"}}\n", .{reason});

            return 2;
        },
    }
}

/// Parse hook input JSON
fn parseHookInput(json: []const u8) HookInput {
    var result = HookInput{};

    // Extract transcript_path
    if (extractJsonString(json, "\"transcript_path\"")) |path| {
        result.transcript_path = path;
    }

    // Extract cwd
    if (extractJsonString(json, "\"cwd\"")) |cwd| {
        result.cwd = cwd;
    }

    return result;
}

/// Read loop state from jwz
fn readJwzState(allocator: std.mem.Allocator) !?[]u8 {
    var child = std.process.Child.init(&.{ "sh", "-c", "jwz read loop:current 2>/dev/null | tail -1" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    if (child.stdout) |stdout| {
        var buf: [65536]u8 = undefined;
        const n = try stdout.readAll(&buf);
        _ = try child.wait();

        if (n == 0) return null;

        const result = try allocator.alloc(u8, n);
        @memcpy(result, buf[0..n]);
        return result;
    }

    _ = try child.wait();
    return null;
}

/// Read last assistant message from transcript
fn readTranscript(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    // Read last 64KB (should contain last message)
    const stat = try file.stat();
    const offset = if (stat.size > 65536) stat.size - 65536 else 0;

    try file.seekTo(offset);

    var buf: [65536]u8 = undefined;
    const n = try file.readAll(&buf);

    if (n == 0) return null;

    // Find last assistant message text
    // This is a simplified extraction - just look for last "text" field
    const content = buf[0..n];

    // Find last occurrence of assistant message
    var last_text_start: ?usize = null;
    var last_text_end: usize = 0;
    var search_pos: usize = 0;

    while (std.mem.indexOf(u8, content[search_pos..], "\"type\":\"assistant\"")) |pos| {
        const abs_pos = search_pos + pos;
        // Look for text content after this
        if (std.mem.indexOf(u8, content[abs_pos..], "\"text\":\"")) |text_pos| {
            const text_start = abs_pos + text_pos + 8;
            // Find end of text (this is simplified, doesn't handle escapes properly)
            var text_end = text_start;
            var escape_next = false;
            while (text_end < content.len) {
                if (escape_next) {
                    escape_next = false;
                } else if (content[text_end] == '\\') {
                    escape_next = true;
                } else if (content[text_end] == '"') {
                    break;
                }
                text_end += 1;
            }
            last_text_start = text_start;
            last_text_end = text_end;
        }
        search_pos = abs_pos + 1;
    }

    // Return a copy of the last text we found
    if (last_text_start) |start| {
        const text = content[start..last_text_end];
        const result = try allocator.alloc(u8, text.len);
        @memcpy(result, text);
        return result;
    }

    return null;
}

/// Post state update to jwz
fn postStateUpdate(allocator: std.mem.Allocator, loop_state: ?*const sm.LoopState, reason: sm.CompletionReason) !void {
    _ = loop_state;

    const reason_str = switch (reason) {
        .COMPLETE => "COMPLETE",
        .MAX_ITERATIONS => "MAX_ITERATIONS",
        .STUCK => "STUCK",
        .NO_MORE_ISSUES => "NO_MORE_ISSUES",
        .MAX_ISSUES => "MAX_ISSUES",
    };

    var cmd_buf: [256]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "jwz post loop:current -m '{{\"schema\":0,\"event\":\"DONE\",\"reason\":\"{s}\",\"stack\":[]}}'", .{reason_str});

    var child = std.process.Child.init(&.{ "sh", "-c", cmd }, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    _ = try child.wait();
}

/// Post iteration update to jwz
fn postIterationUpdate(allocator: std.mem.Allocator, loop_state: ?*const sm.LoopState, new_iter: u32) !void {
    if (loop_state == null) return;
    const state = loop_state.?;
    if (state.stack.len == 0) return;

    // For now, use a simple update approach
    // In production, we'd reconstruct the full state JSON
    _ = new_iter;

    // Get current timestamp
    var ts_buf: [32]u8 = undefined;
    const now = std.time.timestamp();
    const ts = formatIso8601(now, &ts_buf);

    // Build updated state (simplified - just update timestamp)
    var cmd_buf: [512]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "jwz post loop:current -m '{{\"schema\":0,\"event\":\"STATE\",\"run_id\":\"{s}\",\"updated_at\":\"{s}\",\"stack\":[]}}'", .{ state.run_id, ts });

    var child = std.process.Child.init(&.{ "sh", "-c", cmd }, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    _ = try child.wait();
}

/// Format Unix timestamp as ISO 8601
fn formatIso8601(ts: i64, buf: []u8) []const u8 {
    // Simplified: just return a placeholder for now
    // In production, we'd do proper date calculation
    _ = ts;
    const result = "2024-12-28T00:00:00Z";
    @memcpy(buf[0..result.len], result);
    return buf[0..result.len];
}

/// Extract a string value from JSON
fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, json, key) orelse return null;
    const after_key = json[key_pos + key.len ..];

    const colon_pos = std.mem.indexOf(u8, after_key, ":") orelse return null;
    const after_colon = after_key[colon_pos + 1 ..];

    var start: usize = 0;
    while (start < after_colon.len and (after_colon[start] == ' ' or after_colon[start] == '\t')) {
        start += 1;
    }

    if (start >= after_colon.len or after_colon[start] != '"') return null;
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

// ============================================================================
// Tests
// ============================================================================

test "parseHookInput: basic" {
    const json = "{\"transcript_path\":\"/tmp/t.jsonl\",\"cwd\":\"/home/user\"}";
    const input = parseHookInput(json);
    try std.testing.expectEqualStrings("/tmp/t.jsonl", input.transcript_path.?);
    try std.testing.expectEqualStrings("/home/user", input.cwd.?);
}

test "parseHookInput: empty" {
    const input = parseHookInput("{}");
    try std.testing.expect(input.transcript_path == null);
    try std.testing.expect(input.cwd == null);
}
