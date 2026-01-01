#!/bin/bash
# idle UserPromptSubmit hook
# Captures user messages and stores them in jwz for alice context
# Posts new task notification to ntfy
#
# Output: JSON (approve to continue)
# Exit 0 always

set -euo pipefail

# Source shared utilities
source "${BASH_SOURCE%/*}/utils.sh"

# Read hook input from stdin
INPUT=$(cat)

# Extract session info and user prompt
CWD=$(echo "$INPUT" | jq -r '.cwd // "."')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"')
USER_PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""')

cd "$CWD"

# Get project info
PROJECT_NAME=$(get_project_name "$CWD")
GIT_BRANCH=$(get_git_branch "$CWD")
REPO_URL=$(get_repo_url "$CWD")
PROJECT_LABEL="$PROJECT_NAME"
[[ -n "$GIT_BRANCH" ]] && PROJECT_LABEL="$PROJECT_NAME:$GIT_BRANCH"

# Post notification (truncate very long prompts)
if [[ -n "$USER_PROMPT" ]]; then
    PROMPT_DISPLAY="$USER_PROMPT"
    if [[ ${#PROMPT_DISPLAY} -gt 500 ]]; then
        PROMPT_DISPLAY="${PROMPT_DISPLAY:0:500}..."
    fi

    # Create thread name (truncate for Discord's 100 char limit)
    THREAD_NAME="[$PROJECT_LABEL] ${USER_PROMPT:0:60}"
    if [[ ${#USER_PROMPT} -gt 60 ]]; then
        THREAD_NAME="${THREAD_NAME}..."
    fi

    NOTIFY_TITLE="[$PROJECT_LABEL] New task"
    NOTIFY_BODY="> $PROMPT_DISPLAY"

    # Create a new forum thread and capture thread ID
    THREAD_ID=$(notify "$NOTIFY_TITLE" "$NOTIFY_BODY" 3 "speech_balloon" "$REPO_URL" "$THREAD_NAME" "")

    # Store thread ID in jwz for subsequent messages
    if command -v jwz &>/dev/null && [[ -n "$THREAD_ID" ]]; then
        DISCORD_TOPIC="discord:thread:$SESSION_ID"
        jwz topic new "$DISCORD_TOPIC" 2>/dev/null || true
        THREAD_MSG=$(jq -n \
            --arg tid "$THREAD_ID" \
            --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            '{thread_id: $tid, timestamp: $ts}')
        jwz post "$DISCORD_TOPIC" -m "$THREAD_MSG" 2>/dev/null || true
    fi
fi

# --- Parse prompt commands (#review-off, #review-on) ---
# These are sticky toggles stored in jwz

if command -v jwz &>/dev/null && [[ -n "$USER_PROMPT" ]]; then
    REVIEW_STATE_TOPIC="review:state:$SESSION_ID"
    jwz topic new "$REVIEW_STATE_TOPIC" 2>/dev/null || true

    if [[ "$USER_PROMPT" =~ \#review-off ]]; then
        STATE_MSG=$(jq -n --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            '{enabled: false, timestamp: $ts}')
        jwz post "$REVIEW_STATE_TOPIC" -m "$STATE_MSG" 2>/dev/null || true
    elif [[ "$USER_PROMPT" =~ \#review-on ]]; then
        STATE_MSG=$(jq -n --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            '{enabled: true, timestamp: $ts}')
        jwz post "$REVIEW_STATE_TOPIC" -m "$STATE_MSG" 2>/dev/null || true
    fi
fi

# Store user message to jwz for alice context
if command -v jwz &>/dev/null && [[ -n "$USER_PROMPT" ]]; then
    USER_TOPIC="user:context:$SESSION_ID"
    ALICE_TOPIC="alice:status:$SESSION_ID"
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
fi

# Always approve - this hook just captures, doesn't gate
echo '{"decision": "approve"}'
exit 0
