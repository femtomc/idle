#!/bin/bash
# trivial PreToolUse hook - safety guardrails for destructive operations
# Stateless pattern matching only - no workflow enforcement

set -e

# Read hook input from stdin
INPUT=$(cat)

# Extract tool info
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input // empty')

# Only check Bash commands
if [[ "$TOOL_NAME" != "Bash" ]]; then
    exit 0
fi

# Extract the command being run
COMMAND=$(echo "$TOOL_INPUT" | jq -r '.command // empty')

# Safety patterns - block destructive operations
BLOCKED=false
REASON=""

# Git force push to main/master
if echo "$COMMAND" | grep -qE 'git\s+push\s+.*--force.*\s+(main|master)' || \
   echo "$COMMAND" | grep -qE 'git\s+push\s+.*\s+(main|master).*--force'; then
    BLOCKED=true
    REASON="Force push to main/master is blocked. Use a feature branch."
fi

# Git push --force without explicit branch (dangerous default)
if echo "$COMMAND" | grep -qE 'git\s+push\s+--force\s*$'; then
    BLOCKED=true
    REASON="Force push without explicit branch is blocked. Specify the branch."
fi

# Git reset --hard (loses uncommitted work)
if echo "$COMMAND" | grep -qE 'git\s+reset\s+--hard'; then
    BLOCKED=true
    REASON="git reset --hard loses uncommitted work. Stash first or use --soft."
fi

# Dangerous rm commands
if echo "$COMMAND" | grep -qE 'rm\s+-rf?\s+/\s*$' || \
   echo "$COMMAND" | grep -qE 'rm\s+-rf?\s+/\*' || \
   echo "$COMMAND" | grep -qE 'rm\s+-rf?\s+~\s*$' || \
   echo "$COMMAND" | grep -qE 'rm\s+-rf?\s+\$HOME\s*$'; then
    BLOCKED=true
    REASON="Deleting root or home directory is blocked."
fi

# Drop database patterns
if echo "$COMMAND" | grep -qiE 'drop\s+database|dropdb\s+'; then
    BLOCKED=true
    REASON="Dropping databases is blocked. Use a migration or backup first."
fi

# If blocked, return block decision
if [[ "$BLOCKED" == "true" ]]; then
    cat <<EOF
{
  "decision": "block",
  "reason": "SAFETY: $REASON"
}
EOF
    exit 0
fi

# Allow everything else silently (no output = allow)
exit 0
