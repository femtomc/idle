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
    DISCORD_RAW=$(jwz read "$DISCORD_TOPIC" --json 2>/dev/null | jq -r '.[0].body // empty' || echo "")
    if [[ -n "$DISCORD_RAW" ]]; then
        DISCORD_THREAD_ID=$(echo "$DISCORD_RAW" | jq -r '.thread_id // ""' 2>/dev/null || echo "")
    fi
fi

# --- Get user's original request for context ---

USER_REQUEST=""
if command -v jwz &>/dev/null; then
    USER_RAW=$(jwz read "$USER_CONTEXT_TOPIC" --json 2>/dev/null | jq -r '.[0].body // empty' || echo "")
    if [[ -n "$USER_RAW" ]]; then
        USER_REQUEST=$(echo "$USER_RAW" | jq -r '.prompt // ""' 2>/dev/null || echo "")
    fi
fi

# Truncate user request for notifications
USER_REQUEST_PREVIEW="$USER_REQUEST"
if [[ ${#USER_REQUEST_PREVIEW} -gt 200 ]]; then
    USER_REQUEST_PREVIEW="${USER_REQUEST_PREVIEW:0:200}..."
fi

# --- Check review state (opt-in via #gate) ---
# Fail-closed: default to blocking, only approve if positively confirmed no #gate

REVIEW_STATE_TOPIC="review:state:$SESSION_ID"

if ! command -v jwz &>/dev/null; then
    # Fail open with notification - review system can't function without jwz
    notify "[$PROJECT_LABEL] Review Degraded" "jwz unavailable - review system bypassed" 4 "warning" "$REPO_URL" "" "$DISCORD_THREAD_ID"
    jq -n '{decision: "approve", reason: "jwz unavailable - review system bypassed"}'
    exit 0
fi

# Try to read review state using temp file to preserve JSON integrity
JWZ_TMPFILE=$(mktemp)
trap "rm -f $JWZ_TMPFILE" EXIT

set +e
jwz read "$REVIEW_STATE_TOPIC" --json > "$JWZ_TMPFILE" 2>&1
JWZ_EXIT=$?
set -e

# Determine review state with fail-closed logic
if [[ $JWZ_EXIT -ne 0 ]]; then
    # jwz command failed
    if command grep -q "Topic not found" "$JWZ_TMPFILE"; then
        # Topic doesn't exist - no #gate was used, approve
        jq -n '{decision: "approve", reason: "Review not enabled"}'
        exit 0
    else
        # Unknown jwz error - fail open with notification
        ERR_MSG=$(cat "$JWZ_TMPFILE")
        notify "[$PROJECT_LABEL] Review Degraded" "jwz error: $ERR_MSG" 4 "warning" "$REPO_URL" "" "$DISCORD_THREAD_ID"
        jq -n --arg err "$ERR_MSG" '{decision: "approve", reason: ("jwz error - review bypassed: " + $err)}'
        exit 0
    fi
fi

# jwz succeeded - parse the response directly from file
# Note: don't use // with booleans as jq treats false as falsy
REVIEW_ENABLED_RAW=$(jq -r '.[0].body | fromjson | .enabled' "$JWZ_TMPFILE" 2>/dev/null)
if [[ -z "$REVIEW_ENABLED_RAW" || "$REVIEW_ENABLED_RAW" == "null" ]]; then
    # Can't parse enabled field - fail open with notification
    notify "[$PROJECT_LABEL] Review Degraded" "Failed to parse review state" 4 "warning" "$REPO_URL" "" "$DISCORD_THREAD_ID"
    jq -n '{decision: "approve", reason: "Failed to parse review state - review bypassed"}'
    exit 0
fi

if [[ "$REVIEW_ENABLED_RAW" != "true" ]]; then
    # enabled is explicitly false - approve
    jq -n '{decision: "approve", reason: "Review not enabled"}'
    exit 0
fi

# Review is enabled - continue to alice check

# --- Check: Has alice reviewed this session? ---

ALICE_DECISION=""
ALICE_MSG_ID=""
ALICE_SUMMARY=""
ALICE_MESSAGE=""

if command -v jwz &>/dev/null; then
    LATEST_RAW=$(jwz read "$ALICE_TOPIC" --json 2>/dev/null | jq '.[0] // empty' || echo "")
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

    # Reset review state - gate turns off after approval
    if command -v jwz &>/dev/null; then
        RESET_MSG=$(jq -n --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            '{enabled: false, timestamp: $ts}')
        jwz post "$REVIEW_STATE_TOPIC" -m "$RESET_MSG" 2>/dev/null || true
    fi

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

REASON="No alice review for this session. You must spawn alice before exiting.

Invoke alice with this prompt format:

---
SESSION_ID=$SESSION_ID

Changes since last review:
- <file>: <what changed>
- <file>: <what changed>
---

RULES:
- List changes as facts only (file + what), no justifications
- Do NOT summarize intent or explain why
- Do NOT editorialize or argue your case
- Alice forms her own judgment from the user's prompt transcript

Alice will read jwz topic 'user:context:$SESSION_ID' for the user's actual request
and evaluate whether YOUR changes satisfy THE USER's desires (not your interpretation)."

# Post pending review notification (to thread if exists)
NOTIFY_TITLE="[$PROJECT_LABEL] Awaiting Review"
NOTIFY_BODY="**Task**
> $USER_REQUEST_PREVIEW

**Status**
Agent exiting without alice review. Spawning alice for approval..."
notify "$NOTIFY_TITLE" "$NOTIFY_BODY" 4 "hourglass" "$REPO_URL" "" "$DISCORD_THREAD_ID"

jq -n --arg reason "$REASON" '{decision: "block", reason: $reason}'
exit 0
