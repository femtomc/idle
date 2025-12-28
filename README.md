# idle

A Claude Code plugin for long-running agentic workflows with multi-model collaboration.

Agents consult external models (Codex, Gemini) for "second opinions" to mitigate self-bias—but these are **optional**. When unavailable, agents fall back to `claude -p` which provides fresh context and still breaks the self-refinement loop.

Inspired by AmpCode, Anthropic's research on agentic harnesses, and academic work on the self-bias problem in LLMs.

## Agents

| Agent | Model | Second Opinion | Description |
|-------|-------|----------------|-------------|
| `explorer` | haiku | — | Local codebase search and exploration |
| `librarian` | haiku | — | Remote code research (GitHub, docs, APIs) |
| `oracle` | opus | codex or claude | Deep reasoning with external dialogue |
| `documenter` | opus | gemini or claude | Technical writing with external writer |
| `reviewer` | opus | codex or claude | Code review with external dialogue |

### How it works

idle delegates tasks to the right model for the job: fast models (haiku) handle search, while powerful models (opus) tackle reasoning. For critical decisions, opus agents consult a "second opinion" to validate conclusions:

- **If codex/gemini installed**: Uses external model for maximum architectural diversity
- **If not installed**: Falls back to `claude -p` which starts fresh context, still breaking self-bias

Either way, you get multi-perspective validation. External models are preferred for diversity, but the plugin works out of the box with just Claude.

### Why Multi-Model?

- **Self-Bias:** Single models favor their own outputs when self-evaluating. Cross-model review breaks this loop.
- **Correlated Failures:** Different architectures have different blind spots—Claude, Codex, and Gemini together catch errors none would alone.
- **Efficiency:** Fast models (haiku) handle bulk work; powerful models (opus) focus on high-leverage reasoning.

See [docs/architecture.md](docs/architecture.md) for details.

## Commands

### Dev Commands

| Command | Description |
|---------|-------------|
| `/work` | Pick an issue and work it to completion |
| `/fmt` | Auto-detect and run project formatter |
| `/test` | Auto-detect and run project tests |
| `/review` | Run code review via reviewer agent |
| `/document` | Write technical docs via documenter agent |
| `/commit` | Commit staged changes with generated message |

### Loop Commands

| Command | Description |
|---------|-------------|
| `/loop <task>` | Iterative loop until task is complete |
| `/grind [filter]` | Continuously work through issue tracker |
| `/issue <id>` | Work on a specific tissue issue |
| `/land <id>` | Merge a completed issue worktree |
| `/cancel-loop` | Cancel the active loop |

## Worktrees

idle uses git worktrees to enable parallel work. Each issue gets its own isolated environment:

- **Isolation:** Changes happen in `.worktrees/idle/<issue-id>/`
- **Parallelism:** You can have multiple agents working on different issues simultaneously
- **Workflow:**
    1. `/issue <id>` creates/switches to a worktree
    2. Agents work in that directory
    3. `/land <id>` merges changes back to main and removes the worktree
    4. `/worktree` command helps manage orphaned trees

## Requirements

### Required

- [tissue](https://github.com/femtomc/tissue) - Issue tracker (for `/work`, `/grind`, `/issue`)
- [zawinski](https://github.com/femtomc/zawinski) - Async messaging (for agent communication)
- [uv](https://github.com/astral-sh/uv) - Python package runner (for `scripts/search.py`)
- [gh](https://cli.github.com/) - GitHub CLI (for librarian agent)

### Optional (for enhanced multi-model diversity)

- [codex](https://github.com/openai/codex) - OpenAI coding agent → used by oracle/reviewer
- [gemini-cli](https://github.com/google-gemini/gemini-cli) - Google Gemini CLI → used by documenter

When these are not installed, agents fall back to `claude -p` for second opinions.

## Installation

### Quick install

Install dependencies first:

```shell
curl -fsSL https://raw.githubusercontent.com/femtomc/idle/main/install.sh | sh
```

Then in Claude Code:

```
/plugin marketplace add femtomc/idle
/plugin install idle@idle
```

### For development

```shell
claude --plugin-dir /path/to/idle
```

## Quickstart

A typical workflow with idle:

```shell
# 1. Plan your work

# 2. Work an issue (runs test, fmt, review, commit automatically)
/issue auth-1abc2def

# 3. Or grind through your backlog
/grind priority:1
```

For ad-hoc tasks without an issue tracker:

```shell
/loop Add input validation to all API endpoints
```

## Examples

### Work through your backlog

```shell
# Create some issues
tissue new "Add user authentication" -p 1 -t feature
tissue new "Fix login redirect bug" -p 1 -t bug
tissue new "Refactor database queries" -p 2 -t tech-debt

# Grind through P1 issues automatically
/grind priority:1
# → Works idle-abc123 (authentication)
# → Works idle-def456 (login bug)
# → Reports: 2 issues completed, 1 remaining
```

### Iterate without an issue tracker

```shell
# Use /loop for ad-hoc iterative tasks
/loop Add input validation to all API endpoints

# Claude will:
# - Find API endpoints
# - Add validation incrementally
# - Run tests after changes
# - Continue until done or stuck
```

### Call agents directly

```shell
# Explore the local codebase (fast, uses haiku)
"How does the authentication flow work?"
# → explorer agent searches and explains

# Research external code (fast, uses haiku)
"How does React Query handle cache invalidation?"
# → librarian agent fetches docs and explains

# Deep reasoning on hard problems (thorough, uses opus + second opinion)
"I'm stuck on this race condition, help me debug it"
# → oracle agent analyzes with external dialogue, provides recommendation
```

## Observability

Monitor your agent loops:

- `idle status` - Show human-readable status of the current loop
- `idle status --json` - Machine-readable output for tooling

## Roadmap

- **Phase 1 (Current):** Bash scripts + Claude Plugin architecture.
- **Phase 2:** Rewrite core logic in Zig for performance and reliability.
- **Phase 3:** Terminal User Interface (TUI) for interactive loop management.

## Troubleshooting

### tissue: command not found

Install the tissue issue tracker:

```shell
cargo install --git https://github.com/femtomc/tissue tissue
```

Required for: `/work`, `/grind`, `/issue`

### jwz: command not found

Install the jwz messaging CLI:

```shell
cargo install --git https://github.com/femtomc/zawinski jwz
```

Required for: agent-to-agent messaging. Initialize with `jwz init`.

### codex: command not found

**This is optional.** Agents will use `claude -p` for second opinions instead.

To enable OpenAI diversity:
```shell
npm install -g @openai/codex
```

### gemini: command not found

**This is optional.** The documenter will use `claude -p` for writing instead.

To enable Gemini diversity:
```shell
npm install -g @google/gemini-cli
```

### Agent not responding or errors

1. Check that required tools are installed: `which tissue`, `which jwz`, `which uv`, `which gh`
2. If using codex/gemini, verify API credentials (Codex needs `OPENAI_API_KEY`, Gemini needs Google auth)
3. Try running the tool directly to see its error output

### No issues found

If `/work` or `/grind` reports no issues:

1. Ensure you're in a directory with a `.tissue` folder
2. Run `tissue list` to see available issues
3. Run `tissue init` to create a new issue tracker

### Zombie loops

State exists in jwz but Claude is not running.

**Symptoms:** `idle status` shows an active loop but no Claude process is running.

**Fix:**
```shell
IDLE_LOOP_DISABLE=1 claude  # Bypass loop hook
```

Or reset all state:
```shell
rm -rf .jwz/
```

### Worktree conflicts

Case-insensitive filesystem collisions on macOS/Windows.

**Symptoms:** Issue IDs `ABC` and `abc` create conflicting worktrees. Or orphaned worktrees (directory deleted but git still tracks it).

**Fix:**
```shell
/worktree prune         # Via idle
git worktree prune      # Or directly
```

## License

MIT
