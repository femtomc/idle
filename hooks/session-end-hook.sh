#!/bin/bash
# idle SessionEnd hook
# Marks session end in trace for complete session boundaries
#
# Output: JSON (approve to continue)
# Exit 0 always

# Ensure we always output valid JSON, even on error
trap 'echo "{\"decision\": \"approve\"}"; exit 0' ERR

set -uo pipefail

# Read hook input from stdin
INPUT=$(cat || echo '{}')

# Extract session info
CWD=$(echo "$INPUT" | jq -r '.cwd // "."')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"')

cd "$CWD"

# Emit session end trace event
if command -v jwz &>/dev/null && [[ -n "$SESSION_ID" ]]; then
    TRACE_TOPIC="trace:$SESSION_ID"
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Create topic if it doesn't exist (session might have no tool calls)
    jwz topic new "$TRACE_TOPIC" 2>/dev/null || true

    # Create trace event payload
    TRACE_EVENT=$(jq -n \
        --arg event_type "session_end" \
        --arg ts "$TIMESTAMP" \
        '{
            event_type: $event_type,
            timestamp: $ts
        }')

    jwz post "$TRACE_TOPIC" -m "$TRACE_EVENT" 2>/dev/null || true
fi

# Always approve
echo '{"decision": "approve"}'
exit 0
