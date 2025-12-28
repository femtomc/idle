# Architecture

trivial is a Claude Code plugin that provides multi-model development agents. This document explains how it works for contributors and advanced users.

## Overview

trivial delegates specialized tasks to different AI models:

```
User → Claude Code → trivial agents/commands
                         ↓
         ┌───────────────┼───────────────┐
         ↓               ↓               ↓
      Haiku          Opus           External
    (fast tasks)   (complex)         Models
                                       ↓
                              ┌────────┴────────┐
                              ↓                 ↓
                           Codex            Gemini
                          (OpenAI)          (Google)
```

- **Haiku agents** (`explorer`, `librarian`): Fast, cheap operations like file search
- **Opus agents** (`oracle`, `reviewer`, `documenter`): Complex reasoning tasks
- **External model integration**: Codex for diverse perspectives, Gemini for writing

## Plugin Configuration

### Directory Structure

```
trivial/
├── .claude-plugin/
│   ├── plugin.json      # Plugin metadata
│   └── marketplace.json # Marketplace listing
├── agents/              # Agent definitions
│   ├── explorer.md
│   ├── librarian.md
│   ├── oracle.md
│   ├── documenter.md
│   └── reviewer.md
├── commands/            # Command definitions
│   ├── dev/
│   │   ├── commit.md
│   │   ├── document.md
│   │   ├── fmt.md
│   │   ├── message.md
│   │   ├── review.md
│   │   ├── test.md
│   │   └── work.md
│   └── loop/
│       ├── cancel-loop.md
│       ├── grind.md
│       ├── issue.md
│       └── loop.md
├── hooks/               # Claude Code hooks
│   ├── hooks.json       # Hook configuration
│   ├── stop-hook.sh     # Loop continuation logic
│   ├── pre-tool-use-hook.sh  # Safety guardrails
│   └── pre-compact-hook.sh   # Recovery anchor
└── docs/
    └── architecture.md
```

### plugin.json

Minimal metadata for the plugin:

```json
{
  "name": "trivial",
  "version": "0.4.0",
  "description": "Multi-model development agents...",
  "author": { "name": "femtomc" }
}
```

## Agent Structure

Agents are markdown files with YAML frontmatter:

```markdown
---
name: agent-name
description: When to use this agent
model: haiku | opus
tools: Comma-separated list of allowed tools
---

# Agent persona and instructions

## Constraints
What the agent MUST NOT do

## Workflow
How the agent operates

## Output Format
Expected response structure
```

### Key Frontmatter Fields

| Field | Description |
|-------|-------------|
| `name` | Agent identifier |
| `description` | Shown in Claude Code's agent picker |
| `model` | `haiku` for fast/cheap, `opus` for complex |
| `tools` | Allowed tools (e.g., `Read, Grep, Glob, Bash`) |

### Agent Patterns

**Read-only agents** (oracle, explorer):
- Cannot write/edit files
- Bash restricted to specific commands only

**Artifact writers** (librarian, documenter):
- Can create/edit files in `.claude/plugins/trivial/` (librarian) or docs (documenter)
- Cannot modify source code

**Reviewer** (reviewer):
- Writes review artifacts to `.claude/plugins/trivial/reviewer/`
- Read-only access to source code


## Command Structure

Commands are markdown files that define slash commands:

```markdown
---
description: What the command does
---

# Command Name

## Usage
How to invoke the command

## Workflow
Step-by-step execution

## Output
Expected completion signals
```

Commands are user-invocable via `/trivial:dev:command` or `/trivial:loop:command`.

## Loop State Management

Loop commands (`/loop`, `/grind`, `/issue`) use a **Stop hook** to intercept Claude's exit and force re-entry until the task is complete.

### How It Works

```
User runs /loop "fix tests"
         ↓
Command posts state to jwz topic "loop:current"
         ↓
Claude works on task, tries to exit
         ↓
Stop hook intercepts exit
         ↓
Hook reads state from jwz, checks for completion signals
         ↓
If <loop-done> found → allow exit
If not found → block exit, re-inject prompt, increment iteration
```

### State Storage via jwz

Loop state is stored as JSON messages in the `loop:current` topic:

```json
{
  "schema": 1,
  "event": "STATE",
  "run_id": "loop-1703123456-12345",
  "updated_at": "2024-12-21T10:30:00Z",
  "stack": [
    {
      "id": "grind-1703123456-12345",
      "mode": "grind",
      "iter": 3,
      "max": 100,
      "prompt_file": "/tmp/trivial-grind-xxx/prompt.txt"
    },
    {
      "id": "issue-auth-123-1703123456",
      "mode": "issue",
      "iter": 2,
      "max": 10,
      "prompt_file": "/tmp/trivial-issue-xxx/prompt.txt",
      "issue_id": "auth-123"
    }
  ]
}
```

Key design choices:
- **Stack model**: Supports nested loops (grind → issue). Top of stack is current loop.
- **`prompt_file`**: Prompts stored in temp files to avoid JSON escaping issues.
- **TTL**: States older than 2 hours are considered stale (prevents zombie loops).
- **Fallback**: If jwz unavailable, falls back to `.claude/trivial-loop.local.md` state file.

### Completion Signals

Commands emit structured signals that the stop hook detects:

- `<loop-done>COMPLETE</loop-done>` - Task finished successfully
- `<loop-done>MAX_ITERATIONS</loop-done>` - Hit iteration limit
- `<loop-done>STUCK</loop-done>` - No progress, needs user input
- `<issue-complete>DONE</issue-complete>` - Single issue finished
- `<grind-done>NO_MORE_ISSUES</grind-done>` - Backlog cleared
- `<grind-done>MAX_ISSUES</grind-done>` - Session limit reached

### Escape Hatches

If you get stuck in an infinite loop:

1. `/cancel-loop` - Graceful cancellation via command
2. `TRIVIAL_LOOP_DISABLE=1 claude` - Environment variable bypass
3. `rm -rf .jwz/` - Manual reset of all messaging state

## Hooks Philosophy

trivial uses a **minimal hooks strategy** to avoid context bloat:

- **Pull over push** - Let Claude fetch state on-demand via jwz/tissue/git
- **Safety over policy** - Hooks prevent damage; commands enforce workflows
- **Pointer over payload** - Emit locations, not full content

### Active Hooks

| Hook | Purpose | Output |
|------|---------|--------|
| **Stop** | Loop continuation | Block + re-inject prompt |
| **PreToolUse** | Safety guardrails | Block only on dangerous ops |
| **PreCompact** | Recovery anchor | Single-line pointer to jwz |

### PreToolUse (Safety)

Blocks destructive Bash commands before execution:

- `git push --force` to main/master
- `git reset --hard`
- `rm -rf /` or home directory
- `drop database` commands

Silent when allowing - no context consumed for safe operations.

### PreCompact (Recovery)

Before context compaction, persists current task state to `loop:anchor` topic:

```json
{
  "goal": "Working on issue: auth-123",
  "mode": "issue",
  "iteration": "3/10",
  "progress": "Recent commits: abc123; def456",
  "next_step": "Continue working on the task"
}
```

Emits single line: `"TRIVIAL: Recovery anchor saved. After compaction: jwz read loop:anchor"`

### Hooks We Don't Use

| Hook | Why Silent |
|------|-----------|
| SessionStart | Claude pulls state on-demand |
| UserPromptSubmit | Belongs in commands, not hooks |
| PostToolUse | Updates go to jwz quietly |
| SubagentStop | Agents produce structured summaries |

## External Model Integration

### Codex (OpenAI)

Used by: `oracle`, `reviewer`

Pattern: Dialogue-based consultation

```bash
codex exec "You are helping with [TASK].

Context: [RELEVANT CODE/PROBLEM]

Question: [SPECIFIC ASK]"
```

Agents iterate with Codex until reaching consensus or identifying clear disagreement.

### Gemini (Google)

Used by: `documenter`

Pattern: Director-writer relationship

```bash
gemini "You are writing documentation.

TASK: [WHAT TO WRITE]

CONTEXT: [CODE SNIPPETS, ARCHITECTURE]

STRUCTURE: [EXPECTED SECTIONS]"
```

The documenter reviews Gemini's output, sends corrections, and iterates until satisfied.

## Agent Messaging

Agents communicate asynchronously via [zawinski](https://github.com/femtomc/zawinski) (`jwz` CLI), a topic-based messaging CLI.

### Topic Naming Convention

| Pattern | Example | Purpose |
|---------|---------|---------|
| `project:<name>` | `project:trivial` | Project-wide announcements |
| `issue:<id>` | `issue:auth-123` | Per-issue discussion |
| `agent:<name>` | `agent:oracle` | Direct agent communication |

### Commands

```bash
# Initialize (once per project)
jwz init

# Create topic and post
jwz topic new "issue:auth-123"
jwz post "issue:auth-123" -m "[oracle] STARTED: Analyzing auth feature"

# Read and reply
jwz read "issue:auth-123"
jwz reply <msg-id> -m "[oracle] FINDING: Race condition in handler.go:45"

# Search across all messages
jwz search "security"
```

### Message Format

```
[AGENT] ACTION: description

Examples:
[oracle] STARTED: Analyzing auth feature
[oracle] FINDING: Race condition in handler.go:45
[reviewer] BLOCKING: Security issue in token validation
[librarian] RESEARCH: API deprecated in v3
```

### Messaging vs Artifacts

| Use Case | Mechanism | Location |
|----------|-----------|----------|
| Quick status update | Message | `.jwz/` |
| Research finding (quick) | Message | `.jwz/` |
| Research finding (full) | Artifact | `.claude/plugins/trivial/{agent}/` |
| Design decision | Artifact + message | Both |

Messages are ephemeral notes; artifacts are durable references.

## Adding New Agents

1. Create `agents/your-agent.md`
2. Define frontmatter (name, description, model, tools)
3. Write clear constraints (what it MUST NOT do)
4. Define the workflow
5. Specify output format

The agent becomes available automatically as `trivial:your-agent`.

## Adding New Commands

1. Create `commands/category/your-command.md`
2. Add frontmatter with description
3. Document usage and workflow
4. Define completion signals if it's a loop command

The command becomes available as `/trivial:category:your-command`.

## Dependencies

### Required

- [tissue](https://github.com/femtomc/tissue) - Local issue tracker for `/work`, `/grind`, `/issue`
- [zawinski](https://github.com/femtomc/zawinski) - Async messaging for agent communication
- [uv](https://github.com/astral-sh/uv) - Python package runner for `scripts/search.py`
- [gh](https://cli.github.com/) - GitHub CLI for librarian agent

### Optional

- [codex](https://github.com/openai/codex) - OpenAI CLI for oracle/reviewer (falls back to `claude -p`)
- [gemini-cli](https://github.com/google-gemini/gemini-cli) - Google CLI for documenter (falls back to `claude -p`)
