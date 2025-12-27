---
description: Start an iterative loop on a tissue issue
---

# Issue Loop Command

You are entering an iterative development loop for issue: **$ARGUMENTS**

## Setup

1. First, fetch the issue details:
   ```bash
   tissue show $ARGUMENTS
   ```

2. Claim the issue:
   ```bash
   tissue status $ARGUMENTS in_progress
   ```

3. Initialize the loop state:
   ```bash
   echo "$ARGUMENTS" > /tmp/trivial-loop-issue
   echo "0" > /tmp/trivial-loop-active
   ```

## Workflow

1. Work on the issue incrementally
2. Run `/test` after each significant change
3. Run `/fmt` before considering work complete

## Review Cycle (repeat until LGTM)

When you believe the issue is resolved:

1. Ensure tests pass: `/test`
2. Format code: `/fmt`
3. Commit: `git add . && git commit -m "fix/feat: <description>"`
4. Run review: `/review $ARGUMENTS`
5. If CHANGES_REQUESTED: address the feedback, then repeat from step 1
6. If LGTM: output `<loop-done>COMPLETE</loop-done>`

## Iteration Context

Look at your previous work:
- Check modified files: `git status`
- Review recent commits: `git log --oneline -10`
- Re-read the issue if needed: `tissue show $ARGUMENTS`

Keep iterating until the issue is resolved and review passes. Do not give up.
