# Test Command

Run the test suite and summarize results.

## Steps

1. Look for project conventions to determine the test command:
   - Check `Makefile` for a `test` target
   - Check `package.json` scripts for `test`
   - Check for language-specific tooling:
     - `build.zig` or `zig.build.zon` → `zig build test`
     - `Cargo.toml` → `cargo test`
     - `go.mod` → `go test ./...`
     - `pyproject.toml` → `pytest`
   - If unclear, ask the user

2. Capture and summarize the results:
   - If all tests pass: Report success with test count if available
   - If tests fail: List failing tests with file:line references

3. If failures exist, offer to investigate the root cause
