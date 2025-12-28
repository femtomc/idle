# ADR 001: jwz Optionality and Crash Recovery

## Status

Accepted

## Context

The idle plugin provides loop commands (`/loop`, `/issue`, `/grind`) that use a stop-hook to intercept Claude's exit and force re-entry until the task is complete. These loops require persistent state to track the loop stack, iteration counts, and completion signals across session restarts or crashes.

Current documentation (`architecture.md`, line 209) claims:

> Fallback: If jwz unavailable, falls back to `.claude/idle-loop.local.md` state file.

However, analysis reveals this fallback is dead code:

1. **`stop-hook.sh`** contains extensive fallback logic to read and update `.claude/idle-loop.local.md` (lines 77-100, 105-111, 116-121, 193-196, 210-215, 220-222).
2. **No command creates this file.** The `/loop` command only initializes state via `jwz post "loop:current"`. There is no code path that writes the state file.
3. **`pre-compact-hook.sh`** silently exits if jwz is unavailable (lines 17-19), providing no fallback for crash recovery anchors.
4. **`cancel-loop.md`** also references the non-functional state file fallback.

The result: users without jwz installed experience silent failures where loop commands exit immediately or fail to persist state between iterations. The documented "degraded experience" does not exist.

## Decision

We will make **jwz a required dependency** for all idle loop commands. The optional fallback to local state files will be officially removed from the codebase and documentation.

Rationale:
- The fallback code is untested dead code that has never worked
- Dual-write complexity is not justified when one path is non-functional
- A single source of truth simplifies debugging and maintenance
- Explicit failure is better than silent misbehavior

## Consequences

### Positive

**Reliability.** Users receive immediate, actionable errors if jwz is missing, rather than experiencing mysterious loop failures.

**Simplicity.** Loop state resides exclusively in jwz topics (`loop:current`, `loop:anchor`). No dual-write synchronization, no YAML parsing, no file-based edge cases.

**Documentation accuracy.** The architecture documentation will reflect actual system behavior.

### Negative

**Hard dependency.** Users must install jwz to use loop features. There is no lightweight, file-only alternative.

**Future consideration.** A simpler built-in fallback could be explored if user demand warrants it, but this is out of scope for this decision.

## Crash Recovery

With jwz as the single state store, crash recovery works as follows:

### Session Crash

The `.jwz/` directory persists on disk. When a new Claude session starts, the stop-hook reads `loop:current` and finds the active loop stack. The session resumes from the last recorded iteration.

### Machine Restart

Same as session crash. Because jwz uses file-based storage, loop state survives operating system restarts.

### Hook Failure

If the stop-hook encounters an unrecoverable error, it posts an `ABORT` event to jwz:
```json
{"schema":1,"event":"ABORT","reason":"ERROR","stack":[]}
```

Users can escape a stuck loop via the environment variable: `IDLE_LOOP_DISABLE=1 claude`

### Context Compaction

Before Claude compacts its context window, `pre-compact-hook.sh` saves a recovery anchor to the `loop:anchor` topic containing:
- Current goal/task description
- Loop mode and iteration progress
- Recent git commits and modified files

After compaction, Claude can read this anchor to regain context.

### Staleness Protection

Loop states include an `updated_at` timestamp. States older than 2 hours are considered stale and ignored, preventing zombie loops from blocking future sessions.

## Implementation Notes

### 1. Code Removal

Remove all `STATE_FILE` and `USE_JWZ` code paths from `hooks/stop-hook.sh`:
- Line 25: `STATE_FILE` definition
- Lines 77-100: Fallback parsing block (sets `USE_JWZ=false`)
- Lines 106-109, 116-119: Fallback cleanup on error/max iterations
- Lines 179-195: Fallback cleanup on completion signal
- Lines 206-214: Fallback state update (iteration increment)
- Lines 220-222: Fallback prompt reading

Remove fallback section from `commands/loop/cancel-loop.md` (lines 40-48).

### 2. Documentation Updates

Update `docs/architecture.md`:
- Remove line 209's fallback claim
- Update Dependencies section to mark jwz as required for loop functionality

### 3. New Dependency Check

Add explicit check at the start of `hooks/stop-hook.sh`:
```bash
if ! command -v jwz >/dev/null 2>&1; then
    echo "Error: 'jwz' is required for loop commands but not found." >&2
    echo "Install: https://github.com/femtomc/zawinski" >&2
    exit 1
fi
```

Preserve the `IDLE_LOOP_DISABLE=1` escape hatch (line 20-22) for emergency loop exit.
