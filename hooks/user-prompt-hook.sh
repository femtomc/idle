#!/bin/bash
# idle UserPromptSubmit hook
# Captures user messages and stores them in jwz for alice context
#
# Output: JSON (approve to continue)
# Exit 0 always

# Ensure we always output valid JSON, even on error
trap 'echo "{\"decision\": \"approve\"}"; exit 0' ERR

set -uo pipefail

# Read hook input from stdin
INPUT=$(cat || echo '{}')

# Extract session info and user prompt
CWD=$(echo "$INPUT" | jq -r '.cwd // "."')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"')
USER_PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""')
IDLE_MODE_MSG=""

cd "$CWD"

# --- Parse #idle command ---

if command -v jwz &>/dev/null && [[ -n "$USER_PROMPT" ]]; then
    REVIEW_STATE_TOPIC="review:state:$SESSION_ID"

    if [[ "$USER_PROMPT" =~ ^#[Ii][Dd][Ll][Ee]([[:space:]]|$) ]]; then
        # Turn on review for this prompt
        jwz topic new "$REVIEW_STATE_TOPIC" 2>/dev/null || true
        STATE_MSG=$(jq -n --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            '{enabled: true, timestamp: $ts}')
        POST_ERR=""
        if POST_ERR=$(jwz post "$REVIEW_STATE_TOPIC" -m "$STATE_MSG" 2>&1); then
            IDLE_MODE_MSG="idle: review mode ON"
        else
            # Include error details in warning
            if [[ -n "$POST_ERR" ]]; then
                IDLE_MODE_MSG="idle: WARNING - failed to enable review mode: $POST_ERR"
            else
                IDLE_MODE_MSG="idle: WARNING - failed to enable review mode (jwz post exited non-zero with no output)"
            fi
        fi
    fi
fi

# Store user message to jwz for alice context
if command -v jwz &>/dev/null && [[ -n "$USER_PROMPT" ]]; then
    USER_TOPIC="user:context:$SESSION_ID"
    ALICE_TOPIC="alice:status:$SESSION_ID"
    TRACE_TOPIC="trace:$SESSION_ID"
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Create both topics if they don't exist
    jwz topic new "$USER_TOPIC" 2>/dev/null || true
    jwz topic new "$ALICE_TOPIC" 2>/dev/null || true

    # Reset alice status - new prompt requires new review
    RESET_MSG=$(jq -n \
        --arg ts "$TIMESTAMP" \
        '{decision: "PENDING", summary: "New user prompt received, review required", timestamp: $ts}')
    jwz post "$ALICE_TOPIC" -m "$RESET_MSG" 2>/dev/null || true

    # Create message payload
    MSG=$(jq -n \
        --arg prompt "$USER_PROMPT" \
        --arg ts "$TIMESTAMP" \
        '{type: "user_message", prompt: $prompt, timestamp: $ts}')

    jwz post "$USER_TOPIC" -m "$MSG" 2>/dev/null || true

    # Emit prompt_received trace event
    jwz topic new "$TRACE_TOPIC" 2>/dev/null || true
    TRACE_EVENT=$(jq -n \
        --arg event_type "prompt_received" \
        --arg prompt "$USER_PROMPT" \
        --arg ts "$TIMESTAMP" \
        '{event_type: $event_type, prompt: $prompt, timestamp: $ts}')
    jwz post "$TRACE_TOPIC" -m "$TRACE_EVENT" 2>/dev/null || true
fi

# Always approve - this hook just captures, doesn't gate
if [[ -n "$IDLE_MODE_MSG" ]]; then
    jq -n --arg msg "$IDLE_MODE_MSG" '{decision: "approve", hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $msg}}'
else
    echo '{"decision": "approve"}'
fi
exit 0
