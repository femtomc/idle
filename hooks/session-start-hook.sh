#!/bin/bash
# idle SessionStart hook
# Injects context about the idle system into the main agent
# Posts session start notification to ntfy
#
# Output: JSON with context field for injection
# Exit 0 always

set -euo pipefail

# Source shared utilities
source "${BASH_SOURCE%/*}/utils.sh"

# Read hook input from stdin
INPUT=$(cat)

CWD=$(echo "$INPUT" | jq -r '.cwd // "."')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"')

cd "$CWD"

# Get project info
PROJECT_NAME=$(get_project_name "$CWD")
GIT_BRANCH=$(get_git_branch "$CWD")
REPO_URL=$(get_repo_url "$CWD")
PROJECT_LABEL="$PROJECT_NAME"
[[ -n "$GIT_BRANCH" ]] && PROJECT_LABEL="$PROJECT_NAME:$GIT_BRANCH"

# Check tool availability
CODEX_STATUS=$(format_tool_status codex)
GEMINI_STATUS=$(format_tool_status gemini)
TISSUE_STATUS=$(format_tool_status tissue)
JWZ_STATUS=$(format_tool_status jwz)

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

# Post to ntfy
NTFY_TITLE="[$PROJECT_LABEL] Session started"
NTFY_BODY="Tools:
  codex: $CODEX_STATUS  gemini: $GEMINI_STATUS
  tissue: $TISSUE_STATUS  jwz: $JWZ_STATUS

Skills: ${SKILLS:-none}

Session: ${SESSION_ID:0:8}"

notify "$NTFY_TITLE" "$NTFY_BODY" 3 "rocket" "$REPO_URL"

# Build context message for agent
CONTEXT="## idle Plugin Active

You are running with the **idle** plugin, a quality gate system for Claude Code.

### Review System

**Alice** is an adversarial reviewer agent that reviews your work before exit.
- Spawn with: \`idle:alice\` subagent (Task tool with subagent_type)
- Alice will review code changes and flag issues
- The Stop hook gates exit on Alice's approval

### Available Tools

| Tool | Status | Purpose |
|------|--------|---------|
| tissue | $([ "$TISSUE_AVAILABLE" = "true" ] && echo "✓" || echo "✗") | Issue tracking (\`tissue list\`, \`tissue new\`) |
| jwz | $([ "$JWZ_AVAILABLE" = "true" ] && echo "✓" || echo "✗") | Agent messaging (\`jwz read\`, \`jwz post\`) |
| codex | $([ "$CODEX_AVAILABLE" = "true" ] && echo "✓" || echo "✗") | OpenAI second opinions |
| gemini | $([ "$GEMINI_AVAILABLE" = "true" ] && echo "✓" || echo "✗") | Google second opinions |

### Available Skills

$([ -n "$SKILLS" ] && echo "$SKILLS" || echo "None detected")

### Session

Session ID: \`$SESSION_ID\`
"

# Output JSON with context
jq -n \
    --arg context "$CONTEXT" \
    '{decision: "approve", context: $context}'

exit 0
