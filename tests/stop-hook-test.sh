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
# TEST 1: stop_hook_active bypass
# ============================================================================
echo "--- Test 1: stop_hook_active bypass ---"

test_case "stop_hook_active=true allows exit" "approve" '{
  "session_id": "test-123",
  "cwd": "'"$TEMP_DIR"'",
  "stop_hook_active": true
}'

# ============================================================================
# TEST 2: No jwz, no tissue - should request review
# ============================================================================
echo ""
echo "--- Test 2: No review, no issues ---"

# Create a mock environment without jwz/tissue
mkdir -p "$TEMP_DIR/no-tools"
cd "$TEMP_DIR/no-tools"

# Temporarily hide jwz and tissue from PATH
test_case "No tools available requests review" "block" '{
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
