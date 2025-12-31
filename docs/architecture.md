# idle Architecture

**idle** is an outer harness for Claude Code that enables long-running, iterative agent workflows with multi-model consensus. This document describes the system's design, the rationale behind key decisions, and the interactions between components.

## Design Philosophy

Three principles guide idle's architecture:

1. **Pull over push.** Agents retrieve context on demand rather than receiving large injections upfront. The stop hook posts minimal state to jwz; agents read what they need.

2. **Safety over policy.** Critical guardrails are enforced mechanically rather than relying on prompt instructions that agents might ignore.

3. **Pointer over payload.** State messages contain references (file paths, issue IDs) rather than inline content. This keeps message sizes bounded and supports recovery after context compaction.

## System Overview

```
┌────────────────────────────────────────────────────────────────┐
│                         Claude Code                            │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                     idle plugin                          │  │
│  │                                                          │  │
│  │   ┌─────────┐                                            │  │
│  │   │  alice  │   Agents                                   │  │
│  │   │ (opus)  │                                            │  │
│  │   └────┬────┘                                            │  │
│  │        │                                                 │  │
│  │        │                                                 │  │
│  │        │                                                 │  │
│  │  ┌─────┴───────┐                                        │  │
│  │  │     jwz     │   Messaging                            │  │
│  │  └─────────────┘                                        │  │
│  │                                                          │  │
│  │   ┌──────────────────────────────────────────────────┐  │  │
│  │   │                   Hooks                          │  │  │
│  │   │      SessionStart │ Stop │ PreCompact            │  │  │
│  │   └──────────────────────────────────────────────────┘  │  │
│  │                                                          │  │
│  │   ┌──────────────────────────────────────────────────┐  │  │
│  │   │                  Skills                          │  │  │
│  │   │   reviewing │ researching │ issue-tracking │ ... │  │  │
│  │   └──────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                │
│                         ┌───────────┐                          │
│                         │  tissue   │   Issue Tracker          │
│                         └───────────┘                          │
└────────────────────────────────────────────────────────────────┘
```

## Agent Architecture

idle provides a specialized agent with multi-model consensus.

### Agent Roles

| Agent | Model | Role | Constraints |
|-------|-------|------|-------------|
| **alice** | Opus | Deep reasoning, quality gates, design decisions | Read-only; consults external models for second opinions |

### Multi-Model Consensus

Single models exhibit self-bias: they validate their own errors when asked to double-check. alice breaks this loop by consulting external models:

```
Primary: Claude (Opus)
    │
    ├──→ 1st choice: Codex (OpenAI) - different architecture
    ├──→ 2nd choice: Gemini (Google) - third perspective
    └──→ Fallback:   claude -p - fresh context
```

The consensus protocol requires agreement before committing to critical paths. This adds latency but catches edge cases that a single model family would miss.

## Hook System

Hooks intercept Claude Code lifecycle events to implement loops, enforce safety, and preserve state.

### Hook Lifecycle

```
SessionStart ─┐
              │
              ▼
        ┌──────────┐
        │  Agent   │◄───────────────┐
        │  Active  │                │
        └────┬─────┘                │
             │                      │
             ▼                      │
        ┌──────────┐                │
        │  Agent   │                │
        │  Exits   │                │
        └────┬─────┘                │
             │                      │
    PreCompact (if compacting)      │
             │                      │
             ▼                      │
        ┌──────────┐                │
        │   Stop   │────────────────┘
        │   Hook   │   (block + re-entry if looping)
        └──────────┘
```

### Hook Implementations

All hooks are implemented in the Zig CLI (`idle <command>`) for performance and type safety.

**SessionStart** (`idle session-start`)
Injects loop context and agent awareness. Shows active loop state (mode, iteration) and alice usage guidance.

**Stop** (`idle stop`)
The core loop mechanism. On agent exit:
1. Sync transcript to jwz for persistence
2. Read loop state from zawinski store
3. Check for completion signals (`<loop-done>COMPLETE</loop-done>`)
4. If COMPLETE/STUCK and not reviewed: block for alice review
5. If reviewed and complete: post DONE state
6. If incomplete: increment iteration, emit `block` decision to force re-entry
7. Checkpoint reviews triggered at iterations 3, 6, 9, etc.

**PreCompact** (`idle pre-compact`)
Before context compaction, writes a recovery anchor to `loop:anchor` containing:
- Current goal/issue
- Iteration progress
- Alice reminder for post-compaction context

After compaction, agents can read this anchor to restore context.

### State Schema

Loop state is stored as JSON in jwz messages on the `loop:current` topic:

```json
{
  "schema": 1,
  "event": "STATE",
  "run_id": "loop-1735500000-12345",
  "updated_at": "2025-12-30T00:00:00Z",
  "stack": [
    {
      "id": "loop-1735500000-12345",
      "mode": "loop",
      "iter": 3,
      "max": 10,
      "prompt_file": "/tmp/idle-loop-prompt.txt",
      "reviewed": false,
      "checkpoint_reviewed": false
    }
  ]
}
```

## Loop Mode

Iterate on a specific task:

```
/loop Add input validation to API endpoints
```

- Runs up to 10 iterations
- Alice reviews at checkpoints (iterations 3, 6, 9, ...)
- Alice reviews on completion signal
- 3 consecutive failures → STUCK

### Completion Signals

Agents signal loop state via XML markers:

| Signal | Meaning |
|--------|---------|
| `<loop-done>COMPLETE</loop-done>` | Task finished successfully |
| `<loop-done>MAX_ITERATIONS</loop-done>` | Iteration limit reached |
| `<loop-done>STUCK</loop-done>` | Cannot make progress |

## Messaging (jwz)

Agents coordinate via jwz, a topic-based messaging system. (jwz is the CLI for [zawinski](https://github.com/femtomc/zawinski).)

### Topic Naming

| Pattern | Purpose |
|---------|---------|
| `project:<name>` | Project-wide announcements |
| `issue:<id>` | Per-issue discussion |
| `loop:current` | Active loop state |
| `loop:anchor` | Recovery context after compaction |
| `loop:trace` | Trace events (when IDLE_TRACE=1) |

### Message Format

Structured messages for discovery and filtering:

```
[agent] ACTION: description
```

Examples:
- `[alice] ANALYSIS: auth flow race condition`
- `[loop] LANDED: issue-123`
- `[review] LGTM sha:abc123`

## Skills

Skills inject domain-specific context into the generic agent framework. They are discovered automatically from the `skills/` directory.

### Skill Structure

```
skills/
└── researching/
    ├── SKILL.md          ← Skill specification
    └── references.bib    ← Design rationale sources
```

### Skill Invocation

Skills are invoked via `--append-system-prompt`, injecting domain context without modifying agent code:

```bash
claude -p --agent alice \
  --append-system-prompt "$(cat skills/researching/SKILL.md)" \
  "Research OAuth 2.0 best practices"
```

### Available Skills

| Skill | Description |
|-------|-------------|
| reviewing | Multi-model second opinions (Codex, Gemini) |
| researching | Quality-gated research with citations |
| issue-tracking | Work tracking via tissue |
| technical-writing | Multi-layer document review |
| bib-managing | Bibliography curation with bibval |

## Error Handling

### Failure Modes

| Failure | Response |
|---------|----------|
| Review rejected 3x | Allow completion, create follow-up issues |
| State corrupted | Clean up, allow exit |
| State stale (>2 hours) | Allow exit (zombie loop protection) |

### Recovery Mechanisms

1. **PreCompact anchor**: State persisted before context compaction
2. **TTL expiry**: Stale loops (>2 hours) automatically expire
3. **File-based bypass**: Create `.idle-disabled` to skip loop logic
4. **jwz config bypass**: Set `config.disabled: true` in state
5. **Manual reset**: Delete `.jwz/` to clear all state

## Configuration

### State Config (schema 2+)

Config is stored in the jwz loop state:

```json
{
  "schema": 1,
  "config": {
    "disabled": false,
    "trace": false
  },
  "stack": [...]
}
```

| Option | Effect |
|--------|--------|
| `config.disabled` | Bypass all loop hooks |
| `config.trace` | Emit trace events to `loop:trace` |

### File-based Escape Hatches

| File | Effect |
|------|--------|
| `.idle-disabled` | Bypass loop hook (create to disable, remove after) |

## Dependencies

| Dependency | Purpose | Required |
|------------|---------|----------|
| tissue | Issue tracking | No (for issue-tracking skill) |
| jwz | Agent messaging | Yes |
| uv | Python script runner | No (for search) |
| gh | GitHub CLI | No (for GitHub research) |
| bibval | Citation validation | No (for bib-managing skill) |
| codex | OpenAI second opinions | No (falls back to claude -p) |
| gemini | Google third opinions | No (optional diversity) |

## File Structure

```
idle/
├── agents/
│   └── alice.md          # Deep reasoning agent
├── cli/                  # Zig CLI implementation
│   └── src/
│       ├── main.zig      # CLI entry point
│       ├── hooks/        # Hook implementations
│       │   ├── stop.zig
│       │   ├── session_start.zig
│       │   └── pre_compact.zig
│       └── lib/          # Shared modules
│           ├── state_machine.zig
│           ├── event_parser.zig
│           ├── transcript.zig
│           └── ...
├── commands/
│   ├── loop.md           # Main loop command
│   └── cancel.md         # Loop cancellation
├── skills/
│   ├── reviewing/        # Multi-model second opinions
│   ├── researching/      # Quality-gated research
│   ├── issue-tracking/   # tissue integration
│   ├── technical-writing/# Document review
│   └── bib-managing/     # Bibliography curation
├── hooks/
│   └── hooks.json        # Hook configuration (points to cli)
├── docs/
│   ├── architecture.md   # This document
│   └── references.bib    # Design rationale sources
├── README.md
├── CHANGELOG.md
└── CONTRIBUTING.md
```

## References

See `docs/references.bib` for academic and industry sources informing idle's design, including work on LLM self-bias, multi-agent debate, and agentic workflow patterns.
