# idle

`idle` is a Claude Code plugin that exposes a long-running loop mode with persistent state and review gates.

It is implemented as:
- Claude Code hooks (`SessionStart`, `Stop`, `PreCompact`) configured in `hooks/hooks.json`
- A Zig CLI (`bin/idle`) that implements those hooks (and a few helper commands)
- One read-only reviewer agent `idle:alice`, with support for consensus via discussion with other agents, like Codex and Gemini

## Install

### Recommended: release installer

This installs the plugin, installs/updates dependencies, and drops the correct `bin/idle` for your OS/arch into the Claude plugin cache:

```sh
curl -fsSL https://github.com/evil-mind-evil-sword/idle/releases/latest/download/install.sh | sh
```

This is the easiest way to get a working `bin/idle` on Linux and macOS (x86_64 + arm64). The repository itself currently contains a macOS arm64 binary in `bin/idle`.

### Manual: Claude marketplace

```sh
claude plugin marketplace add evil-mind-evil-sword/marketplace
claude plugin marketplace refresh
claude plugin install idle@emes
```

## Implementation

### Looping

The loop is driven by a message in the zawinski store (the `.zawinski/` directory) on topic `loop:current`.

- If `loop:current` has an active stack frame, the `Stop` hook blocks Claude from exiting (exit code `2`) and forces another iteration.
- If your last assistant message contains a completion marker, the `Stop` hook allows exit (exit code `0`).
- For `COMPLETE` and `STUCK`, the first completion attempt is intercepted to request an `idle:alice` review; you then re-signal completion to exit.

### Claude Code surface area

idle ships:

- Commands (prompt templates in `commands/`):
  - `/loop` – describes the loop contract and completion markers
  - `/cancel` – describes how to cancel an active loop
  - `/init` – guided “initialize + plan” workflow
- Agent:
  - `idle:alice` – read-only adversarial reviewer (`agents/alice.md`)
- Skills (prompt templates in `skills/`):
  - `reviewing`, `researching`, `issue-tracking`, `technical-writing`, `bib-managing`

### Completion signals (must be exact)

The `Stop` hook scans the *last assistant message text* and looks for one of these **exact** lines:

```
<loop-done>COMPLETE</loop-done>
<loop-done>STUCK</loop-done>
<loop-done>MAX_ITERATIONS</loop-done>
```

Rules (these are enforced by the parser in `cli/src/lib/state_machine.zig`):
- The tag must start at column 0 (no leading spaces/tabs)
- The line must match exactly (no extra characters or trailing spaces)

### Starting a loop

In Claude Code, start by running `/loop <task>`. Before iterating, initialize the loop state:

```bash
idle init-loop
```

This initializes `.zawinski/` (messaging), `.tissue/` (issues), and `loop:current` state. If a loop is already active, it leaves it alone.

### Hooks

#### `SessionStart` (`bin/idle session-start`)

- If a loop is active, injects `Mode` and `Iteration` context at the start of the session.
- Always injects “idle:alice is available” guidance.
- If a `.tissue/` store exists, lists up to 15 ready issues.

#### `Stop` (`bin/idle stop`)

- Syncs the Claude transcript into the `.zawinski/` database (if present).
- Reads `loop:current` and decides whether to allow exit (`0`) or block (`2`).
- Blocks on every iteration until completion/max iterations; if `updated_at` is older than 2 hours, the loop is treated as stale and exit is allowed.
- On iterations 3, 6, 9, … injects a checkpoint message requesting an `idle:alice` checkpoint review.
- On `<loop-done>COMPLETE</loop-done>` or `<loop-done>STUCK</loop-done>`, blocks once to request `idle:alice` completion review.
- On `MAX_ITERATIONS`, posts a `DONE` state and allows exit.

#### `PreCompact` (`bin/idle pre-compact`)

- If a loop is active, posts a recovery “anchor” message to `loop:anchor` in `.zawinski/`.
- Prints a reminder to recover with `jwz read loop:anchor` after compaction.

## Observability & control

```sh
idle status        # human-readable (mode + iteration)
idle status --json # raw JSON from loop:current

jwz read loop:current --limit 1
jwz read loop:anchor  --limit 1
```

## CLI reference

`bin/idle` is both the hook implementation and a small helper CLI:

```text
idle stop | pre-compact | session-start
idle status [--json]
idle doctor
idle emit <topic> <role> <action> [--task-id ID] [--status S] [--confidence C] [--summary TEXT]
idle issues [ready|show <id>|close <id>] [--json]
idle version
```

Exit codes:
- `0`: allow/success
- `1`: error
- `2`: block (hook tells Claude Code to re-enter)

## License

AGPL-3.0
