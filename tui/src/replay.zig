const std = @import("std");
const sm = @import("state_machine.zig");
const ep = @import("event_parser.zig");

/// A trace event captured from the stop-hook
pub const TraceEvent = struct {
    event_id: []const u8,
    ts: []const u8,
    run_id: []const u8,
    loop_kind: []const u8,
    event: []const u8,
    iteration: u32,
    max: u32,
    details: []const u8,
};

/// Parse a trace event from JSON
pub fn parseTraceEvent(json: []const u8) ?TraceEvent {
    const event_id = extractString(json, "\"event_id\"") orelse return null;
    const ts = extractString(json, "\"ts\"") orelse "";
    const run_id = extractString(json, "\"run_id\"") orelse "";
    const loop_kind = extractString(json, "\"loop_kind\"") orelse "";
    const event = extractString(json, "\"event\"") orelse return null;
    const iteration = extractNumber(json, "\"iteration\"") orelse 0;
    const max = extractNumber(json, "\"max\"") orelse 0;

    // Extract details object as raw string
    const details_start = std.mem.indexOf(u8, json, "\"details\"") orelse return TraceEvent{
        .event_id = event_id,
        .ts = ts,
        .run_id = run_id,
        .loop_kind = loop_kind,
        .event = event,
        .iteration = iteration,
        .max = max,
        .details = "{}",
    };

    const colon = std.mem.indexOf(u8, json[details_start..], ":") orelse return null;
    const obj_start = details_start + colon + 1;

    // Skip whitespace
    var start = obj_start;
    while (start < json.len and (json[start] == ' ' or json[start] == '\t')) {
        start += 1;
    }

    // Find matching brace
    if (start >= json.len or json[start] != '{') {
        return TraceEvent{
            .event_id = event_id,
            .ts = ts,
            .run_id = run_id,
            .loop_kind = loop_kind,
            .event = event,
            .iteration = iteration,
            .max = max,
            .details = "{}",
        };
    }

    var depth: i32 = 0;
    var end = start;
    while (end < json.len) {
        if (json[end] == '{') depth += 1;
        if (json[end] == '}') {
            depth -= 1;
            if (depth == 0) {
                end += 1;
                break;
            }
        }
        end += 1;
    }

    return TraceEvent{
        .event_id = event_id,
        .ts = ts,
        .run_id = run_id,
        .loop_kind = loop_kind,
        .event = event,
        .iteration = iteration,
        .max = max,
        .details = json[start..end],
    };
}

/// Replay a sequence of trace events through the state machine
/// Returns true if all transitions match expected behavior
pub fn replayTrace(allocator: std.mem.Allocator, trace_events: []const []const u8) !ReplayResult {
    var machine = sm.StateMachine.init(allocator);
    var result = ReplayResult{
        .events_processed = 0,
        .transitions = std.ArrayListUnmanaged(Transition){},
        .errors = std.ArrayListUnmanaged([]const u8){},
    };

    var current_state: ?sm.LoopState = null;

    for (trace_events) |event_json| {
        const trace = parseTraceEvent(event_json) orelse {
            try result.errors.append(allocator, "Failed to parse trace event");
            continue;
        };

        result.events_processed += 1;

        // Simulate state based on trace event
        const simulated_state = simulateState(trace);

        // Determine completion signal from event type
        const completion_signal: ?sm.CompletionReason = blk: {
            if (std.mem.eql(u8, trace.event, "COMPLETION")) {
                // Extract reason from details
                const reason_str = extractString(trace.details, "\"reason\"");
                if (reason_str) |r| {
                    break :blk sm.CompletionReason.fromString(r);
                }
            }
            break :blk null;
        };

        // Evaluate with simulated state
        const eval_result = machine.evaluate(&simulated_state, 1000, completion_signal);

        // Record transition
        try result.transitions.append(allocator, .{
            .from_event = trace.event,
            .to_state = eval_result.state,
            .decision = eval_result.decision,
            .iteration = trace.iteration,
        });

        current_state = simulated_state;
    }

    return result;
}

/// Result of replaying a trace
pub const ReplayResult = struct {
    events_processed: u32,
    transitions: std.ArrayListUnmanaged(Transition),
    errors: std.ArrayListUnmanaged([]const u8),

    pub fn deinit(self: *ReplayResult, allocator: std.mem.Allocator) void {
        self.transitions.deinit(allocator);
        self.errors.deinit(allocator);
    }
};

/// A single state transition
pub const Transition = struct {
    from_event: []const u8,
    to_state: sm.State,
    decision: sm.Decision,
    iteration: u32,
};

/// Simulate a LoopState from a trace event
fn simulateState(trace: TraceEvent) sm.LoopState {
    // Create a static frame for the simulation
    const frame = sm.StackFrame{
        .id = trace.run_id,
        .mode = sm.Mode.fromString(trace.loop_kind) orelse .loop,
        .iter = trace.iteration,
        .max = trace.max,
        .prompt_file = "",
    };

    // Use a static array for the stack
    const static_frames = struct {
        var frames: [1]sm.StackFrame = undefined;
    };
    static_frames.frames[0] = frame;

    return sm.LoopState{
        .schema = 0,
        .event = .STATE,
        .run_id = trace.run_id,
        .updated_at = 1000, // Fresh state
        .stack = &static_frames.frames,
    };
}

/// Extract string from JSON
fn extractString(json: []const u8, key: []const u8) ?[]const u8 {
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
    while (end < after_colon.len and after_colon[end] != '"') {
        end += 1;
    }

    return after_colon[start..end];
}

/// Extract number from JSON
fn extractNumber(json: []const u8, key: []const u8) ?u32 {
    const key_pos = std.mem.indexOf(u8, json, key) orelse return null;
    const after_key = json[key_pos + key.len ..];

    const colon_pos = std.mem.indexOf(u8, after_key, ":") orelse return null;
    const after_colon = after_key[colon_pos + 1 ..];

    var start: usize = 0;
    while (start < after_colon.len and (after_colon[start] == ' ' or after_colon[start] == '\t')) {
        start += 1;
    }

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

test "parseTraceEvent: basic" {
    const json =
        \\{"event_id":"loop-123-LOOP_START-0","ts":"2024-12-28T00:00:00Z","run_id":"loop-123","loop_kind":"loop","event":"LOOP_START","iteration":0,"max":10,"details":{}}
    ;
    const event = parseTraceEvent(json);
    try std.testing.expect(event != null);
    try std.testing.expectEqualStrings("loop-123-LOOP_START-0", event.?.event_id);
    try std.testing.expectEqualStrings("LOOP_START", event.?.event);
    try std.testing.expectEqual(@as(u32, 0), event.?.iteration);
    try std.testing.expectEqual(@as(u32, 10), event.?.max);
}

test "parseTraceEvent: with completion reason" {
    const json =
        \\{"event_id":"loop-123-COMPLETION-5","ts":"2024-12-28T00:00:00Z","run_id":"loop-123","loop_kind":"loop","event":"COMPLETION","iteration":5,"max":10,"details":{"reason":"COMPLETE"}}
    ;
    const event = parseTraceEvent(json);
    try std.testing.expect(event != null);
    try std.testing.expectEqualStrings("COMPLETION", event.?.event);
    try std.testing.expectEqualStrings("{\"reason\":\"COMPLETE\"}", event.?.details);
}

test "replayTrace: simple loop with early completion" {
    // Completion signal detected before max iterations
    const trace = [_][]const u8{
        \\{"event_id":"loop-1-LOOP_START-0","ts":"2024-12-28T00:00:00Z","run_id":"loop-1","loop_kind":"loop","event":"LOOP_START","iteration":0,"max":10,"details":{}}
        ,
        \\{"event_id":"loop-1-ITERATION-1","ts":"2024-12-28T00:00:01Z","run_id":"loop-1","loop_kind":"loop","event":"ITERATION","iteration":1,"max":10,"details":{}}
        ,
        \\{"event_id":"loop-1-ITERATION-2","ts":"2024-12-28T00:00:02Z","run_id":"loop-1","loop_kind":"loop","event":"ITERATION","iteration":2,"max":10,"details":{}}
        ,
        \\{"event_id":"loop-1-COMPLETION-3","ts":"2024-12-28T00:00:03Z","run_id":"loop-1","loop_kind":"loop","event":"COMPLETION","iteration":3,"max":10,"details":{"reason":"COMPLETE"}}
        ,
    };

    var result = try replayTrace(std.testing.allocator, &trace);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 4), result.events_processed);
    try std.testing.expectEqual(@as(usize, 4), result.transitions.items.len);

    // First event: LOOP_START at iter 0 -> should continue (block exit)
    try std.testing.expectEqual(sm.Decision.block_exit, result.transitions.items[0].decision);

    // Middle events: ITERATION -> should continue
    try std.testing.expectEqual(sm.Decision.block_exit, result.transitions.items[1].decision);
    try std.testing.expectEqual(sm.Decision.block_exit, result.transitions.items[2].decision);

    // Last event: COMPLETION -> should allow exit with completing state
    try std.testing.expectEqual(sm.Decision.allow_exit, result.transitions.items[3].decision);
    try std.testing.expectEqual(sm.State.completing, result.transitions.items[3].to_state);
}

test "replayTrace: max iterations" {
    const trace = [_][]const u8{
        \\{"event_id":"loop-1-LOOP_START-0","ts":"2024-12-28T00:00:00Z","run_id":"loop-1","loop_kind":"loop","event":"LOOP_START","iteration":0,"max":2,"details":{}}
        ,
        \\{"event_id":"loop-1-ITERATION-1","ts":"2024-12-28T00:00:01Z","run_id":"loop-1","loop_kind":"loop","event":"ITERATION","iteration":1,"max":2,"details":{}}
        ,
        \\{"event_id":"loop-1-MAX_ITERATIONS-2","ts":"2024-12-28T00:00:02Z","run_id":"loop-1","loop_kind":"loop","event":"MAX_ITERATIONS","iteration":2,"max":2,"details":{}}
        ,
    };

    var result = try replayTrace(std.testing.allocator, &trace);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 3), result.events_processed);

    // Last event at max iterations -> should be stuck state
    try std.testing.expectEqual(sm.State.stuck, result.transitions.items[2].to_state);
    try std.testing.expectEqual(sm.Decision.allow_exit, result.transitions.items[2].decision);
}
