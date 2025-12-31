# idle Architecture

**idle** is a quality gate plugin for Claude Code. Every exit requires alice review.

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
        ├─► Check jwz for alice decision
        │   └─► COMPLETE/APPROVED? → allow exit
        │
        ├─► Check tissue for open alice-review issues
        │   └─► Issues open? → block, keep working
        │
        └─► No review? → block, request /alice
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
  "reason": "No alice review on record. Run /alice to get approval."
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

## File Structure

```
idle/
├── .claude-plugin/
│   └── plugin.json        # Plugin metadata, hooks reference
├── agents/
│   └── alice.md           # Adversarial reviewer
├── hooks/
│   ├── hooks.json         # Hook configuration
│   └── stop-hook.sh       # Stop hook implementation
├── skills/
│   ├── reviewing/
│   ├── researching/
│   ├── issue-tracking/
│   ├── technical-writing/
│   └── bib-managing/
├── docs/
│   └── architecture.md    # This document
├── tests/
│   └── stop-hook-test.sh  # Hook tests
├── README.md
├── CHANGELOG.md
└── CONTRIBUTING.md
```

## Dependencies

| Dependency | Purpose | Required |
|------------|---------|----------|
| jwz | Agent messaging | Yes |
| tissue | Issue tracking | Yes |
| jq | JSON parsing in hooks | Yes |

## Escape Hatches

| Method | Effect |
|--------|--------|
| `.idle-disabled` file | Bypass stop hook |
| `stop_hook_active: true` | Hook already triggered, allows exit |

## References

See `docs/references.bib` for academic sources informing idle's design.
