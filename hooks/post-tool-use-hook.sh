#!/bin/bash
# idle PostToolUse hook
# Captures tool execution events for trace construction
#
# Output: JSON (approve to continue)
# Exit 0 always

# Ensure we always output valid JSON, even on error
trap 'echo "{\"decision\": \"approve\"}"; exit 0' ERR

set -uo pipefail

# Read hook input from stdin
INPUT=$(cat || echo '{}')

# Extract session info and tool details
CWD=$(echo "$INPUT" | jq -r '.cwd // "."')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input // "{}"')
TOOL_OUTPUT=$(echo "$INPUT" | jq -r '.tool_output // ""')

cd "$CWD"

# Emit trace event to jwz
if command -v jwz &>/dev/null && [[ -n "$SESSION_ID" ]]; then
    TRACE_TOPIC="trace:$SESSION_ID"
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Create topic if it doesn't exist
    jwz topic new "$TRACE_TOPIC" 2>/dev/null || true

    # Truncate tool_output if too large (>4KB)
    TRUNCATED_OUTPUT="$TOOL_OUTPUT"
    if [[ ${#TOOL_OUTPUT} -gt 4096 ]]; then
        TRUNCATED_OUTPUT="${TOOL_OUTPUT:0:4000}... [truncated]"
    fi

    # Create trace event payload
    TRACE_EVENT=$(jq -n \
        --arg event_type "tool_completed" \
        --arg tool_name "$TOOL_NAME" \
        --arg tool_input "$TOOL_INPUT" \
        --arg tool_output "$TRUNCATED_OUTPUT" \
        --arg ts "$TIMESTAMP" \
        '{
            event_type: $event_type,
            tool_name: $tool_name,
            tool_input: $tool_input,
            tool_output: $tool_output,
            timestamp: $ts
        }')

    jwz post "$TRACE_TOPIC" -m "$TRACE_EVENT" 2>/dev/null || true
fi

# Always approve - this hook just captures, doesn't gate
echo '{"decision": "approve"}'
exit 0
