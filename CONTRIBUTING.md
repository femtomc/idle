# Contributing to idle

Thank you for your interest in contributing to idle!

## Development Setup

1. Clone the repository:
   ```shell
   git clone https://github.com/femtomc/idle.git
   cd idle
   ```

2. Install dependencies:
   ```shell
   # jwz (messaging)
   # See: https://github.com/femtomc/zawinski

   # tissue (issue tracking)
   # See: https://github.com/femtomc/tissue

   # jq (JSON parsing)
   brew install jq  # or apt-get install jq
   ```

3. Run Claude Code with the plugin:
   ```shell
   claude --plugin-dir .
   ```

4. Test the stop hook:
   ```shell
   # The stop hook will block exit until alice reviews
   # Run /alice to trigger a review
   ```

## Adding a New Agent

1. Create a new file in `agents/`:
   ```
   agents/your-agent.md
   ```

2. Add YAML frontmatter:
   ```yaml
   ---
   name: your-agent
   description: When to use this agent (shown in agent picker)
   model: haiku | opus
   tools: Read, Grep, Glob, Bash
   ---
   ```

3. Write the agent instructions:
   - **Role**: What the agent does
   - **Constraints**: What the agent MUST NOT do
   - **Workflow**: How the agent operates
   - **Output Format**: Expected response structure

4. The agent becomes available as `idle:your-agent`

See `agents/alice.md` for an example.

## Adding a New Skill

1. Create a new directory in `skills/`:
   ```
   skills/your-skill/SKILL.md
   ```

2. Add YAML frontmatter:
   ```yaml
   ---
   name: your-skill
   description: What the skill does (third person voice)
   ---
   ```

3. Write the skill specification:
   - **When to Use**: Trigger conditions
   - **Workflow**: Step-by-step execution
   - **Output**: Expected artifacts or results

See `skills/messaging/SKILL.md` for a tool documentation skill or `skills/researching/SKILL.md` for a composition skill.

## Code Style

- Agent/command/skill files are Markdown with YAML frontmatter
- Use clear, imperative language in instructions
- Be explicit about constraints (what the agent MUST NOT do)
- Include concrete examples in workflows

## Messaging Guidelines

Agents communicate via zawinski messaging (`jwz` CLI). All artifacts and findings are stored in jwz, not local files.

### Topic Naming

| Pattern | Purpose |
|---------|---------|
| `project:<name>` | Project-wide announcements |
| `issue:<id>` | Per-issue discussion |
| `agent:<name>` | Direct agent communication |

### Message Format

```
[agent] ACTION: description

Examples:
[alice] ANALYSIS: Auth flow race condition
[alice] DECISION: Use JWT with refresh tokens
[loop] LANDED: issue-123
```

## Testing

idle doesn't have automated tests. Manual testing workflow:

1. Load the plugin with `claude --plugin-dir`
2. Invoke your agent/skill
3. Verify it behaves as documented
4. Test edge cases (missing dependencies, errors)

## Pull Request Process

1. Fork the repository
2. Create a branch for your change
3. Add/modify agents or skills
4. Test manually
5. Submit a PR with:
   - Clear description of what you added/changed
   - Any new dependencies required
   - Example usage

## Architecture

For a deeper understanding of how idle works, see [docs/architecture.md](docs/architecture.md).
