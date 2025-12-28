#!/bin/bash
# trivial PreCompact hook - persist recovery anchor before context compaction
# Writes minimal state to jwz for recovery after compaction

set -e

# Read hook input from stdin
INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Change to project directory
if [[ -n "$CWD" ]]; then
    cd "$CWD"
fi

# Only proceed if jwz is available and initialized
if ! command -v jwz >/dev/null 2>&1 || [[ ! -d .jwz ]]; then
    exit 0
fi

# Check if there's an active loop
STATE=$(jwz read "loop:current" 2>/dev/null | tail -1 || true)
if [[ -z "$STATE" ]] || ! echo "$STATE" | jq -e '.stack | length > 0' >/dev/null 2>&1; then
    # No active loop, nothing to preserve
    exit 0
fi

# Extract current task info from loop state
MODE=$(echo "$STATE" | jq -r '.stack[-1].mode // "unknown"')
ITER=$(echo "$STATE" | jq -r '.stack[-1].iter // 0')
MAX=$(echo "$STATE" | jq -r '.stack[-1].max // 0')
ISSUE_ID=$(echo "$STATE" | jq -r '.stack[-1].issue_id // empty')
PROMPT_FILE=$(echo "$STATE" | jq -r '.stack[-1].prompt_file // empty')

# Build goal description
if [[ -n "$ISSUE_ID" ]]; then
    GOAL="Working on issue: $ISSUE_ID"
elif [[ -n "$PROMPT_FILE" ]] && [[ -f "$PROMPT_FILE" ]]; then
    GOAL=$(head -1 "$PROMPT_FILE" | cut -c1-100)
else
    GOAL="$MODE loop in progress"
fi

# Get recent progress from git
RECENT_COMMITS=$(git log --oneline -3 2>/dev/null | tr '\n' '; ' || echo "none")
MODIFIED_FILES=$(git diff --name-only 2>/dev/null | head -5 | tr '\n' ', ' || echo "none")

# Build anchor JSON
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ANCHOR=$(jq -n \
    --arg goal "$GOAL" \
    --arg mode "$MODE" \
    --argjson iter "$ITER" \
    --argjson max "$MAX" \
    --arg progress "Recent commits: $RECENT_COMMITS" \
    --arg modified "$MODIFIED_FILES" \
    --arg timestamp "$NOW" \
    '{
        goal: $goal,
        mode: $mode,
        iteration: "\($iter)/\($max)",
        progress: $progress,
        modified_files: $modified,
        next_step: "Continue working on the task. Check git status and loop state.",
        timestamp: $timestamp
    }')

# Post anchor to jwz
jwz post "loop:anchor" -m "$ANCHOR" 2>/dev/null || true

# Emit minimal pointer (this goes to context)
echo "TRIVIAL: Recovery anchor saved. After compaction: jwz read loop:anchor"
