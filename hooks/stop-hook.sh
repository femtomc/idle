#!/bin/bash
# idle stop hook - implements self-referential loops via jwz messaging
# Intercepts Claude's exit to force continuation until task complete

set -e

# Lock file for protecting concurrent jwz operations
LOCK_FILE="${TMPDIR:-/tmp}/idle-loop.lock"

# Acquire lock with timeout (10 seconds)
acquire_lock() {
    local max_wait=100
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        if mkdir "$LOCK_FILE" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    return 1  # Failed to acquire lock
}

# Release lock
release_lock() {
    rmdir "$LOCK_FILE" 2>/dev/null || true
}

# Ensure lock is released on any exit (signal or script failure)
trap 'release_lock' EXIT


# Helper function to emit trace events
emit_trace_event() {
    [[ "${IDLE_TRACE:-}" != "1" ]] && return
    local event="$1"
    local details="${2:-{}}"
    local event_id="${RUN_ID:-unknown-$$}-${event}-${ITERATION:-0}"
    local ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    if ! command -v jwz >/dev/null 2>&1; then
        return
    fi

    # Create topic if it doesn't exist
    jwz topic new "loop:trace" 2>/dev/null || true

    # Build and emit event JSON
    local event_json="{\"event_id\":\"$event_id\",\"ts\":\"$ts\",\"run_id\":\"${RUN_ID:-}\",\"loop_kind\":\"${MODE:-}\",\"event\":\"$event\",\"iteration\":${ITERATION:-0},\"max\":${MAX_ITERATIONS:-0},\"details\":$details}"
    jwz post "loop:trace" -m "$event_json" 2>/dev/null || true
}

# Read hook input from stdin
INPUT=$(cat)

# Extract session info
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Change to project directory
if [[ -n "$CWD" ]]; then
    cd "$CWD"
fi

# Environment variable escape hatch
if [[ "${IDLE_LOOP_DISABLE:-}" == "1" ]]; then
    exit 0
fi

# State file fallback location
STATE_FILE=".claude/idle-loop.local.md"

# Try to read loop state from jwz first
STATE=""
if command -v jwz >/dev/null 2>&1 && [[ -d .jwz ]]; then
    # Acquire lock before reading jwz state
    if acquire_lock; then
        # Get the latest message from loop:current topic
        STATE=$(jwz read "loop:current" 2>/dev/null | tail -1 || true)
        release_lock
    else
        # Lock acquisition failed - wait briefly and try fallback
        echo "Warning: Could not acquire lock on jwz state, using fallback" >&2
    fi
fi

# Parse state (either from jwz JSON or fallback to state file)
if [[ -n "$STATE" ]] && echo "$STATE" | jq -e '.schema' >/dev/null 2>&1; then
    # jwz JSON state
    STACK_LEN=$(echo "$STATE" | jq -r '.stack | length')

    if [[ "$STACK_LEN" == "0" ]] || [[ -z "$STACK_LEN" ]]; then
        # No active loop
        exit 0
    fi

    # Check for ABORT event
    EVENT=$(echo "$STATE" | jq -r '.event // "STATE"')
    if [[ "$EVENT" == "ABORT" ]]; then
        exit 0
    fi

    # Check staleness (2 hour TTL) - use UTC for both timestamps
    UPDATED_AT=$(echo "$STATE" | jq -r '.updated_at // empty')
    if [[ -n "$UPDATED_AT" ]]; then
        UPDATED_TS=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${UPDATED_AT%Z}" +%s 2>/dev/null || \
                     date -u -d "$UPDATED_AT" +%s 2>/dev/null || echo 0)
        NOW_TS=$(date -u +%s)
        AGE=$((NOW_TS - UPDATED_TS))
        if [[ $AGE -gt 7200 ]]; then
            echo "Warning: Loop state is stale ($AGE seconds old), allowing exit" >&2
            emit_trace_event "STALENESS" "{\"age\":$AGE}"
            exit 0
        fi
    fi

    # Get top of stack (current loop frame)
    TOP=$(echo "$STATE" | jq -r '.stack[-1]')
    MODE=$(echo "$TOP" | jq -r '.mode')
    ITERATION=$(echo "$TOP" | jq -r '.iter')
    MAX_ITERATIONS=$(echo "$TOP" | jq -r '.max')
    PROMPT_FILE=$(echo "$TOP" | jq -r '.prompt_file // empty')
    RUN_ID=$(echo "$STATE" | jq -r '.run_id')

    # Worktree context (for issue mode)
    WORKTREE_PATH=$(echo "$TOP" | jq -r '.worktree_path // empty')
    BRANCH=$(echo "$TOP" | jq -r '.branch // empty')
    ISSUE_ID=$(echo "$TOP" | jq -r '.issue_id // empty')

    USE_JWZ=true

    # Emit LOOP_START on first iteration
    if [[ "$ITERATION" -eq 0 ]]; then
        emit_trace_event "LOOP_START"
    fi
else
    # Fallback to state file
    if [[ ! -f "$STATE_FILE" ]]; then
        exit 0
    fi

    # Parse YAML frontmatter
    parse_yaml_value() {
        local key="$1"
        sed -n '/^---$/,/^---$/p' "$STATE_FILE" | grep "^${key}:" | sed "s/^${key}: *//"
    }

    ACTIVE=$(parse_yaml_value "active")
    if [[ "$ACTIVE" != "true" ]]; then
        rm -f "$STATE_FILE"
        exit 0
    fi

    MODE=$(parse_yaml_value "mode")
    ITERATION=$(parse_yaml_value "iteration")
    MAX_ITERATIONS=$(parse_yaml_value "max_iterations")
    PROMPT_FILE=""

    USE_JWZ=false

    # Emit LOOP_START on first iteration (fallback path)
    if [[ "$ITERATION" -eq 0 ]]; then
        emit_trace_event "LOOP_START"
    fi
fi

# Validate numeric values
if ! [[ "$ITERATION" =~ ^[0-9]+$ ]] || ! [[ "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
    echo "Warning: Corrupted loop state, cleaning up" >&2
    emit_trace_event "ABORT" "{\"reason\":\"corrupted_state\"}"
    if [[ "$USE_JWZ" == "true" ]]; then
        # Acquire lock before writing state
        if acquire_lock; then
            jwz post "loop:current" -m '{"schema":1,"event":"ABORT","stack":[]}'
            release_lock
        fi
    else
        rm -f "$STATE_FILE"
    fi
    exit 0
fi

# Check if max iterations reached
if [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
    emit_trace_event "MAX_ITERATIONS"
    if [[ "$USE_JWZ" == "true" ]]; then
        # Acquire lock before writing state
        if acquire_lock; then
            jwz post "loop:current" -m '{"schema":1,"event":"DONE","reason":"MAX_ITERATIONS","stack":[]}'
            release_lock
        fi
    else
        rm -f "$STATE_FILE"
    fi
    exit 0
fi

# Read transcript and check for completion signals
COMPLETION_FOUND=false
COMPLETION_REASON=""

if [[ -n "$TRANSCRIPT_PATH" ]] && [[ -f "$TRANSCRIPT_PATH" ]]; then
    # Get last assistant message using slurp mode to handle long transcripts
    # Load entire file at once and find the last assistant message reliably
    LAST_MESSAGE=$(jq -r -Rs 'split("\n") | .[] | select(length > 0) | fromjson? | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' "$TRANSCRIPT_PATH" 2>/dev/null | tail -1 || true)

    # Check for completion signals based on mode
    # Only match completion markers at the start of a line (not indented or in code blocks)
    # Use grep with ^ anchor to reject indented markers in code blocks
    # Unified signal: <loop-done>COMPLETE|MAX_ITERATIONS|STUCK</loop-done>
    case "$MODE" in
        task|loop)  # "loop" is legacy, "task" is new
            if printf '%s' "$LAST_MESSAGE" | grep -qE '^<loop-done>COMPLETE</loop-done>$'; then
                COMPLETION_FOUND=true
                COMPLETION_REASON="COMPLETE"
            elif printf '%s' "$LAST_MESSAGE" | grep -qE '^<loop-done>MAX_ITERATIONS</loop-done>$'; then
                COMPLETION_FOUND=true
                COMPLETION_REASON="MAX_ITERATIONS"
            elif printf '%s' "$LAST_MESSAGE" | grep -qE '^<loop-done>STUCK</loop-done>$'; then
                COMPLETION_FOUND=true
                COMPLETION_REASON="STUCK"
            fi
            ;;
        issue)
            if printf '%s' "$LAST_MESSAGE" | grep -qE '^<loop-done>COMPLETE</loop-done>$'; then
                COMPLETION_FOUND=true
                COMPLETION_REASON="COMPLETE"
            elif printf '%s' "$LAST_MESSAGE" | grep -qE '^<loop-done>MAX_ITERATIONS</loop-done>$'; then
                COMPLETION_FOUND=true
                COMPLETION_REASON="MAX_ITERATIONS"
            elif printf '%s' "$LAST_MESSAGE" | grep -qE '^<loop-done>STUCK</loop-done>$'; then
                COMPLETION_FOUND=true
                COMPLETION_REASON="STUCK"
            fi
            ;;
    esac
fi

# If completion signal found, verify review requirements before allowing exit
if [[ "$COMPLETION_FOUND" == "true" ]]; then
    # REVIEW GATE: For issue mode with COMPLETE, verify review was done
    # Read review status from jwz messages on the issue topic
    REVIEW_REQUIRED=false
    REVIEW_PASSED=true
    REVIEW_ESCALATE=false

    if [[ "$USE_JWZ" == "true" ]] && [[ "$COMPLETION_REASON" == "COMPLETE" ]] && [[ -n "$ISSUE_ID" ]] && [[ -n "$WORKTREE_PATH" ]] && [[ -d "$WORKTREE_PATH" ]]; then
        REVIEW_REQUIRED=true

        # Get current HEAD
        CURRENT_SHA=$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || echo "")
        if [[ -z "$CURRENT_SHA" ]]; then
            REVIEW_PASSED=false
            REVIEW_BLOCK_REASON="Cannot determine HEAD in worktree. Check worktree state."
        fi

        # Check for uncommitted changes
        HAS_CHANGES=false
        if ! git -C "$WORKTREE_PATH" diff --quiet 2>/dev/null || \
           ! git -C "$WORKTREE_PATH" diff --cached --quiet 2>/dev/null; then
            HAS_CHANGES=true
        fi

        if [[ -n "$CURRENT_SHA" ]]; then
            if [[ "$HAS_CHANGES" == "true" ]]; then
                REVIEW_PASSED=false
                REVIEW_BLOCK_REASON="Uncommitted changes exist. Commit and run /review before completing."
            else
                # Read review status from jwz messages
                # Look for latest [review] message on issue topic
                REVIEW_MESSAGES=$(jwz read "issue:$ISSUE_ID" 2>/dev/null | grep '\[review\]' || true)
                LATEST_REVIEW=$(echo "$REVIEW_MESSAGES" | tail -1)

                if [[ -z "$LATEST_REVIEW" ]]; then
                    REVIEW_PASSED=false
                    REVIEW_BLOCK_REASON="Code has not been reviewed. Run /review before completing."
                else
                    # Parse review verdict and SHA from message
                    # Format: [review] LGTM sha:abc123 or [review] CHANGES_REQUESTED sha:abc123
                    REVIEW_STATUS=$(echo "$LATEST_REVIEW" | grep -oE '\[review\] (LGTM|CHANGES_REQUESTED)' | awk '{print $2}')
                    REVIEW_SHA=$(echo "$LATEST_REVIEW" | grep -oE 'sha:[a-f0-9]+' | cut -d: -f2)

                    # Count review iterations
                    REVIEW_ITER=$(echo "$REVIEW_MESSAGES" | wc -l | tr -d ' ')

                    if [[ -z "$REVIEW_SHA" ]] || [[ "$CURRENT_SHA" != "$REVIEW_SHA"* ]]; then
                        # Commits after review
                        REVIEW_PASSED=false
                        REVIEW_BLOCK_REASON="Commits made after last review. Run /review before completing."
                    elif [[ "$REVIEW_STATUS" == "LGTM" ]]; then
                        REVIEW_PASSED=true
                    elif [[ "$REVIEW_STATUS" == "CHANGES_REQUESTED" ]]; then
                        if [[ "$REVIEW_ITER" -ge 3 ]]; then
                            REVIEW_PASSED=true
                            REVIEW_ESCALATE=true
                        else
                            REVIEW_PASSED=false
                            REVIEW_BLOCK_REASON="Last review requested changes. Address feedback and run /review again. (Review iteration $REVIEW_ITER/3)"
                        fi
                    else
                        REVIEW_PASSED=false
                        REVIEW_BLOCK_REASON="Review status unclear. Run /review to get explicit LGTM."
                    fi
                fi
            fi
        fi
    fi

    # Check for escalation (review limit exceeded, must create follow-up issues)
    if [[ "${REVIEW_ESCALATE:-false}" == "true" ]]; then
        emit_trace_event "REVIEW_ESCALATE" "{\"review_iter\":$REVIEW_ITER}"
        # Allow completion but inject guidance about follow-up issues
        # The grind.md documentation specifies creating issues tagged review-followup
    fi

    # If review gate fails, reject completion and continue loop
    if [[ "$REVIEW_REQUIRED" == "true" ]] && [[ "$REVIEW_PASSED" != "true" ]]; then
        # Escape reason for JSON trace event using jq's @json for proper escaping
        ESCAPED_BLOCK_REASON=$(printf '%s' "$REVIEW_BLOCK_REASON" | jq -Rs '@json')
        emit_trace_event "REVIEW_GATE_BLOCKED" "{\"reason\":$ESCAPED_BLOCK_REASON}"

        # Continue the loop instead of allowing exit
        NEW_ITERATION=$((ITERATION + 1))
        NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        if [[ "$USE_JWZ" == "true" ]]; then
            if acquire_lock; then
                NEW_STACK=$(echo "$STATE" | jq --argjson iter "$NEW_ITERATION" '.stack[-1].iter = $iter')
                jwz post "loop:current" -m "{\"schema\":1,\"event\":\"STATE\",\"run_id\":\"$RUN_ID\",\"updated_at\":\"$NOW\",\"stack\":$(echo "$NEW_STACK" | jq -c '.stack')}"
                release_lock
            fi
        else
            # Fallback path: update state file iteration
            TEMP_FILE=$(mktemp)
            sed "s/^iteration: .*/iteration: $NEW_ITERATION/" "$STATE_FILE" > "$TEMP_FILE"
            mv "$TEMP_FILE" "$STATE_FILE"
        fi

        # Build rejection message with inline worktree context
        GATE_WORKTREE_CTX=""
        if [[ -n "$WORKTREE_PATH" ]]; then
            GATE_WORKTREE_CTX="

WORKTREE: $WORKTREE_PATH
BRANCH: $BRANCH
ISSUE: $ISSUE_ID"
        fi

        REASON="[REVIEW GATE] Completion rejected. $REVIEW_BLOCK_REASON

ITERATION $NEW_ITERATION/$MAX_ITERATIONS - You must complete review before marking done.

Workflow:
1. Commit all changes
2. Run /review
3. If CHANGES_REQUESTED: fix issues, commit, run /review again
4. When LGTM: then emit completion signal$GATE_WORKTREE_CTX"

        ESCAPED_REASON=$(printf '%s' "$REASON" | jq -Rs '.')
        cat <<EOF
{
  "decision": "block",
  "reason": $ESCAPED_REASON
}
EOF
        exit 2
    fi

    emit_trace_event "COMPLETION" "{\"reason\":\"$COMPLETION_REASON\"}"

    # AUTO-LAND for issue mode with COMPLETE
    AUTO_LAND_SUCCESS=false
    if [[ "$MODE" == "issue" ]] && [[ "$COMPLETION_REASON" == "COMPLETE" ]] && [[ -n "$WORKTREE_PATH" ]] && [[ -d "$WORKTREE_PATH" ]]; then
        emit_trace_event "AUTO_LAND_START" "{\"issue_id\":\"$ISSUE_ID\",\"branch\":\"$BRANCH\"}"

        # Derive main repo root from worktree path (worktrees are at REPO/.worktrees/idle/ID)
        # WORKTREE_PATH format: /path/to/repo/.worktrees/idle/<issue-id>
        MAIN_REPO=$(echo "$WORKTREE_PATH" | sed 's|/\.worktrees/idle/[^/]*$||')
        BASE_REF=$(echo "$TOP" | jq -r '.base_ref // "main"')

        if [[ -n "$MAIN_REPO" ]] && [[ -d "$MAIN_REPO/.git" ]]; then
            # Verify worktree is clean
            if git -C "$WORKTREE_PATH" diff --quiet 2>/dev/null && \
               git -C "$WORKTREE_PATH" diff --cached --quiet 2>/dev/null; then

                # Fetch from main repo and update local BASE_REF
                git -C "$MAIN_REPO" fetch origin 2>/dev/null || true

                # Check if main repo has uncommitted changes
                STASH_CREATED=false
                STASH_REF=""
                if ! git -C "$MAIN_REPO" diff --quiet 2>/dev/null || \
                   ! git -C "$MAIN_REPO" diff --cached --quiet 2>/dev/null; then
                    # Count stashes before push (locale-independent detection)
                    STASH_COUNT_BEFORE=$(git -C "$MAIN_REPO" stash list 2>/dev/null | wc -l | tr -d ' ')
                    git -C "$MAIN_REPO" stash push -m "idle-auto-land-$$" 2>/dev/null || true
                    STASH_COUNT_AFTER=$(git -C "$MAIN_REPO" stash list 2>/dev/null | wc -l | tr -d ' ')
                    if [[ "$STASH_COUNT_AFTER" -gt "$STASH_COUNT_BEFORE" ]]; then
                        STASH_CREATED=true
                        STASH_REF="stash@{0}"
                    fi
                fi

                # Verify branch can fast-forward into BASE_REF
                # First, update local BASE_REF to match origin
                CURRENT_BASE=$(git -C "$MAIN_REPO" rev-parse "refs/heads/$BASE_REF" 2>/dev/null || echo "")
                ORIGIN_BASE=$(git -C "$MAIN_REPO" rev-parse "refs/remotes/origin/$BASE_REF" 2>/dev/null || echo "")
                BRANCH_TIP=$(git -C "$MAIN_REPO" rev-parse "refs/heads/$BRANCH" 2>/dev/null || echo "")

                if [[ -z "$BRANCH_TIP" ]]; then
                    emit_trace_event "AUTO_LAND_NO_BRANCH" "{\"issue_id\":\"$ISSUE_ID\",\"branch\":\"$BRANCH\"}"
                    jwz post "issue:$ISSUE_ID" -m "[loop] AUTO_LAND_FAILED: Branch $BRANCH not found" 2>/dev/null || true
                elif [[ -n "$ORIGIN_BASE" ]] && ! git -C "$MAIN_REPO" merge-base --is-ancestor "$ORIGIN_BASE" "$BRANCH_TIP" 2>/dev/null; then
                    # Branch is not a fast-forward from origin/BASE_REF
                    emit_trace_event "AUTO_LAND_FF_FAILED" "{\"issue_id\":\"$ISSUE_ID\"}"
                    jwz post "issue:$ISSUE_ID" -m "[loop] AUTO_LAND_FAILED: Cannot fast-forward. Rebase onto origin/$BASE_REF needed." 2>/dev/null || true
                else
                    # Update local BASE_REF to origin/BASE_REF first (if behind)
                    if [[ -n "$ORIGIN_BASE" ]] && [[ "$CURRENT_BASE" != "$ORIGIN_BASE" ]]; then
                        git -C "$MAIN_REPO" update-ref "refs/heads/$BASE_REF" "$ORIGIN_BASE" 2>/dev/null || true
                    fi

                    # Now fast-forward BASE_REF to include the branch
                    if git -C "$MAIN_REPO" update-ref "refs/heads/$BASE_REF" "$BRANCH_TIP" 2>/dev/null; then
                        # Push to remote
                        if git -C "$MAIN_REPO" push origin "$BASE_REF" 2>/dev/null; then
                            # Clean up worktree and branch
                            git -C "$MAIN_REPO" worktree remove "$WORKTREE_PATH" 2>/dev/null || true
                            git -C "$MAIN_REPO" branch -d "$BRANCH" 2>/dev/null || true

                            # Update tissue
                            tissue status "$ISSUE_ID" closed 2>/dev/null || true
                            tissue comment "$ISSUE_ID" -m "[loop] Merged to $BASE_REF and cleaned up" 2>/dev/null || true

                            # Post to jwz
                            jwz post "issue:$ISSUE_ID" -m "[loop] LANDED: Merged to $BASE_REF" 2>/dev/null || true
                            jwz post "project:$(basename "$MAIN_REPO")" -m "[loop] Issue $ISSUE_ID landed" 2>/dev/null || true

                            AUTO_LAND_SUCCESS=true
                            emit_trace_event "AUTO_LAND_SUCCESS" "{\"issue_id\":\"$ISSUE_ID\"}"
                        else
                            emit_trace_event "AUTO_LAND_PUSH_FAILED" "{\"issue_id\":\"$ISSUE_ID\"}"
                            jwz post "issue:$ISSUE_ID" -m "[loop] AUTO_LAND_FAILED: Push rejected. Remote may have new commits." 2>/dev/null || true
                        fi
                    else
                        emit_trace_event "AUTO_LAND_UPDATE_REF_FAILED" "{\"issue_id\":\"$ISSUE_ID\"}"
                    fi
                fi

                # Restore stashed changes if we created a stash
                if [[ "$STASH_CREATED" == "true" ]] && [[ -n "$STASH_REF" ]]; then
                    git -C "$MAIN_REPO" stash pop "$STASH_REF" 2>/dev/null || true
                fi
            else
                emit_trace_event "AUTO_LAND_DIRTY" "{\"issue_id\":\"$ISSUE_ID\"}"
                jwz post "issue:$ISSUE_ID" -m "[loop] AUTO_LAND_FAILED: Worktree has uncommitted changes" 2>/dev/null || true
            fi
        fi
    fi

    # PICK-NEXT-ISSUE for issue mode after successful landing
    NEXT_ISSUE_FOUND=false
    if [[ "$MODE" == "issue" ]] && [[ "$AUTO_LAND_SUCCESS" == "true" ]]; then
        # Check for next ready issue
        NEXT_ISSUE_ID=$(tissue ready --format=id 2>/dev/null | head -1 || true)

        if [[ -n "$NEXT_ISSUE_ID" ]]; then
            emit_trace_event "PICK_NEXT_ISSUE" "{\"next_issue_id\":\"$NEXT_ISSUE_ID\"}"
            NEXT_ISSUE_FOUND=true

            # Set up next issue (similar to loop.md setup)
            REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
            NEW_RUN_ID="loop-$(date +%s)-$$"

            # Resolve base ref
            BASE_REF=$(git config idle.baseRef 2>/dev/null || true)
            if [[ -z "$BASE_REF" ]]; then
                BASE_REF=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || true)
            fi
            if [[ -z "$BASE_REF" ]] && git show-ref --verify refs/heads/main >/dev/null 2>&1; then
                BASE_REF="main"
            fi
            if [[ -z "$BASE_REF" ]] && git show-ref --verify refs/heads/master >/dev/null 2>&1; then
                BASE_REF="master"
            fi
            if [[ -z "$BASE_REF" ]]; then
                BASE_REF="HEAD"
            fi

            # Create worktree for next issue
            SAFE_ID=$(printf '%s' "$NEXT_ISSUE_ID" | tr -cd 'a-zA-Z0-9_-')
            NEW_BRANCH="idle/issue/$SAFE_ID"
            NEW_WORKTREE_PATH="$REPO_ROOT/.worktrees/idle/$SAFE_ID"

            if git worktree list | grep -qF "$NEW_WORKTREE_PATH"; then
                # Reuse existing
                true
            else
                mkdir -p "$(dirname "$NEW_WORKTREE_PATH")"
                git worktree add -b "$NEW_BRANCH" "$NEW_WORKTREE_PATH" "$BASE_REF" 2>/dev/null || \
                git worktree add "$NEW_WORKTREE_PATH" "$NEW_BRANCH" 2>/dev/null || true

                # Initialize submodules
                if [[ -f "$REPO_ROOT/.gitmodules" ]]; then
                    git -C "$NEW_WORKTREE_PATH" submodule update --init --recursive 2>/dev/null || true
                fi
            fi

            # Create prompt from issue
            STATE_DIR="/tmp/idle-$NEW_RUN_ID"
            mkdir -p "$STATE_DIR"
            tissue show "$NEXT_ISSUE_ID" > "$STATE_DIR/prompt.txt" 2>/dev/null || true

            # Update state with new issue frame
            NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            NEW_FRAME=$(jq -n \
                --arg id "$NEW_RUN_ID" \
                --arg issue_id "$NEXT_ISSUE_ID" \
                --arg prompt_file "$STATE_DIR/prompt.txt" \
                --arg worktree_path "$NEW_WORKTREE_PATH" \
                --arg branch "$NEW_BRANCH" \
                --arg base_ref "$BASE_REF" \
                '{
                    id: $id,
                    mode: "issue",
                    iter: 1,
                    max: 10,
                    prompt_file: $prompt_file,
                    issue_id: $issue_id,
                    worktree_path: $worktree_path,
                    branch: $branch,
                    base_ref: $base_ref
                }')

            if acquire_lock; then
                jwz post "loop:current" -m "{\"schema\":1,\"event\":\"STATE\",\"run_id\":\"$NEW_RUN_ID\",\"updated_at\":\"$NOW\",\"stack\":[$NEW_FRAME]}"
                release_lock
            fi

            jwz topic new "issue:$NEXT_ISSUE_ID" 2>/dev/null || true
            jwz post "issue:$NEXT_ISSUE_ID" -m "[loop] STARTED: Working in $NEW_WORKTREE_PATH" 2>/dev/null || true

            # Continue loop with next issue
            NEXT_PROMPT=$(cat "$STATE_DIR/prompt.txt" 2>/dev/null || echo "Work on issue $NEXT_ISSUE_ID")
            REASON="[NEXT ISSUE] Picked $NEXT_ISSUE_ID from tracker. Starting fresh iteration.

WORKTREE: $NEW_WORKTREE_PATH
BRANCH: $NEW_BRANCH
ISSUE: $NEXT_ISSUE_ID

$NEXT_PROMPT"

            ESCAPED_REASON=$(printf '%s' "$REASON" | jq -Rs '.')
            cat <<EOF
{
  "decision": "block",
  "reason": $ESCAPED_REASON
}
EOF
            exit 2
        else
            emit_trace_event "NO_MORE_ISSUES" "{}"
        fi
    fi

    if [[ "$USE_JWZ" == "true" ]]; then
        # Acquire lock before modifying state
        if acquire_lock; then
            # Pop the completed frame from stack
            NEW_STACK=$(echo "$STATE" | jq '.stack[:-1]')
            STACK_LEN=$(echo "$NEW_STACK" | jq 'length')

            if [[ "$STACK_LEN" == "0" ]]; then
                # All loops complete
                jwz post "loop:current" -m "{\"schema\":1,\"event\":\"DONE\",\"reason\":\"$COMPLETION_REASON\",\"stack\":[]}"
            else
                # Pop frame, continue outer loop
                NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
                jwz post "loop:current" -m "{\"schema\":1,\"event\":\"STATE\",\"run_id\":\"$RUN_ID\",\"updated_at\":\"$NOW\",\"stack\":$NEW_STACK}"
            fi
            release_lock
        fi
    else
        rm -f "$STATE_FILE"
    fi
    exit 0
fi

# No completion signal found - continue the loop

# Increment iteration counter
NEW_ITERATION=$((ITERATION + 1))
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if [[ "$USE_JWZ" == "true" ]]; then
    # Acquire lock before updating state
    if acquire_lock; then
        # Update top of stack with new iteration
        NEW_STACK=$(echo "$STATE" | jq --argjson iter "$NEW_ITERATION" '.stack[-1].iter = $iter')
        jwz post "loop:current" -m "{\"schema\":1,\"event\":\"STATE\",\"run_id\":\"$RUN_ID\",\"updated_at\":\"$NOW\",\"stack\":$(echo "$NEW_STACK" | jq -c '.stack')}"
        release_lock
    fi
    emit_trace_event "ITERATION"
else
    # Update state file (atomic via temp + mv)
    TEMP_FILE=$(mktemp)
    sed "s/^iteration: .*/iteration: $NEW_ITERATION/" "$STATE_FILE" > "$TEMP_FILE"
    emit_trace_event "ITERATION"
    mv "$TEMP_FILE" "$STATE_FILE"
fi

# Get original prompt
if [[ -n "$PROMPT_FILE" ]] && [[ -f "$PROMPT_FILE" ]]; then
    ORIGINAL_PROMPT=$(cat "$PROMPT_FILE")
elif [[ "$USE_JWZ" != "true" ]] && [[ -f "$STATE_FILE" ]]; then
    # Extract from state file (everything after second ---)
    ORIGINAL_PROMPT=$(sed -n '/^---$/,/^---$/!p' "$STATE_FILE" | tail -n +1)
else
    ORIGINAL_PROMPT="Continue working on the task."
fi

# Build worktree context if available
WORKTREE_CONTEXT=""
PHASE_CONTEXT=""
if [[ -n "$WORKTREE_PATH" ]] && [[ -d "$WORKTREE_PATH" ]]; then
    WORKTREE_CONTEXT="

WORKTREE CONTEXT:
- Working directory: $WORKTREE_PATH
- Branch: $BRANCH
- Issue: $ISSUE_ID

IMPORTANT: All file operations must use absolute paths under $WORKTREE_PATH
- Read/Write/Edit: Use absolute paths like $WORKTREE_PATH/src/file.py
- Bash commands: Start with cd \"$WORKTREE_PATH\" && ...
- tissue commands: Run from main repo only (not worktree)"

    # Check for uncommitted changes
    HAS_CHANGES=false
    if ! git -C "$WORKTREE_PATH" diff --quiet 2>/dev/null || \
       ! git -C "$WORKTREE_PATH" diff --cached --quiet 2>/dev/null; then
        HAS_CHANGES=true
    fi

    CURRENT_SHA=$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || echo "")

    # Derive phase from jwz review messages
    LAST_REVIEW_SHA=""
    LAST_REVIEW_STATUS=""
    if [[ -n "$ISSUE_ID" ]]; then
        LATEST_REVIEW=$(jwz read "issue:$ISSUE_ID" 2>/dev/null | grep '\[review\]' | tail -1 || true)
        if [[ -n "$LATEST_REVIEW" ]]; then
            LAST_REVIEW_SHA=$(echo "$LATEST_REVIEW" | grep -oE 'sha:[a-f0-9]+' | cut -d: -f2)
            LAST_REVIEW_STATUS=$(echo "$LATEST_REVIEW" | grep -oE '\[review\] (LGTM|CHANGES_REQUESTED)' | awk '{print $2}')
        fi
    fi

    if [[ "$HAS_CHANGES" == "true" ]]; then
        PHASE="implement"
        PHASE_CONTEXT="
PHASE: implement
ACTION: Changes pending. When implementation complete, run /review before marking done."
    elif [[ -z "$LAST_REVIEW_SHA" ]] || [[ "$CURRENT_SHA" != "$LAST_REVIEW_SHA"* ]]; then
        PHASE="review_pending"
        PHASE_CONTEXT="
PHASE: review_pending
ACTION REQUIRED: Run /review before emitting <loop-done>COMPLETE</loop-done>"
    elif [[ "$LAST_REVIEW_STATUS" == "CHANGES_REQUESTED" ]]; then
        PHASE="changes_requested"
        PHASE_CONTEXT="
PHASE: changes_requested
ACTION: Address review feedback, commit changes, then run /review again."
    else
        PHASE="reviewed"
        PHASE_CONTEXT="
PHASE: reviewed
STATUS: Changes reviewed (LGTM). Ready to complete."
    fi

    # Add agent awareness
    PHASE_CONTEXT="$PHASE_CONTEXT

AGENTS: If stuck on a design decision, consult idle:oracle. After changes, use /review."
fi

# Build continuation message
REASON="[ITERATION $NEW_ITERATION/$MAX_ITERATIONS] Continue working on the task. Check your progress and either complete the task or keep iterating.$WORKTREE_CONTEXT$PHASE_CONTEXT"

# Escape for JSON
ESCAPED_REASON=$(printf '%s' "$REASON" | jq -Rs '.')

# Output block decision (exit code 2 = block)
cat <<EOF
{
  "decision": "block",
  "reason": $ESCAPED_REASON
}
EOF

exit 2
