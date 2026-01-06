# idle

Quality gate plugin for Claude Code. Blocks Claude from stopping (via Claude Code's Stop hook) until work passes review by an independent agent. 

Be aware: 
- It's kind of like a "super ultra extra thinking" mode for Claude Code, with some interesting and useful properties.
- Can accidentally (or intentionally) be used to run Claude Code for many hours without intervention.
- I would not recommend unless you're rolling a variant of the Max plan. The reviews are extensive and exhaustive, and the token usage is consequentially large.

## Install

```sh
curl -fsSL https://github.com/evil-mind-evil-sword/idle/releases/latest/download/install.sh | sh
```

This installs:
- `jwz` - Agent messaging
- `tissue` - Issue tracking
- `jq` - JSON parsing (if needed)
- The idle plugin (registered with Claude Code)

Those other two binaries (`jwz` and `tissue`) are small Zig programs which allow Claude Code to store issues, messages, retain state (all in JSONL + SQLite, like `beads`) -- and are used by `idle` to track the state required to enforce the reviewer pattern (as well as giving Claude Code a place to store issues, research notes, etc). The plugin assumes these binaries are available and contains explicit instructions for how the agent should use them. The goal here is to make it easy to install these and get started (meaning: the goal is you shouldn't have to think about them!)

## Motivation

LLMs struggle to reliably evaluate their own outputs ([Huang et al., 2023](https://arxiv.org/abs/2310.01798)). A model asked to verify its work tends to confirm rather than critique. This creates a gap in agentic coding workflows—agents can exit believing they've completed a task when issues remain.

Research on multi-agent debate suggests a path forward: models produce more accurate outputs when they critique each other ([Du et al., 2023](https://arxiv.org/abs/2305.14325); [Liang et al., 2023](https://arxiv.org/abs/2305.19118)).

idle applies this idea: rather than prompting agents to review themselves, it blocks exit until an independent reviewer (alice, a subagent) explicitly approves.

## Usage

```
#idle <your prompt>
```

Review is opt-in per-prompt. After alice approves, the gate resets automatically.

## How It Works

```
Agent works → tries to exit → Stop hook → alice reviewed? → block/allow
```

1. **Stop hook** intercepts every agent exit attempt
2. `#idle` at start of prompt enables review via [jwz](https://github.com/evil-mind-evil-sword/zawinski)
3. If review enabled but no approval: blocks exit, agent must spawn alice
4. **alice** (adversarial reviewer) examines the work
5. Creates [tissue](https://github.com/evil-mind-evil-sword/tissue) issues for problems found
6. Posts decision: `COMPLETE` allows exit, `ISSUES` keeps agent working

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                         Claude Code                            │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                     idle plugin                          │  │
│  │                                                          │  │
│  │   ┌─────────┐                                            │  │
│  │   │  alice  │   Reviewer agent (Claude Opus)             │  │
│  │   │         │   Read-only: cannot modify files           │  │
│  │   └────┬────┘                                            │  │
│  │        │ posts decision                                  │  │
│  │        ▼                                                 │  │
│  │  ┌───────────┐         ┌───────────┐                     │  │
│  │  │    jwz    │         │  tissue   │                     │  │
│  │  │ (messages)│         │ (issues)  │                     │  │
│  │  └───────────┘         └───────────┘                     │  │
│  │        ▲                     ▲                           │  │
│  │        │ reads status        │ checks issues             │  │
│  │        │                     │                           │  │
│  │  ┌─────┴─────────────────────┴─────┐                     │  │
│  │  │           Stop Hook             │                     │  │
│  │  │     (hooks/stop-hook.sh)        │                     │  │
│  │  └─────────────────────────────────┘                     │  │
│  └──────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
```

## Design Philosophy

Three principles guide idle's architecture:

| Principle | Implementation |
|-----------|----------------|
| **Pull over push** | Agents retrieve context on demand, not via large upfront injections |
| **Safety over policy** | Critical guardrails enforced mechanically (hooks), not via prompts |
| **Pointer over payload** | Messages contain references (issue IDs, session IDs), not inline content |

## Skills

idle extends Claude Code with domain-specific capabilities:

| Skill | Purpose | When to Use |
|-------|---------|-------------|
| **reviewing** | Query other LLMs for a second opinion | When you want another model to check the work |
| **researching** | Cited research with source verification | Complex topics requiring evidence |
| **issue-tracking** | Git-native work tracking via tissue | Managing tasks, dependencies, priorities |
| **technical-writing** | Multi-layer document review (structure/clarity/evidence) | Documentation, design docs, papers |
| **bib-managing** | Bibliography curation with bibval | Academic citations, reference validation |

### Reviewing Skill

The reviewing skill queries external models for independent perspectives:

```
Priority: codex CLI → gemini CLI → claude -p fallback
```

This provides a second opinion from a different model. Configure the specific models via each CLI's settings.

## Alice

alice is the reviewer agent. It critiques the main agent's work rather than accepting it uncritically. Key properties:

- **Model**: Claude Opus
- **Access**: Read-only (cannot modify files)
- **Tools**: Read, Grep, Glob, Bash (restricted to `tissue` and `jwz` commands)

alice reviews proportionally to scope:
- Simple Q&A → instant `COMPLETE`
- Bug fix → verify the fix is correct
- New feature → check implementation completeness
- Refactor → ensure behavior is preserved

When issues are found, alice creates tissue issues tagged `alice-review` and blocks exit until they're resolved.

## Related Work

| Area | Reference | Relevance to idle |
|------|-----------|-------------------|
| Self-correction limits | [Huang et al., 2023](https://arxiv.org/abs/2310.01798) | Motivates using a separate reviewer rather than self-review |
| Multi-agent debate | [Du et al., 2023](https://arxiv.org/abs/2305.14325) | Supports querying multiple models for review |
| Constitutional AI | [Bai et al., 2022](https://arxiv.org/abs/2212.08073) | Informs alice's structured critique approach |
| Code review practices | [Sadowski et al., 2018](https://dl.acm.org/doi/10.1145/3183519.3183525) | Supports mandatory review before landing code |

## Dependencies

| Dependency | Purpose | Required |
|------------|---------|----------|
| [jwz](https://github.com/evil-mind-evil-sword/zawinski) | Agent messaging and coordination | Yes |
| [tissue](https://github.com/evil-mind-evil-sword/tissue) | Git-native issue tracking | Yes |
| jq | JSON parsing in hooks | Yes |
| codex | OpenAI CLI for second opinions (reviewing skill) | Optional |
| gemini | Google CLI for second opinions (reviewing skill) | Optional |
| [bibval](https://github.com/evil-mind-evil-sword/bibval) | Citation validation (bib-managing skill) | Optional |

## Session Traces

idle captures session events for post-hoc analysis via the `idle` CLI:

```bash
# Show trace for a session
idle trace <session_id>

# Verbose mode - see tool inputs and outputs
idle trace <session_id> -v

# Export as GraphViz DOT
idle trace <session_id> --format dot > trace.dot
```

**Example output:**

```
=== Session abc123 ===

[1] prompt_received: "Fix the auth bug" (01KE5DEF)
[2] tool_completed: Read (01KE5GHI)
[3] tool_completed: Edit (01KE5JKL)
[4] tool_completed: Bash [FAILED] (01KE5MNO)

4 events total
=== End Session ===
```

Traces help debug tool failures and understand agent behavior.

## Project Structure

```
idle/
├── .claude-plugin/
│   └── plugin.json        # Plugin metadata
├── agents/
│   └── alice.md           # Adversarial reviewer
├── hooks/
│   ├── hooks.json         # Hook configuration
│   ├── stop-hook.sh       # Quality gate
│   └── user-prompt-hook.sh
├── skills/
│   ├── reviewing/         # Multi-model consensus
│   ├── researching/       # Cited research
│   ├── issue-tracking/    # tissue integration
│   ├── technical-writing/ # Document review
│   └── bib-managing/      # Bibliography curation
├── src/                   # Zig CLI source
│   ├── main.zig
│   ├── root.zig
│   └── trace.zig
├── docs/
│   ├── architecture.md    # Detailed design
│   └── references.bib     # Academic sources
└── tests/
    └── stop-hook-test.sh  # Hook tests
```

## Further Reading

- [Architecture documentation](docs/architecture.md) - Detailed design and flow diagrams
- [Contributing guide](CONTRIBUTING.md) - How to add agents and skills
- [Changelog](CHANGELOG.md) - Version history

## License

AGPL-3.0
