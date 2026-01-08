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
# TEST 1: No jwz store → approve (review was never enabled)
# ============================================================================
echo "--- Test 1: No jwz store (review never enabled) ---"

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

# Review is opt-in via #idle, so without it, exit is allowed
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
# TEST 7: Circuit breaker trips after 3 blocks on same review
# ============================================================================
echo ""
echo "--- Test 7: Circuit breaker trips after repeated blocks ---"

if command -v jwz &>/dev/null; then
    JWZ_CIRCUIT_DIR="$TEMP_DIR/jwz-circuit"
    mkdir -p "$JWZ_CIRCUIT_DIR"
    cd "$JWZ_CIRCUIT_DIR"
    jwz init 2>/dev/null || true

    SESSION="test-circuit-breaker"

    # First, post alice ISSUES and get the auto-generated ID
    jwz topic new "alice:status:$SESSION" 2>/dev/null || true
    jwz post "alice:status:$SESSION" -m '{"decision": "ISSUES", "summary": "Test issue"}' 2>/dev/null || true
    REVIEW_ID=$(jwz read "alice:status:$SESSION" --json 2>/dev/null | jq -r '.[0].id // ""')

    if [[ -n "$REVIEW_ID" ]]; then
        # Set up state showing we've already blocked twice on this review ID
        # Use jq to properly construct JSON with variable expansion
        STATE_MSG=$(jq -n --arg id "$REVIEW_ID" '{enabled: true, timestamp: "2024-01-01T00:00:00Z", last_blocked_review_id: $id, block_count: 2}')
        jwz topic new "review:state:$SESSION" 2>/dev/null || true
        jwz post "review:state:$SESSION" -m "$STATE_MSG" 2>/dev/null || true

        # Third block on same review should trip circuit breaker and approve
        test_case "Circuit breaker trips after 3 blocks" "approve" '{
          "session_id": "'"$SESSION"'",
          "cwd": "'"$JWZ_CIRCUIT_DIR"'",
          "stop_hook_active": false
        }'

        # Verify warning was posted (need to cd back to circuit dir for store access)
        cd "$JWZ_CIRCUIT_DIR"
        WARNINGS=$(jwz read "idle:warnings:$SESSION" --json 2>/dev/null | jq -r '.[0].body // ""' || echo "")
        if echo "$WARNINGS" | grep -q "Circuit breaker"; then
            echo "✓ Circuit breaker warning was posted"
            ((pass++)) || true
        else
            echo "✗ Circuit breaker warning not found"
            ((fail++)) || true
        fi
    else
        echo "⊘ Skipping circuit breaker test (couldn't get review ID from jwz)"
    fi
else
    echo "⊘ Skipping jwz tests (jwz not available)"
fi

# ============================================================================
# TEST 8: Circuit breaker trips with empty alice ID
# ============================================================================
echo ""
echo "--- Test 8: Circuit breaker with no alice review ID ---"

if command -v jwz &>/dev/null; then
    JWZ_NOID_DIR="$TEMP_DIR/jwz-noid"
    mkdir -p "$JWZ_NOID_DIR"
    cd "$JWZ_NOID_DIR"
    jwz init 2>/dev/null || true

    SESSION="test-no-id-breaker"

    # Enable review but don't post any alice status (or post without decision)
    STATE_MSG=$(jq -n '{enabled: true, timestamp: "2024-01-01", no_id_block_count: 2}')
    jwz topic new "review:state:$SESSION" 2>/dev/null || true
    jwz post "review:state:$SESSION" -m "$STATE_MSG" 2>/dev/null || true

    # Don't create alice:status topic at all - simulates missing alice review

    # Third block with no ID should trip circuit breaker
    test_case "Circuit breaker trips with no alice ID" "approve" '{
      "session_id": "'"$SESSION"'",
      "cwd": "'"$JWZ_NOID_DIR"'",
      "stop_hook_active": false
    }'
else
    echo "⊘ Skipping jwz tests (jwz not available)"
fi

# ============================================================================
# TEST 9: #idle:stop disables review mode
# ============================================================================
echo ""
echo "--- Test 9: #idle:stop disables review mode ---"

if command -v jwz &>/dev/null; then
    JWZ_STOP_DIR="$TEMP_DIR/jwz-stop"
    mkdir -p "$JWZ_STOP_DIR"
    cd "$JWZ_STOP_DIR"
    jwz init 2>/dev/null || true

    SESSION="test-idle-stop"
    USER_HOOK="$SCRIPT_DIR/../hooks/user-prompt-hook.sh"

    # First enable review
    echo "{\"session_id\": \"$SESSION\", \"cwd\": \"$JWZ_STOP_DIR\", \"prompt\": \"#idle Do something\"}" | bash "$USER_HOOK" >/dev/null 2>&1

    # Verify it's enabled (use tostring to avoid jq's // treating false as falsy)
    ENABLED=$(jwz read "review:state:$SESSION" --json 2>/dev/null | jq -r '.[0].body | fromjson | .enabled | tostring')
    if [[ "$ENABLED" == "true" ]]; then
        echo "✓ Review enabled after #idle"
        ((pass++)) || true
    else
        echo "✗ Review not enabled after #idle (got: $ENABLED)"
        ((fail++)) || true
    fi

    # Now disable with #idle:stop
    echo "{\"session_id\": \"$SESSION\", \"cwd\": \"$JWZ_STOP_DIR\", \"prompt\": \"#idle:stop\"}" | bash "$USER_HOOK" >/dev/null 2>&1

    # Verify it's disabled
    ENABLED=$(jwz read "review:state:$SESSION" --json 2>/dev/null | jq -r '.[0].body | fromjson | .enabled | tostring')
    if [[ "$ENABLED" == "false" ]]; then
        echo "✓ Review disabled after #idle:stop"
        ((pass++)) || true
    else
        echo "✗ Review not disabled after #idle:stop (got: $ENABLED)"
        ((fail++)) || true
    fi

    # Test case-insensitive #IDLE:STOP
    echo "{\"session_id\": \"$SESSION\", \"cwd\": \"$JWZ_STOP_DIR\", \"prompt\": \"#idle enable\"}" | bash "$USER_HOOK" >/dev/null 2>&1
    echo "{\"session_id\": \"$SESSION\", \"cwd\": \"$JWZ_STOP_DIR\", \"prompt\": \"#IDLE:STOP\"}" | bash "$USER_HOOK" >/dev/null 2>&1
    ENABLED=$(jwz read "review:state:$SESSION" --json 2>/dev/null | jq -r '.[0].body | fromjson | .enabled | tostring')
    if [[ "$ENABLED" == "false" ]]; then
        echo "✓ #IDLE:STOP works (case-insensitive)"
        ((pass++)) || true
    else
        echo "✗ #IDLE:STOP not recognized (got: $ENABLED)"
        ((fail++)) || true
    fi
else
    echo "⊘ Skipping jwz tests (jwz not available)"
fi

# ============================================================================
# TEST 10: Session start cleans up stale review state
# ============================================================================
echo ""
echo "--- Test 10: Session start cleans up stale review state ---"

if command -v jwz &>/dev/null; then
    JWZ_CLEANUP_DIR="$TEMP_DIR/jwz-cleanup"
    mkdir -p "$JWZ_CLEANUP_DIR"
    cd "$JWZ_CLEANUP_DIR"
    jwz init 2>/dev/null || true

    SESSION="test-session-cleanup"
    START_HOOK="$SCRIPT_DIR/../hooks/session-start-hook.sh"

    # Simulate stale review state (enabled: true from a previous session)
    jwz topic new "review:state:$SESSION" 2>/dev/null || true
    jwz post "review:state:$SESSION" -m '{"enabled": true, "timestamp": "2024-01-01T00:00:00Z"}' >/dev/null 2>&1

    # Run session start hook
    echo "{\"session_id\": \"$SESSION\", \"cwd\": \"$JWZ_CLEANUP_DIR\"}" | bash "$START_HOOK" >/dev/null 2>&1

    # Verify review state was cleaned up (use tostring to avoid jq's // treating false as falsy)
    ENABLED=$(jwz read "review:state:$SESSION" --json 2>/dev/null | jq -r '.[0].body | fromjson | .enabled | tostring')
    CLEANUP=$(jwz read "review:state:$SESSION" --json 2>/dev/null | jq -r '.[0].body | fromjson | .session_start_cleanup | tostring')

    if [[ "$ENABLED" == "false" && "$CLEANUP" == "true" ]]; then
        echo "✓ Session start cleaned up stale review state"
        ((pass++)) || true
    else
        echo "✗ Stale review state not cleaned up (enabled=$ENABLED, cleanup=$CLEANUP)"
        ((fail++)) || true
    fi
else
    echo "⊘ Skipping jwz tests (jwz not available)"
fi

# ============================================================================
# TEST 11: Compaction does NOT clean up review state
# ============================================================================
echo ""
echo "--- Test 11: Compaction preserves review state ---"

if command -v jwz &>/dev/null; then
    JWZ_COMPACT_DIR="$TEMP_DIR/jwz-compact"
    mkdir -p "$JWZ_COMPACT_DIR"
    cd "$JWZ_COMPACT_DIR"
    jwz init 2>/dev/null || true

    SESSION="test-session-compact"
    START_HOOK="$SCRIPT_DIR/../hooks/session-start-hook.sh"

    # Simulate active review state (enabled: true during conversation)
    jwz topic new "review:state:$SESSION" 2>/dev/null || true
    jwz post "review:state:$SESSION" -m '{"enabled": true, "timestamp": "2024-01-01T00:00:00Z"}' >/dev/null 2>&1

    # Run session start hook with source:"compact" (simulates compaction)
    echo "{\"session_id\": \"$SESSION\", \"cwd\": \"$JWZ_COMPACT_DIR\", \"source\": \"compact\"}" | bash "$START_HOOK" >/dev/null 2>&1

    # Verify review state was NOT cleaned up (should still be enabled: true)
    ENABLED=$(jwz read "review:state:$SESSION" --json 2>/dev/null | jq -r '.[0].body | fromjson | .enabled | tostring')

    if [[ "$ENABLED" == "true" ]]; then
        echo "✓ Compaction preserved review state (enabled=$ENABLED)"
        ((pass++)) || true
    else
        echo "✗ Compaction incorrectly cleaned up review state (enabled=$ENABLED)"
        ((fail++)) || true
    fi
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
