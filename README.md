# trivial

Multi-model development agents for Claude Code.

## Agents

| Agent | Model | Description |
|-------|-------|-------------|
| `explorer` | haiku | Local codebase search and exploration |
| `librarian` | haiku | Remote code research (GitHub, docs, APIs) |
| `oracle` | opus | Deep reasoning with Codex dialogue |
| `documenter` | opus | Technical writing with Gemini |
| `reviewer` | opus | Code review with Codex dialogue |
| `planner` | opus | Design and issue tracker curation with Codex |

## Commands

### Dev Commands

| Command | Description |
|---------|-------------|
| `/work` | Pick an issue and work it to completion |
| `/fmt` | Auto-detect and run project formatter |
| `/test` | Auto-detect and run project tests |
| `/review` | Run code review via reviewer agent |
| `/plan` | Design discussion or backlog curation via planner agent |

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

## License

MIT
