#!/bin/bash
# idle SessionStart hook
# Injects context about the idle system into the main agent
#
# Output: JSON with context field for injection
# Exit 0 always

set -euo pipefail

# Read hook input from stdin
INPUT=$(cat)

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

# Output JSON with context (hookSpecificOutput.additionalContext for SessionStart)
jq -n \
    --arg context "$CONTEXT" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $context}}'

exit 0
