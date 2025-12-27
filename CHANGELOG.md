# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] - 2025-12-27

### Added

- `scripts/search.py` - BM25 search over agent artifacts (uses `uv run`)
- Inter-agent communication via `.claude/plugins/trivial/{agent}/` directories
- YAML frontmatter metadata in artifacts for conversation cross-referencing
- Search capability documented in all reading agents (oracle, planner, reviewer, documenter)

### Changed

- Artifact storage moved from `/tmp/trivial/` to `.claude/plugins/trivial/`
- Each agent writes to its own subdirectory (librarian/, reviewer/, oracle/)
- Added `.claude/plugins/trivial/` subdirectories to .gitignore

## [0.3.0] - 2025-12-27

### Added

- `/document` command to invoke documenter agent
- State directory pattern for Codex/Gemini logs (`/tmp/trivial-<agent>-$$`)
- `---SUMMARY---` delimiter for Codex responses
- `---DOCUMENT---` delimiter for Gemini responses
- Explicit wait/read blocking instructions in all external model agents

### Changed

- `oracle`, `reviewer`, `planner` agents now log full Codex output to temp files
- `documenter` agent now logs full Gemini output to temp files
- Only summary/document sections returned to agent context (reduces bloat)
- YAML frontmatter added to all command files

### Fixed

- README: Corrected gemini-cli package name (`@google/gemini-cli`)
- docs/architecture.md: Updated version to match plugin.json
- docs/architecture.md: Added document.md to directory structure
- agents/planner.md: Fixed tissue commands (`new` not `create`, `dep add`, `tag add`)
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
  - `planner` - Design and issue tracker curation with Codex (opus)

- **Dev Commands**
  - `/work` - Pick an issue and work it to completion
  - `/fmt` - Auto-detect and run project formatter
  - `/test` - Auto-detect and run project tests
  - `/review` - Run code review via reviewer agent
  - `/plan` - Design discussion or backlog curation via planner agent
  - `/commit` - Commit staged changes with generated message

- **Loop Commands**
  - `/loop <task>` - Iterative loop until task is complete
  - `/grind [filter]` - Continuously work through issue tracker
  - `/issue <id>` - Work on a specific tissue issue
  - `/cancel-loop` - Cancel the active loop

- Multi-model delegation pattern (haiku for fast tasks, opus for complex reasoning)
- External model integration (Codex for diverse perspectives, Gemini for documentation)
- Loop state management with session isolation
