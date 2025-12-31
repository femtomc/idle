# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.4.0] - 2025-12-30

### Added

- **Alice review on completion signals** - Stop hook triggers alice review
  - When Claude signals `COMPLETE` or `STUCK`, blocks exit for alice review
  - `reviewed` flag in StackFrame tracks review state
  - After alice review, loop can complete normally
- **Enhanced SessionStart hook** - Injects full loop context
  - Shows active loop state (mode, iteration, issue, worktree, branch)
  - Comprehensive alice usage guidance
- **Enhanced PreCompact hook** - Alice reminder in recovery anchor
  - Anchor JSON includes `alice_reminder` field
  - Output reminds about alice availability before compaction

### Removed

- **Hooks simplified** - Removed SubagentStop and PreToolUse hooks
  - SubagentStop (alice second-opinion enforcement) removed
  - PreToolUse (Bash safety guardrails) removed
  - safety.zig module removed
- **TUI module removed** - Duplicate code in `tui/` directory removed
- **REFACTOR_PLAN.md removed** - Obsolete planning document
- **Agents removed**: `bob` (orchestrator) and `charlie` (worker) agents removed
  - spawn.zig module removed
  - spawn command removed from CLI

### Changed

- **Architecture docs updated** - Reflects Zig CLI hooks, removes stale references
- **3 hooks remain**: Stop, SessionStart, PreCompact

## [1.3.0] - 2025-12-29

### Added

- **Orchestrator/Worker architecture** for scalable research
  - `charlie` agent: Haiku-based leaf worker for focused tasks
  - bob upgraded to Opus orchestrator that spawns workers via `claude -p`
  - Recursive decomposition with bounds (MAX_DEPTH=3, MAX_WORKERS=10)
  - Task contracts with deliverables and acceptance criteria
  - Parallel worker dispatch with jwz coordination

### Changed

- `bob` model upgraded from haiku to opus (orchestration role)
- `researching` skill updated for orchestrator/worker pattern
- All inter-agent communication via jwz messaging

### Architecture

```
bob (orchestrator, opus)
 ├─→ bob (recursive, if complex)
 │    └─→ charlie (worker, haiku)
 └─→ charlie (worker, haiku)
      └─→ alice (review, on request)
```

## [1.2.0] - 2025-12-29

### Changed

- **Skills aligned with Claude best practices** (per platform.claude.com/docs)
- Renamed `codex` skill to `querying-codex` (gerund naming convention)
- Renamed `gemini` skill to `querying-gemini` (gerund naming convention)
- Condensed ASCII workflow diagrams in `bib-managing` skill (505→392 lines)

### Added

- Per-skill `references.bib` files tracking design rationale sources
  - `technical-writing/references.bib` - Strunk & White, Pinker, Peyton Jones, etc.
  - `researching/references.bib` - Self-Refine, quality gate patterns
  - `bib-managing/references.bib` - DBLP, CrossRef, Semantic Scholar
  - `querying-codex/references.bib` - LLM self-bias, multi-agent debate
  - `querying-gemini/references.bib` - Multi-model consensus
  - `messaging/references.bib` - Enterprise Integration Patterns

## [1.1.0] - 2025-12-28

### Added

- `technical-writing` skill with multi-layer review (STRUCTURE/CLARITY/EVIDENCE)
- `bib-managing` skill for bibliography curation with bibval
- `codex` skill for OpenAI Codex CLI second opinions
- `gemini` skill for Google Gemini CLI third perspectives

## [1.0.0] - 2025-12-27

### Added

- Initial stable release with bob/alice agents and core skills

## [0.7.0] - 2025-12-27

### Changed

- **Project renamed from `trivial` to `idle`**
- All directory paths: `.claude/plugins/idle/`, `.worktrees/idle/`
- Git branch naming: `idle/issue/<id>`
- Git config key: `idle.baseRef`
- Temp directories: `/tmp/idle-*`
- State files: `.claude/idle-loop.local.md`
- Environment variable: `IDLE_LOOP_DISABLE`
- Command namespaces: `idle:dev:*`, `idle:loop:*`
- GitHub repository: `femtomc/idle`

## [0.6.1] - 2025-12-27

### Fixed

- Shell scripting robustness across all hook and command scripts:
  - `grep -qF --` for fixed-string matching with option-terminator protection
  - Complete dirty checks (staged + unstaged) in worktree status/remove/land
  - JSON injection fix in grind.md using `jq -Rs` to escape filter arguments
  - Pipeline fallback fixes in issue.md (sequential conditionals instead of broken `||`)
  - `printf` instead of `echo` in stop-hook.sh for safe handling of arbitrary data

## [0.6.0] - 2025-12-27

### Added

- **Git worktrees for issues** - Each `/issue` gets its own worktree for clean isolation
- `/land <id>` command to merge completed issue branches
- `/worktree` command for worktree management (list, status, remove, prune)
- Stop hook injects worktree context on each iteration
- **Implementor agent** - Haiku-based execution agent for code changes, with Opus escalation
- **Orchestrator pattern** - `/orchestrate` command for context-saving delegation
- PreToolUse hook enforces orchestrator mode (blocks Write/Edit, redirects to implementor)
- **Stop hook for loop commands** - Self-referential iteration via Claude Code hooks
- **PreToolUse hook** - Safety guardrails blocking destructive git/bash commands
- **PreCompact hook** - Recovery anchor persisted to `loop:anchor` before compaction
- `hooks/hooks.json` and hook scripts for loop, safety, orchestration, and recovery
- Loop state stored via jwz messaging (`loop:current` topic) with JSON schema
- Stack-based nested loop model (grind → issue)
- TTL-based staleness detection (2 hour timeout prevents zombie loops)
- Environment variable escape hatch: `IDLE_LOOP_DISABLE=1`
- Hooks philosophy documented: "pull over push", "safety over policy", "pointer over payload"

### Changed

- `/issue` creates worktree with branch `idle/issue/<id>`
- Loop state includes worktree_path, branch, base_ref
- Implementor agent updated with worktree instructions (absolute paths, cd prefix)
- Loop commands (`/loop`, `/issue`, `/grind`) now use jwz for state management
- `/cancel-loop` posts ABORT event to jwz and cleans up gracefully
- Removed planner agent in favor of oracle
- Prompts stored in temp files to avoid JSON escaping issues

### Fixed

- Loop commands now actually loop (previously just documented the pattern)

## [0.5.0] - 2025-12-27

### Added

- **Zawinski messaging integration** - Async topic-based messaging between agents (`jwz` CLI)
- `/message` command for posting and reading messages
- Messaging sections in all opus agents (oracle, reviewer, documenter) and librarian
- Message status updates in `/grind` and `/issue` loop commands
- Topic naming convention: `project:`, `issue:`, `agent:`

### Changed

- Zawinski is now a required dependency (like tissue)
- Updated install.sh to install zawinski
- Updated docs/architecture.md with messaging documentation
- Updated CONTRIBUTING.md with messaging guidelines

## [0.4.1] - 2025-12-27

### Fixed

- **Security**: Session ID sanitization to prevent path traversal in loop commands
- **Security**: Use `printf` instead of `echo` to handle edge case session IDs
- **Security**: Quote `$ARGUMENTS` in tissue commands to prevent word splitting
- **Security**: Add error handling for file reads in `scripts/search.py`
- Documentation: Fix agent categorization in architecture.md
- Documentation: Remove oracle from artifact writers list in CHANGELOG

## [0.4.0] - 2025-12-27

### Added

- `scripts/search.py` - BM25 search over agent artifacts (uses `uv run`)
- Inter-agent communication via `.claude/plugins/idle/{agent}/` directories
- YAML frontmatter metadata in artifacts for conversation cross-referencing
- Search capability documented in all reading agents (oracle, reviewer, documenter)

### Changed

- Artifact storage moved from `/tmp/idle/` to `.claude/plugins/idle/`
- Each agent writes to its own subdirectory (librarian/, reviewer/)
- Added `.claude/plugins/idle/` subdirectories to .gitignore

## [0.3.0] - 2025-12-27

### Added

- `/document` command to invoke documenter agent
- State directory pattern for Codex/Gemini logs (`/tmp/idle-<agent>-$$`)
- `---SUMMARY---` delimiter for Codex responses
- `---DOCUMENT---` delimiter for Gemini responses
- Explicit wait/read blocking instructions in all external model agents

### Changed

- `oracle`, `reviewer` agents now log full Codex output to temp files
- `documenter` agent now logs full Gemini output to temp files
- Only summary/document sections returned to agent context (reduces bloat)
- YAML frontmatter added to all command files

### Fixed

- README: Corrected gemini-cli package name (`@google/gemini-cli`)
- docs/architecture.md: Updated version to match plugin.json
- docs/architecture.md: Added document.md to directory structure
- agents/reviewer.md, commands/dev/review.md: Fixed style guide path reference

## [0.2.0] - 2025-12-27

### Added

- MIT LICENSE file
- CHANGELOG.md following Keep a Changelog format
- CONTRIBUTING.md with development setup and contribution guidelines
- `docs/architecture.md` documenting plugin structure and patterns
- README: Quickstart workflow example
- README: End-to-end usage examples
- README: Troubleshooting section
- README: "How it works" blurb explaining multi-model delegation

### Changed

- `/grind` now runs `/review` after each issue with iterative fix loop (max 3 rounds)
- `/grind` files remaining review problems as new issues (tagged `review-followup`)
- `/grind` max issues per session raised from 10 to 100

## [0.1.0] - 2025-12-27

### Added

- **Agents**
  - `explorer` - Local codebase search and exploration (haiku)
  - `librarian` - Remote code research via GitHub, docs, APIs (haiku)
  - `oracle` - Deep reasoning with Codex dialogue (opus)
  - `documenter` - Technical writing with Gemini 3 Flash (opus)
  - `reviewer` - Code review with Codex dialogue (opus)

- **Dev Commands**
  - `/work` - Pick an issue and work it to completion
  - `/fmt` - Auto-detect and run project formatter
  - `/test` - Auto-detect and run project tests
  - `/review` - Run code review via reviewer agent
  - `/commit` - Commit staged changes with generated message

- **Loop Commands**
  - `/loop <task>` - Iterative loop until task is complete
  - `/grind [filter]` - Continuously work through issue tracker
  - `/issue <id>` - Work on a specific tissue issue
  - `/cancel-loop` - Cancel the active loop

- Multi-model delegation pattern (haiku for fast tasks, opus for complex reasoning)
- External model integration (Codex for diverse perspectives, Gemini for documentation)
- Loop state management with session isolation
