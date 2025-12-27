---
description: Cancel the active iteration loop
---

# Cancel Loop

The user wants to cancel the iteration loop.

1. Check if there's an active issue:
   ```bash
   cat /tmp/trivial-loop-issue 2>/dev/null
   ```

2. If an issue was being worked on, pause it:
   ```bash
   ISSUE_ID=$(cat /tmp/trivial-loop-issue 2>/dev/null)
   if [[ -n "$ISSUE_ID" ]]; then
       tissue status "$ISSUE_ID" paused
       tissue comment "$ISSUE_ID" -m "[loop] Cancelled by user"
   fi
   ```

3. Remove all loop state files:
   ```bash
   rm -f /tmp/trivial-loop-active /tmp/trivial-loop-issue /tmp/trivial-loop-mode /tmp/trivial-loop-context
   ```

4. Confirm to the user that the loop has been cancelled
5. Summarize what was accomplished so far
