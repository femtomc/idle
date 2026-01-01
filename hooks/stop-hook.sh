#!/bin/bash
# idle STOP hook
# Gates exit on alice review - alice makes the judgment call
# Posts block/approve notifications to ntfy
#
# Output: JSON with decision (block/approve) and reason
# Exit 0 for both - decision field controls behavior

set -euo pipefail

# Source shared utilities
source "${BASH_SOURCE%/*}/utils.sh"

# Read hook input from stdin
INPUT=$(cat)

# Check if stop hook already triggered (prevent infinite loops)
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
    jq -n '{decision: "approve", reason: "Stop hook already active"}'
    exit 0
fi

# Extract session info
CWD=$(echo "$INPUT" | jq -r '.cwd // "."')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"')

cd "$CWD"

# Get project info
PROJECT_NAME=$(get_project_name "$CWD")
GIT_BRANCH=$(get_git_branch "$CWD")
REPO_URL=$(get_repo_url "$CWD")
PROJECT_LABEL="$PROJECT_NAME"
[[ -n "$GIT_BRANCH" ]] && PROJECT_LABEL="$PROJECT_NAME:$GIT_BRANCH"

ALICE_TOPIC="alice:status:$SESSION_ID"
USER_CONTEXT_TOPIC="user:context:$SESSION_ID"
DISCORD_TOPIC="discord:thread:$SESSION_ID"

# --- Get Discord thread ID if exists ---

DISCORD_THREAD_ID=""
if command -v jwz &>/dev/null; then
    DISCORD_RAW=$(jwz read "$DISCORD_TOPIC" --json 2>/dev/null | jq -r '.[-1].body // empty' || echo "")
    if [[ -n "$DISCORD_RAW" ]]; then
        DISCORD_THREAD_ID=$(echo "$DISCORD_RAW" | jq -r '.thread_id // ""' 2>/dev/null || echo "")
    fi
fi

# --- Get user's original request for context ---

USER_REQUEST=""
if command -v jwz &>/dev/null; then
    USER_RAW=$(jwz read "$USER_CONTEXT_TOPIC" --json 2>/dev/null | jq '.[-1].body // empty' || echo "")
    if [[ -n "$USER_RAW" ]]; then
        USER_REQUEST=$(echo "$USER_RAW" | jq -r '.prompt // ""' 2>/dev/null || echo "")
    fi
fi

# Truncate user request for notifications
USER_REQUEST_PREVIEW="$USER_REQUEST"
if [[ ${#USER_REQUEST_PREVIEW} -gt 200 ]]; then
    USER_REQUEST_PREVIEW="${USER_REQUEST_PREVIEW:0:200}..."
fi

# --- Check review state (sticky toggle via #review-off / #review-on) ---

REVIEW_ENABLED=true
REVIEW_STATE_TOPIC="review:state:$SESSION_ID"

if command -v jwz &>/dev/null; then
    STATE_RAW=$(jwz read "$REVIEW_STATE_TOPIC" --json 2>/dev/null | jq '.[-1].body // empty' || echo "")
    if [[ -n "$STATE_RAW" ]]; then
        REVIEW_ENABLED_RAW=$(echo "$STATE_RAW" | jq -r '.enabled // true' 2>/dev/null || echo "true")
        [[ "$REVIEW_ENABLED_RAW" == "false" ]] && REVIEW_ENABLED=false
    fi
fi

# --- Parse per-prompt command (#skip-review) ---

SKIP_REVIEW=false
if [[ "$USER_REQUEST" =~ \#skip-review ]]; then
    SKIP_REVIEW=true
fi

# --- Handle review skip (toggle or per-prompt) ---

if [[ "$REVIEW_ENABLED" == "false" || "$SKIP_REVIEW" == "true" ]]; then
    SKIP_REASON="Review skipped"
    [[ "$REVIEW_ENABLED" == "false" ]] && SKIP_REASON="Review disabled (#review-off)"
    [[ "$SKIP_REVIEW" == "true" ]] && SKIP_REASON="Review skipped (#skip-review)"

    NOTIFY_TITLE="[$PROJECT_LABEL] Skipped Review"
    NOTIFY_BODY="**Task**
> $USER_REQUEST_PREVIEW

**Status**
$SKIP_REASON"
    notify "$NOTIFY_TITLE" "$NOTIFY_BODY" 2 "fast_forward" "$REPO_URL" "" "$DISCORD_THREAD_ID"

    jq -n --arg reason "$SKIP_REASON" '{decision: "approve", reason: $reason}'
    exit 0
fi

# --- Check: Has alice reviewed this session? ---

ALICE_DECISION=""
ALICE_MSG_ID=""
ALICE_SUMMARY=""
ALICE_MESSAGE=""

if command -v jwz &>/dev/null; then
    LATEST_RAW=$(jwz read "$ALICE_TOPIC" --json 2>/dev/null | jq '.[-1] // empty' || echo "")
    if [[ -n "$LATEST_RAW" ]]; then
        ALICE_MSG_ID=$(echo "$LATEST_RAW" | jq -r '.id // ""')
        LATEST_BODY=$(echo "$LATEST_RAW" | jq -r '.body // ""')
        if [[ -n "$LATEST_BODY" ]]; then
            ALICE_DECISION=$(echo "$LATEST_BODY" | jq -r '.decision // ""' 2>/dev/null || echo "")
            ALICE_SUMMARY=$(echo "$LATEST_BODY" | jq -r '.summary // ""' 2>/dev/null || echo "")
            ALICE_MESSAGE=$(echo "$LATEST_BODY" | jq -r '.message_to_agent // ""' 2>/dev/null || echo "")
        fi
    fi
fi

# --- Decision: COMPLETE/APPROVED → allow exit ---

if [[ "$ALICE_DECISION" == "COMPLETE" || "$ALICE_DECISION" == "APPROVED" ]]; then
    REASON="alice approved"
    [[ -n "$ALICE_MSG_ID" ]] && REASON="$REASON (msg: $ALICE_MSG_ID)"
    [[ -n "$ALICE_SUMMARY" ]] && REASON="$REASON - $ALICE_SUMMARY"

    # Post approval notification (to thread if exists)
    NOTIFY_TITLE="[$PROJECT_LABEL] Approved"
    NOTIFY_BODY="**Task**
> $USER_REQUEST_PREVIEW

**Result**
$ALICE_SUMMARY"
    notify "$NOTIFY_TITLE" "$NOTIFY_BODY" 3 "white_check_mark" "$REPO_URL" "" "$DISCORD_THREAD_ID"

    jq -n --arg reason "$REASON" '{decision: "approve", reason: $reason}'
    exit 0
fi

# --- Decision: ISSUES → block, pass alice's message ---

if [[ "$ALICE_DECISION" == "ISSUES" ]]; then
    REASON="alice found issues that need to be addressed before exiting."
    [[ -n "$ALICE_MSG_ID" ]] && REASON="$REASON (review: $ALICE_MSG_ID)"
    [[ -n "$ALICE_SUMMARY" ]] && REASON="$REASON

$ALICE_SUMMARY"
    [[ -n "$ALICE_MESSAGE" ]] && REASON="$REASON

alice says: $ALICE_MESSAGE"

    # Post block notification (high priority, to thread if exists)
    NOTIFY_TITLE="[$PROJECT_LABEL] Blocked"
    NOTIFY_BODY="**Task**
> $USER_REQUEST_PREVIEW

**Issues**
$ALICE_SUMMARY"
    if [[ -n "$ALICE_MESSAGE" ]]; then
        NOTIFY_BODY="$NOTIFY_BODY

**Action Required**
$ALICE_MESSAGE"
    fi
    notify "$NOTIFY_TITLE" "$NOTIFY_BODY" 5 "x" "$REPO_URL" "" "$DISCORD_THREAD_ID"

    jq -n --arg reason "$REASON" '{decision: "block", reason: $reason}'
    exit 0
fi

# --- No review yet → request alice review ---

REASON="No alice review for this session. Spawn the idle:alice agent to get review approval before exiting.

Use: Task tool with subagent_type='idle:alice' and prompt including SESSION_ID=$SESSION_ID

Alice will read your conversation context and decide if the work is complete or needs fixes."

# Post pending review notification (to thread if exists)
NOTIFY_TITLE="[$PROJECT_LABEL] Awaiting Review"
NOTIFY_BODY="**Task**
> $USER_REQUEST_PREVIEW

**Status**
Agent exiting without alice review. Spawning alice for approval..."
notify "$NOTIFY_TITLE" "$NOTIFY_BODY" 4 "hourglass" "$REPO_URL" "" "$DISCORD_THREAD_ID"

jq -n --arg reason "$REASON" '{decision: "block", reason: $reason}'
exit 0
