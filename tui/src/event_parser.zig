const std = @import("std");
const sm = @import("state_machine.zig");

/// Parse a JSON event from jwz into a LoopState
/// Returns null if parsing fails or state is invalid
pub fn parseEvent(allocator: std.mem.Allocator, json_str: []const u8) !?ParsedEvent {
    const trimmed = std.mem.trim(u8, json_str, " \t\n\r");
    if (trimmed.len == 0) return null;

    // Check for schema field first
    const schema = extractNumber(trimmed, "\"schema\"") orelse return null;

    // Parse event type
    const event_str = extractString(trimmed, "\"event\"") orelse "STATE";
    const event = sm.EventType.fromString(event_str) orelse .STATE;

    // Parse run_id
    const run_id = extractString(trimmed, "\"run_id\"") orelse "";

    // Parse updated_at timestamp
    const updated_at_str = extractString(trimmed, "\"updated_at\"");
    const updated_at = if (updated_at_str) |ts| parseIso8601(ts) else null;

    // Parse reason (for DONE events)
    const reason_str = extractString(trimmed, "\"reason\"");
    const reason = if (reason_str) |r| sm.CompletionReason.fromString(r) else null;

    // Parse stack array
    var stack = std.ArrayListUnmanaged(sm.StackFrame){};
    errdefer stack.deinit(allocator);

    try parseStack(allocator, trimmed, &stack);

    return ParsedEvent{
        .state = sm.LoopState{
            .schema = @intCast(schema),
            .event = event,
            .run_id = run_id,
            .updated_at = updated_at,
            .stack = try stack.toOwnedSlice(allocator),
            .reason = reason,
        },
        .allocator = allocator,
    };
}

/// Wrapper that owns the parsed state and its memory
pub const ParsedEvent = struct {
    state: sm.LoopState,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ParsedEvent) void {
        self.allocator.free(self.state.stack);
    }
};

/// Parse ISO 8601 timestamp to Unix timestamp
/// Handles format: 2024-12-21T10:30:00Z
pub fn parseIso8601(ts: []const u8) ?i64 {
    if (ts.len < 19) return null;

    // Parse: YYYY-MM-DDTHH:MM:SS
    const year = std.fmt.parseInt(i32, ts[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, ts[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, ts[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, ts[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, ts[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, ts[17..19], 10) catch return null;

    // Convert to days since epoch using Zig's epoch day calculation
    const epoch_day = daysSinceEpoch(year, month, day) orelse return null;
    const day_seconds: i64 = @as(i64, epoch_day) * 86400;
    const time_seconds: i64 = @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);

    return day_seconds + time_seconds;
}

/// Calculate days since Unix epoch (1970-01-01)
fn daysSinceEpoch(year: i32, month: u8, day: u8) ?i64 {
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;

    // Days in each month (non-leap year)
    const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var total_days: i64 = 0;

    // Years since 1970
    var y = @as(i64, 1970);
    while (y < year) : (y += 1) {
        total_days += if (isLeapYear(@intCast(y))) 366 else 365;
    }
    while (y > year) : (y -= 1) {
        total_days -= if (isLeapYear(@intCast(y - 1))) 366 else 365;
    }

    // Months
    var m: u8 = 1;
    while (m < month) : (m += 1) {
        total_days += days_in_month[m - 1];
        if (m == 2 and isLeapYear(year)) total_days += 1;
    }

    // Days
    total_days += day - 1;

    return total_days;
}

fn isLeapYear(year: i32) bool {
    if (@mod(year, 400) == 0) return true;
    if (@mod(year, 100) == 0) return false;
    if (@mod(year, 4) == 0) return true;
    return false;
}

/// Parse the stack array from JSON
fn parseStack(allocator: std.mem.Allocator, json_str: []const u8, stack: *std.ArrayListUnmanaged(sm.StackFrame)) !void {

    // Find "stack" array
    const stack_key = std.mem.indexOf(u8, json_str, "\"stack\"") orelse return;
    const array_start = std.mem.indexOf(u8, json_str[stack_key..], "[") orelse return;
    const start = stack_key + array_start + 1;

    // Parse each object in the array
    var pos = start;
    while (pos < json_str.len) {
        // Find next {
        while (pos < json_str.len and json_str[pos] != '{' and json_str[pos] != ']') {
            pos += 1;
        }
        if (pos >= json_str.len or json_str[pos] == ']') break;

        // Find matching }
        const obj_start = pos;
        var brace_depth: i32 = 0;
        var in_string = false;
        var escape_next = false;

        while (pos < json_str.len) {
            const ch = json_str[pos];
            if (escape_next) {
                escape_next = false;
            } else if (ch == '\\') {
                escape_next = true;
            } else if (ch == '"') {
                in_string = !in_string;
            } else if (!in_string) {
                if (ch == '{') {
                    brace_depth += 1;
                } else if (ch == '}') {
                    brace_depth -= 1;
                    if (brace_depth == 0) {
                        pos += 1;
                        break;
                    }
                }
            }
            pos += 1;
        }

        const obj_str = json_str[obj_start..pos];

        // Parse frame fields
        const id = extractString(obj_str, "\"id\"") orelse "";
        const mode_str = extractString(obj_str, "\"mode\"") orelse "loop";
        const mode = sm.Mode.fromString(mode_str) orelse .loop;
        const iter = extractNumber(obj_str, "\"iter\"") orelse 0;
        const max = extractNumber(obj_str, "\"max\"") orelse 10;
        const prompt_file = extractString(obj_str, "\"prompt_file\"") orelse "";

        // Optional fields
        const issue_id = extractString(obj_str, "\"issue_id\"");
        const worktree_path = extractString(obj_str, "\"worktree_path\"");
        const branch = extractString(obj_str, "\"branch\"");
        const base_ref = extractString(obj_str, "\"base_ref\"");
        const filter = extractString(obj_str, "\"filter\"");

        try stack.append(allocator, .{
            .id = id,
            .mode = mode,
            .iter = @intCast(iter),
            .max = @intCast(max),
            .prompt_file = prompt_file,
            .issue_id = issue_id,
            .worktree_path = worktree_path,
            .branch = branch,
            .base_ref = base_ref,
            .filter = filter,
        });
    }
}

/// Extract a string value from JSON given a key
fn extractString(json_str: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, json_str, key) orelse return null;
    const after_key = json_str[key_pos + key.len ..];

    // Find colon
    const colon_pos = std.mem.indexOf(u8, after_key, ":") orelse return null;
    const after_colon = after_key[colon_pos + 1 ..];

    // Skip whitespace
    var start: usize = 0;
    while (start < after_colon.len and (after_colon[start] == ' ' or after_colon[start] == '\t' or after_colon[start] == '\n')) {
        start += 1;
    }

    if (start >= after_colon.len) return null;

    // Check for null
    if (after_colon.len >= start + 4 and std.mem.eql(u8, after_colon[start .. start + 4], "null")) {
        return null;
    }

    // Expect opening quote
    if (after_colon[start] != '"') return null;
    start += 1;

    // Find closing quote (handle escapes)
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

/// Extract a number value from JSON given a key
fn extractNumber(json_str: []const u8, key: []const u8) ?u32 {
    const key_pos = std.mem.indexOf(u8, json_str, key) orelse return null;
    const after_key = json_str[key_pos + key.len ..];

    // Find colon
    const colon_pos = std.mem.indexOf(u8, after_key, ":") orelse return null;
    const after_colon = after_key[colon_pos + 1 ..];

    // Skip whitespace
    var start: usize = 0;
    while (start < after_colon.len and (after_colon[start] == ' ' or after_colon[start] == '\t' or after_colon[start] == '\n')) {
        start += 1;
    }

    if (start >= after_colon.len) return null;

    // Find end of number
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

test "parseIso8601: basic timestamp" {
    const ts = parseIso8601("2024-12-21T10:30:00Z");
    try std.testing.expect(ts != null);
    // 2024-12-21 10:30:00 UTC
    // This is a rough sanity check - exact value depends on epoch calculation
    try std.testing.expect(ts.? > 1700000000); // After 2023
    try std.testing.expect(ts.? < 1800000000); // Before 2027
}

test "parseIso8601: epoch" {
    const ts = parseIso8601("1970-01-01T00:00:00Z");
    try std.testing.expectEqual(@as(i64, 0), ts.?);
}

test "parseIso8601: invalid format" {
    try std.testing.expect(parseIso8601("invalid") == null);
    try std.testing.expect(parseIso8601("2024-13-01T00:00:00Z") == null); // Invalid month
}

test "extractString: basic" {
    const json = "{\"name\":\"test\",\"value\":123}";
    const name = extractString(json, "\"name\"");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("test", name.?);
}

test "extractString: with spaces" {
    const json = "{\"name\": \"test value\"}";
    const name = extractString(json, "\"name\"");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("test value", name.?);
}

test "extractString: null value" {
    const json = "{\"name\":null}";
    const name = extractString(json, "\"name\"");
    try std.testing.expect(name == null);
}

test "extractNumber: basic" {
    const json = "{\"iter\":5,\"max\":10}";
    const iter = extractNumber(json, "\"iter\"");
    try std.testing.expectEqual(@as(u32, 5), iter.?);
}

test "parseEvent: simple loop state" {
    const json =
        \\{"schema":0,"event":"STATE","run_id":"loop-123","updated_at":"2024-12-21T10:00:00Z","stack":[{"id":"loop-123","mode":"loop","iter":3,"max":10,"prompt_file":"/tmp/p.txt"}]}
    ;

    var parsed = try parseEvent(std.testing.allocator, json);
    try std.testing.expect(parsed != null);
    defer parsed.?.deinit();

    const state = parsed.?.state;
    try std.testing.expectEqual(@as(u32, 0), state.schema);
    try std.testing.expectEqual(sm.EventType.STATE, state.event);
    try std.testing.expectEqualStrings("loop-123", state.run_id);
    try std.testing.expectEqual(@as(usize, 1), state.stack.len);

    const frame = state.stack[0];
    try std.testing.expectEqualStrings("loop-123", frame.id);
    try std.testing.expectEqual(sm.Mode.loop, frame.mode);
    try std.testing.expectEqual(@as(u32, 3), frame.iter);
    try std.testing.expectEqual(@as(u32, 10), frame.max);
}

test "parseEvent: DONE event" {
    const json =
        \\{"schema":0,"event":"DONE","reason":"COMPLETE","stack":[]}
    ;

    var parsed = try parseEvent(std.testing.allocator, json);
    try std.testing.expect(parsed != null);
    defer parsed.?.deinit();

    const state = parsed.?.state;
    try std.testing.expectEqual(sm.EventType.DONE, state.event);
    try std.testing.expectEqual(sm.CompletionReason.COMPLETE, state.reason.?);
    try std.testing.expectEqual(@as(usize, 0), state.stack.len);
}

test "parseEvent: ABORT event" {
    const json =
        \\{"schema":0,"event":"ABORT","stack":[]}
    ;

    var parsed = try parseEvent(std.testing.allocator, json);
    try std.testing.expect(parsed != null);
    defer parsed.?.deinit();

    const state = parsed.?.state;
    try std.testing.expectEqual(sm.EventType.ABORT, state.event);
}

test "parseEvent: nested grind/issue stack" {
    const json =
        \\{"schema":0,"event":"STATE","run_id":"grind-123","updated_at":"2024-12-21T10:00:00Z","stack":[{"id":"grind-123","mode":"grind","iter":2,"max":100,"prompt_file":"/tmp/g.txt","filter":"priority:1"},{"id":"issue-456","mode":"issue","iter":1,"max":10,"prompt_file":"/tmp/i.txt","issue_id":"auth-123","worktree_path":"/path/to/wt","branch":"idle/issue/auth-123"}]}
    ;

    var parsed = try parseEvent(std.testing.allocator, json);
    try std.testing.expect(parsed != null);
    defer parsed.?.deinit();

    const state = parsed.?.state;
    try std.testing.expectEqual(@as(usize, 2), state.stack.len);

    const grind_frame = state.stack[0];
    try std.testing.expectEqual(sm.Mode.grind, grind_frame.mode);
    try std.testing.expectEqualStrings("priority:1", grind_frame.filter.?);

    const issue_frame = state.stack[1];
    try std.testing.expectEqual(sm.Mode.issue, issue_frame.mode);
    try std.testing.expectEqualStrings("auth-123", issue_frame.issue_id.?);
    try std.testing.expectEqualStrings("/path/to/wt", issue_frame.worktree_path.?);
}

test "parseEvent: invalid json returns null" {
    const result = try parseEvent(std.testing.allocator, "not json");
    try std.testing.expect(result == null);
}

test "parseEvent: empty string returns null" {
    const result = try parseEvent(std.testing.allocator, "");
    try std.testing.expect(result == null);
}
