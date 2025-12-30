---
description: Cancel the active loop
---

# Cancel Command

Stop the current iteration loop gracefully.

## Steps

1. **Check for active loop via jwz**:
   ```bash
   if command -v jwz >/dev/null 2>&1 && [ -d .jwz ]; then
       STATE=$(jwz read "loop:current" 2>/dev/null | tail -1 || true)
       if [ -n "$STATE" ] && echo "$STATE" | jq -e '.stack | length > 0' >/dev/null 2>&1; then
           # Get current loop info
           MODE=$(echo "$STATE" | jq -r '.stack[-1].mode')
           ITER=$(echo "$STATE" | jq -r '.stack[-1].iter')
           ISSUE_ID=$(echo "$STATE" | jq -r '.stack[-1].issue_id // empty')

           echo "Cancelling $MODE loop at iteration $ITER"

           # Pause issue if applicable
           if [ -n "$ISSUE_ID" ]; then
               tissue status "$ISSUE_ID" paused 2>/dev/null || true
               tissue comment "$ISSUE_ID" -m "[cancel] Loop cancelled by user at iteration $ITER" 2>/dev/null || true
           fi

           # Post abort event
           jwz post "loop:current" -m '{"schema":1,"event":"ABORT","reason":"USER_CANCELLED","stack":[]}'
           jwz post "project:$(basename $PWD)" -m "[loop] CANCELLED: User aborted at iteration $ITER"

           echo "Loop cancelled successfully"
       else
           echo "No active loop found in jwz"
       fi
   fi
   ```

2. **Fallback: Check state file**:
   ```bash
   STATE_FILE=".claude/idle-loop.local.md"
   if [ -f "$STATE_FILE" ]; then
       ITER=$(grep '^iteration:' "$STATE_FILE" | sed 's/iteration: *//')
       echo "Cancelling loop at iteration $ITER (state file)"
       rm -f "$STATE_FILE"
       echo "Loop cancelled successfully"
   fi
   ```

3. **Summarize** what was accomplished before cancellation

## Alternative Escape Methods

If `/cancel` doesn't work:

1. **Disable file**: Create a disable marker to bypass loop on next session:
   ```bash
   touch .idle-disabled
   claude
   # After session, remove the marker:
   rm .idle-disabled
   ```

2. **jwz config**: Set disabled flag in state:
   ```bash
   jwz post "loop:current" -m '{"schema":2,"config":{"disabled":true},"stack":[]}'
   ```

3. **Manual reset**: Delete the jwz topic:
   ```bash
   rm -rf .jwz/topics/loop:current/
   ```

4. **Nuclear option**: Delete all jwz state:
   ```bash
   rm -rf .jwz/
   ```
