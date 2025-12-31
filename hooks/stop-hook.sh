#!/bin/bash
# idle STOP hook
# Checks alice review status before allowing exit
#
# Output: JSON with decision (block/approve) and reason
# Exit 0 for both - decision field controls behavior

set -euo pipefail

# Read hook input from stdin
INPUT=$(cat)

# Check if stop hook already triggered (prevent infinite loops)
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
    echo '{"decision": "approve", "reason": "Stop hook already active"}'
    exit 0
fi

# Extract session info
CWD=$(echo "$INPUT" | jq -r '.cwd // "."')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"')

cd "$CWD"

ALICE_TOPIC="alice:status:$SESSION_ID"

# --- Check 1: Has alice posted a COMPLETE decision? ---

ALICE_DECISION=""
if command -v jwz &>/dev/null; then
    LATEST_MSG=$(jwz read "$ALICE_TOPIC" --json 2>/dev/null | jq -r '.[-1].body // ""' || echo "")
    if [[ -n "$LATEST_MSG" ]]; then
        ALICE_DECISION=$(echo "$LATEST_MSG" | jq -r '.decision // ""' 2>/dev/null || echo "")
    fi
fi

if [[ "$ALICE_DECISION" == "COMPLETE" || "$ALICE_DECISION" == "APPROVED" ]]; then
    echo '{"decision": "approve", "reason": "alice approved"}'
    exit 0
fi

# --- Check 2: Are there open alice-review issues? ---

OPEN_ISSUES=0
if command -v tissue &>/dev/null; then
    OPEN_ISSUES=$(tissue list --tag alice-review --status open 2>/dev/null | wc -l | tr -d ' ' || echo "0")
fi

if [[ "$OPEN_ISSUES" -gt 0 ]]; then
    ISSUE_LIST=$(tissue list --tag alice-review --status open 2>/dev/null || echo "")
    cat <<EOF
{
  "decision": "block",
  "reason": "There are $OPEN_ISSUES open alice-review issue(s). Address them before exiting:\n$ISSUE_LIST\n\nClose issues with: tissue status <id> closed"
}
EOF
    exit 0
fi

# --- Check 3: alice said ISSUES but they're now closed - re-review ---

if [[ "$ALICE_DECISION" == "ISSUES" ]]; then
    cat <<EOF
{
  "decision": "block",
  "reason": "Previous alice issues resolved. Run /alice again for re-review before exiting."
}
EOF
    exit 0
fi

# --- Check 4: No alice review yet - request one ---

cat <<EOF
{
  "decision": "block",
  "reason": "No alice review on record. Run /alice to get review approval before exiting. Alice will review your work and post issues to tissue if problems are found."
}
EOF
exit 0
