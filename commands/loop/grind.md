---
description: Continuously work through the issue tracker (optionally filtered)
---

# Grind Mode

You are entering continuous development mode. You will work through the issue tracker until stopped.

## Context

$ARGUMENTS

## Setup

Initialize the loop:
```bash
echo "0" > /tmp/trivial-loop-active
echo "grind" > /tmp/trivial-loop-mode
```

Save the filter context (if any):
```bash
echo "$ARGUMENTS" > /tmp/trivial-loop-context
```

## Workflow

1. **Find next issue**:
   - Run `tissue ready --json` to get all unblocked issues
   - Filter based on the context above (e.g., if context mentions a tag or epic, only pick matching issues)
   - Pick the highest priority matching issue (P1 > P2 > P3)
   - If no matching issues remain, output `<grind-done>NO_MORE_ISSUES</grind-done>` and stop

2. **Claim it**:
   ```bash
   tissue status <issue-id> in_progress
   echo "<issue-id>" > /tmp/trivial-loop-issue
   ```

3. **Read the issue**: `tissue show <issue-id>`

4. **Work on it**:
   - Look for project style guides in `.claude/` or docs
   - Run `/test` after changes
   - Run `/fmt` before completing

5. **Review cycle** (repeat until LGTM):
   - Ensure tests pass: `/test`
   - Format code: `/fmt`
   - Commit: `git add . && git commit -m "fix/feat: <description>"`
   - Run review via reviewer agent:
     ```
     Task(subagent_type="reviewer", prompt="Review the changes for issue <issue-id>")
     ```
   - If CHANGES_REQUESTED: address the feedback, then repeat this step
   - If LGTM: proceed to step 6

6. **Close and move on**:
   - Close it: `tissue status <issue-id> closed`
   - Push: `git push`
   - Output: `<issue-complete>DONE</issue-complete>`

7. **Then immediately pick the next issue** - go back to step 1

## Available Agents

Use the Task tool to delegate:

- **reviewer** - Code review. Opus + Codex dialogue, returns LGTM or CHANGES_REQUESTED
- **oracle** - Stuck on complex problems? Deep analysis with Codex
- **librarian** - Need to understand how something is implemented? Searches remote code
- **explorer** - Quick "where is X defined" or "what files match Y" searches
- **documenter** - Documentation issues? Drives Gemini to write docs

Examples:
```
Task(subagent_type="reviewer", prompt="Review changes for issue #42")
Task(subagent_type="oracle", prompt="I'm stuck on this design issue: [details]")
Task(subagent_type="librarian", prompt="How does library X implement feature Y?")
```

## Rules

- Work ONE issue at a time
- Always run tests before closing an issue
- Always format code before closing an issue
- Commit after each completed issue
- Use subagents when stuck rather than spinning
- If stuck on an issue for too long, pause it and move on:
  ```bash
  tissue status <issue-id> paused
  tissue comment <issue-id> -m "[grind] Paused - needs human input"
  ```

## To stop

User will run `/cancel-loop` or you'll hit max iterations.

Keep grinding.
