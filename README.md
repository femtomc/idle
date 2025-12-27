# trivial

This is a Claude Code plugin which you can conveniently install using the marketplace.

It provides long running agents with conversational support from Codex / Gemini.

The features are inspired by AmpCode, Anthropic's blog post on long running agentic harnesses, and several academic papers which study the "self-bias" problem.

## Agents

| Agent | Model | Description |
|-------|-------|-------------|
| `explorer` | haiku | Local codebase search and exploration |
| `librarian` | haiku | Remote code research (GitHub, docs, APIs) |
| `oracle` | opus | Deep reasoning with Codex dialogue |
| `documenter` | opus | Technical writing with Gemini 3 Flash |
| `reviewer` | opus | Code review with Codex dialogue |
| `planner` | opus | Design and issue tracker curation with Codex |

### How it works

trivial delegates tasks to the right model for the job: fast models (haiku) handle search, while powerful models (opus) tackle reasoning. For critical decisions, opus agents consult external models—Codex and Gemini—to validate conclusions, mitigating the self-bias inherent in single-model workflows. This multi-model collaboration catches blind spots and ensures reliability that no single architecture can achieve alone.

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
| `/plan` | Design discussion or backlog curation via planner agent |
| `/commit` | Commit staged changes with generated message |

### Loop Commands

| Command | Description |
|---------|-------------|
| `/loop <task>` | Iterative loop until task is complete |
| `/grind [filter]` | Continuously work through issue tracker |
| `/issue <id>` | Work on a specific tissue issue |
| `/cancel-loop` | Cancel the active loop |

## Requirements

- [tissue](https://github.com/femtomc/tissue) - Issue tracker (for `/work`, `/grind`, `/issue`)
- [codex](https://github.com/openai/codex) - OpenAI coding agent (for oracle/reviewer agents)
- [gemini-cli](https://github.com/google-gemini/gemini-cli) - Google Gemini CLI (for documenter agent)

## Installation

### As a marketplace

```shell
/plugin marketplace add femtomc/trivial
/plugin install trivial@trivial
```

### For development

```shell
claude --plugin-dir /path/to/trivial
```

## Quickstart

A typical workflow with trivial:

```shell
# 1. Plan your work
/plan Break down the authentication feature

# 2. Pick an issue and work it
/issue auth-1abc2def

# 3. Review your changes
/review

# 4. Run tests
/test

# 5. Commit when ready
/commit
```

For continuous work through your issue backlog:

```shell
/grind priority:1   # Work through all P1 issues
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
# → Works trivial-abc123 (authentication)
# → Works trivial-def456 (login bug)
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

# Deep reasoning on hard problems (thorough, uses opus + Codex)
"I'm stuck on this race condition, help me debug it"
# → oracle agent analyzes with Codex, provides recommendation
```

## Troubleshooting

### tissue: command not found

Install the tissue issue tracker:

```shell
# See https://github.com/femtomc/tissue for installation
cargo install tissue
```

Required for: `/work`, `/grind`, `/issue`

### codex: command not found

Install the OpenAI Codex CLI:

```shell
# See https://github.com/openai/codex
npm install -g @openai/codex
```

Required for: `oracle`, `reviewer`, `planner` agents

### gemini: command not found

Install the Google Gemini CLI:

```shell
# See https://github.com/google-gemini/gemini-cli
npm install -g @google/gemini-cli
```

Required for: `documenter` agent

### Agent not responding or errors

1. Verify the external tool is installed: `which tissue`, `which codex`, `which gemini`
2. Check API credentials are configured (Codex needs `OPENAI_API_KEY`, Gemini needs Google auth)
3. Try running the external tool directly to see its error output

### No issues found

If `/work` or `/grind` reports no issues:

1. Ensure you're in a directory with a `.tissue` folder
2. Run `tissue list` to see available issues
3. Run `tissue init` to create a new issue tracker

## License

MIT
