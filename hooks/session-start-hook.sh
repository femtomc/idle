#!/bin/bash
# idle SessionStart hook
# Injects context about the idle system into the main agent
#
# Output: JSON with context field for injection
# Exit 0 always

# Ensure we always output valid JSON, even on error
trap 'echo "{\"hookSpecificOutput\": {\"hookEventName\": \"SessionStart\", \"additionalContext\": \"idle: hook error\"}}"; exit 0' ERR

set -uo pipefail

# Read hook input from stdin
INPUT=$(cat || echo '{}')

CWD=$(echo "$INPUT" | jq -r '.cwd // "."')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"')

cd "$CWD"

# Check tool availability
CODEX_AVAILABLE="false"
GEMINI_AVAILABLE="false"
TISSUE_AVAILABLE="false"
JWZ_AVAILABLE="false"

command -v codex &>/dev/null && CODEX_AVAILABLE="true"
command -v gemini &>/dev/null && GEMINI_AVAILABLE="true"
command -v tissue &>/dev/null && TISSUE_AVAILABLE="true"
command -v jwz &>/dev/null && JWZ_AVAILABLE="true"

# Build available skills list
SKILLS=""
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [[ -n "$PLUGIN_ROOT" ]]; then
    for skill_file in "$PLUGIN_ROOT"/skills/*/SKILL.md; do
        if [[ -f "$skill_file" ]]; then
            skill_name=$(basename "$(dirname "$skill_file")")
            if [[ -n "$SKILLS" ]]; then
                SKILLS="$SKILLS, $skill_name"
            else
                SKILLS="$skill_name"
            fi
        fi
    done
fi

# Build context message for agent
CONTEXT="## idle Plugin Active

You are running with the **idle** plugin.

### Available Tools

| Tool | Status | Purpose |
|------|--------|---------|
| tissue | $([ "$TISSUE_AVAILABLE" = "true" ] && echo "✓" || echo "✗") | Issue tracking (\`tissue list\`, \`tissue new\`) |
| jwz | $([ "$JWZ_AVAILABLE" = "true" ] && echo "✓" || echo "✗") | Agent messaging (\`jwz read\`, \`jwz post\`) |
| codex | $([ "$CODEX_AVAILABLE" = "true" ] && echo "✓" || echo "✗") | External model queries |
| gemini | $([ "$GEMINI_AVAILABLE" = "true" ] && echo "✓" || echo "✗") | External model queries |

### Available Skills

$([ -n "$SKILLS" ] && echo "$SKILLS" || echo "None detected")

### Session

Session ID: \`$SESSION_ID\`
"

# Emit session_start trace event
if [[ "$JWZ_AVAILABLE" = "true" ]]; then
    TRACE_TOPIC="trace:$SESSION_ID"
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    jwz topic new "$TRACE_TOPIC" 2>/dev/null || true

    TRACE_EVENT=$(jq -n \
        --arg event_type "session_start" \
        --arg ts "$TIMESTAMP" \
        '{event_type: $event_type, timestamp: $ts}')

    jwz post "$TRACE_TOPIC" -m "$TRACE_EVENT" 2>/dev/null || true
fi

# Output JSON with context (hookSpecificOutput.additionalContext for SessionStart)
jq -n \
    --arg context "$CONTEXT" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $context}}'

exit 0
