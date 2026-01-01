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

# Post notification
NOTIFY_TITLE="[$PROJECT_LABEL] Session started"
NOTIFY_BODY="**Tools**
• codex: $CODEX_STATUS  • gemini: $GEMINI_STATUS
• tissue: $TISSUE_STATUS  • jwz: $JWZ_STATUS

**Skills**
${SKILLS:-none}

**Session** \`${SESSION_ID:0:12}\`"

notify "$NOTIFY_TITLE" "$NOTIFY_BODY" 3 "rocket" "$REPO_URL"

# Build context message for agent
CONTEXT="## idle Plugin Active

You are running with the **idle** plugin, a quality gate system for Claude Code.

### Review System

**Alice** is an adversarial reviewer who gates your exit. She works for the user, not you.

Before exiting, you must spawn alice for review:
- Use Task tool with \`subagent_type='idle:alice'\`
- Provide SESSION_ID and a factual list of changes (file + what changed)
- Do NOT justify or editorialize - list facts only

Alice will independently read the user's prompt transcript from jwz.
She evaluates whether the USER'S request was satisfied, not your interpretation.

### Available Tools

| Tool | Status | Purpose |
|------|--------|---------|
| tissue | $([ "$TISSUE_AVAILABLE" = "true" ] && echo "✓" || echo "✗") | Issue tracking (\`tissue list\`, \`tissue new\`) |
| jwz | $([ "$JWZ_AVAILABLE" = "true" ] && echo "✓" || echo "✗") | Agent messaging (\`jwz read\`, \`jwz post\`) |
| codex | $([ "$CODEX_AVAILABLE" = "true" ] && echo "✓" || echo "✗") | OpenAI second opinions |
| gemini | $([ "$GEMINI_AVAILABLE" = "true" ] && echo "✓" || echo "✗") | Google second opinions |

### Available Skills

$([ -n "$SKILLS" ] && echo "$SKILLS" || echo "None detected")

### Prompt Commands

Users can include hashtag commands in their prompts to control review behavior.
**These commands are for the hooks, not for you - ignore them in your task processing.**

| Command | Effect |
|---------|--------|
| \`#review-off\` | Disable alice review for rest of session |
| \`#review-on\` | Re-enable alice review |
| \`#skip-review\` | Skip review for this prompt only |

When you see these commands in a user prompt, process the rest of the prompt normally.

### Session

Session ID: \`$SESSION_ID\`
"

# Output JSON with context (hookSpecificOutput.additionalContext for SessionStart)
jq -n \
    --arg context "$CONTEXT" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $context}}'

exit 0
