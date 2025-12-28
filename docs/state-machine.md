# Stop-Hook State Machine

## Overview

The `stop-hook.sh` script implements a state machine that controls loop iteration in the idle plugin. It intercepts Claude's exit attempts and decides whether to allow termination or force continuation. This document serves as the authoritative reference for the Zig reimplementation, detailing states, transitions, safety invariants, and edge cases.

The hook reads state from the `jwz` topic `loop:current` (with fallback to `.claude/idle-loop.local.md`), analyzes the recent transcript for completion signals, and outputs a decision.

## State Diagram

```
                    +───────────+
         +──────────│   IDLE    │◄─────────────+
         │          +───────────+              │
         │ loop start                          │ stack empty
         │ (stack not empty)                   │ after pop
         ▼                                     │
    +───────────+                         +────┴──────+
    │  ACTIVE   │────completion signal───►│COMPLETING │
    +───────────+                         +───────────+
         │  │                                  │
         │  │                                  │ stack not empty
         │  │ no signal                        │ (outer loop)
         │  │ iter++                           │
         │  │                                  │
         │  │ max iter OR                      │
         │  │ staleness (>2h)                  │
         │  └──────────────────────────►+───────────+
         │                              │   STUCK   │
         │ corruption OR abort event    +───────────+
         ▼
    +───────────+
    │  ABORTED  │
    +───────────+
```

## States

### IDLE

- **Entry**: No active loop. Stack is empty or no state exists in jwz.
- **Behavior**: Hook exits immediately with no action.
- **Exit Code**: 0 (allow exit)

### ACTIVE

- **Entry**: Loop is running. Stack has frames, event is `STATE`, state is fresh (<2 hours old).
- **Behavior**:
  1. Reads last 20 lines of transcript (`tail -20`)
  2. Checks for mode-specific completion signals:
     - `loop` mode: `<loop-done>COMPLETE|MAX_ITERATIONS|STUCK</loop-done>`
     - `issue` mode: Same as loop, plus `<issue-complete>DONE</issue-complete>`
     - `grind` mode: `<grind-done>NO_MORE_ISSUES|MAX_ISSUES</grind-done>`
  3. If no signal found: increments iteration, posts updated state to jwz
- **Exit Code**: 2 (block exit, inject continuation prompt)

### COMPLETING

- **Entry**: Completion signal detected in last assistant message.
- **Behavior**: Pops the top frame from the stack. Posts updated state to jwz.
  - If stack becomes empty: posts `DONE` event
  - If stack still has frames: posts `STATE` event (outer loop resumes on next invocation)
- **Exit Code**: 0 (allow exit)

### STUCK

- **Entry**: Either max iterations reached (`iter >= max`) OR state is stale (`updated_at > 2 hours ago`).
- **Behavior**: Posts `DONE` event with reason (`MAX_ITERATIONS` or logs warning for staleness).
- **Exit Code**: 0 (allow exit, human intervention needed)

### ABORTED

- **Entry**: Either explicit `ABORT` event in state OR corrupted state (non-numeric iteration values).
- **Behavior**: Posts `ABORT` event to jwz (or removes state file). Cleans up and allows exit.
- **Exit Code**: 0 (allow exit, cleanup performed)

## Transition Table

| From | To | Trigger | Condition |
|------|-----|---------|-----------|
| IDLE | ACTIVE | loop start | stack not empty |
| ACTIVE | ACTIVE | iteration | no completion signal |
| ACTIVE | COMPLETING | completion | signal found in transcript |
| ACTIVE | STUCK | max_iter | iteration >= max |
| ACTIVE | STUCK | staleness | age > 7200s |
| ACTIVE | ABORTED | corruption | invalid state |
| COMPLETING | IDLE | pop frame | stack empty after pop |
| COMPLETING | ACTIVE | pop frame | outer loop continues |

## Safety Invariants

1. **Never continue if state is stale (>2 hours)**: Prevents zombie loops from resuming after crashes or forgotten sessions.

2. **Never continue with corrupted/invalid iteration counts**: Non-numeric iteration values trigger immediate abort to prevent undefined behavior.

3. **Block exit (return 2) only when actively iterating**: All error conditions, completions, and edge cases default to exit 0 (fail open) to avoid trapping users.

4. **Completion signals must appear on their own line**: The hook uses `grep -qF` to match signals. **KNOWN LIMITATION**: Signals inside code fences are not filtered out.

## Edge Cases

### Code Block False Positive (KNOWN LIMITATION)

If Claude explains the completion signal by showing it in a code block:
```
Here's how to signal completion:
`<loop-done>COMPLETE</loop-done>`
```

The grep-based check will match this and trigger premature completion. The Zig implementation should parse markdown and ignore signals inside fenced code blocks.

### Concurrent Session Races

Multiple Claude sessions in the same project directory share the jwz state. State updates use a last-writer-wins strategy. If two sessions read state simultaneously, increment locally, and write back, one iteration count is lost.

### Long Transcripts (tail -20 limit)

The hook only scans the last 20 lines of the transcript JSONL file. If Claude produces very long output before the completion signal, the signal may be scrolled off and missed. The loop will continue until max iterations.

### Malformed JSON in State

If jwz returns invalid JSON or the state file is corrupted, jq parsing fails. The hook catches this and exits 0 (fail open) to avoid trapping the user in an infinite loop.

### Stale State After Crash

If the agent process crashes without clearing state, the staleness check (2 hour TTL) ensures it transitions to STUCK on the next invocation rather than resuming incorrectly.

## Exit Code Semantics

| Code | Meaning |
|------|---------|
| 0 | Allow exit (task done, stale, corrupt, abort, completing) |
| 2 | Block exit (continue iterating) |

When blocking (exit 2), the hook outputs JSON to stdout:

```json
{
  "decision": "block",
  "reason": "[ITERATION N/MAX] Continue working on the task. Check your progress and either complete the task or keep iterating."
}
```

The `reason` field is injected back to Claude as the continuation prompt.

## Zig Reimplementation Notes

### 1. JSON Parsing

Use Zig `std.json`. Must handle:
- Missing fields (use safe defaults)
- Null values
- Malformed JSON (catch error, return ABORTED state)

The `schema` field presence indicates valid state.

### 2. Date Parsing for Staleness Check

The `updated_at` field is ISO 8601 format: `2024-12-21T10:30:00Z`

Calculate `age = now - updated_at`. If `age > 7200` seconds, state is stale. Handle both `Z` suffix and `+00:00` offset formats.

### 3. Signal Detection (Fix Code Block Limitation)

Replace naive grep with:
1. Parse transcript JSONL
2. Extract text from assistant messages
3. Tokenize markdown content
4. Only match completion signals outside code fences (` ``` `)

### 4. Atomic State Updates

The bash version has a race window between reading jwz and writing back the incremented state. Use file locking (`flock`) or jwz atomic operations if available.

### 5. Output Format

Exit 2 must write exactly this JSON to stdout:
```json
{"decision": "block", "reason": "[ITERATION N/MAX] Continue working on the task. Check your progress and either complete the task or keep iterating."}
```

### 6. Environment Variable Escape Hatch

Check `IDLE_LOOP_DISABLE=1` before any processing. If set, immediately exit 0.

---

## Verification

- [x] Checked against source: `/hooks/stop-hook.sh`
- [x] Examples match actual API
- [x] Writer drafts reviewed and corrected
- [x] Edge cases from tests documented
