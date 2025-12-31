# idle Architecture

**idle** is an outer harness for Claude Code that enables long-running, iterative agent workflows with multi-model consensus. This document describes the system's design, the rationale behind key decisions, and the interactions between components.

## Design Philosophy

Three principles guide idle's architecture:

1. **Pull over push.** Agents retrieve context on demand rather than receiving large injections upfront. The stop hook posts minimal state to jwz; agents read what they need.

2. **Safety over policy.** Guardrails are enforced mechanically (PreToolUse hook blocks destructive commands) rather than relying on prompt instructions that agents might ignore.

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
│  │   │  SessionStart │ Stop │ SubagentStop │ PreToolUse │  │  │
│  │   └──────────────────────────────────────────────────┘  │  │
│  │                                                          │  │
│  │   ┌──────────────────────────────────────────────────┐  │  │
│  │   │                  Skills                          │  │  │
│  │   │  messaging │ issue-tracking │ researching │ ...  │  │  │
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
    PreToolUse (per tool)           │
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

**SessionStart** (`session-start-hook.sh`)
Injects minimal agent awareness. Context pointing to alice.

**Stop** (`stop-hook.sh`)
The core loop mechanism. On agent exit:
1. Read loop state from `jwz read "loop:current"`
2. Check for completion signals (`<loop-done>COMPLETE</loop-done>`)
3. If complete and issue mode: run auto-land, pick next issue
4. If incomplete: increment iteration, emit `block` decision to force re-entry

**PreToolUse** (`pre-tool-use-hook.sh`)
Safety guardrails for Bash commands. Blocks:
- `git push --force` to main/master
- `git reset --hard`
- `rm -rf /` or `rm -rf ~`
- `DROP DATABASE`

**PreCompact** (`pre-compact-hook.sh`)
Before context compaction, writes a recovery anchor to `loop:anchor` containing:
- Current goal/issue
- Iteration progress
- Recent commits
- Modified files

After compaction, agents can read this anchor to restore context.

**SubagentStop** (`subagent-stop-hook.sh`)
Enforces the second-opinion requirement for alice. When alice completes, the hook verifies:
1. A `codex exec` or `claude -p` command was invoked
2. The output contains a `## Second Opinion` section with content

If either check fails, the hook blocks completion and instructs alice to consult an external model before proceeding.

### State Schema

Loop state is stored as JSON in jwz messages on the `loop:current` topic:

```json
{
  "schema": 2,
  "event": "STATE",
  "run_id": "loop-1735500000-12345",
  "updated_at": "2025-12-30T00:00:00Z",
  "stack": [
    {
      "id": "loop-1735500000-12345",
      "mode": "issue",
      "iter": 3,
      "max": 10,
      "prompt_blob": "sha256:abc123...",
      "issue_id": "auth-bug-42",
      "worktree_path": "/path/to/repo/.worktrees/idle/auth-bug-42",
      "branch": "idle/issue/auth-bug-42",
      "base_ref": "main"
    }
  ]
}
```

The stack model supports nested loops (e.g., `/loop` working through issues, each issue having its own iteration state).

## Loop Modes

### Task Mode

Iterate on a specific task with no issue tracking:

```
/loop Add input validation to API endpoints
```

- Runs up to 10 iterations
- 3 consecutive failures → STUCK
- No worktree isolation
- No auto-land

### Issue Mode

Pull from tissue, work in worktrees, auto-land on completion:

```
/loop
```

1. Pick first ready issue from `tissue ready`
2. Create worktree at `.worktrees/idle/<issue-id>/`
3. Work on issue (up to 10 iterations)
4. On `<loop-done>COMPLETE</loop-done>`:
   - Verify review gate passed
   - Fast-forward merge to base branch
   - Push to remote
   - Remove worktree, delete branch
   - Close issue
   - Pick next issue

### Completion Signals

Agents signal loop state via XML markers:

| Signal | Meaning |
|--------|---------|
| `<loop-done>COMPLETE</loop-done>` | Task finished successfully |
| `<loop-done>MAX_ITERATIONS</loop-done>` | Iteration limit reached |
| `<loop-done>STUCK</loop-done>` | Cannot make progress |

## Worktree Isolation

Each issue gets its own git worktree for isolation:

```
repo/
├── .worktrees/
│   └── idle/
│       ├── issue-abc123/   ← worktree for issue abc123
│       └── issue-def456/   ← worktree for issue def456
└── src/                    ← main worktree
```

Benefits:
- Parallel work on multiple issues
- Clean rollback (just delete worktree)
- No uncommitted changes leak between issues

The stop hook injects worktree context on each iteration, reminding agents to use absolute paths under the worktree.

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
| messaging | Agent coordination via jwz |
| issue-tracking | Work tracking via tissue |
| researching | Quality-gated research with citations |
| technical-writing | Multi-layer document review |
| bib-managing | Bibliography curation with bibval |
| querying-codex | OpenAI Codex second opinions |
| querying-gemini | Google Gemini third perspectives |

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
  "schema": 2,
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

### Git Configuration

```bash
git config idle.baseRef main  # Base branch for worktrees
```

## Dependencies

| Dependency | Purpose | Required |
|------------|---------|----------|
| tissue | Issue tracking | Yes (for issue mode) |
| jwz | Agent messaging | Yes |
| uv | Python script runner | Yes (for search) |
| gh | GitHub CLI | Yes (for GitHub research) |
| bibval | Citation validation | Yes (for bib-managing) |
| codex | OpenAI second opinions | No (falls back to claude -p) |
| gemini | Google third opinions | No (optional diversity) |

## File Structure

```
idle/
├── agents/
│   └── alice.md          # Deep reasoning agent
├── commands/
│   ├── loop.md           # Main loop command
│   └── cancel.md         # Loop cancellation
├── skills/
│   ├── messaging/        # jwz coordination
│   ├── issue-tracking/   # tissue integration
│   ├── researching/      # Quality-gated research
│   ├── technical-writing/# Document review
│   ├── bib-managing/     # Bibliography curation
│   ├── querying-codex/   # OpenAI second opinions
│   └── querying-gemini/  # Google third opinions
├── hooks/
│   ├── hooks.json        # Hook configuration
│   ├── session-start-hook.sh
│   ├── stop-hook.sh      # Core loop mechanism
│   ├── pre-tool-use-hook.sh  # Safety guardrails
│   ├── pre-compact-hook.sh   # Recovery anchors
│   └── subagent-stop-hook.sh
├── tui/                  # Terminal UI (in development)
│   └── src/
├── docs/
│   ├── architecture.md   # This document
│   └── references.bib    # Design rationale sources
├── README.md
├── CHANGELOG.md
├── CONTRIBUTING.md
└── install.sh
```

## References

See `docs/references.bib` for academic and industry sources informing idle's design, including work on LLM self-bias, multi-agent debate, and agentic workflow patterns.
