# idle Architecture

**idle** is a quality gate plugin for Claude Code.

## Usage

```
#idle <your prompt>
```

Review is opt-in per-prompt. After alice approves, the gate resets automatically.

## Design Philosophy

Three principles guide idle's architecture:

1. **Pull over push.** Agents retrieve context on demand rather than receiving large injections upfront.

2. **Safety over policy.** Critical guardrails are enforced mechanically (hooks) rather than relying on prompt instructions.

3. **Pointer over payload.** State messages contain references (issue IDs, session IDs) rather than inline content.

## System Overview

```
┌────────────────────────────────────────────────────────────────┐
│                         Claude Code                            │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                     idle plugin                          │  │
│  │                                                          │  │
│  │   ┌─────────┐                                            │  │
│  │   │  alice  │   Adversarial reviewer (opus)              │  │
│  │   │         │                                            │  │
│  │   └────┬────┘                                            │  │
│  │        │                                                 │  │
│  │        │ posts decision                                  │  │
│  │        ▼                                                 │  │
│  │  ┌───────────┐         ┌───────────┐                    │  │
│  │  │    jwz    │         │  tissue   │                    │  │
│  │  │ (messages)│         │ (issues)  │                    │  │
│  │  └───────────┘         └───────────┘                    │  │
│  │        ▲                     ▲                          │  │
│  │        │ reads status        │ checks issues            │  │
│  │        │                     │                          │  │
│  │  ┌─────┴─────────────────────┴─────┐                    │  │
│  │  │           Stop Hook             │                    │  │
│  │  │     (hooks/stop-hook.sh)        │                    │  │
│  │  └─────────────────────────────────┘                    │  │
│  │                                                          │  │
│  │  ┌──────────────────────────────────────────────────┐   │  │
│  │  │                  Skills                          │   │  │
│  │  │   reviewing │ researching │ issue-tracking │ ... │   │  │
│  │  └──────────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
```

## Stop Hook

The core mechanism. When Claude tries to exit:

```
Agent tries to exit
        │
        ▼
   stop-hook.sh
        │
        ├─► Check if #idle enabled review
        │   └─► Not enabled? → allow exit
        │
        ├─► Check jwz for alice decision
        │   └─► COMPLETE/APPROVED? → allow exit
        │
        └─► No review yet? → block, request alice
```

### Hook Input

The hook receives JSON on stdin:

```json
{
  "session_id": "abc123",
  "transcript_path": "/path/to/transcript.jsonl",
  "cwd": "/project/directory",
  "stop_hook_active": false
}
```

### Hook Output

Returns JSON with decision:

```json
{
  "decision": "block",
  "reason": "No alice review on record. Spawn alice to get approval."
}
```

Or to allow exit:

```json
{
  "decision": "approve",
  "reason": "alice approved"
}
```

## Alice Agent

Adversarial reviewer. Read-only.

### Process

1. Reviews the work done
2. Creates tissue issues for problems (tagged `alice-review`)
3. Posts decision to jwz (`alice:status:{session_id}`)

### Decision Schema

```json
{
  "decision": "COMPLETE",
  "summary": "No issues found",
  "issues": []
}
```

Or when problems found:

```json
{
  "decision": "ISSUES",
  "summary": "Found 2 problems",
  "issues": ["issue-id-1", "issue-id-2"]
}
```

## Messaging (jwz)

Topic-based messaging for agent coordination.

### Topics

| Pattern | Purpose |
|---------|---------|
| `alice:status:{session_id}` | Alice's review decision |
| `project:<name>` | Project-wide announcements |
| `issue:<id>` | Per-issue discussion |

## Issue Tracking (tissue)

Git-native issue tracker.

### Alice Review Issues

Alice creates issues tagged `alice-review`:

```bash
tissue new "Missing error handling in auth flow" -t alice-review -p 2
```

The stop hook checks for open alice-review issues before allowing exit.

## Skills

Domain-specific context injected into agents.

| Skill | Description |
|-------|-------------|
| reviewing | Multi-model second opinions (Codex, Gemini) |
| researching | Quality-gated research with citations |
| issue-tracking | Work tracking via tissue |
| technical-writing | Multi-layer document review |
| bib-managing | Bibliography curation with bibval |

## Trace Hooks

Trace hooks capture session events to jwz for post-hoc analysis via the `idle` CLI.

### Trace Topics

Events are stored in `trace:{session_id}` topics:

```bash
jwz read trace:abc123 --json
```

### Event Types

| Hook | Event Type | Fields |
|------|------------|--------|
| SessionStart | `session_start` | timestamp |
| UserPromptSubmit | `prompt_received` | timestamp, prompt |
| PostToolUse | `tool_completed` | timestamp, tool_name, tool_input, tool_output |
| SessionEnd | `session_end` | timestamp |

### Hook Configuration

Hooks are configured in Claude Code settings (`~/.claude/settings.json`):

```json
{
  "hooks": {
    "SessionStart": [{
      "matcher": "",
      "hooks": ["$PLUGIN_ROOT/hooks/session-start-hook.sh"]
    }],
    "UserPromptSubmit": [{
      "matcher": "",
      "hooks": ["$PLUGIN_ROOT/hooks/user-prompt-hook.sh"]
    }],
    "Stop": [{
      "matcher": "",
      "hooks": ["$PLUGIN_ROOT/hooks/stop-hook.sh"]
    }],
    "PostToolUse": [{
      "matcher": "",
      "hooks": ["$PLUGIN_ROOT/hooks/post-tool-use-hook.sh"]
    }],
    "SessionEnd": [{
      "matcher": "",
      "hooks": ["$PLUGIN_ROOT/hooks/session-end-hook.sh"]
    }]
  }
}
```

Replace `$PLUGIN_ROOT` with the actual plugin path.

## File Structure

```
idle/
├── .claude-plugin/
│   └── plugin.json           # Plugin metadata
├── agents/
│   └── alice.md              # Adversarial reviewer
├── hooks/
│   ├── session-start-hook.sh # Context injection + trace
│   ├── user-prompt-hook.sh   # Prompt capture + trace
│   ├── stop-hook.sh          # Alice review gate
│   ├── post-tool-use-hook.sh # Tool call tracing
│   └── session-end-hook.sh   # Session end tracing
├── skills/
│   ├── reviewing/
│   ├── researching/
│   ├── issue-tracking/
│   ├── technical-writing/
│   └── bib-managing/
├── src/                      # Zig CLI source
│   ├── root.zig
│   ├── trace.zig
│   └── main.zig
├── build.zig
├── build.zig.zon
├── docs/
│   └── architecture.md       # This document
├── tests/
│   └── stop-hook-test.sh     # Hook tests
├── README.md
├── CHANGELOG.md
└── CONTRIBUTING.md
```

## Version Management

Uses **CalVer** (Calendar Versioning) with format **YY.M.D** (e.g., `26.1.15`).

Three JSON files track the plugin version:

| File | Location |
|------|----------|
| `plugin.json` | `idle/.claude-plugin/` |
| `marketplace.json` | `idle/.claude-plugin/` |
| `marketplace.json` | `marketplace/.claude-plugin/` |

### Automatic Releases

Push to monorepo `main` triggers automatic CalVer releases via `.github/workflows/release.yml`.

### Manual Releases

```bash
# Calculate CalVer for idle
./scripts/calver.sh idle

# Or manually specify version
./scripts/bump-idle-version.sh 26.1.15

# Commit and push
cd idle
git add -A && git commit -m "chore: Release v26.1.15"
cd ..
./scripts/push-package.sh idle --release v26.1.15
```

### Installing/Updating Plugin

```bash
claude /plugin uninstall idle
claude /plugin install idle@emes
```

## Dependencies

| Dependency | Purpose | Required |
|------------|---------|----------|
| jwz | Agent messaging | Yes |
| tissue | Issue tracking | Yes |
| jq | JSON parsing in hooks | Yes |

## References

See `docs/references.bib` for academic sources informing idle's design.
