# Work Command

Pick up an issue from the tracker and work it to completion.

## Phase 1: Select Issue

1. Run `tissue ready` to see issues with no blockers
2. Pick the highest priority issue (P1 > P2 > P3 > P4 > P5)
3. Run `tissue show <issue-id>` to read full details
4. Run `tissue status <issue-id> in_progress` to claim it

## Phase 2: Implement

1. **Understand** the requirements fully before writing code
2. **Explore** relevant code to understand existing patterns
3. **Plan** your approach
4. **Implement** following project conventions:
   - Look for style guides in `.claude/` or project docs
   - Run `/fmt` before considering work complete
   - Run `/test` to ensure all tests pass
   - Add tests if the change warrants them

## Phase 3: Review Cycle

When you believe the implementation is complete:

1. Run `/fmt` and `/test` one final time
2. Run `/review <issue-id>` to get code review

3. Review the results:
   - If changes requested: Address the feedback and re-run review
   - If LGTM: Proceed to Phase 4

## Phase 4: Complete

1. Close the issue: `tissue status <issue-id> closed`
2. Commit and push:
   ```bash
   git add <modified-files>
   git commit -m "type: description"
   git push
   ```

   Commit types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`

3. Summarize what was accomplished
4. **Stop** - do not automatically pick up another issue

## Rules

- Work **ONE** issue at a time
- **Always** run `/fmt` before completing
- **Always** run `/test` before completing
- **Do not skip the review cycle**. **DO NOT do the review yourself**.
- Review must pass (LGTM) before closing an issue
- If tests fail, investigate and fix the root cause
- If blocked, document the blocker with `tissue comment <issue-id> -m "..."`
