#!/bin/bash
# idle STOP hook
# Gates exit on alice review - alice makes the judgment call
#
# Output: JSON with decision (block/approve) and reason
# Exit 0 for both - decision field controls behavior

set -euo pipefail

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

ALICE_TOPIC="alice:status:$SESSION_ID"
REVIEW_STATE_TOPIC="review:state:$SESSION_ID"

# --- Check review state (opt-in via #idle:on, opt-out via #idle:off) ---

if ! command -v jwz &>/dev/null; then
    # Fail open - review system can't function without jwz
    printf "idle: WARNING: jwz unavailable - review system bypassed\n" >&2
    jq -n '{decision: "approve", reason: "jwz unavailable - review system bypassed"}'
    exit 0
fi

# Try to read review state using temp file to preserve JSON integrity
JWZ_TMPFILE=$(mktemp)
trap "rm -f $JWZ_TMPFILE" EXIT

set +e
jwz list "$REVIEW_STATE_TOPIC" --json > "$JWZ_TMPFILE" 2>&1
JWZ_EXIT=$?
set -e

# Determine review state
if [[ $JWZ_EXIT -ne 0 ]]; then
    # jwz command failed
    if command grep -q "Topic not found" "$JWZ_TMPFILE"; then
        # Topic doesn't exist - #idle:on was never used, approve
        jq -n '{decision: "approve", reason: "Review not enabled"}'
        exit 0
    else
        # Unknown jwz error - fail open
        ERR_MSG=$(cat "$JWZ_TMPFILE")
        printf "idle: WARNING: jwz error - review system bypassed: %s\n" "$ERR_MSG" >&2
        jq -n --arg err "$ERR_MSG" '{decision: "approve", reason: ("jwz error - review bypassed: " + $err)}'
        exit 0
    fi
fi

# jwz succeeded - parse the response

# First check if topic is empty (exists but no messages)
# This happens when #idle:on was used but jwz post failed silently
TOPIC_LENGTH=$(jq 'length' "$JWZ_TMPFILE" 2>/dev/null || echo "0")
if [[ "$TOPIC_LENGTH" == "0" ]]; then
    # Topic exists but is empty - #idle:on was attempted but failed
    # Fail CLOSED (block) rather than open
    printf "idle: ERROR: review:state topic exists but is empty - #idle:on may have failed\n" >&2
    jq -n '{decision: "block", reason: "Review state corrupted: topic exists but is empty. This suggests #idle:on failed to post state. Please re-run #idle:on or use #idle:off to explicitly disable review."}'
    exit 0
fi

REVIEW_ENABLED_RAW=$(jq -r '.[0].body | fromjson | .enabled' "$JWZ_TMPFILE" 2>/dev/null || echo "")
if [[ -z "$REVIEW_ENABLED_RAW" || "$REVIEW_ENABLED_RAW" == "null" ]]; then
    # Can't parse enabled field - fail open
    printf "idle: WARNING: Failed to parse review state - review bypassed\n" >&2
    jq -n '{decision: "approve", reason: "Failed to parse review state - review bypassed"}'
    exit 0
fi

if [[ "$REVIEW_ENABLED_RAW" != "true" ]]; then
    # enabled is explicitly false - approve
    jq -n '{decision: "approve", reason: "Review not enabled"}'
    exit 0
fi

# Review is enabled - check alice's decision

ALICE_DECISION=""
ALICE_MSG_ID=""
ALICE_SUMMARY=""
ALICE_MESSAGE=""

LATEST_RAW=$(jwz list "$ALICE_TOPIC" --json 2>/dev/null | jq '.[0] // empty' || echo "")
if [[ -n "$LATEST_RAW" ]]; then
    ALICE_MSG_ID=$(echo "$LATEST_RAW" | jq -r '.id // ""')
    LATEST_BODY=$(echo "$LATEST_RAW" | jq -r '.body // ""')
    if [[ -n "$LATEST_BODY" ]]; then
        ALICE_DECISION=$(echo "$LATEST_BODY" | jq -r '.decision // ""' 2>/dev/null || echo "")
        ALICE_SUMMARY=$(echo "$LATEST_BODY" | jq -r '.summary // ""' 2>/dev/null || echo "")
        ALICE_MESSAGE=$(echo "$LATEST_BODY" | jq -r '.message_to_agent // ""' 2>/dev/null || echo "")
    fi
fi

# --- Decision: COMPLETE/APPROVED → allow exit ---

if [[ "$ALICE_DECISION" == "COMPLETE" || "$ALICE_DECISION" == "APPROVED" ]]; then
    REASON="alice approved"
    [[ -n "$ALICE_MSG_ID" ]] && REASON="$REASON (msg: $ALICE_MSG_ID)"
    [[ -n "$ALICE_SUMMARY" ]] && REASON="$REASON - $ALICE_SUMMARY"

    # Reset review state - gate turns off after approval
    RESET_MSG=$(jq -n --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{enabled: false, timestamp: $ts}')
    jwz post "$REVIEW_STATE_TOPIC" -m "$RESET_MSG" 2>/dev/null || true

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

    jq -n --arg reason "$REASON" '{decision: "block", reason: $reason}'
    exit 0
fi

# --- No review yet → request alice review ---

REASON="No alice review for this session. You must spawn alice before exiting.

Invoke alice with this prompt format:

---
SESSION_ID=$SESSION_ID

## Work performed

<Include relevant sections based on what you did>

### Context (if you referenced issues or messages):
- tissue issue <id>: <title or summary>
- jwz message <topic>: <what it informed>

### Code changes (if any files were modified):
- <file>: <what changed>

### Research findings (if you explored/investigated):
- <what you searched for>: <what you found or concluded>

### Planning outcomes (if you made or refined a plan):
- <decision or step>: <the outcome>
---

RULES:
- Report ALL work you performed, not just code changes
- List facts only (what you did, what you found), no justifications
- Do NOT summarize intent or explain why you chose an approach
- Do NOT editorialize or argue your case
- Include relevant details: files read, searches run, conclusions reached
- Alice forms her own judgment from the user's prompt transcript

Alice will read jwz topic 'user:context:$SESSION_ID' for the user's actual request
and evaluate whether YOUR work satisfies THE USER's desires (not your interpretation)."

jq -n --arg reason "$REASON" '{decision: "block", reason: $reason}'
exit 0
