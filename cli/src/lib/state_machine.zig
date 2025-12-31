const std = @import("std");

/// Loop execution states matching the documented state machine
pub const State = enum {
    /// No active loop - stack empty or no state exists
    idle,
    /// Loop is running - stack has frames, event is STATE, state is fresh
    active,
    /// Completion signal detected - popping frame from stack
    completing,
    /// Max iterations reached or state is stale (>2 hours)
    stuck,
    /// Corrupted state or explicit ABORT event
    aborted,
};

/// Event types from schema v0
pub const EventType = enum {
    STATE,
    DONE,
    ABORT,
    ANCHOR,

    pub fn fromString(s: []const u8) ?EventType {
        if (std.mem.eql(u8, s, "STATE")) return .STATE;
        if (std.mem.eql(u8, s, "DONE")) return .DONE;
        if (std.mem.eql(u8, s, "ABORT")) return .ABORT;
        if (std.mem.eql(u8, s, "ANCHOR")) return .ANCHOR;
        return null;
    }
};

/// Loop modes
pub const Mode = enum {
    loop,
    grind,
    issue,

    pub fn fromString(s: []const u8) ?Mode {
        if (std.mem.eql(u8, s, "loop")) return .loop;
        if (std.mem.eql(u8, s, "grind")) return .grind;
        if (std.mem.eql(u8, s, "issue")) return .issue;
        return null;
    }
};

/// Completion signal reasons
pub const CompletionReason = enum {
    COMPLETE,
    MAX_ITERATIONS,
    STUCK,
    NO_MORE_ISSUES,
    MAX_ISSUES,

    pub fn fromString(s: []const u8) ?CompletionReason {
        if (std.mem.eql(u8, s, "COMPLETE")) return .COMPLETE;
        if (std.mem.eql(u8, s, "MAX_ITERATIONS")) return .MAX_ITERATIONS;
        if (std.mem.eql(u8, s, "STUCK")) return .STUCK;
        if (std.mem.eql(u8, s, "NO_MORE_ISSUES")) return .NO_MORE_ISSUES;
        if (std.mem.eql(u8, s, "MAX_ISSUES")) return .MAX_ISSUES;
        return null;
    }
};

/// Stack frame representing a loop execution context
pub const StackFrame = struct {
    id: []const u8,
    mode: Mode,
    iter: u32,
    max: u32,
    prompt_file: []const u8,
    // issue mode fields
    issue_id: ?[]const u8 = null,
    worktree_path: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    base_ref: ?[]const u8 = null,
    // grind mode fields
    filter: ?[]const u8 = null,
    // review tracking - true if alice has reviewed this iteration's completion
    reviewed: bool = false,
};

/// Loop state parsed from jwz or state file
pub const LoopState = struct {
    schema: u32,
    event: EventType,
    run_id: []const u8,
    updated_at: ?i64, // Unix timestamp (parsed from ISO 8601)
    stack: []StackFrame,
    reason: ?CompletionReason = null,

    pub fn stackLen(self: *const LoopState) usize {
        return self.stack.len;
    }

    pub fn topFrame(self: *const LoopState) ?*const StackFrame {
        if (self.stack.len == 0) return null;
        return &self.stack[self.stack.len - 1];
    }
};

/// Decision output from the state machine
pub const Decision = enum {
    /// Allow Claude to exit (exit code 0)
    allow_exit,
    /// Block exit and inject continuation prompt (exit code 2)
    block_exit,
};

/// Result of state machine evaluation
pub const EvalResult = struct {
    state: State,
    decision: Decision,
    reason: ?[]const u8 = null,
    new_iteration: ?u32 = null,
    completion_reason: ?CompletionReason = null,
};

/// Staleness threshold in seconds (2 hours)
pub const STALENESS_TTL: i64 = 7200;

/// State machine evaluator
pub const StateMachine = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StateMachine {
        return .{ .allocator = allocator };
    }

    /// Evaluate the current state and determine the next action
    pub fn evaluate(
        self: *StateMachine,
        loop_state: ?*const LoopState,
        now_ts: i64,
        completion_signal: ?CompletionReason,
    ) EvalResult {
        _ = self;

        // No state exists -> IDLE
        if (loop_state == null) {
            return .{
                .state = .idle,
                .decision = .allow_exit,
            };
        }

        const state = loop_state.?;

        // Empty stack -> IDLE
        if (state.stack.len == 0) {
            return .{
                .state = .idle,
                .decision = .allow_exit,
            };
        }

        // Explicit ABORT event -> ABORTED
        if (state.event == .ABORT) {
            return .{
                .state = .aborted,
                .decision = .allow_exit,
            };
        }

        // Get top frame
        const frame = state.topFrame() orelse {
            return .{
                .state = .idle,
                .decision = .allow_exit,
            };
        };

        // Check staleness (>2 hours)
        if (state.updated_at) |updated_at| {
            const age = now_ts - updated_at;
            if (age > STALENESS_TTL) {
                return .{
                    .state = .stuck,
                    .decision = .allow_exit,
                    .reason = "State is stale",
                };
            }
        }

        // Check max iterations
        if (frame.iter >= frame.max) {
            return .{
                .state = .stuck,
                .decision = .allow_exit,
                .completion_reason = .MAX_ITERATIONS,
            };
        }

        // Check for completion signal
        if (completion_signal) |signal| {
            return .{
                .state = .completing,
                .decision = .allow_exit,
                .completion_reason = signal,
            };
        }

        // No completion signal -> ACTIVE, continue iterating
        const new_iter = frame.iter + 1;
        return .{
            .state = .active,
            .decision = .block_exit,
            .new_iteration = new_iter,
        };
    }

    /// Check transcript text for completion signals based on mode
    /// Returns the signal reason if found, null otherwise
    pub fn detectCompletionSignal(mode: Mode, text: []const u8) ?CompletionReason {
        // Only match signals at start of line (not indented in code blocks)
        // This is a simple heuristic - the bash version uses grep with ^

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimLeft(u8, line, " \t");

            // Skip if indented (likely in code block)
            if (trimmed.len != line.len) continue;

            switch (mode) {
                .loop => {
                    if (std.mem.eql(u8, trimmed, "<loop-done>COMPLETE</loop-done>")) return .COMPLETE;
                    if (std.mem.eql(u8, trimmed, "<loop-done>MAX_ITERATIONS</loop-done>")) return .MAX_ITERATIONS;
                    if (std.mem.eql(u8, trimmed, "<loop-done>STUCK</loop-done>")) return .STUCK;
                },
                .issue => {
                    if (std.mem.eql(u8, trimmed, "<loop-done>COMPLETE</loop-done>")) return .COMPLETE;
                    if (std.mem.eql(u8, trimmed, "<loop-done>MAX_ITERATIONS</loop-done>")) return .MAX_ITERATIONS;
                    if (std.mem.eql(u8, trimmed, "<loop-done>STUCK</loop-done>")) return .STUCK;
                    if (std.mem.eql(u8, trimmed, "<issue-complete>DONE</issue-complete>")) return .COMPLETE;
                },
                .grind => {
                    if (std.mem.eql(u8, trimmed, "<grind-done>NO_MORE_ISSUES</grind-done>")) return .NO_MORE_ISSUES;
                    if (std.mem.eql(u8, trimmed, "<grind-done>MAX_ISSUES</grind-done>")) return .MAX_ISSUES;
                },
            }
        }

        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "State: idle when no state" {
    var sm = StateMachine.init(std.testing.allocator);
    const result = sm.evaluate(null, 0, null);
    try std.testing.expectEqual(State.idle, result.state);
    try std.testing.expectEqual(Decision.allow_exit, result.decision);
}

test "State: idle when stack empty" {
    var sm = StateMachine.init(std.testing.allocator);
    var state = LoopState{
        .schema = 0,
        .event = .STATE,
        .run_id = "test-123",
        .updated_at = 1000,
        .stack = &[_]StackFrame{},
    };
    const result = sm.evaluate(&state, 1000, null);
    try std.testing.expectEqual(State.idle, result.state);
    try std.testing.expectEqual(Decision.allow_exit, result.decision);
}

test "State: aborted on ABORT event" {
    var sm = StateMachine.init(std.testing.allocator);
    var frames = [_]StackFrame{
        .{ .id = "test", .mode = .loop, .iter = 1, .max = 10, .prompt_file = "/tmp/p.txt" },
    };
    var state = LoopState{
        .schema = 0,
        .event = .ABORT,
        .run_id = "test-123",
        .updated_at = 1000,
        .stack = &frames,
    };
    const result = sm.evaluate(&state, 1000, null);
    try std.testing.expectEqual(State.aborted, result.state);
    try std.testing.expectEqual(Decision.allow_exit, result.decision);
}

test "State: stuck when stale (>2 hours)" {
    var sm = StateMachine.init(std.testing.allocator);
    var frames = [_]StackFrame{
        .{ .id = "test", .mode = .loop, .iter = 1, .max = 10, .prompt_file = "/tmp/p.txt" },
    };
    var state = LoopState{
        .schema = 0,
        .event = .STATE,
        .run_id = "test-123",
        .updated_at = 0,
        .stack = &frames,
    };
    // Now is 3 hours later
    const result = sm.evaluate(&state, 3 * 3600, null);
    try std.testing.expectEqual(State.stuck, result.state);
    try std.testing.expectEqual(Decision.allow_exit, result.decision);
}

test "State: stuck when max iterations reached" {
    var sm = StateMachine.init(std.testing.allocator);
    var frames = [_]StackFrame{
        .{ .id = "test", .mode = .loop, .iter = 10, .max = 10, .prompt_file = "/tmp/p.txt" },
    };
    var state = LoopState{
        .schema = 0,
        .event = .STATE,
        .run_id = "test-123",
        .updated_at = 1000,
        .stack = &frames,
    };
    const result = sm.evaluate(&state, 1000, null);
    try std.testing.expectEqual(State.stuck, result.state);
    try std.testing.expectEqual(Decision.allow_exit, result.decision);
    try std.testing.expectEqual(CompletionReason.MAX_ITERATIONS, result.completion_reason.?);
}

test "State: completing when signal detected" {
    var sm = StateMachine.init(std.testing.allocator);
    var frames = [_]StackFrame{
        .{ .id = "test", .mode = .loop, .iter = 3, .max = 10, .prompt_file = "/tmp/p.txt" },
    };
    var state = LoopState{
        .schema = 0,
        .event = .STATE,
        .run_id = "test-123",
        .updated_at = 1000,
        .stack = &frames,
    };
    const result = sm.evaluate(&state, 1000, .COMPLETE);
    try std.testing.expectEqual(State.completing, result.state);
    try std.testing.expectEqual(Decision.allow_exit, result.decision);
    try std.testing.expectEqual(CompletionReason.COMPLETE, result.completion_reason.?);
}

test "State: active when no signal, increments iteration" {
    var sm = StateMachine.init(std.testing.allocator);
    var frames = [_]StackFrame{
        .{ .id = "test", .mode = .loop, .iter = 3, .max = 10, .prompt_file = "/tmp/p.txt" },
    };
    var state = LoopState{
        .schema = 0,
        .event = .STATE,
        .run_id = "test-123",
        .updated_at = 1000,
        .stack = &frames,
    };
    const result = sm.evaluate(&state, 1000, null);
    try std.testing.expectEqual(State.active, result.state);
    try std.testing.expectEqual(Decision.block_exit, result.decision);
    try std.testing.expectEqual(@as(u32, 4), result.new_iteration.?);
}

test "Signal detection: loop mode COMPLETE" {
    const signal = StateMachine.detectCompletionSignal(.loop, "some output\n<loop-done>COMPLETE</loop-done>\nmore text");
    try std.testing.expectEqual(CompletionReason.COMPLETE, signal.?);
}

test "Signal detection: loop mode MAX_ITERATIONS" {
    const signal = StateMachine.detectCompletionSignal(.loop, "<loop-done>MAX_ITERATIONS</loop-done>");
    try std.testing.expectEqual(CompletionReason.MAX_ITERATIONS, signal.?);
}

test "Signal detection: loop mode STUCK" {
    const signal = StateMachine.detectCompletionSignal(.loop, "<loop-done>STUCK</loop-done>");
    try std.testing.expectEqual(CompletionReason.STUCK, signal.?);
}

test "Signal detection: issue mode with issue-complete" {
    const signal = StateMachine.detectCompletionSignal(.issue, "<issue-complete>DONE</issue-complete>");
    try std.testing.expectEqual(CompletionReason.COMPLETE, signal.?);
}

test "Signal detection: grind mode NO_MORE_ISSUES" {
    const signal = StateMachine.detectCompletionSignal(.grind, "<grind-done>NO_MORE_ISSUES</grind-done>");
    try std.testing.expectEqual(CompletionReason.NO_MORE_ISSUES, signal.?);
}

test "Signal detection: grind mode MAX_ISSUES" {
    const signal = StateMachine.detectCompletionSignal(.grind, "<grind-done>MAX_ISSUES</grind-done>");
    try std.testing.expectEqual(CompletionReason.MAX_ISSUES, signal.?);
}

test "Signal detection: ignores indented signals (code blocks)" {
    const signal = StateMachine.detectCompletionSignal(.loop, "  <loop-done>COMPLETE</loop-done>");
    try std.testing.expect(signal == null);
}

test "Signal detection: no signal in text" {
    const signal = StateMachine.detectCompletionSignal(.loop, "just some regular output\nnothing here");
    try std.testing.expect(signal == null);
}
