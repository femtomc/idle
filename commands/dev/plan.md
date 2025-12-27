---
description: Design discussion or issue tracker curation via planner agent
---

# Plan Command

Invoke the planner agent for design and planning tasks.

## Usage

```
/plan <task>
```

## Examples

```
/plan Break down the authentication feature
/plan Review and curate the backlog
/plan Help decide between REST vs GraphQL
/plan Create issues for the new caching layer
```

## Invocation

```
Task(subagent_type="planner", prompt="$ARGUMENTS")
```

The planner will:
1. Gather context from code and issues
2. Discuss with Codex for diverse perspectives
3. Execute: create issues, set priorities, link dependencies
4. Report what was done
