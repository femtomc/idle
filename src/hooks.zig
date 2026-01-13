//! Claude Code hook implementations
//!
//! This module provides native Zig implementations of the Claude Code hooks,
//! replacing the previous bash+jq scripts with direct store access.
//!
//! Usage:
//!   alice hook session-start    < input.json
//!   alice hook user-prompt      < input.json
//!   alice hook post-tool-use    < input.json
//!   alice hook stop             < input.json
//!   alice hook session-end      < input.json

const std = @import("std");
const jwz = @import("jwz");
const tissue = @import("tissue");

// ============================================================================
// Common Types
// ============================================================================

/// Input provided by Claude Code to hooks via stdin
pub const HookInput = struct {
    cwd: []const u8 = ".",
    session_id: []const u8 = "default",
    prompt: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    tool_input: ?std.json.Value = null,
    tool_response: ?std.json.Value = null,
    source: ?[]const u8 = null, // For SessionStart: "startup", "resume", "clear", "compact"
    // SubagentStop fields
    subagent_type: ?[]const u8 = null,
    subagent_prompt: ?[]const u8 = null,
    subagent_response: ?[]const u8 = null,

    pub fn parse(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(HookInput) {
        return std.json.parseFromSlice(HookInput, allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }
};

/// Hook decision
pub const Decision = enum {
    approve,
    block,

    pub fn jsonStringify(self: Decision, options: std.json.StringifyOptions, writer: anytype) !void {
        _ = options;
        try writer.writeByte('"');
        try writer.writeAll(@tagName(self));
        try writer.writeByte('"');
    }
};

/// Additional context to inject into the conversation
pub const HookSpecificOutput = struct {
    hookEventName: []const u8,
    additionalContext: ?[]const u8 = null,
};

/// Output returned by hooks to Claude Code
pub const HookOutput = struct {
    decision: Decision = .approve,
    reason: ?[]const u8 = null,
    hookSpecificOutput: ?HookSpecificOutput = null,
    systemMessage: ?[]const u8 = null,

    pub fn writeJson(self: HookOutput, writer: anytype) !void {
        try writer.writeByte('{');

        // decision
        try writer.writeAll("\"decision\":\"");
        try writer.writeAll(@tagName(self.decision));
        try writer.writeByte('"');

        // reason
        if (self.reason) |reason| {
            try writer.writeAll(",\"reason\":\"");
            try writeEscapedJson(reason, writer);
            try writer.writeByte('"');
        }

        // hookSpecificOutput
        if (self.hookSpecificOutput) |hso| {
            try writer.writeAll(",\"hookSpecificOutput\":{\"hookEventName\":\"");
            try writer.writeAll(hso.hookEventName);
            try writer.writeByte('"');
            if (hso.additionalContext) |ctx| {
                try writer.writeAll(",\"additionalContext\":\"");
                try writeEscapedJson(ctx, writer);
                try writer.writeByte('"');
            }
            try writer.writeByte('}');
        }

        // systemMessage
        if (self.systemMessage) |msg| {
            try writer.writeAll(",\"systemMessage\":\"");
            try writeEscapedJson(msg, writer);
            try writer.writeByte('"');
        }

        try writer.writeByte('}');
    }

    fn writeEscapedJson(s: []const u8, writer: anytype) !void {
        for (s) |c| {
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

    pub fn approve() HookOutput {
        return .{ .decision = .approve };
    }

    pub fn approveWithContext(event_name: []const u8, context: []const u8) HookOutput {
        return .{
            .decision = .approve,
            .hookSpecificOutput = .{
                .hookEventName = event_name,
                .additionalContext = context,
            },
        };
    }

    pub fn approveWithMessage(event_name: []const u8, context: []const u8, message: []const u8) HookOutput {
        return .{
            .decision = .approve,
            .hookSpecificOutput = .{
                .hookEventName = event_name,
                .additionalContext = context,
            },
            .systemMessage = message,
        };
    }

    pub fn block(reason: []const u8) HookOutput {
        return .{
            .decision = .block,
            .reason = reason,
        };
    }
};

/// Review state stored in jwz
pub const ReviewState = struct {
    enabled: bool = false,
    timestamp: ?[]const u8 = null,
    manually_stopped: ?bool = null,
    session_start_cleanup: ?bool = null,
    circuit_breaker_tripped: ?bool = null,
    last_blocked_review_id: ?[]const u8 = null,
    block_count: ?u32 = null,
    no_id_block_count: ?u32 = null,
};

/// Alice decision stored in jwz
pub const AliceStatus = struct {
    decision: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    message_to_agent: ?[]const u8 = null,
    second_opinions: ?[]const u8 = null,
    timestamp: ?[]const u8 = null,
};

// ============================================================================
// Store Helpers
// ============================================================================

/// Get the default alice store directory (~/.claude/alice/.jwz)
/// Returns a slice that is either from environment or from the provided buffer
/// Get the jwz store path using proper discovery (local stores first, then env var)
pub fn getAliceJwzStore(allocator: std.mem.Allocator) ?[]const u8 {
    // Use jwz's store discovery: local .jwz first, then JWZ_STORE env var
    return jwz.store.discoverStoreDir(allocator) catch null;
}

/// Ensure parent directory exists
fn ensureParentDir(path: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse return;
    std.fs.makeDirAbsolute(dir_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

/// Open the jwz store, creating it if needed
pub fn openOrCreateStore(allocator: std.mem.Allocator, path: []const u8) !jwz.store.Store {
    // Try to open existing store
    return jwz.store.Store.open(allocator, path) catch |err| {
        if (err == error.StoreNotFound) {
            // Ensure parent directory exists first
            ensureParentDir(path) catch {};
            // Initialize new store
            try jwz.store.Store.init(allocator, path);
            return jwz.store.Store.open(allocator, path);
        }
        return err;
    };
}

/// Emit a warning and fail open - for infrastructure errors that shouldn't block
pub fn emitWarningAndApprove(
    allocator: std.mem.Allocator,
    store: ?*jwz.store.Store,
    session_id: []const u8,
    warning_msg: []const u8,
) HookOutput {
    // Layer 1: stderr (shown in verbose mode)
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;
    stderr.print("alice: WARNING: {s}\n", .{warning_msg}) catch {};
    stderr.flush() catch {};

    // Layer 2: jwz persistence (best effort)
    if (store) |s| {
        var topic_buf: [128]u8 = undefined;
        const warnings_topic = std.fmt.bufPrint(&topic_buf, "alice:warnings:{s}", .{session_id}) catch "";
        if (warnings_topic.len > 0) {
            var ts_buf: [32]u8 = undefined;
            const timestamp = getTimestamp(&ts_buf);

            // Build warning message (escape warning_msg for JSON)
            var warn_list: std.ArrayList(u8) = .empty;
            defer warn_list.deinit(allocator);
            var warn_writer = warn_list.writer(allocator);
            warn_writer.writeAll("{\"warning\":\"") catch {};
            escapeJsonString(warning_msg, warn_writer) catch {};
            warn_writer.print("\",\"timestamp\":\"{s}\"}}", .{timestamp}) catch {};
            if (warn_list.items.len > 0) {
                postToTopic(allocator, s, warnings_topic, warn_list.items) catch {};
            }
        }
    }

    // Layer 3: approve with systemMessage for inline display
    // Note: Stop hooks don't support hookSpecificOutput, only systemMessage
    var msg_list: std.ArrayList(u8) = .empty;
    defer msg_list.deinit(allocator);
    msg_list.writer(allocator).print("⚠️ alice: {s}", .{warning_msg}) catch {};

    // Duplicate the message for the return value since msg_list will be deinitialized
    const system_msg = if (msg_list.items.len > 0)
        allocator.dupe(u8, msg_list.items) catch null
    else
        null;

    return .{
        .decision = .approve,
        .systemMessage = system_msg,
    };
}

/// Ensure a topic exists
pub fn ensureTopic(allocator: std.mem.Allocator, store: *jwz.store.Store, topic: []const u8) !void {
    const id = store.createTopic(topic, "") catch |err| {
        if (err != error.TopicExists) return err;
        return; // TopicExists is not an error
    };
    allocator.free(id); // Free the returned topic ID
}

/// Post a message to a topic, creating the topic if needed
pub fn postToTopic(
    allocator: std.mem.Allocator,
    store: *jwz.store.Store,
    topic: []const u8,
    body: []const u8,
) !void {
    try ensureTopic(allocator, store, topic);
    const id = try store.createMessage(topic, null, body, .{});
    allocator.free(id);
}

/// Simplified message with just what hooks need
pub const SimpleMessage = struct {
    id: []const u8,
    body: []const u8,

    pub fn deinit(self: SimpleMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.body);
    }
};

/// Get the latest message from a topic
pub fn getLatestMessage(
    allocator: std.mem.Allocator,
    store: *jwz.store.Store,
    topic: []const u8,
) ?SimpleMessage {
    const messages = store.listMessages(topic, 1) catch return null;
    defer {
        for (messages) |*m| m.deinit(allocator);
        allocator.free(messages);
    }
    if (messages.len == 0) return null;

    // Copy the fields we need
    const id = allocator.dupe(u8, messages[0].id) catch return null;
    const body = allocator.dupe(u8, messages[0].body) catch {
        // errdefer doesn't run on 'return null', so explicitly free id
        allocator.free(id);
        return null;
    };

    return .{ .id = id, .body = body };
}

/// Get timestamp in ISO 8601 format
pub fn getTimestamp(buf: []u8) []const u8 {
    const now = std.time.timestamp();
    const epoch_seconds: u64 = @intCast(now);
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_seconds };
    const day_seconds = es.getDaySeconds();
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1, // day_index is 0-based
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch "1970-01-01T00:00:00Z";
}

/// Parse ISO 8601 timestamp to Unix epoch seconds
/// Expected format: "YYYY-MM-DDTHH:MM:SSZ"
fn parseIso8601ToEpoch(ts: []const u8) ?i64 {
    // Minimum length: "YYYY-MM-DDTHH:MM:SSZ" = 20 chars
    if (ts.len < 20) return null;

    const year = std.fmt.parseInt(i32, ts[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, ts[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, ts[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, ts[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, ts[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, ts[17..19], 10) catch return null;

    // Basic validation
    if (month < 1 or month > 12) return null;
    if (day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 59) return null;

    // Calculate days since Unix epoch (1970-01-01) using direct calculation
    // This is simpler than using the std.time.epoch utilities which are designed for the reverse
    const days_since_epoch = daysFromYmd(year, month, day);
    const day_secs: i64 = @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
    return days_since_epoch * 86400 + day_secs;
}

/// Calculate days since Unix epoch (1970-01-01) from year/month/day
/// Uses the algorithm from Howard Hinnant's date library
fn daysFromYmd(year: i32, month: u8, day: u8) i64 {
    // Adjust for months (March = 0 in this algorithm)
    const y: i64 = if (month <= 2) year - 1 else year;
    const m: i64 = if (month <= 2) month + 12 else month;
    const era: i64 = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: i64 = y - era * 400; // year of era [0, 399]
    const doy: i64 = @divFloor((153 * (m - 3) + 2), 5) + day - 1; // day of year [0, 365]
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // day of era [0, 146096]
    return era * 146097 + doe - 719468; // Unix epoch offset
}

// ============================================================================
// Hook Implementations
// ============================================================================

/// SessionEnd hook - marks session end in trace
pub fn sessionEnd(allocator: std.mem.Allocator, input: HookInput) HookOutput {
    const store_path = getAliceJwzStore(allocator) orelse {
        return HookOutput.approve();
    };
    defer allocator.free(store_path);

    var store = openOrCreateStore(allocator, store_path) catch {
        return HookOutput.approve();
    };
    defer store.deinit();

    // Build topic and message
    var topic_buf: [128]u8 = undefined;
    const trace_topic = std.fmt.bufPrint(&topic_buf, "trace:{s}", .{input.session_id}) catch {
        return HookOutput.approve();
    };

    var ts_buf: [32]u8 = undefined;
    const timestamp = getTimestamp(&ts_buf);

    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf,
        \\{{"event_type":"session_end","timestamp":"{s}"}}
    , .{timestamp}) catch {
        return HookOutput.approve();
    };

    postToTopic(allocator, &store, trace_topic, msg) catch {};

    return HookOutput.approve();
}

/// Find the last valid UTF-8 boundary at or before `max_len`.
/// UTF-8 encoding: bytes starting with 10xxxxxx are continuation bytes.
/// We walk back from max_len to find a byte that's not a continuation.
fn findUtf8Boundary(data: []const u8, max_len: usize) usize {
    if (data.len <= max_len) return data.len;

    var end = max_len;
    // Walk back while we're on continuation bytes (0x80-0xBF)
    while (end > 0 and (data[end] & 0xC0) == 0x80) {
        end -= 1;
    }
    // If we're now on a multi-byte start (0xC0-0xFF), check if the sequence is complete
    if (end > 0 and (data[end - 1] & 0x80) != 0) {
        // Check if the byte at end-1 starts a sequence that would extend past end
        const start_byte = data[end - 1];
        const seq_len: usize = if ((start_byte & 0xF8) == 0xF0) 4 // 11110xxx = 4 bytes
        else if ((start_byte & 0xF0) == 0xE0) 3 // 1110xxxx = 3 bytes
        else if ((start_byte & 0xE0) == 0xC0) 2 // 110xxxxx = 2 bytes
        else 1;
        // If sequence would be incomplete, exclude it
        if (end - 1 + seq_len > max_len) {
            end -= 1;
        }
    }
    return end;
}

/// Truncate and serialize a JSON value to a string, respecting UTF-8 boundaries.
fn truncateJsonValue(allocator: std.mem.Allocator, value: ?std.json.Value, max_len: usize) []const u8 {
    const val = value orelse return "";

    // Serialize to JSON using std.json.stringifyAlloc
    var json_list: std.ArrayList(u8) = .empty;
    defer json_list.deinit(allocator);

    writeJsonValue(val, json_list.writer(allocator)) catch return "";

    if (json_list.items.len == 0) return "";

    // Truncate at UTF-8 boundary if needed
    const safe_len = findUtf8Boundary(json_list.items, max_len);
    const truncated = json_list.items[0..safe_len];

    // Duplicate since we're returning from deferred data
    return allocator.dupe(u8, truncated) catch "";
}

/// Write a JSON value to a writer (manual serialization for Zig 0.15)
fn writeJsonValue(value: std.json.Value, writer: anytype) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |i| try writer.print("{d}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .string => |s| {
            try writer.writeByte('"');
            try escapeJsonString(s, writer);
            try writer.writeByte('"');
        },
        .array => |arr| {
            try writer.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try writeJsonValue(item, writer);
            }
            try writer.writeByte(']');
        },
        .object => |obj| {
            try writer.writeByte('{');
            var first = true;
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                if (!first) try writer.writeByte(',');
                first = false;
                try writer.writeByte('"');
                try escapeJsonString(entry.key_ptr.*, writer);
                try writer.writeAll("\":");
                try writeJsonValue(entry.value_ptr.*, writer);
            }
            try writer.writeByte('}');
        },
        .number_string => |s| try writer.writeAll(s),
    }
}

/// PostToolUse hook - captures tool execution events for trace
pub fn postToolUse(allocator: std.mem.Allocator, input: HookInput) HookOutput {
    const store_path = getAliceJwzStore(allocator) orelse {
        return HookOutput.approve();
    };
    defer allocator.free(store_path);

    var store = openOrCreateStore(allocator, store_path) catch {
        return HookOutput.approve();
    };
    defer store.deinit();

    // Build topic
    var topic_buf: [128]u8 = undefined;
    const trace_topic = std.fmt.bufPrint(&topic_buf, "trace:{s}", .{input.session_id}) catch {
        return HookOutput.approve();
    };

    var ts_buf: [32]u8 = undefined;
    const timestamp = getTimestamp(&ts_buf);

    // Extract tool_name
    const tool_name = input.tool_name orelse "unknown";

    // Determine success from tool_response
    var success = true;
    if (input.tool_response) |tr| {
        if (tr == .object) {
            if (tr.object.get("success")) |s| {
                if (s == .bool) success = s.bool;
            }
        }
    }

    // Truncate tool payloads (8KB max, UTF-8-safe)
    const max_payload_size: usize = 8192;
    const tool_input_str = truncateJsonValue(allocator, input.tool_input, max_payload_size);
    defer if (tool_input_str.len > 0) allocator.free(tool_input_str);
    const tool_response_str = truncateJsonValue(allocator, input.tool_response, max_payload_size);
    defer if (tool_response_str.len > 0) allocator.free(tool_response_str);

    // Build trace event with tool payloads
    var msg_list: std.ArrayList(u8) = .empty;
    defer msg_list.deinit(allocator);

    var writer = msg_list.writer(allocator);

    // Start JSON object (escape tool_name for JSON)
    writer.writeAll("{\"event_type\":\"tool_completed\",\"tool_name\":\"") catch {
        return HookOutput.approve();
    };
    escapeJsonString(tool_name, writer) catch {};
    writer.print("\",\"success\":{s},\"timestamp\":\"{s}\"", .{
        if (success) "true" else "false",
        timestamp,
    }) catch {};

    // Add tool_input if present
    if (tool_input_str.len > 0) {
        writer.writeAll(",\"tool_input\":\"") catch {};
        escapeJsonString(tool_input_str, writer) catch {};
        writer.writeByte('"') catch {};
    }

    // Add tool_response if present
    if (tool_response_str.len > 0) {
        writer.writeAll(",\"tool_response\":\"") catch {};
        escapeJsonString(tool_response_str, writer) catch {};
        writer.writeByte('"') catch {};
    }

    writer.writeByte('}') catch {};

    postToTopic(allocator, &store, trace_topic, msg_list.items) catch {};

    return HookOutput.approve();
}

/// UserPromptSubmit hook - captures user messages and handles #alice command
pub fn userPrompt(allocator: std.mem.Allocator, input: HookInput) HookOutput {
    const store_path = getAliceJwzStore(allocator) orelse {
        return HookOutput.approve();
    };
    defer allocator.free(store_path);

    var store = openOrCreateStore(allocator, store_path) catch {
        return HookOutput.approve();
    };
    defer store.deinit();

    const user_prompt = input.prompt orelse return HookOutput.approve();
    if (user_prompt.len == 0) return HookOutput.approve();

    var ts_buf: [32]u8 = undefined;
    const timestamp = getTimestamp(&ts_buf);

    // Topic names
    var review_topic_buf: [128]u8 = undefined;
    const review_state_topic = std.fmt.bufPrint(&review_topic_buf, "review:state:{s}", .{input.session_id}) catch {
        return HookOutput.approve();
    };

    var user_topic_buf: [128]u8 = undefined;
    const user_topic = std.fmt.bufPrint(&user_topic_buf, "user:context:{s}", .{input.session_id}) catch {
        return HookOutput.approve();
    };

    var alice_topic_buf: [128]u8 = undefined;
    const alice_topic = std.fmt.bufPrint(&alice_topic_buf, "alice:status:{s}", .{input.session_id}) catch {
        return HookOutput.approve();
    };

    var trace_topic_buf: [128]u8 = undefined;
    const trace_topic = std.fmt.bufPrint(&trace_topic_buf, "trace:{s}", .{input.session_id}) catch {
        return HookOutput.approve();
    };

    // Check for #alice command (case-insensitive)
    var alice_mode_msg: ?[]const u8 = null;
    if (startsWithAliceCommand(user_prompt)) |cmd| {
        alice_mode_msg = processAliceCommand(allocator, &store, review_state_topic, timestamp, cmd);
    }

    // Store user message for alice context
    {
        // Reset alice status
        var reset_buf: [256]u8 = undefined;
        const reset_msg = std.fmt.bufPrint(&reset_buf,
            \\{{"decision":"PENDING","summary":"New user prompt received, review required","timestamp":"{s}"}}
        , .{timestamp}) catch "";
        if (reset_msg.len > 0) {
            postToTopic(allocator, &store, alice_topic, reset_msg) catch {};
        }

        // Store user prompt - need to escape the prompt for JSON
        var escaped_prompt: std.ArrayList(u8) = .empty;
        defer escaped_prompt.deinit(allocator);
        escapeJsonString(user_prompt, escaped_prompt.writer(allocator)) catch {};

        var user_msg_list: std.ArrayList(u8) = .empty;
        defer user_msg_list.deinit(allocator);
        user_msg_list.writer(allocator).print(
            \\{{"type":"user_message","prompt":"{s}","timestamp":"{s}"}}
        , .{ escaped_prompt.items, timestamp }) catch {};

        if (user_msg_list.items.len > 0) {
            postToTopic(allocator, &store, user_topic, user_msg_list.items) catch {};
        }

        // Emit trace event
        var trace_msg_list: std.ArrayList(u8) = .empty;
        defer trace_msg_list.deinit(allocator);
        trace_msg_list.writer(allocator).print(
            \\{{"event_type":"prompt_received","prompt":"{s}","timestamp":"{s}"}}
        , .{ escaped_prompt.items, timestamp }) catch {};

        if (trace_msg_list.items.len > 0) {
            postToTopic(allocator, &store, trace_topic, trace_msg_list.items) catch {};
        }
    }

    // Return with optional alice mode message
    if (alice_mode_msg) |msg| {
        return HookOutput.approveWithContext("UserPromptSubmit", msg);
    }

    return HookOutput.approve();
}

const AliceCommand = enum { enable, disable };

fn processAliceCommand(
    allocator: std.mem.Allocator,
    store: *jwz.store.Store,
    review_state_topic: []const u8,
    timestamp: []const u8,
    cmd: AliceCommand,
) []const u8 {
    switch (cmd) {
        .enable => {
            var state_buf: [256]u8 = undefined;
            const state_msg = std.fmt.bufPrint(&state_buf,
                \\{{"enabled":true,"timestamp":"{s}"}}
            , .{timestamp}) catch {
                return "alice: WARNING - failed to enable review mode";
            };
            postToTopic(allocator, store, review_state_topic, state_msg) catch {
                return "alice: WARNING - failed to enable review mode";
            };
            return "alice: review mode ON";
        },
        .disable => {
            var state_buf: [256]u8 = undefined;
            const state_msg = std.fmt.bufPrint(&state_buf,
                \\{{"enabled":false,"timestamp":"{s}","manually_stopped":true}}
            , .{timestamp}) catch {
                return "alice: WARNING - failed to disable review mode";
            };
            postToTopic(allocator, store, review_state_topic, state_msg) catch {
                return "alice: WARNING - failed to disable review mode";
            };
            return "alice: review mode OFF (manually stopped)";
        },
    }
}

fn startsWithAliceCommand(prompt: []const u8) ?AliceCommand {
    // Match #alice or #ALICE (case insensitive) at start
    if (prompt.len < 6) return null;
    if (prompt[0] != '#') return null;

    const rest = prompt[1..];
    if (rest.len >= 5 and std.ascii.eqlIgnoreCase(rest[0..5], "alice")) {
        const after_alice = rest[5..];
        // Check for :stop variant
        if (after_alice.len >= 5) {
            if (after_alice[0] == ':' and std.ascii.eqlIgnoreCase(after_alice[1..5], "stop")) {
                // Must be followed by whitespace or end
                if (after_alice.len == 5 or std.ascii.isWhitespace(after_alice[5])) {
                    return .disable;
                }
            }
        }
        // Plain #alice - must be followed by whitespace or end
        if (after_alice.len == 0 or std.ascii.isWhitespace(after_alice[0])) {
            return .enable;
        }
    }
    return null;
}

fn escapeJsonString(s: []const u8, writer: anytype) !void {
    for (s) |c| {
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

/// SessionStart hook - injects context and performs health checks
pub fn sessionStart(allocator: std.mem.Allocator, input: HookInput) HookOutput {
    const source = input.source orelse "startup";

    // Discover tissue store path (for health check display only)
    const tissue_path = tissue.store.discoverStoreDir(allocator) catch null;
    defer if (tissue_path) |p| allocator.free(p);

    // Try to discover and open jwz store - continue with degraded functionality if it fails
    var jwz_status: []const u8 = "no store";
    var store_path_owned: ?[]const u8 = null;
    var store: ?jwz.store.Store = null;

    if (getAliceJwzStore(allocator)) |path| {
        store_path_owned = path;
        if (openOrCreateStore(allocator, path)) |s| {
            store = s;
            jwz_status = "ok";
        } else |err| {
            // Store path found but couldn't open - report the specific error
            var err_buf: [64]u8 = undefined;
            jwz_status = std.fmt.bufPrint(&err_buf, "error: {s}", .{@errorName(err)}) catch "error";
        }
    }
    defer if (store_path_owned) |p| allocator.free(p);
    defer if (store) |*s| s.deinit();

    var ts_buf: [32]u8 = undefined;
    const timestamp = getTimestamp(&ts_buf);

    // Health check status
    var tissue_status: []const u8 = "not installed";
    var codex_status: []const u8 = "not installed";
    var gemini_status: []const u8 = "not installed";

    // Check tissue and get ready issues
    // Use input.cwd so tissue can find local .tissue/ stores
    var ready_issues: []const u8 = "";
    if (std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tissue", "list", "--limit", "1" },
        .cwd = input.cwd,
        .max_output_bytes = 1024,
    })) |result| {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        tissue_status = if (result.term.Exited == 0) "ok" else "error";

        // If tissue works, get ready issues (limit to 10 for context window)
        if (result.term.Exited == 0) {
            if (std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ "tissue", "ready", "--limit", "10" },
                .cwd = input.cwd,
                .max_output_bytes = 4096,
            })) |ready_result| {
                defer allocator.free(ready_result.stderr);
                if (ready_result.term.Exited == 0 and ready_result.stdout.len > 0) {
                    // Trim trailing whitespace
                    var end = ready_result.stdout.len;
                    while (end > 0 and (ready_result.stdout[end - 1] == '\n' or ready_result.stdout[end - 1] == ' ')) {
                        end -= 1;
                    }
                    if (end > 0) {
                        ready_issues = ready_result.stdout[0..end];
                        // Don't free stdout - we're keeping it
                    } else {
                        allocator.free(ready_result.stdout);
                    }
                } else {
                    allocator.free(ready_result.stdout);
                }
            } else |_| {}
        }
    } else |_| {}

    // Check codex
    if (std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "which", "codex" },
        .max_output_bytes = 256,
    })) |result| {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        if (result.term.Exited == 0) codex_status = "ok";
    } else |_| {}

    // Check gemini
    if (std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "which", "gemini" },
        .max_output_bytes = 256,
    })) |result| {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        if (result.term.Exited == 0) gemini_status = "ok";
    } else |_| {}

    // Clean up stale review state (except on compact) - only if store is available
    var review_cleaned: ?[]const u8 = null;
    if (store) |*s| {
        if (!std.mem.eql(u8, source, "compact")) {
            var review_topic_buf: [128]u8 = undefined;
            const review_state_topic = std.fmt.bufPrint(&review_topic_buf, "review:state:{s}", .{input.session_id}) catch "";

            if (review_state_topic.len > 0) {
                if (getLatestMessage(allocator, s, review_state_topic)) |msg| {
                    defer msg.deinit(allocator);

                    // Parse to check if enabled
                    if (std.json.parseFromSlice(ReviewState, allocator, msg.body, .{
                        .ignore_unknown_fields = true,
                    })) |parsed| {
                        defer parsed.deinit();
                        if (parsed.value.enabled) {
                            // Clean up stale state
                            var cleanup_buf: [256]u8 = undefined;
                            const cleanup_msg = std.fmt.bufPrint(&cleanup_buf,
                                \\{{"enabled":false,"timestamp":"{s}","session_start_cleanup":true}}
                            , .{timestamp}) catch "";
                            if (cleanup_msg.len > 0) {
                                postToTopic(allocator, s, review_state_topic, cleanup_msg) catch {};
                                review_cleaned = "Previous review state cleaned up (was enabled). Use #alice to re-enable.";
                            }
                        }
                    } else |_| {}
                }
            }
        }
    }

    // Discover available skills
    var skills_buf: [512]u8 = undefined;
    var skills_len: usize = 0;
    if (std.posix.getenv("CLAUDE_PLUGIN_ROOT")) |plugin_root| {
        var path_buf: [512]u8 = undefined;
        const skills_path = std.fmt.bufPrint(&path_buf, "{s}/skills", .{plugin_root}) catch "";
        if (skills_path.len > 0) {
            if (std.fs.openDirAbsolute(skills_path, .{ .iterate = true })) |dir| {
                var d = dir;
                defer d.close();
                var iter = d.iterate();
                while (iter.next() catch null) |entry| {
                    if (entry.kind == .directory) {
                        // Check for SKILL.md
                        var skill_file_buf: [256]u8 = undefined;
                        const skill_file = std.fmt.bufPrint(&skill_file_buf, "{s}/{s}/SKILL.md", .{ skills_path, entry.name }) catch continue;
                        if (std.fs.accessAbsolute(skill_file, .{})) |_| {
                            if (skills_len > 0) {
                                if (skills_len + 2 < skills_buf.len) {
                                    skills_buf[skills_len] = ',';
                                    skills_buf[skills_len + 1] = ' ';
                                    skills_len += 2;
                                }
                            }
                            const name_len = @min(entry.name.len, skills_buf.len - skills_len);
                            @memcpy(skills_buf[skills_len..][0..name_len], entry.name[0..name_len]);
                            skills_len += name_len;
                        } else |_| {}
                    }
                }
            } else |_| {}
        }
    }
    const skills = if (skills_len > 0) skills_buf[0..skills_len] else "None detected";

    // Emit session_start trace event - only if store is available
    if (store) |*s| {
        var trace_topic_buf: [128]u8 = undefined;
        const trace_topic = std.fmt.bufPrint(&trace_topic_buf, "trace:{s}", .{input.session_id}) catch "";
        if (trace_topic.len > 0) {
            var trace_buf: [256]u8 = undefined;
            const trace_msg = std.fmt.bufPrint(&trace_buf,
                \\{{"event_type":"session_start","timestamp":"{s}","source":"{s}"}}
            , .{ timestamp, source }) catch "";
            if (trace_msg.len > 0) {
                postToTopic(allocator, s, trace_topic, trace_msg) catch {};
            }
        }
    }

    // Build context message
    // Note: Not using defer since we return a slice referencing this data
    // Process exits immediately after so OS cleans up
    var context_list: std.ArrayList(u8) = .empty;

    var writer = context_list.writer(allocator);
    writer.print(
        \\## alice Plugin Active
        \\
        \\You are running with the **alice** plugin.
        \\
        \\### Tool Health
        \\
        \\| Tool | Status | Purpose |
        \\|------|--------|---------|
        \\| tissue | {s} | Issue tracking (`tissue list`, `tissue new`) |
        \\| jwz | {s} | Agent messaging (`jwz read`, `jwz post`) |
        \\| codex | {s} | External model queries |
        \\| gemini | {s} | External model queries |
        \\
        \\### Review Mode
        \\
        \\`#alice` enables review mode. **Answer normally.** If alice review is required, you will be blocked and given instructions. Do not proactively invoke alice.
        \\
        \\**Important:** The alice review gate uses the `alice:alice` agent (Task tool), NOT the `alice:reviewing` skill.
        \\
        \\### Available Skills
        \\
        \\{s}
        \\
        \\### Session
        \\
        \\Session ID: `{s}`
        \\
    , .{ tissue_status, jwz_status, codex_status, gemini_status, skills, input.session_id }) catch {};

    // Add ready issues if available
    if (ready_issues.len > 0) {
        writer.writeAll(
            \\### Ready Issues
            \\
            \\Issues with no blockers (use `tissue show <id>` for details):
            \\
            \\```
            \\
        ) catch {};
        writer.writeAll(ready_issues) catch {};
        writer.writeAll(
            \\
            \\```
            \\
        ) catch {};
    }

    if (review_cleaned) |cleaned_msg| {
        return HookOutput.approveWithMessage("SessionStart", context_list.items, cleaned_msg);
    }

    return HookOutput.approveWithContext("SessionStart", context_list.items);
}

/// Stop hook - gates exit on alice review
pub fn stop(allocator: std.mem.Allocator, input: HookInput) HookOutput {
    const store_path = getAliceJwzStore(allocator) orelse {
        // Can't find any jwz store - fail open
        return HookOutput.approve();
    };
    defer allocator.free(store_path);

    var store = openOrCreateStore(allocator, store_path) catch {
        // Fail open - review system can't function
        return HookOutput.approve();
    };
    defer store.deinit();

    // Emit trace event to record that stop hook was called
    {
        var trace_topic_buf: [128]u8 = undefined;
        const trace_topic = std.fmt.bufPrint(&trace_topic_buf, "trace:{s}", .{input.session_id}) catch "";
        if (trace_topic.len > 0) {
            var ts_buf: [32]u8 = undefined;
            const timestamp = getTimestamp(&ts_buf);
            var trace_buf: [256]u8 = undefined;
            const trace_msg = std.fmt.bufPrint(&trace_buf,
                \\{{"event_type":"stop_hook_called","timestamp":"{s}"}}
            , .{timestamp}) catch "";
            if (trace_msg.len > 0) {
                postToTopic(allocator, &store, trace_topic, trace_msg) catch {};
            }
        }
    }

    // Topic names
    var review_topic_buf: [128]u8 = undefined;
    const review_state_topic = std.fmt.bufPrint(&review_topic_buf, "review:state:{s}", .{input.session_id}) catch {
        return HookOutput.approve();
    };

    var alice_topic_buf: [128]u8 = undefined;
    const alice_topic = std.fmt.bufPrint(&alice_topic_buf, "alice:status:{s}", .{input.session_id}) catch {
        return HookOutput.approve();
    };

    // Check review state
    const review_msg = getLatestMessage(allocator, &store, review_state_topic) orelse {
        // No review state - approve
        return HookOutput.approve();
    };
    defer review_msg.deinit(allocator);

    const review_state = std.json.parseFromSlice(ReviewState, allocator, review_msg.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        // Can't parse - fail open with warning
        return emitWarningAndApprove(allocator, &store, input.session_id, "Failed to parse review state - may be corrupted");
    };
    defer review_state.deinit();

    if (!review_state.value.enabled) {
        return HookOutput.approve();
    }

    // Review is enabled - check alice's decision
    const alice_msg_opt = getLatestMessage(allocator, &store, alice_topic);

    // Circuit breaker constants
    const max_blocks: u32 = 3;
    const current_block_count = review_state.value.block_count orelse 0;
    const current_no_id_count = review_state.value.no_id_block_count orelse 0;
    const last_blocked_id = review_state.value.last_blocked_review_id;

    // Handle case where there's no alice message (review enabled but alice never ran)
    if (alice_msg_opt == null) {
        const new_no_id_count = current_no_id_count + 1;

        if (new_no_id_count >= max_blocks) {
            // Trip circuit breaker
            return tripCircuitBreaker(
                allocator,
                &store,
                input.session_id,
                review_state_topic,
                "blocked too many times with no alice review ID",
            );
        }

        // Update no_id_block_count
        var ts_buf: [32]u8 = undefined;
        const timestamp = getTimestamp(&ts_buf);

        var update_list: std.ArrayList(u8) = .empty;
        defer update_list.deinit(allocator);
        update_list.writer(allocator).print(
            \\{{"enabled":true,"timestamp":"{s}","no_id_block_count":{d}}}
        , .{ timestamp, new_no_id_count }) catch {};
        if (update_list.items.len > 0) {
            postToTopic(allocator, &store, review_state_topic, update_list.items) catch {
                // Can't persist counter - fail open to prevent infinite loop
                return emitWarningAndApprove(allocator, &store, input.session_id, "Circuit breaker: failed to persist state. Failing open.");
            };
        }

        return buildBlockReason(allocator, input.session_id, null, null);
    }

    const alice_msg = alice_msg_opt.?;
    defer alice_msg.deinit(allocator);

    const alice_status = std.json.parseFromSlice(AliceStatus, allocator, alice_msg.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        return buildBlockReason(allocator, input.session_id, null, null);
    };
    defer alice_status.deinit();

    const decision = alice_status.value.decision orelse {
        return buildBlockReason(allocator, input.session_id, null, null);
    };

    // COMPLETE or APPROVED → allow exit
    if (std.mem.eql(u8, decision, "COMPLETE") or std.mem.eql(u8, decision, "APPROVED")) {
        // Reset review state
        var ts_buf: [32]u8 = undefined;
        const timestamp = getTimestamp(&ts_buf);

        var reset_buf: [256]u8 = undefined;
        const reset_msg = std.fmt.bufPrint(&reset_buf,
            \\{{"enabled":false,"timestamp":"{s}"}}
        , .{timestamp}) catch "";
        if (reset_msg.len > 0) {
            postToTopic(allocator, &store, review_state_topic, reset_msg) catch {
                // Warn but still approve - the approval itself is valid
                return emitWarningAndApprove(allocator, &store, input.session_id, "Failed to reset review state after approval. Stop hook may fire repeatedly.");
            };
        }

        return HookOutput.approve();
    }

    // Circuit breaker logic for stale reviews
    // Check if we're re-blocking on the same stale review
    if (last_blocked_id) |last_id| {
        if (std.mem.eql(u8, last_id, alice_msg.id)) {
            // Same review - increment block count
            const new_count = current_block_count + 1;
            if (new_count >= max_blocks) {
                // Trip circuit breaker
                return tripCircuitBreaker(
                    allocator,
                    &store,
                    input.session_id,
                    review_state_topic,
                    "blocked too many times on same review",
                );
            }

            // Update block count
            var ts_buf: [32]u8 = undefined;
            const timestamp = getTimestamp(&ts_buf);

            var update_list: std.ArrayList(u8) = .empty;
            defer update_list.deinit(allocator);
            update_list.writer(allocator).print(
                \\{{"enabled":true,"timestamp":"{s}","last_blocked_review_id":"{s}","block_count":{d}}}
            , .{ timestamp, alice_msg.id, new_count }) catch {};
            if (update_list.items.len > 0) {
                postToTopic(allocator, &store, review_state_topic, update_list.items) catch {
                    return emitWarningAndApprove(allocator, &store, input.session_id, "Circuit breaker: failed to persist state. Failing open.");
                };
            }
        } else {
            // New review ID - reset counters and record new ID
            var ts_buf: [32]u8 = undefined;
            const timestamp = getTimestamp(&ts_buf);

            var update_list: std.ArrayList(u8) = .empty;
            defer update_list.deinit(allocator);
            update_list.writer(allocator).print(
                \\{{"enabled":true,"timestamp":"{s}","last_blocked_review_id":"{s}","block_count":1,"no_id_block_count":0}}
            , .{ timestamp, alice_msg.id }) catch {};
            if (update_list.items.len > 0) {
                postToTopic(allocator, &store, review_state_topic, update_list.items) catch {
                    return emitWarningAndApprove(allocator, &store, input.session_id, "Circuit breaker: failed to persist state. Failing open.");
                };
            }
        }
    } else {
        // No last_blocked_id - first block ever, record it
        var ts_buf: [32]u8 = undefined;
        const timestamp = getTimestamp(&ts_buf);

        var update_list: std.ArrayList(u8) = .empty;
        defer update_list.deinit(allocator);
        update_list.writer(allocator).print(
            \\{{"enabled":true,"timestamp":"{s}","last_blocked_review_id":"{s}","block_count":1,"no_id_block_count":0}}
        , .{ timestamp, alice_msg.id }) catch {};
        if (update_list.items.len > 0) {
            postToTopic(allocator, &store, review_state_topic, update_list.items) catch {
                return emitWarningAndApprove(allocator, &store, input.session_id, "Circuit breaker: failed to persist state. Failing open.");
            };
        }
    }

    // Block with alice's feedback
    if (std.mem.eql(u8, decision, "ISSUES")) {
        return buildBlockReasonWithIssues(
            allocator,
            alice_msg.id,
            alice_status.value.summary,
            alice_status.value.message_to_agent,
        );
    }

    return buildBlockReason(allocator, input.session_id, alice_msg.id, null);
}

/// SubagentStop hook - validates alice:alice actually posted its decision
pub fn subagentStop(allocator: std.mem.Allocator, input: HookInput) HookOutput {
    // Only care about alice:alice subagent
    const subagent_type = input.subagent_type orelse return HookOutput.approve();
    if (!std.mem.eql(u8, subagent_type, "alice:alice")) {
        return HookOutput.approve();
    }

    // Extract session ID from the subagent prompt
    // Look for "SESSION_ID=xxx" pattern
    const subagent_prompt = input.subagent_prompt orelse {
        // No prompt means we can't validate - approve with warning
        return HookOutput.approve();
    };

    const session_id = extractSessionId(subagent_prompt) orelse {
        // Couldn't find SESSION_ID in prompt - this is a bug in the invoking agent
        return HookOutput.block(
            \\alice:alice completed but SESSION_ID was not found in the prompt.
            \\
            \\The invoking agent must include SESSION_ID=<session_id> in the alice prompt.
            \\Re-invoke alice:alice with the correct format.
        );
    };

    // Check if alice posted a decision to jwz
    const store_path = getAliceJwzStore(allocator) orelse {
        return HookOutput.approve(); // Fail open if no store
    };
    defer allocator.free(store_path);

    var store = openOrCreateStore(allocator, store_path) catch {
        return HookOutput.approve(); // Fail open on store error
    };
    defer store.deinit();

    // Build topic name for the ID used in the prompt
    var used_topic_buf: [128]u8 = undefined;
    const used_topic = std.fmt.bufPrint(&used_topic_buf, "alice:status:{s}", .{session_id}) catch {
        return HookOutput.approve();
    };

    // Get the latest message from the topic alice posted to
    const alice_msg = getLatestMessage(allocator, &store, used_topic) orelse {
        // No message at all - alice didn't post
        return buildAliceDidNotPostError(allocator, session_id);
    };
    defer alice_msg.deinit(allocator);

    // Parse the message
    const alice_status = std.json.parseFromSlice(AliceStatus, allocator, alice_msg.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        // Malformed message
        return buildAliceDidNotPostError(allocator, session_id);
    };
    defer alice_status.deinit();

    const decision = alice_status.value.decision orelse {
        // No decision field
        return buildAliceDidNotPostError(allocator, session_id);
    };

    // Check if it's a valid decision (not PENDING)
    if (std.mem.eql(u8, decision, "PENDING")) {
        return buildAliceDidNotPostError(allocator, session_id);
    }

    // Soft check: warn if second_opinions is missing (alice may not have waited for codex/gemini)
    const has_second_opinions = if (alice_status.value.second_opinions) |so|
        so.len > 0
    else
        false;

    if (!has_second_opinions) {
        return emitWarningAndApprove(
            allocator,
            &store,
            session_id,
            "alice decision missing 'second_opinions' - external validation may have been skipped",
        );
    }

    // Topic aliasing: if agent used a custom topic name instead of the canonical session UUID,
    // copy the decision to the canonical topic so the stop hook will find it.
    // This implements Postel's Law - be liberal in what we accept.
    //
    // SECURITY: Validate timestamp to prevent replay attacks. Old decisions from previous
    // sessions on custom topics must not auto-approve the current session.
    const canonical_id = input.session_id;
    if (!std.mem.eql(u8, session_id, canonical_id)) {
        // Validate the decision is recent (within 30 minutes) to prevent replay attacks
        const is_recent = blk: {
            const decision_ts = alice_status.value.timestamp orelse break :blk false;
            const decision_epoch = parseIso8601ToEpoch(decision_ts) orelse break :blk false;
            const now_epoch: i64 = std.time.timestamp();
            const age_seconds = now_epoch - decision_epoch;
            // Accept decisions from the last 30 minutes
            break :blk age_seconds >= 0 and age_seconds < 30 * 60;
        };

        if (!is_recent) {
            // Stale decision from a previous session - do NOT copy, warn instead
            return emitWarningAndApprove(
                allocator,
                &store,
                canonical_id,
                "alice decision found on custom topic but timestamp is stale or missing - not copying to canonical topic",
            );
        }

        var canonical_topic_buf: [128]u8 = undefined;
        const canonical_topic = std.fmt.bufPrint(&canonical_topic_buf, "alice:status:{s}", .{canonical_id}) catch "";
        if (canonical_topic.len > 0) {
            // Copy the recent decision to the canonical topic
            postToTopic(allocator, &store, canonical_topic, alice_msg.body) catch {
                // Best effort - warn but don't block
                return emitWarningAndApprove(
                    allocator,
                    &store,
                    canonical_id,
                    "alice decision found but failed to copy to canonical topic - stop hook may block",
                );
            };
        }
    }

    // Valid decision posted with second opinions - approve
    return HookOutput.approve();
}

fn extractSessionId(prompt: []const u8) ?[]const u8 {
    // Look for "SESSION_ID=" pattern
    const marker = "SESSION_ID=";
    const start_idx = std.mem.indexOf(u8, prompt, marker) orelse return null;
    const value_start = start_idx + marker.len;
    if (value_start >= prompt.len) return null;

    // Find the end (newline, space, or end of string)
    var end_idx = value_start;
    while (end_idx < prompt.len) : (end_idx += 1) {
        const c = prompt[end_idx];
        if (c == '\n' or c == '\r' or c == ' ' or c == '\t') break;
    }

    if (end_idx == value_start) return null;
    return prompt[value_start..end_idx];
}

fn buildAliceDidNotPostError(allocator: std.mem.Allocator, session_id: []const u8) HookOutput {
    var reason_list: std.ArrayList(u8) = .empty;

    var writer = reason_list.writer(allocator);
    writer.print(
        \\alice:alice completed but did NOT post its decision to jwz.
        \\
        \\The alice agent must execute this command (not just output it as text):
        \\
        \\```bash
        \\jwz post "alice:status:{s}" -m '{{
        \\  "decision": "COMPLETE",
        \\  "summary": "...",
        \\  ...
        \\}}'
        \\```
        \\
        \\Re-invoke alice:alice. Ensure the agent actually runs the jwz post command.
    , .{session_id}) catch {};

    const reason = allocator.dupe(u8, reason_list.items) catch "alice did not post decision";
    reason_list.deinit(allocator);

    return HookOutput.block(reason);
}

/// Trip the circuit breaker and disable review
fn tripCircuitBreaker(
    allocator: std.mem.Allocator,
    store: *jwz.store.Store,
    session_id: []const u8,
    review_state_topic: []const u8,
    reason: []const u8,
) HookOutput {
    var ts_buf: [32]u8 = undefined;
    const timestamp = getTimestamp(&ts_buf);

    var disable_buf: [256]u8 = undefined;
    const disable_msg = std.fmt.bufPrint(&disable_buf,
        \\{{"enabled":false,"timestamp":"{s}","circuit_breaker_tripped":true}}
    , .{timestamp}) catch "";
    if (disable_msg.len > 0) {
        postToTopic(allocator, store, review_state_topic, disable_msg) catch {};
    }

    return emitWarningAndApprove(allocator, store, session_id, reason);
}

fn buildBlockReason(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    alice_msg_id: ?[]const u8,
    _: ?[]const u8,
) HookOutput {
    var reason_list: std.ArrayList(u8) = .empty;
    // Note: We don't defer deinit because the output owns the memory

    var writer = reason_list.writer(allocator);
    writer.print(
        \\Review is enabled but alice hasn't approved.
        \\
        \\Use the Task tool with subagent_type="alice:alice" and this prompt:
        \\
        \\---
        \\SESSION_ID={s}
        \\
        \\IMPORTANT: SESSION_ID must be the EXACT UUID shown above (format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx).
        \\Do NOT use a custom name, issue ID, or descriptive label - the stop hook will not find your approval.
        \\
        \\## Work performed
        \\
        \\<Include relevant sections based on what you did>
        \\
        \\### Context (if you referenced issues or messages):
        \\- tissue issue <id>: <title or summary>
        \\- jwz message <topic>: <what it informed>
        \\
        \\### Code changes (if any files were modified):
        \\- <file>: <what changed>
        \\
        \\### Research findings (if you explored/investigated):
        \\- <what you searched for>: <what you found or concluded>
        \\
        \\### Planning outcomes (if you made or refined a plan):
        \\- <decision or step>: <the outcome>
        \\
        \\### Open questions (if you have gaps or uncertainties):
        \\- <question>: <why it matters or what's blocking>
        \\---
        \\
        \\RULES:
        \\- Report ALL work you performed, not just code changes
        \\- List facts only (what you did, what you found), no justifications
        \\- Do NOT summarize intent or explain why you chose an approach
        \\- Do NOT editorialize or argue your case
        \\- Include relevant details: files read, searches run, conclusions reached
        \\- Alice forms her own judgment from the user's prompt transcript
        \\
        \\Alice will read jwz topic 'user:context:{s}' for the user's actual request
        \\and evaluate whether YOUR work satisfies THE USER's desires (not your interpretation).
    , .{ session_id, session_id }) catch {};

    if (alice_msg_id) |id| {
        writer.print("\n\n(Previous review: {s})", .{id}) catch {};
    }

    // Create a static reason slice that will persist
    // This is a workaround - ideally we'd have better lifetime management
    const reason = allocator.dupe(u8, reason_list.items) catch "Review required";
    reason_list.deinit(allocator);

    return HookOutput.block(reason);
}

fn buildBlockReasonWithIssues(
    allocator: std.mem.Allocator,
    alice_msg_id: []const u8,
    summary: ?[]const u8,
    message: ?[]const u8,
) HookOutput {
    var reason_list: std.ArrayList(u8) = .empty;

    var writer = reason_list.writer(allocator);
    writer.print("alice found issues that must be addressed. (review: {s})", .{alice_msg_id}) catch {};

    if (summary) |s| {
        writer.print("\n\n{s}", .{s}) catch {};
    }

    if (message) |m| {
        writer.print("\n\nalice says: {s}", .{m}) catch {};
    }

    writer.writeAll(
        \\
        \\
        \\---
        \\Address these issues, then use the Task tool with subagent_type="alice:alice" for a fresh review.
        \\If you have questions about how to proceed, include them in your alice invocation - do not ask the user.
    ) catch {};

    const reason = allocator.dupe(u8, reason_list.items) catch "Review required";
    reason_list.deinit(allocator);

    return HookOutput.block(reason);
}

// ============================================================================
// Main Entry Point
// ============================================================================

/// Run a hook by name, reading input from stdin and writing output to stdout
pub fn runHook(base_allocator: std.mem.Allocator, hook_name: []const u8) !void {
    // Use arena allocator for all hook allocations - automatically freed at end
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Read stdin
    const stdin = std.fs.File.stdin();
    const input_json = try stdin.readToEndAlloc(allocator, 1024 * 1024);
    // No defer free needed - arena handles cleanup

    // Setup stdout
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    // Parse input
    const parsed = HookInput.parse(allocator, input_json) catch {
        // On parse error, output approve and exit
        try stdout.writeAll("{\"decision\":\"approve\"}");
        try stdout.flush();
        return;
    };
    // No defer deinit needed - arena handles cleanup

    const input = parsed.value;

    // Dispatch to appropriate hook
    const output: HookOutput = if (std.mem.eql(u8, hook_name, "session-start"))
        sessionStart(allocator, input)
    else if (std.mem.eql(u8, hook_name, "session-end"))
        sessionEnd(allocator, input)
    else if (std.mem.eql(u8, hook_name, "user-prompt"))
        userPrompt(allocator, input)
    else if (std.mem.eql(u8, hook_name, "post-tool-use"))
        postToolUse(allocator, input)
    else if (std.mem.eql(u8, hook_name, "stop"))
        stop(allocator, input)
    else if (std.mem.eql(u8, hook_name, "subagent-stop"))
        subagentStop(allocator, input)
    else {
        try stdout.print("{{\"decision\":\"approve\",\"reason\":\"Unknown hook: {s}\"}}", .{hook_name});
        try stdout.flush();
        return;
    };

    // Write output
    try output.writeJson(stdout);
    try stdout.flush();
    // Arena automatically frees all allocations including HookOutput data
}

// ============================================================================
// Tests
// ============================================================================

test "alice command parsing" {
    const testing = std.testing;

    try testing.expectEqual(AliceCommand.enable, startsWithAliceCommand("#alice").?);
    try testing.expectEqual(AliceCommand.enable, startsWithAliceCommand("#alice ").?);
    try testing.expectEqual(AliceCommand.enable, startsWithAliceCommand("#ALICE").?);
    try testing.expectEqual(AliceCommand.enable, startsWithAliceCommand("#Alice some text").?);
    try testing.expectEqual(AliceCommand.disable, startsWithAliceCommand("#alice:stop").?);
    try testing.expectEqual(AliceCommand.disable, startsWithAliceCommand("#alice:stop ").?);
    try testing.expectEqual(AliceCommand.disable, startsWithAliceCommand("#ALICE:STOP").?);

    try testing.expectEqual(@as(?AliceCommand, null), startsWithAliceCommand("alice"));
    try testing.expectEqual(@as(?AliceCommand, null), startsWithAliceCommand("#aliceX"));
    try testing.expectEqual(@as(?AliceCommand, null), startsWithAliceCommand("#alice:other"));
}

test "json string escaping" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    try escapeJsonString("hello\nworld", stream.writer());
    try testing.expectEqualStrings("hello\\nworld", stream.getWritten());

    stream.reset();
    try escapeJsonString("quote\"here", stream.writer());
    try testing.expectEqualStrings("quote\\\"here", stream.getWritten());
}

test "extractSessionId" {
    const testing = std.testing;

    // Basic case
    try testing.expectEqualStrings("abc123", extractSessionId("SESSION_ID=abc123").?);

    // With newline
    try testing.expectEqualStrings("abc123", extractSessionId("SESSION_ID=abc123\nMore text").?);

    // With other content before
    try testing.expectEqualStrings("xyz789", extractSessionId("Some intro\nSESSION_ID=xyz789\nMore").?);

    // UUID-style session ID
    try testing.expectEqualStrings(
        "03374894-467b-404f-bfa4-ed8a0388ba4e",
        extractSessionId("SESSION_ID=03374894-467b-404f-bfa4-ed8a0388ba4e\n").?,
    );

    // No session ID
    try testing.expectEqual(@as(?[]const u8, null), extractSessionId("No session here"));

    // Empty value
    try testing.expectEqual(@as(?[]const u8, null), extractSessionId("SESSION_ID=\n"));
}

test "findUtf8Boundary" {
    const testing = std.testing;

    // ASCII-only: boundary is exact
    try testing.expectEqual(@as(usize, 5), findUtf8Boundary("hello world", 5));

    // Under max_len: return full length
    try testing.expectEqual(@as(usize, 5), findUtf8Boundary("hello", 10));

    // 2-byte UTF-8 (e.g., "é" = C3 A9): don't cut in middle
    const e_acute = "caf\xc3\xa9"; // "café"
    try testing.expectEqual(@as(usize, 3), findUtf8Boundary(e_acute, 4)); // Before the é
    try testing.expectEqual(@as(usize, 5), findUtf8Boundary(e_acute, 5)); // Include full é

    // 3-byte UTF-8 (e.g., "─" = E2 94 80): don't cut in middle
    const box_char = "a\xe2\x94\x80b"; // "a─b"
    try testing.expectEqual(@as(usize, 1), findUtf8Boundary(box_char, 2)); // Before box char
    try testing.expectEqual(@as(usize, 1), findUtf8Boundary(box_char, 3)); // Still before (incomplete)
    try testing.expectEqual(@as(usize, 4), findUtf8Boundary(box_char, 4)); // Include full box char

    // 4-byte UTF-8 (e.g., emoji "😀" = F0 9F 98 80)
    const emoji = "x\xf0\x9f\x98\x80y"; // "x😀y"
    try testing.expectEqual(@as(usize, 1), findUtf8Boundary(emoji, 2)); // Before emoji
    try testing.expectEqual(@as(usize, 1), findUtf8Boundary(emoji, 4)); // Still before (incomplete)
    try testing.expectEqual(@as(usize, 5), findUtf8Boundary(emoji, 5)); // Include full emoji

    // Empty string
    try testing.expectEqual(@as(usize, 0), findUtf8Boundary("", 10));
}

test "parseIso8601ToEpoch" {
    const testing = std.testing;

    // Unix epoch
    try testing.expectEqual(@as(?i64, 0), parseIso8601ToEpoch("1970-01-01T00:00:00Z"));

    // Known timestamp: 2026-01-13T23:00:00Z
    // Days from 1970-01-01 to 2026-01-13 = 20466 days
    // 20466 * 86400 + 23*3600 = 1768266000
    const expected: i64 = 1768266000;
    try testing.expectEqual(@as(?i64, expected), parseIso8601ToEpoch("2026-01-13T23:00:00Z"));

    // Invalid inputs
    try testing.expectEqual(@as(?i64, null), parseIso8601ToEpoch("short"));
    try testing.expectEqual(@as(?i64, null), parseIso8601ToEpoch("not-a-timestamp-!!!"));
    try testing.expectEqual(@as(?i64, null), parseIso8601ToEpoch("2026-13-01T00:00:00Z")); // Invalid month
    try testing.expectEqual(@as(?i64, null), parseIso8601ToEpoch("2026-01-32T00:00:00Z")); // Invalid day
}
