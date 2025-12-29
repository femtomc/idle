# Architecture

idle is a Claude Code plugin that provides multi-model development agents. This document explains how it works for contributors and advanced users.

## Overview

idle delegates specialized tasks to different AI models:

```
User → Claude Code → idle agents/skills
                         ↓
         ┌───────────────┴───────────────┐
         ↓                               ↓
      bob (haiku)                   alice (opus)
    (fast research)              (deep reasoning)
                                       ↓
                                    Codex
                                   (OpenAI)
```

- **bob** (haiku): Fast external research with citations
- **alice** (opus): Deep reasoning with multi-model consensus via Codex

## Control-Plane Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                           CONTROL PLANE                              │
│                                                                      │
│   ┌─────────────────────┐        ┌──────────────────────────────┐   │
│   │      PLUGIN         │        │        CONTROLLER            │   │
│   │  (Claude Code)      │        │     (future: idle CLI)       │   │
│   │                     │        │                              │   │
│   │  - Slash commands   │◄──────►│  - idle status               │   │
│   │  - Stop/PreToolUse  │  jwz   │  - idle tui (future)         │   │
│   │    hooks            │        │  - Observability             │   │
│   │  - Agent dispatch   │        │  - External monitoring       │   │
│   └─────────────────────┘        └──────────────────────────────┘   │
│                                                                      │
│                              ▼                                       │
│                           [ jwz ]                                    │
│                     (state + messaging)                              │
└─────────────────────────────────────────────────────────────────────┘
```

The idle architecture is moving towards a hybrid model:

- **Plugin**: Embedded in Claude Code. Provides slash commands (/loop, /cancel), hooks (Stop hook for loop continuation), and agent dispatch.
- **Controller** (future): Separate binary. Provides `idle status` for observability, `idle tui` for interactive control. Reads state from jwz.
- **jwz**: The shared state layer. Both plugin and controller read/write to jwz topics (loop:current, loop:anchor, etc.).
- This separation allows external tools to observe and control loops without being inside Claude Code.

## Plugin Configuration

### Directory Structure

```
idle/
├── .claude-plugin/
│   ├── plugin.json      # Plugin metadata
│   └── marketplace.json # Marketplace listing
├── agents/              # Agent definitions
│   ├── alice.md         # Deep reasoning agent
│   └── bob.md           # Research agent
├── commands/            # Explicit user-invoked commands
│   ├── cancel.md        # Cancel active loop
│   └── loop.md          # Universal loop (task mode + issue mode)
├── skills/              # Auto-discovered capabilities
│   ├── messaging/SKILL.md      # jwz reference
│   ├── issue-tracking/SKILL.md # tissue reference
│   └── researching/SKILL.md    # bob → alice composition
├── hooks/               # Claude Code hooks
│   ├── hooks.json       # Hook configuration
│   ├── stop-hook.sh     # Loop continuation logic
│   ├── pre-tool-use-hook.sh  # Safety guardrails
│   └── pre-compact-hook.sh   # Recovery anchor
└── docs/
    └── architecture.md
```

## Agents

### alice (Deep Reasoning)

- **Model**: opus
- **Tools**: Read, Grep, Glob, Bash (read-only + codex/claude)
- **Role**: Complex reasoning, quality gates, design decisions
- **Second Opinion**: Consults Codex or `claude -p` for diverse perspectives

alice is read-only. She advises but does not modify code. She's called for:
- Architectural decisions
- Tricky bugs
- Quality gate reviews (validating bob's research)
- Design tradeoffs

### bob (Research)

- **Model**: haiku
- **Tools**: WebFetch, WebSearch, Bash, Read, Write
- **Role**: External research with citations
- **Artifacts**: Writes to `.claude/plugins/idle/bob/`

bob researches external code, libraries, and documentation. He produces cited artifacts that alice can validate.

### Agent Patterns

**Read-only agents** (alice):
- Cannot write/edit files
- Bash restricted to specific commands only

**Artifact writers** (bob):
- Can create files in `.claude/plugins/idle/bob/`
- Cannot modify source code

## Skills

Skills are auto-discovered capabilities that provide tool documentation or agent compositions.

### Skill Categories

| Category | Skills | Purpose |
|----------|--------|---------|
| **Tool Docs** | messaging, issue-tracking | Reference for jwz and tissue |
| **Compositions** | researching | Multi-agent workflows |

### Composition Patterns

The `researching` skill demonstrates the **Review-Gate** pattern:

```
bob (research) ──→ alice (quality gate)
                        │
               PASS ────┼──── REVISE
                 │             │
               DONE      bob (fix, 1x max)
                               │
                         alice (final gate)
```

- bob produces research with citations
- alice validates quality (not content - that's bob's job)
- Max 1 revision keeps cost predictable

## Loop State Management

The `/loop` command uses a **Stop hook** to intercept Claude's exit and force re-entry until the task is complete.

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
      "id": "issue-auth-123-1703123456",
      "mode": "issue",
      "iter": 2,
      "max": 10,
      "prompt_file": "/tmp/idle-issue-xxx/prompt.txt",
      "issue_id": "auth-123"
    }
  ]
}
```

### Completion Signals

Commands emit structured signals that the stop hook detects:

- `<loop-done>COMPLETE</loop-done>` - Task finished successfully
- `<loop-done>MAX_ITERATIONS</loop-done>` - Hit iteration limit
- `<loop-done>STUCK</loop-done>` - No progress, needs user input

### Escape Hatches

If you get stuck in an infinite loop:

1. `/cancel` - Graceful cancellation via command
2. `IDLE_LOOP_DISABLE=1 claude` - Environment variable bypass
3. `rm -rf .jwz/` - Manual reset of all messaging state

## Git Worktrees

In issue mode, `/loop` creates a Git worktree for each issue to enable clean isolation.

### Structure

```
main repo/                          .worktrees/idle/
├── src/                            ├── auth-123/     ← issue worktree
├── .tissue/                        │   └── (branch: idle/issue/auth-123)
├── .worktrees/ (gitignored)        └── perf-456/     ← another issue
└── ...                                 └── (branch: idle/issue/perf-456)
```

### Lifecycle

1. **Create** (`/loop` without args):
   - Picks first ready issue from `tissue ready`
   - Creates worktree at `.worktrees/idle/<id>/`
   - Creates branch `idle/issue/<id>` from base ref

2. **Work**:
   - Stop hook injects worktree context on each iteration
   - All file operations use absolute paths under worktree

3. **Complete & Auto-Land**:
   - Agent emits `<loop-done>COMPLETE</loop-done>`
   - Auto-lands: fast-forward merge to main, push, cleanup worktree
   - Picks next issue automatically

## Hooks Philosophy

idle uses a **minimal hooks strategy** to avoid context bloat:

- **Pull over push** - Let Claude fetch state on-demand via jwz/tissue/git
- **Safety over policy** - Hooks prevent damage; commands enforce workflows
- **Pointer over payload** - Emit locations, not full content

### Active Hooks

| Hook | Purpose | Output |
|------|---------|--------|
| **Stop** | Loop continuation | Block + re-inject prompt |
| **PreToolUse** | Safety guardrails | Block only on dangerous ops |
| **PreCompact** | Recovery anchor | Single-line pointer to jwz |
| **SubagentStop** | Second opinion enforcement | Block alice if no consensus |

### SubagentStop (Second Opinion Enforcement)

Ensures alice obtains second opinion before completing:

**Detection**: Identifies alice by output patterns (`**Status**: RESOLVED | NEEDS_INPUT | UNRESOLVED`)

**Enforcement** (exit code 2 = block):
- Must invoke `codex exec` or `claude -p` for second opinion
- Must include `## Second Opinion` section with actual findings
- Must not have placeholder content

**Rationale**: Single-model analysis exhibits self-bias. The hook enforces multi-model consensus.

## External Model Integration

### Codex (OpenAI)

Used by: `alice`

Pattern: Dialogue-based consultation

```bash
codex exec "You are helping with [TASK].

Context: [RELEVANT CODE/PROBLEM]

Question: [SPECIFIC ASK]"
```

alice iterates with Codex until reaching consensus or identifying clear disagreement.

## Agent Messaging

Agents communicate asynchronously via [zawinski](https://github.com/femtomc/zawinski) (`jwz` CLI).

### Topic Naming Convention

| Pattern | Example | Purpose |
|---------|---------|---------|
| `project:<name>` | `project:idle` | Project-wide announcements |
| `issue:<id>` | `issue:auth-123` | Per-issue discussion |
| `agent:<name>` | `agent:alice` | Direct agent communication |

### Message Format

```
[AGENT] ACTION: description

Examples:
[alice] ANALYSIS: Auth flow race condition
[alice] DECISION: Use JWT with refresh tokens
[bob] RESEARCH: OAuth 2.0 best practices
```

### Artifact Notification Protocol

When an agent creates an artifact, it MUST post a notification to jwz:

```bash
jwz post "issue:<issue-id>" --role <agent> \
  -m "[<agent>] <TYPE>: <topic>
Path: .claude/plugins/idle/<agent>/<filename>.md
Summary: <one-line summary>"
```

**Standard notification types:**

| Agent | Type | Additional Fields |
|-------|------|-------------------|
| bob | RESEARCH | `Confidence:`, `Sources:` |
| alice | ANALYSIS | `Status:`, `Confidence:`, `Key finding:` |
| alice | DECISION | `Recommendation:`, `Alternatives:` |
| alice | REVIEW | `Verdict:`, `Required fixes:` |

## Adding New Agents

1. Create `agents/your-agent.md`
2. Define frontmatter (name, description, model, tools)
3. Write clear constraints (what it MUST NOT do)
4. Define the workflow
5. Specify output format

The agent becomes available automatically as `idle:your-agent`.

## Dependencies

### Required

- [tissue](https://github.com/femtomc/tissue) - Local issue tracker for `/loop` issue mode
- [zawinski](https://github.com/femtomc/zawinski) - Async messaging for agent communication
- [uv](https://github.com/astral-sh/uv) - Python package runner for `scripts/search.py`
- [gh](https://cli.github.com/) - GitHub CLI for bob's research
- [bibval](https://github.com/evil-mind-evil-sword/bibval) - Citation validator for bob's academic research

### Optional

- [codex](https://github.com/openai/codex) - OpenAI CLI for alice (falls back to `claude -p`)
