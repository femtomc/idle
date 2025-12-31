---
name: messaging
description: Posts and reads zawinski (jwz) messages for agent coordination, status updates, and context sharing. Use for handoffs between sessions or searching previous findings.
---

# Messaging Skill

Agent-to-agent coordination via [zawinski](https://github.com/femtomc/zawinski) (jwz).

## When to Use

- Communicating status to other agents
- Recording findings for later reference
- Handoff between sessions
- Searching for previous context
- Discovering artifacts from prior work

## Setup

```bash
# Initialize (once per project)
[ ! -d .jwz ] && jwz init
```

## Core Operations

### Post a message
```bash
jwz post "<topic>" -m "<message>"

# With role (for agent identity)
jwz post "<topic>" --role <agent> -m "<message>"
```

### Read a topic
```bash
jwz read "<topic>"

# Limit to recent
jwz read "<topic>" --limit 10
```

### Show thread
```bash
jwz thread "<message-id>"
```

### Reply to message
```bash
jwz reply "<message-id>" -m "<reply>"
```

### Search messages
```bash
jwz search "<query>"

# Search specific topic
jwz search "<query>" --topic "issue:auth-123"
```

## Topic Naming

| Pattern | Purpose | Example |
|---------|---------|---------|
| `project:<name>` | Project-wide | `project:idle` |
| `issue:<id>` | Per-issue discussion | `issue:auth-123` |
| `agent:<name>` | Direct to agent | `agent:alice` |
| `loop:current` | Active loop state | - |
| `loop:anchor` | Recovery after compaction | - |

## Message Format

Structured format for clarity:
```
[agent] ACTION: description
```

### Standard Actions

| Agent | Actions |
|-------|---------|
| **alice** | `ANALYSIS`, `DECISION`, `REVIEW` |
| **loop** | `STARTED`, `COMPLETE`, `STUCK` |

### Examples

```bash
# alice posts analysis
jwz post "issue:auth-123" --role alice \
  -m "[alice] ANALYSIS: auth flow
Status: RESOLVED
Confidence: HIGH
Summary: Race condition in token refresh"

# alice posts review
jwz post "issue:auth-123" --role alice \
  -m "[alice] REVIEW: JWT implementation
Verdict: PASS
Notes: Implementation verified, security good"
```

## Discovery Patterns

```bash
# Find all research artifacts
jwz search "RESEARCH:"

# Find alice's analyses
jwz search "ANALYSIS:" --from alice

# Find artifacts for an issue
jwz read "issue:auth-123" | grep "Path:"

# Find review verdicts
jwz search "REVIEW:" | grep "Verdict:"
```

## Handoff Protocol

When completing significant work:
```bash
jwz post "issue:<id>" --role <agent> \
  -m "[<agent>] COMPLETE: <topic>
Key findings:
- Finding 1
- Finding 2
Artifacts: .claude/plugins/idle/<agent>/<file>.md
Next steps: <what should happen next>"
```

## Loop State Topics

The stop hook uses these topics:

| Topic | Purpose |
|-------|---------|
| `loop:current` | Active loop state (mode, iteration, etc.) |
| `loop:anchor` | Recovery context after compaction |

```bash
# Check current loop state
jwz read "loop:current" | tail -1 | jq .

# Read recovery anchor
jwz read "loop:anchor" | tail -1
```
