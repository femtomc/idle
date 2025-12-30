// idle hook library
//
// Core logic for idle's hook implementations.
// Provides state machine, event parsing, and hook utilities.

pub const state_machine = @import("state_machine.zig");
pub const event_parser = @import("event_parser.zig");
pub const transcript = @import("transcript.zig");
pub const safety = @import("safety.zig");

// CLI commands
pub const spawn = @import("spawn.zig");
pub const emit = @import("emit.zig");
pub const doctor = @import("doctor.zig");
pub const worktree = @import("worktree.zig");

// Re-export common types
pub const State = state_machine.State;
pub const Mode = state_machine.Mode;
pub const EventType = state_machine.EventType;
pub const CompletionReason = state_machine.CompletionReason;
pub const StackFrame = state_machine.StackFrame;
pub const LoopState = state_machine.LoopState;
pub const Decision = state_machine.Decision;
pub const EvalResult = state_machine.EvalResult;
pub const StateMachine = state_machine.StateMachine;

pub const ParsedEvent = event_parser.ParsedEvent;
pub const parseEvent = event_parser.parseEvent;
pub const parseIso8601 = event_parser.parseIso8601;

test {
    @import("std").testing.refAllDecls(@This());
}
