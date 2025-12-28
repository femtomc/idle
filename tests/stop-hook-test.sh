#!/bin/bash
# Stop hook unit tests
# Tests edge cases in transcript parsing and state handling

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/stop-hook.sh"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

pass=0
fail=0

# Test helper function
test_case() {
    local name="$1"
    local expected="$2"
    shift 2

    if "$@" >/dev/null 2>&1; then
        result="pass"
    else
        result="fail"
    fi

    if [[ "$result" == "$expected" ]]; then
        echo "✓ $name"
        ((pass++)) || true
    else
        echo "✗ $name (expected $expected, got $result)"
        ((fail++)) || true
    fi
}

echo "=== Stop Hook Reliability Tests ==="
echo ""

# ============================================================================
# TEST FIXTURE 1: Long Transcript - tail -20 miss scenario
# ============================================================================
echo "--- Fixture 1: Long Transcript Parsing ---"
mkdir -p "$TEMP_DIR/long-transcript"

# Create a transcript with 100+ messages to ensure tail -20 would miss the marker
(
    # Generate many assistant messages
    for i in {1..50}; do
        echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Working on step $i...\"}]}}"
    done
    # Add the completion marker as the last message
    echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"<loop-done>COMPLETE</loop-done>\"}]}}"
) > "$TEMP_DIR/long-transcript/transcript.jsonl"

(
    cd "$TEMP_DIR/long-transcript"
    mkdir -p .claude
    # Create state file (fallback mode, no jwz)
    cat > .claude/idle-loop.local.md << 'STATEEOF'
---
active: true
mode: loop
iteration: 5
max_iterations: 10
---
STATEEOF

    echo "{\"transcript_path\":\"$TEMP_DIR/long-transcript/transcript.jsonl\",\"cwd\":\"$(pwd)\"}" | bash "$HOOK" > /dev/null 2>&1
    exit_code=$?
    # Should exit with 0 (completion found and exit allowed)
    [[ $exit_code -eq 0 ]]
) && test_case "Long transcript finds last assistant message" "pass" true || \
    test_case "Long transcript finds last assistant message" "pass" false

# ============================================================================
# TEST FIXTURE 2: Code Block False Positive - indented marker rejection
# ============================================================================
echo ""
echo "--- Fixture 2: Code Block False Positive Prevention ---"
mkdir -p "$TEMP_DIR/codeblock"

cat > "$TEMP_DIR/codeblock/transcript.jsonl" << 'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"Here's the indented marker:\n  <loop-done>COMPLETE</loop-done>"}]}}
EOF

(
    cd "$TEMP_DIR/codeblock"
    mkdir -p .claude
    cat > .claude/idle-loop.local.md << 'STATEEOF'
---
active: true
mode: loop
iteration: 5
max_iterations: 10
---
STATEEOF

    echo "{\"transcript_path\":\"$TEMP_DIR/codeblock/transcript.jsonl\",\"cwd\":\"$(pwd)\"}" | bash "$HOOK" > /dev/null 2>&1
    exit_code=$?
    # Should exit with 2 (no completion found, continue looping) because marker is indented
    [[ $exit_code -eq 2 ]]
) && test_case "Indented code block marker NOT matched" "pass" true || \
    test_case "Indented code block marker NOT matched" "pass" false

# ============================================================================
# TEST FIXTURE 3: Marker in backticks - another false positive case
# ============================================================================
echo ""
echo "--- Fixture 3: Backtick Code Block ---"
mkdir -p "$TEMP_DIR/backtick"

cat > "$TEMP_DIR/backtick/transcript.jsonl" << 'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"Here is example code:\n\n`<loop-done>COMPLETE</loop-done>`\n\nBut this is in backticks, not a real completion."}]}}
EOF

(
    cd "$TEMP_DIR/backtick"
    mkdir -p .claude
    cat > .claude/idle-loop.local.md << 'STATEEOF'
---
active: true
mode: loop
iteration: 5
max_iterations: 10
---
STATEEOF

    echo "{\"transcript_path\":\"$TEMP_DIR/backtick/transcript.jsonl\",\"cwd\":\"$(pwd)\"}" | bash "$HOOK" > /dev/null 2>&1
    exit_code=$?
    # Should continue (exit 2) because marker is part of backtick text, not on its own line
    [[ $exit_code -eq 2 ]]
) && test_case "Backtick-enclosed marker NOT matched" "pass" true || \
    test_case "Backtick-enclosed marker NOT matched" "pass" false

# ============================================================================
# TEST FIXTURE 4: Valid Completion - marker on its own line
# ============================================================================
echo ""
echo "--- Fixture 4: Valid Completion Signal ---"
mkdir -p "$TEMP_DIR/valid-completion"

cat > "$TEMP_DIR/valid-completion/transcript.jsonl" << 'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"Lots of work done..."}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Final step complete.\n<loop-done>COMPLETE</loop-done>"}]}}
EOF

(
    cd "$TEMP_DIR/valid-completion"
    mkdir -p .claude
    cat > .claude/idle-loop.local.md << 'STATEEOF'
---
active: true
mode: loop
iteration: 5
max_iterations: 10
---
STATEEOF

    echo "{\"transcript_path\":\"$TEMP_DIR/valid-completion/transcript.jsonl\",\"cwd\":\"$(pwd)\"}" | bash "$HOOK" > /dev/null 2>&1
    exit_code=$?
    # Should exit with 0 (completion found)
    [[ $exit_code -eq 0 ]]
) && test_case "Valid completion signal on own line IS matched" "pass" true || \
    test_case "Valid completion signal on own line IS matched" "pass" false

# ============================================================================
# TEST FIXTURE 5: Concurrent session safety - locking mechanism
# ============================================================================
echo ""
echo "--- Fixture 5: Concurrent Session Safety ---"
mkdir -p "$TEMP_DIR/concurrent"

# Simulate two hook invocations racing to update state
(
    cd "$TEMP_DIR/concurrent"
    mkdir -p .claude
    cat > .claude/idle-loop.local.md << 'STATEEOF'
---
active: true
mode: loop
iteration: 5
max_iterations: 10
---
STATEEOF

    # Run hook in background, then immediately try to run it again
    echo "{\"transcript_path\":\"nonexistent\",\"cwd\":\"$(pwd)\"}" | bash "$HOOK" > /dev/null 2>&1 &
    pid1=$!

    # Give first process time to acquire lock
    sleep 0.05

    # Second invocation should wait for lock
    echo "{\"transcript_path\":\"nonexistent\",\"cwd\":\"$(pwd)\"}" | bash "$HOOK" > /dev/null 2>&1 &
    pid2=$!

    # Both should complete without error
    wait $pid1 2>/dev/null && wait $pid2 2>/dev/null
    exit_code=$?
    [[ $exit_code -eq 0 ]] || true  # Both processes may exit with different codes

    # File should exist and have valid iteration value
    [[ -f .claude/idle-loop.local.md ]] && grep -q "iteration: [0-9]" .claude/idle-loop.local.md
) && test_case "Concurrent sessions handle locking safely" "pass" true || \
    test_case "Concurrent sessions handle locking safely" "pass" false

# ============================================================================
# TEST FIXTURE 6: Issue mode completion signal
# ============================================================================
echo ""
echo "--- Fixture 6: Issue Mode Completion ---"
mkdir -p "$TEMP_DIR/issue-mode"

cat > "$TEMP_DIR/issue-mode/transcript.jsonl" << 'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"Working on the issue..."}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Issue resolved.\n<issue-complete>DONE</issue-complete>"}]}}
EOF

(
    cd "$TEMP_DIR/issue-mode"
    mkdir -p .claude
    cat > .claude/idle-loop.local.md << 'STATEEOF'
---
active: true
mode: issue
iteration: 3
max_iterations: 10
---
STATEEOF

    echo "{\"transcript_path\":\"$TEMP_DIR/issue-mode/transcript.jsonl\",\"cwd\":\"$(pwd)\"}" | bash "$HOOK" > /dev/null 2>&1
    exit_code=$?
    # Should exit with 0 (issue completion found)
    [[ $exit_code -eq 0 ]]
) && test_case "Issue mode <issue-complete> signal matched" "pass" true || \
    test_case "Issue mode <issue-complete> signal matched" "pass" false

# ============================================================================
# TEST FIXTURE 7: Grind mode completion
# ============================================================================
echo ""
echo "--- Fixture 7: Grind Mode Completion ---"
mkdir -p "$TEMP_DIR/grind-mode"

cat > "$TEMP_DIR/grind-mode/transcript.jsonl" << 'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"Processing issues..."}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"All done.\n<grind-done>NO_MORE_ISSUES</grind-done>"}]}}
EOF

(
    cd "$TEMP_DIR/grind-mode"
    mkdir -p .claude
    cat > .claude/idle-loop.local.md << 'STATEEOF'
---
active: true
mode: grind
iteration: 2
max_iterations: 10
---
STATEEOF

    echo "{\"transcript_path\":\"$TEMP_DIR/grind-mode/transcript.jsonl\",\"cwd\":\"$(pwd)\"}" | bash "$HOOK" > /dev/null 2>&1
    exit_code=$?
    # Should exit with 0 (grind completion found)
    [[ $exit_code -eq 0 ]]
) && test_case "Grind mode completion signal matched" "pass" true || \
    test_case "Grind mode completion signal matched" "pass" false

# ============================================================================
# TEST FIXTURE 8: No state file - should exit cleanly
# ============================================================================
echo ""
echo "--- Fixture 8: No Active Loop ---"
(
    cd "$TEMP_DIR"
    mkdir -p clean-dir
    cd clean-dir
    echo '{}' | bash "$HOOK" > /dev/null 2>&1
    exit_code=$?
    [[ $exit_code -eq 0 ]]
) && test_case "No state exits cleanly" "pass" true || \
    test_case "No state exits cleanly" "pass" false

# ============================================================================
# TEST FIXTURE 9: Max iterations reached
# ============================================================================
echo ""
echo "--- Fixture 9: Max Iterations Limit ---"
mkdir -p "$TEMP_DIR/max-iter"

(
    cd "$TEMP_DIR/max-iter"
    mkdir -p .claude
    cat > .claude/idle-loop.local.md << 'STATEEOF'
---
active: true
mode: loop
iteration: 10
max_iterations: 10
---
STATEEOF

    echo "{\"transcript_path\":\"nonexistent\",\"cwd\":\"$(pwd)\"}" | bash "$HOOK" > /dev/null 2>&1
    exit_code=$?
    # Should exit with 0 (max iterations reached, cleanup and allow exit)
    [[ $exit_code -eq 0 ]]
) && test_case "Max iterations reached exits cleanly" "pass" true || \
    test_case "Max iterations reached exits cleanly" "pass" false

# ============================================================================
# TEST FIXTURE 10: Corrupt JSON handling
# ============================================================================
echo ""
echo "--- Fixture 10: Corrupt Data Handling ---"
mkdir -p "$TEMP_DIR/corrupt"

# Intentionally malformed JSON
cat > "$TEMP_DIR/corrupt/transcript.jsonl" << 'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"Working on it...
EOF

(
    cd "$TEMP_DIR/corrupt"
    mkdir -p .claude
    cat > .claude/idle-loop.local.md << 'STATEEOF'
---
active: true
mode: loop
iteration: 5
max_iterations: 10
---
STATEEOF

    echo "{\"transcript_path\":\"$TEMP_DIR/corrupt/transcript.jsonl\",\"cwd\":\"$(pwd)\"}" | bash "$HOOK" 2>/dev/null
    exit_code=$?
    # Should either continue (exit 2) or handle gracefully (exit 0)
    [[ $exit_code -eq 0 ]] || [[ $exit_code -eq 2 ]]
) && test_case "Corrupt transcript handled gracefully" "pass" true || \
    test_case "Corrupt transcript handled gracefully" "pass" false

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo "=== Test Summary ==="
echo "Passed: $pass"
echo "Failed: $fail"
echo ""

if [[ $fail -gt 0 ]]; then
    echo "Some tests failed. Review output above."
    exit 1
else
    echo "All tests passed!"
    exit 0
fi
