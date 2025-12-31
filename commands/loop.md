---
description: Iterate on a task until complete
---

# /loop

Iterate on a task until it's complete.

## Usage

```
/loop <task description>
```

Before starting, run `idle init-loop` to initialize the infrastructure (`.zawinski/`, `.tissue/`, loop state).

## Example

```sh
/loop Add input validation to API endpoints
```

Iterates on the task until complete.

- **Max iterations**: 10
- **Checkpoint reviews**: Every 3 iterations (alice)
- **Completion review**: On COMPLETE/STUCK signals (alice)

## Completion Signals

Signal completion status in your response:

| Signal | Meaning |
|--------|---------|
| `<loop-done>COMPLETE</loop-done>` | **Original task** finished successfully |
| `<loop-done>STUCK</loop-done>` | Cannot make progress |
| `<loop-done>MAX_ITERATIONS</loop-done>` | Hit iteration limit |

**IMPORTANT**: `COMPLETE` means the ENTIRE `/loop <task>` is done, not just "I finished this iteration's work". If there's more to do on the original task, keep iterating—don't signal COMPLETE.

Wrong:
- Closed 3 issues, 5 remain → signal COMPLETE ❌

Right:
- Closed 3 issues, 5 remain → keep working
- All work for original task done → signal COMPLETE ✓

## Alice Review

When you signal `COMPLETE` or `STUCK`, the Stop hook:
1. Blocks exit
2. Requests alice review
3. Alice analyzes your work using domain-specific checklists
4. Creates tissue issues for problems (tagged `alice-review`)
5. If approved (no issues) → exit. If not → continue.

This ensures quality before completion.

## Checkpoint Reviews

Every 3 iterations, alice performs a checkpoint review to:
- Check progress against the original task
- Identify issues early
- Provide guidance for next steps

## Escape Hatches

```sh
/cancel                  # Graceful cancellation
touch .idle-disabled     # Bypass hooks
rm -rf .zawinski/        # Reset all jwz state
```
