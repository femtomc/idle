---
description: Iterate on a task until complete, or work through the issue tracker
---

# Loop Command

Universal iteration loop. Works on a specific task or pulls from the issue tracker.

## Usage

```
/loop [task description]
```

- **With args**: Iterate on that specific task
- **Without args**: Pull issues from tracker and work indefinitely

## Modes

### Task Mode (with args)

Simple iteration on a specific task. No worktree, no issue tracker.

**Limits**: 10 iterations, 3 consecutive failures = stuck

### Issue Mode (no args)

Pull from `tissue ready`, create worktree, work issue, auto-land, repeat.

**Limits**: 10 iterations per issue, unlimited issues

## How It Works

Uses a **Stop hook** to intercept exit and force re-entry until complete. Loop state stored via jwz messaging.

The hook checks for completion signals (`<loop-done>`) to decide whether to continue or allow exit.

## Setup

Initialize based on mode:

```bash
RUN_ID="loop-$(date +%s)-$$"
REPO_ROOT=$(git rev-parse --show-toplevel)

# Ensure jwz is initialized
[ ! -d .jwz ] && jwz init

if [[ -z "$ARGUMENTS" ]]; then
    # Issue mode - pick first ready issue
    ISSUE_ID=$(tissue ready --format=id 2>/dev/null | head -1)
    if [[ -z "$ISSUE_ID" ]]; then
        echo "No issues ready to work. Use 'tissue list' to see all issues."
        exit 0
    fi

    # Validate issue exists
    if ! tissue show "$ISSUE_ID" >/dev/null 2>&1; then
        echo "Error: Issue $ISSUE_ID not found"
        exit 1
    fi

    MODE="issue"

    # Resolve base ref (config > origin/HEAD > main > master > HEAD)
    BASE_REF=""
    BASE_REF=$(git config idle.baseRef 2>/dev/null || true)
    if [[ -z "$BASE_REF" ]]; then
        BASE_REF=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || true)
    fi
    if [[ -z "$BASE_REF" ]] && git show-ref --verify refs/heads/main >/dev/null 2>&1; then
        BASE_REF="main"
    fi
    if [[ -z "$BASE_REF" ]] && git show-ref --verify refs/heads/master >/dev/null 2>&1; then
        BASE_REF="master"
    fi
    if [[ -z "$BASE_REF" ]]; then
        BASE_REF="HEAD"
    fi

    # Create worktree
    SAFE_ID=$(printf '%s' "$ISSUE_ID" | tr -cd 'a-zA-Z0-9_-')
    BRANCH="idle/issue/$SAFE_ID"
    WORKTREE_PATH="$REPO_ROOT/.worktrees/idle/$SAFE_ID"

    # Ensure .worktrees/ is gitignored
    grep -q '^\.worktrees/' "$REPO_ROOT/.gitignore" 2>/dev/null || echo ".worktrees/" >> "$REPO_ROOT/.gitignore"

    if git worktree list | grep -qF "$WORKTREE_PATH"; then
        echo "Reusing existing worktree at $WORKTREE_PATH"
    else
        mkdir -p "$(dirname "$WORKTREE_PATH")"
        git worktree add -b "$BRANCH" "$WORKTREE_PATH" "$BASE_REF" 2>/dev/null || \
        git worktree add "$WORKTREE_PATH" "$BRANCH"

        # Initialize submodules
        [[ -f "$REPO_ROOT/.gitmodules" ]] && git -C "$WORKTREE_PATH" submodule update --init --recursive
    fi

    # Store prompt as blob
    PROMPT_BLOB=$(tissue show "$ISSUE_ID" | jwz blob put /dev/stdin)

    # Post initial state
    NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jwz post "loop:current" -m "{\"schema\":2,\"event\":\"STATE\",\"run_id\":\"$RUN_ID\",\"updated_at\":\"$NOW\",\"stack\":[{\"id\":\"$RUN_ID\",\"mode\":\"issue\",\"iter\":1,\"max\":10,\"prompt_blob\":\"$PROMPT_BLOB\",\"issue_id\":\"$ISSUE_ID\",\"worktree_path\":\"$WORKTREE_PATH\",\"branch\":\"$BRANCH\",\"base_ref\":\"$BASE_REF\"}]}"

    jwz topic new "issue:$ISSUE_ID" 2>/dev/null || true
    jwz post "issue:$ISSUE_ID" -m "[loop] STARTED: Working in $WORKTREE_PATH"
else
    # Task mode - simple iteration
    MODE="task"

    # Store prompt as blob
    PROMPT_BLOB=$(echo "$ARGUMENTS" | jwz blob put /dev/stdin)

    NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jwz post "loop:current" -m "{\"schema\":2,\"event\":\"STATE\",\"run_id\":\"$RUN_ID\",\"updated_at\":\"$NOW\",\"stack\":[{\"id\":\"$RUN_ID\",\"mode\":\"task\",\"iter\":1,\"max\":10,\"prompt_blob\":\"$PROMPT_BLOB\"}]}"
    jwz post "project:$(basename $PWD)" -m "[loop] STARTED: $ARGUMENTS"
fi
```

## Worktree Context (Issue Mode)

All file operations use the worktree path:
- **Read/Write/Edit**: Absolute paths under `$WORKTREE_PATH`
- **Bash**: Prefix with `cd "$WORKTREE_PATH" && ...`
- **tissue commands**: Run from main repo

The stop hook injects worktree context on each iteration.

## Workflow

### Task Mode
1. Work on the task incrementally
2. On success: `<loop-done>COMPLETE</loop-done>`
3. On failure: analyze, retry

### Issue Mode
1. Read the issue from the prompt
2. Implement the fix in the worktree
3. Run review before completion
4. On success: `<loop-done>COMPLETE</loop-done>` (auto-lands)
5. Loop picks next issue automatically

## Definition of Done (Issue Mode)

Before completing, you MUST:
1. **Commit all changes**: No uncommitted changes
2. **Run review**: Code must be reviewed
3. **Address feedback**: Fix CHANGES_REQUESTED (max 3 iterations)

The stop hook enforces these requirements.

## Completion

**Success**:
```
<loop-done>COMPLETE</loop-done>
```
- Task mode: Loop exits
- Issue mode: Auto-lands, then picks next issue

**Auto-land flow** (issue mode):
```bash
git fetch origin
git checkout main
git merge --ff-only "$BRANCH" && git push origin main
git worktree remove "$WORKTREE_PATH"
git branch -d "$BRANCH"
tissue status "$ISSUE_ID" closed
```

**Max iterations**:
```
<loop-done>MAX_ITERATIONS</loop-done>
```

**Stuck**:
```
<loop-done>STUCK</loop-done>
```

## Escape Hatches

If stuck in an infinite loop:
1. `/cancel` - Graceful cancellation
2. `touch .idle-disabled` - File-based bypass (remove after)
3. Delete `.jwz/` directory - Manual reset
