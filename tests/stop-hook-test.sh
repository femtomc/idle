#!/bin/bash
# Stop hook unit tests
# Tests the stop hook logic for alice review gating

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/stop-hook.sh"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

pass=0
fail=0

# Test helper
test_case() {
    local name="$1"
    local expected_decision="$2"
    local input="$3"

    cd "$TEMP_DIR"
    result=$(echo "$input" | bash "$HOOK" 2>/dev/null || true)
    decision=$(echo "$result" | jq -r '.decision // "error"')

    if [[ "$decision" == "$expected_decision" ]]; then
        echo "✓ $name"
        ((pass++)) || true
    else
        echo "✗ $name (expected $expected_decision, got $decision)"
        echo "  Output: $result"
        ((fail++)) || true
    fi
}

echo "=== Stop Hook Tests ==="
echo ""

# ============================================================================
# TEST 1: No jwz store → fail-open (review not enabled)
# ============================================================================
echo "--- Test 1: No jwz store (fail-open) ---"

test_case "No jwz store approves (review not enabled)" "approve" '{
  "session_id": "test-123",
  "cwd": "'"$TEMP_DIR"'",
  "stop_hook_active": false
}'

# ============================================================================
# TEST 2: No jwz, no tissue - review off by default, should approve
# ============================================================================
echo ""
echo "--- Test 2: No review enabled (default) ---"

# Create a mock environment without jwz/tissue
mkdir -p "$TEMP_DIR/no-tools"
cd "$TEMP_DIR/no-tools"

# Review is opt-in via #idle:on, so without it, exit is allowed
test_case "No tools available, review not enabled" "approve" '{
  "session_id": "test-456",
  "cwd": "'"$TEMP_DIR/no-tools"'",
  "stop_hook_active": false
}'

# ============================================================================
# TEST 3: JSON output format
# ============================================================================
echo ""
echo "--- Test 3: Output format ---"

cd "$TEMP_DIR"
result=$(echo '{"session_id":"fmt-test","cwd":"'"$TEMP_DIR"'","stop_hook_active":false}' | bash "$HOOK" 2>/dev/null || true)

# Check it's valid JSON with required fields
if echo "$result" | jq -e '.decision and .reason' > /dev/null 2>&1; then
    echo "✓ Output is valid JSON with decision and reason"
    ((pass++)) || true
else
    echo "✗ Output format invalid: $result"
    ((fail++)) || true
fi

# ============================================================================
# TEST 4: Alice ISSUES always blocks
# ============================================================================
echo ""
echo "--- Test 4: Alice ISSUES blocks ---"

if command -v jwz &>/dev/null; then
    # Set up jwz store
    JWZ_TEST_DIR="$TEMP_DIR/jwz-test"
    mkdir -p "$JWZ_TEST_DIR"
    cd "$JWZ_TEST_DIR"
    jwz init 2>/dev/null || true

    SESSION="test-issues-blocking"

    # Enable review
    jwz topic new "review:state:$SESSION" 2>/dev/null || true
    jwz post "review:state:$SESSION" -m '{"enabled": true, "timestamp": "2024-01-01T00:00:00Z"}' 2>/dev/null || true

    # Post alice ISSUES decision
    jwz topic new "alice:status:$SESSION" 2>/dev/null || true
    jwz post "alice:status:$SESSION" -m '{"decision": "ISSUES", "summary": "Test issue found", "message_to_agent": "Fix the bug"}' 2>/dev/null || true

    # Alice ISSUES always blocks - no escape hatch
    test_case "Alice ISSUES blocks" "block" '{
      "session_id": "'"$SESSION"'",
      "cwd": "'"$JWZ_TEST_DIR"'",
      "stop_hook_active": false
    }'
else
    echo "⊘ Skipping jwz tests (jwz not available)"
fi

# ============================================================================
# TEST 5: Alice APPROVED allows exit
# ============================================================================
echo ""
echo "--- Test 5: Alice APPROVED allows exit ---"

if command -v jwz &>/dev/null; then
    JWZ_APPROVE_DIR="$TEMP_DIR/jwz-approve"
    mkdir -p "$JWZ_APPROVE_DIR"
    cd "$JWZ_APPROVE_DIR"
    jwz init 2>/dev/null || true

    SESSION="test-approved"

    # Enable review
    jwz topic new "review:state:$SESSION" 2>/dev/null || true
    jwz post "review:state:$SESSION" -m '{"enabled": true, "timestamp": "2024-01-01T00:00:00Z"}' 2>/dev/null || true

    # Post alice APPROVED decision
    jwz topic new "alice:status:$SESSION" 2>/dev/null || true
    jwz post "alice:status:$SESSION" -m '{"decision": "APPROVED", "summary": "Work complete"}' 2>/dev/null || true

    test_case "Alice APPROVED allows exit" "approve" '{
      "session_id": "'"$SESSION"'",
      "cwd": "'"$JWZ_APPROVE_DIR"'",
      "stop_hook_active": false
    }'
else
    echo "⊘ Skipping jwz tests (jwz not available)"
fi

# ============================================================================
# TEST 6: No alice approval → always block (no loop prevention escape hatch)
# ============================================================================
echo ""
echo "--- Test 6: No approval = block (simple rule) ---"

if command -v jwz &>/dev/null; then
    JWZ_PENDING_DIR="$TEMP_DIR/jwz-pending"
    mkdir -p "$JWZ_PENDING_DIR"
    cd "$JWZ_PENDING_DIR"
    jwz init 2>/dev/null || true

    SESSION="test-pending"

    # Enable review but NO alice approval
    jwz topic new "review:state:$SESSION" 2>/dev/null || true
    jwz post "review:state:$SESSION" -m '{"enabled": true, "timestamp": "2024-01-01T00:00:00Z"}' 2>/dev/null || true

    # alice topic exists but has PENDING (not APPROVED)
    jwz topic new "alice:status:$SESSION" 2>/dev/null || true
    jwz post "alice:status:$SESSION" -m '{"decision": "PENDING", "summary": "Waiting for review"}' 2>/dev/null || true

    # PENDING always blocks - no escape hatch
    test_case "PENDING blocks (alice must approve)" "block" '{
      "session_id": "'"$SESSION"'",
      "cwd": "'"$JWZ_PENDING_DIR"'",
      "stop_hook_active": false
    }'
else
    echo "⊘ Skipping jwz tests (jwz not available)"
fi

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo "=== Test Summary ==="
echo "Passed: $pass"
echo "Failed: $fail"
echo ""

if [[ $fail -gt 0 ]]; then
    echo "Some tests failed."
    exit 1
else
    echo "All tests passed!"
    exit 0
fi
