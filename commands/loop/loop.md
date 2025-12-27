---
description: Start an iterative task loop that continues until completion
---

# Loop Command

You are entering an iterative development loop. Your task:

$ARGUMENTS

## Rules

1. Work on the task incrementally
2. Run `/test` after each significant change
3. When you believe the task is complete, output: `<loop-done>COMPLETE</loop-done>`
4. If tests fail, analyze the failure and fix it
5. Check your git history (`git log --oneline -5`) to see what you've already tried

## Iteration Context

Look at your previous work:
- Check modified files: `git status`
- Review recent commits: `git log --oneline -10`
- See test output from previous runs

Keep iterating until success. Do not give up.
