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

# Post to ntfy (truncate long prompts)
if [[ -n "$USER_PROMPT" ]]; then
    PROMPT_PREVIEW="$USER_PROMPT"
    if [[ ${#PROMPT_PREVIEW} -gt 200 ]]; then
        PROMPT_PREVIEW="${PROMPT_PREVIEW:0:200}..."
    fi

    NTFY_TITLE="[$PROJECT_LABEL] New task"
    NTFY_BODY="$PROMPT_PREVIEW"

    notify "$NTFY_TITLE" "$NTFY_BODY" 3 "speech_balloon" "$REPO_URL"
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
