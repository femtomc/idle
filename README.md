# idle

**An opinionated outer harness for Claude Code.** Long-running loops, multi-model consensus, memory notes via local issue tracker and mail for agents.

`idle` is a (very) opinionated plugin for Claude Code (CC) that overloads several of CC's native points of extension (subagents, hooks, etc) so that one may usefully use
CC for long running, open ended tasks.

Note: `idle` will likely break other plugins that you may be using with Claude Code (especially if they define their own hooks). It's kind of a "batteries included" plugin.

## Why?

I dream of freeing myself from careful and methodical curation of my Claude Code sessions. Much of my time spent manually moving context around, manually saving context, manually directing Claude to do tasks.

This plugin bundles together an issue tracker, a message passing tool, and two specialized subagents, along with overloading CC's hooks to allow you to kind of just let Claude drive itself for a very long time. Now, there's still a bunch of issues doing this today (like: it can still totally go off the rails, and you have to be precise). To combat some of these problems, another thing this plugin does is provide subagent hook overloads to force some of the specialized subagents to shell out to Codex / Gemini for second opinions. This, it turns out, seems to be very useful -- at least, it seems to nullify some of the "self bias" issues you might get if you have Claude review Claude.

Overall:
- **Outer harness:** Provides a structured runtime that controls agent execution, manages worktrees, and handles state persistence across sessions.
- **Loop:** Enables agents to break out of single-turn interactions to perform continuous iterative work.
- **Consensus:** Mitigates LLM self-bias and hallucinations by requiring agreement between distinct models (or fresh contexts) before committing to critical paths.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/evil-mind-evil-sword/idle/main/install.sh | sh
```

Then in Claude Code:
```
/plugin marketplace add evil-mind-evil-sword/marketplace
/plugin install idle@emes
```

## Agents

| Agent | Model | Second Opinion | Description |
|-------|-------|----------------|-------------|
| `alice` | opus | codex or claude | Deep reasoning, quality gates, design decisions |
| `bob` | haiku | — | External research with citations (GitHub, docs, APIs) |

### How it works

idle acts as an "outer harness" for Claude Code that orchestrates specialized agents within a continuous loop. bob handles fast information retrieval, while alice drives complex reasoning with multi-model consensus.

When the primary agent needs deep analysis or quality validation, alice consults a secondary model. If an external model (Codex) is available, it provides an independent perspective. If not, alice falls back to `claude -p`, creating a fresh context to break the self-refinement loop.

### Why Consensus?

- **Self-Bias:** Single models tend to validate their own errors when asked to double-check. Consensus forces an external review to break this validation loop.
- **Correlated Failures:** Distinct model architectures have different blind spots. Consensus between Claude and Codex catches edge cases that a single model family might miss.
- **Efficiency:** The harness routes simple tasks to bob (fast, cheap) and reserves the expensive consensus process for alice's complex reasoning steps.

See [docs/architecture.md](docs/architecture.md) for details.

## Skills

Auto-discovered capabilities based on context:

| Skill | Description |
|-------|-------------|
| `messaging` | Post/read jwz messages for agent coordination |
| `issue-tracking` | Create/manage tissue issues for work tracking |
| `researching` | Comprehensive research with quality gate (bob → alice) |

## Commands

| Command | Description |
|---------|-------------|
| `/loop [task]` | Universal iteration loop. With args: iterate on task. Without args: work through issue tracker (auto-lands, picks next) |
| `/cancel` | Cancel the active loop |

## Worktrees

idle uses git worktrees to enable parallel work. Each issue gets its own isolated environment:

- **Isolation:** Changes happen in `.worktrees/idle/<issue-id>/`
- **Parallelism:** You can have multiple agents working on different issues simultaneously
- **Workflow:**
    1. `/loop` (without args) picks an issue and creates a worktree
    2. Agent works in that directory
    3. On completion, auto-lands (merges to main, cleans up worktree)
    4. Loop automatically picks next issue

## Requirements

### Required

- [tissue](https://github.com/femtomc/tissue) - Issue tracker (for `/loop` issue mode)
- [zawinski](https://github.com/femtomc/zawinski) - Async messaging (for agent communication)
- [uv](https://github.com/astral-sh/uv) - Python package runner (for `scripts/search.py`)
- [gh](https://cli.github.com/) - GitHub CLI (for bob's GitHub research)
- [bibval](https://github.com/evil-mind-evil-sword/bibval) - Citation validator (for bob's academic research)

### Optional (for enhanced multi-model diversity)

- [codex](https://github.com/openai/codex) - OpenAI coding agent → used by alice for second opinions

When codex is not installed, alice falls back to `claude -p` for second opinions.

## Quickstart

A typical workflow with idle:

```shell
# Work through your issue backlog (picks issues, auto-lands, repeats)
/loop

# Or iterate on a specific task
/loop Add input validation to all API endpoints
```

## Examples

### Work through your backlog

```shell
# Create some issues
tissue new "Add user authentication" -p 1 -t feature
tissue new "Fix login redirect bug" -p 1 -t bug
tissue new "Refactor database queries" -p 2 -t tech-debt

# Work through issues automatically
/loop
# → Picks first ready issue, creates worktree
# → Works on it, auto-lands on completion
# → Picks next issue, repeats until backlog empty
```

### Iterate on a specific task

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
# Research external code (fast, uses haiku)
"How does React Query handle cache invalidation?"
# → bob fetches docs and explains with citations

# Deep reasoning on hard problems (thorough, uses opus + second opinion)
"I'm stuck on this race condition, help me debug it"
# → alice analyzes with external dialogue, provides recommendation

# Comprehensive research with quality gate
/researching OAuth 2.0 best practices for SPAs
# → bob researches, alice validates, produces verified artifact
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

Required for: `/loop` (issue mode)

### jwz: command not found

Install the jwz messaging CLI:

```shell
cargo install --git https://github.com/femtomc/zawinski jwz
```

Required for: agent-to-agent messaging. Initialize with `jwz init`.

### codex: command not found

**This is optional.** alice will use `claude -p` for second opinions instead.

To enable OpenAI diversity:
```shell
npm install -g @openai/codex
```

### Agent not responding or errors

1. Check that required tools are installed: `which tissue`, `which jwz`, `which uv`, `which gh`
2. If using codex, verify API credentials (`OPENAI_API_KEY`)
3. Try running the tool directly to see its error output

### No issues found

If `/loop` (without args) reports no issues:

1. Ensure you're in a directory with a `.tissue` folder
2. Run `tissue list` to see available issues
3. Run `tissue ready` to see issues ready to work (no blockers)
4. Run `tissue init` to create a new issue tracker

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
git worktree prune      # Clean up orphaned worktrees
git worktree list       # Check current worktrees
```

## License

AGPL-3.0
