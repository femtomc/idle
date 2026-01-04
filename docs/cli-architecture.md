# idle CLI Architecture

**Status:** Draft
**Date:** 2026-01-04
**Supersedes:** v2.2.0 "pure Bash hooks" decision

## Background

v2.2.0 (2025-12-31) removed the Zig CLI entirely, simplifying idle to pure Bash hooks. This document proposes **re-introducing** a Zig CLI for trace construction and session management.

**Rationale for reversal:**
- Traces require efficient queries across tissue + jwz stores
- Bash parsing of tool outputs is fragile for trace construction
- Zig CLI can use tissue/zawinski as libraries (no subprocess overhead)
- Future: CLI can invoke and manage Claude Code itself

**Related documents:**
- `conversation-trace-design.md` - Trace data model and schema changes

## Overview

`idle` evolves from a pure Claude Code plugin into a hybrid package:

1. **Claude Code plugin** - hooks, agents, skills (existing)
2. **Zig CLI tool** - trace queries, session management (new)
3. **Zig library** - embeddable trace construction (new)

## Package Structure

```
idle/
├── .claude-plugin/           # Plugin metadata
│   ├── plugin.json
│   └── marketplace.json
├── agents/                   # Agent definitions
│   └── alice.md
├── skills/                   # Skill definitions
│   ├── researching/
│   ├── reviewing/
│   └── ...
├── hooks/                    # Bash hook scripts
│   ├── hooks.json            # Hook configuration
│   ├── session-start-hook.sh
│   ├── user-prompt-hook.sh
│   ├── stop-hook.sh
│   └── trace-hook.sh         # NEW: unified trace emitter
├── src/                      # Zig source code (NEW)
│   ├── main.zig              # CLI entry point
│   ├── root.zig              # Library exports
│   ├── trace.zig             # Trace construction
│   └── render.zig            # Trace visualization
├── build.zig                 # Zig build config (NEW)
├── build.zig.zon             # Zig dependencies (NEW)
└── docs/
    ├── architecture.md
    ├── conversation-trace-design.md
    └── cli-architecture.md
```

## Dependencies

The idle CLI depends on zawinski and tissue as Zig modules.

**For local development** (monorepo - default):
```zig
// build.zig.zon
.dependencies = .{
    .zawinski = .{ .path = "../zawinski" },
    .tissue = .{ .path = "../tissue" },
},
```

**For releases** (standalone builds):

CI workflow updates `build.zig.zon` before building using `zig fetch`:
```bash
# scripts/patch-deps-for-release.sh
# First, remove path deps and add URL deps with correct hashes
zig fetch --save=zawinski "https://github.com/femtomc/zawinski/archive/refs/tags/${ZAWINSKI_VERSION}.tar.gz"
zig fetch --save=tissue "https://github.com/femtomc/tissue/archive/refs/tags/${TISSUE_VERSION}.tar.gz"
```

**Note:** `zig fetch --save` downloads the tarball, calculates its cryptographic hash, and updates `build.zig.zon` with the correct `.url` and `.hash` values. The monorepo uses path deps by default; release CI converts to URL deps.

This allows idle to:
- Query jwz stores directly (no subprocess)
- Query tissue stores directly (no subprocess)
- Share SQLite/ULID code

## CLI Commands

### Phase 1: Trace Queries

```bash
# Show trace for a session
idle trace <session_id>
idle trace <session_id> --format text|dot|json

# List recent sessions
idle sessions
idle sessions --limit 10

# Show session details
idle session <session_id>
```

### Phase 2: Session Management (Future)

```bash
# Start a new Claude Code session with tracing
idle run "prompt here"

# Resume a session
idle resume <session_id>

# Watch a session in real-time
idle watch <session_id>
```

## Trace Data Model

```zig
pub const TraceEvent = struct {
    id: []const u8,           // ULID
    session_id: []const u8,
    timestamp: i64,
    event_type: EventType,
    payload: Payload,

    pub const EventType = enum {
        prompt_received,
        tool_called,
        tool_completed,
        file_modified,
        issue_created,
        issue_updated,
        subagent_started,
        subagent_completed,
        alice_decision,
        session_end,
    };

    pub const Payload = union(EventType) {
        prompt_received: struct { prompt: []const u8 },
        tool_called: struct { tool: []const u8, input: []const u8 },
        tool_completed: struct { tool: []const u8, success: bool },
        file_modified: struct { path: []const u8, action: []const u8 },
        issue_created: struct { issue_id: []const u8, title: []const u8 },
        issue_updated: struct { issue_id: []const u8, field: []const u8 },
        subagent_started: struct { agent_type: []const u8 },
        subagent_completed: struct { agent_type: []const u8, success: bool },
        alice_decision: struct { decision: []const u8, issues: [][]const u8 },
        session_end: struct { reason: []const u8 },
    };
};
```

## Trace Construction

Traces are constructed from three sources:

### 1. Hook-generated events (reliable)

Events emitted by hooks to `trace:{session_id}` topic:

```json
{"type": "prompt_received", "timestamp": 1704326400000}
{"type": "tool_called", "tool": "Write", "path": "src/main.zig", "timestamp": 1704326401000}
```

### 2. Tissue queries (reliable)

Issues with `origin_session_id` matching the session:

```zig
const issues = try tissue_store.listBySession(session_id);
```

### 3. Jwz queries (reliable)

Messages in session-scoped topics:

```zig
const user_context = try jwz_store.readTopic("user:context:" ++ session_id);
const alice_status = try jwz_store.readTopic("alice:status:" ++ session_id);
```

## New Hooks for Tracing

**Hook availability in Claude Code** (per [hooks documentation](https://docs.anthropic.com/en/docs/claude-code/hooks)):

| Hook | Claude Code | idle history |
|------|-------------|--------------|
| `PostToolUse` | ✓ Supported | Never used in idle |
| `PreToolUse` | ✓ Supported | Added v0.6.0, removed v1.4.0 |
| `SubagentStop` | ✓ Supported | Removed v1.4.0, re-added v2.1.0, removed v2.2.0 |
| `SessionEnd` | ✓ Supported | Never used in idle |

We're adding these hooks to idle for trace construction.

**Hook responsibilities:**
- `Stop` - Existing: alice review gating (unchanged)
- `SessionEnd` - New: emit `session_end` trace event
- `PostToolUse` - New: emit `tool_completed`, `file_modified`, `issue_created` events
- `PreToolUse` - New: emit `subagent_started` for Task tool
- `SubagentStop` - New: emit `subagent_completed` events

Add to `hooks.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{
          "type": "command",
          "command": "${CLAUDE_PLUGIN_ROOT}/hooks/trace-hook.sh",
          "timeout": 5
        }]
      },
      {
        "matcher": "Write|Edit",
        "hooks": [{
          "type": "command",
          "command": "${CLAUDE_PLUGIN_ROOT}/hooks/trace-hook.sh",
          "timeout": 5
        }]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Task",
        "hooks": [{
          "type": "command",
          "command": "${CLAUDE_PLUGIN_ROOT}/hooks/trace-hook.sh",
          "timeout": 5
        }]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [{
          "type": "command",
          "command": "${CLAUDE_PLUGIN_ROOT}/hooks/trace-hook.sh",
          "timeout": 5
        }]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [{
          "type": "command",
          "command": "${CLAUDE_PLUGIN_ROOT}/hooks/trace-hook.sh",
          "timeout": 5
        }]
      }
    ]
  }
}
```

### Unified trace-hook.sh

Single script that handles all trace events:

```bash
#!/bin/bash
set -euo pipefail

INPUT=$(cat)
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
TIMESTAMP=$(date +%s000)
TRACE_TOPIC="trace:$SESSION_ID"

case "$HOOK_EVENT" in
  "PostToolUse")
    TOOL=$(echo "$INPUT" | jq -r '.tool_name')
    # Emit trace event based on tool type
    ;;
  "PreToolUse")
    # Emit subagent_started for Task tool
    ;;
  "SubagentStop")
    # Emit subagent_completed
    ;;
  "SessionEnd")
    REASON=$(echo "$INPUT" | jq -r '.reason')
    jwz post "$TRACE_TOPIC" -m "{\"type\":\"session_end\",\"reason\":\"$REASON\",\"timestamp\":$TIMESTAMP}"
    ;;
esac

echo '{"decision": "approve"}'
```

## Schema Changes

### Tissue: Add origin_session_id

```zig
// tissue/src/store.zig
pub const Issue = struct {
    // ... existing fields ...
    origin_session_id: ?[]const u8,  // NEW
};
```

CLI: `tissue new "title" --session <session_id>`
Query: `tissue list --session <session_id>`

### Zawinski: Add session_id to Message

```zig
// zawinski/src/store.zig
pub const Message = struct {
    // ... existing fields ...
    session_id: ?[]const u8,  // NEW
};
```

CLI: `jwz post <topic> --session <session_id> -m "..."`
Query: `jwz search --session <session_id> "query"`

## Release CI

Same pattern as zawinski/tissue:

```yaml
# .github/workflows/release.yml
name: Release

on:
  push:
    tags:
      - 'v*'

jobs:
  build:
    strategy:
      matrix:
        include:
          - os: ubuntu-latest
            target: x86_64-linux
            artifact: idle-linux-x86_64
          - os: macos-latest
            target: x86_64-macos
            artifact: idle-macos-x86_64
          - os: macos-latest
            target: aarch64-macos
            artifact: idle-macos-aarch64

    runs-on: ${{ matrix.os }}
    steps:
      # ... standard Zig build steps ...
```

## Implementation Phases

### Phase 1: Zig Project Setup
- Create `build.zig` and `build.zig.zon`
- Create `src/main.zig` with basic CLI structure
- Create `src/root.zig` for library exports
- Test build with `zig build`

### Phase 2: Trace Hooks
- Create `trace-hook.sh`
- Update `hooks.json` with new hook configurations
- Test trace event emission

### Phase 3: Schema Changes
- Add `origin_session_id` to tissue
- Add `session_id` to zawinski
- Update CLIs with new flags

### Phase 4: Trace Queries
- Implement `src/trace.zig` with trace construction
- Implement `src/render.zig` with output formats
- Add `idle trace` command
- Add `idle sessions` command

### Phase 5: Release CI
- Create `.github/workflows/release.yml`
- Test release workflow
- Deploy to site

## Open Questions

1. **Dependency management**: Use `build.zig.zon` paths or git submodules?
   - Path deps (`../zawinski`) work in monorepo but break for standalone clones
   - Options: (a) require monorepo checkout, (b) use git URLs in build.zig.zon, (c) vendor copies
   - **Recommendation**: Use git URLs for releases, path overrides for local dev

2. **SQLite sharing**: Each package bundles SQLite - should idle share or bundle its own?
   - Currently tissue and zawinski each vendor sqlite3.c (~2MB each)
   - idle could link against their sqlite or bundle its own
   - **Recommendation**: Bundle own copy for build simplicity

3. **Plugin vs CLI install**: Keep them separate or bundle CLI with plugin?
   - Plugin is installed via `claude /plugin install idle@emes`
   - CLI would need separate install (`curl ... | sh`)
   - **Recommendation**: Separate installs, plugin references CLI if present
