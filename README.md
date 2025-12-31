# idle

Quality gate for Claude Code.

Every exit requires alice review. No issues = exit allowed.

## How It Works

```
Agent works → tries to exit → Stop hook → alice reviewed? → block/allow
```

1. **Stop hook** checks for alice review decision in jwz
2. If no review: blocks exit, tells agent to run `/alice`
3. **alice** reviews the work, creates `alice-review` issues for problems
4. **No open issues** = exit allowed. **Issues exist** = keep working.

## Install

```sh
curl -fsSL https://github.com/evil-mind-evil-sword/idle/releases/latest/download/install.sh | sh
```

This installs:
- `jwz` - Agent messaging
- `tissue` - Issue tracking
- The idle plugin (registered with Claude Code)

## Skills

| Skill | Purpose |
|-------|---------|
| reviewing | Multi-model second opinions |
| researching | Cited research with verification |
| issue-tracking | Work tracking via tissue |
| technical-writing | Multi-layer document review |
| bib-managing | Bibliography curation |

## Dependencies

- `jwz` - Agent messaging ([zawinski](https://github.com/femtomc/zawinski))
- `tissue` - Issue tracking ([tissue](https://github.com/femtomc/tissue))
- `jq` - JSON parsing

## License

AGPL-3.0
