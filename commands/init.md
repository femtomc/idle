---
description: Initialize project with planning workflow
---

# /init

Initialize a project with idle infrastructure and create an actionable plan.

## Workflow

### Step 1: Setup Infrastructure

Initialize the idle infrastructure:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/idle" init-loop
```

This creates `.zawinski/` (messaging) and `.tissue/` (issues) if needed.

### Step 2: Explore the Codebase

Use the Task tool with `subagent_type="Explore"` to understand the project:

- What is this project? What does it do?
- What's the architecture? Key components?
- What technologies/frameworks are used?
- What's the current state? Any obvious issues?

Provide a brief summary of findings.

### Step 3: Plan with the User

Enter plan mode using the `EnterPlanMode` tool. In plan mode:

1. Ask the user what they want to accomplish
2. Research any unclear requirements
3. Draft an implementation plan with:
   - Clear objectives
   - Key milestones
   - Technical approach
   - Risks and considerations
4. Iterate with the user until they approve

Use `AskUserQuestion` to clarify ambiguities.

### Step 4: Alice Review

Once the user approves the plan, invoke Alice for adversarial review:

```
Task tool with subagent_type="idle:alice"
```

Tell Alice:
> Review this implementation plan. Check for:
> - Missing edge cases or error handling
> - Architectural concerns
> - Security considerations
> - Testing strategy gaps
> - Unclear or ambiguous steps
>
> Suggest improvements. Be specific about concerns.

Iterate with Alice until the plan is solid.

### Step 5: Break into Issues

Ask Alice to decompose the approved plan into tissue issues:

> Create tissue issues for each actionable work item in this plan.
>
> For each issue:
> - Clear, specific title
> - Appropriate priority (1-5)
> - Relevant tags (feature, bug, refactor, docs)
> - Dependencies between issues (use `tissue dep add`)
>
> Group related work. Ensure issues are small enough to complete in one session.

Alice should run commands like:
```bash
tissue new "Implement user authentication" -t feature -p 1
tissue new "Add input validation" -t feature -p 2
tissue dep add auth-xxxx blocks validation-yyyy
```

### Step 6: Confirm

Show the user:
1. Summary of the plan
2. List of created issues (`tissue ready`)
3. Suggested starting point

## Example

```
/init

> Setting up infrastructure...
> ✓ jwz initialized
> ✓ tissue initialized

> Exploring codebase...
> This is a web API built with Express.js...

> What would you like to accomplish?
[User describes goals]

> [Planning iteration...]
> [Alice review...]
> [Issue creation...]

> Ready! 12 issues created. Start with:
>   tissue-a3f2  P1  Set up project structure
```

## Notes

- This is an interactive workflow - expect back-and-forth
- The plan should be detailed enough to execute without ambiguity
- Issues should be atomic and testable
- Use `/loop` after init to start working through issues
