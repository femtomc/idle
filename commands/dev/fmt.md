# Format Command

Format source code and show what changed.

## Steps

1. Look for project conventions to determine the format command:
   - Check `Makefile` for a `format` or `fmt` target
   - Check `package.json` scripts for `format`, `fmt`, or `lint:fix`
   - Check for language-specific tooling:
     - `build.zig` or `zig.build.zon` → `zig fmt src/`
     - `Cargo.toml` → `cargo fmt`
     - `go.mod` → `go fmt ./...`
     - `pyproject.toml` → `ruff format .` or `black .`
   - If unclear, ask the user

2. Run `git diff --stat` to show what files were modified

3. If files were changed, briefly list them

4. If no changes, report "Already formatted"
