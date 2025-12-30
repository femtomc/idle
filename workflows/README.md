# Workflows

Workflows define **choreography** - the sequence of steps and roles needed to accomplish a task.

## Three-Layer Architecture

```
Skills (domain specs)     Workflows (choreography)     Agents (primitives)
       │                          │                          │
       ▼                          ▼                          ▼
   rubrics                   role: orchestrator    →    bob (decompose/synthesize)
   constraints               role: worker          →    charlie (execute)
   output schemas            role: reviewer        →    alice (review)
```

Workflows use **abstract roles**, not agent names. The harness binds roles to agents at runtime.

## Skill Categories

| Category | Skills | Agent References |
|----------|--------|------------------|
| **Domain skills** | researching, technical-writing, bib-managing | None - purely declarative |
| **Integration skills** | messaging, querying-codex, querying-gemini | May reference agents (describes protocols) |
| **Infrastructure skills** | issue-tracking | None - purely declarative |

Domain skills define **what** (quality rubrics, constraints). Integration skills define **how agents communicate**.

## Role Bindings

| Role | Agent | Responsibility |
|------|-------|----------------|
| `orchestrator` | bob | Decompose tasks, spawn workers, synthesize results |
| `worker` | charlie | Execute focused tasks, post results to jwz |
| `reviewer` | alice | Review artifacts against domain rubrics |

## Workflow Structure

```yaml
name: <workflow-name>
skill: <skill-name>           # Domain context injected from skill
description: <what this does>

phases:
  - name: <phase-name>
    role: orchestrator | worker | reviewer
    action: <what to do>
    inputs: [...]
    outputs: [...]
    parallel: true            # Optional: fan out
    fanout: from_subtasks     # Optional: how to parallelize
    iterate_on_revise: true   # Optional: retry on REVISE
    max_iterations: 1         # Optional: iteration bound

stop_conditions:
  - <condition>

artifact_path: <where output goes>
```

## Available Workflows

| Workflow | Skill | Pattern |
|----------|-------|---------|
| `research.yaml` | researching | decompose → parallel workers → synthesize → review |
| `technical-writing.yaml` | technical-writing | draft → structure review → clarity review → evidence review |
| `bibliography.yaml` | bib-managing | multiple operations (add, validate, curate, clean) |

## Context Flow

1. Harness reads workflow YAML
2. Harness reads skill spec from `skill:` field
3. For each phase, harness:
   - Binds role to agent (orchestrator → bob, etc.)
   - Injects skill context via `--append-system-prompt`
   - Executes agent with phase instructions
   - Collects outputs, passes to next phase
