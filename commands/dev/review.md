# Review Command

Run code review on current changes using the reviewer agent.

## Usage

```
/review [issue-id]
```

## Steps

Invoke the reviewer agent:

```
Task(subagent_type="reviewer", prompt="Review the current changes. Issue: <issue-id or 'uncommitted'>")
```

The reviewer agent will:
1. Run `git diff` to see changes
2. Look for project style guides in `.claude/` or docs
3. Collaborate with Codex for a second opinion
4. Return verdict: LGTM or CHANGES_REQUESTED
