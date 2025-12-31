# Idle Runtime Distribution

## Current Status

The idle runtime is an Elixir application that depends on absynthe. For distribution, we need to package it as a standalone executable.

## Burrito Status: BLOCKED

Burrito (https://github.com/burrito-elixir/burrito) is the preferred solution for packaging Elixir applications as native executables. However, it is currently blocked due to a dependency conflict:

- **Burrito** depends on `typed_struct ~> 0.2.0 or ~> 0.3.0`
- **absynthe** (via decibel) depends on `typedstruct ~> 0.5.0`

These are two different packages that both define the `TypedStruct` module, causing a conflict.

### Resolution Options

1. **Wait for upstream fix** - Either Burrito or decibel updates their dependency
2. **Fork and patch** - Fork one package and update the dependency
3. **Use alternative packaging** - Mix releases, Bakeware, or escript

## Alternative: Mix Releases

For now, use standard Mix releases:

```bash
# Build release
cd idle/runtime
MIX_ENV=prod mix release idle

# Run release
_build/prod/rel/idle/bin/idle start

# Or run as daemon
_build/prod/rel/idle/bin/idle daemon
```

### Release Configuration

The mix.exs is already configured for releases:

```elixir
defp releases do
  [
    idle: [
      include_executables_for: [:unix],
      applications: [runtime_tools: :permanent]
    ]
  ]
end
```

## Distribution Strategy

### For Development

Run directly via mix:
```bash
cd idle/runtime
mix run --no-halt
```

### For Production

Build and deploy a Mix release:
```bash
cd idle/runtime
MIX_ENV=prod mix deps.get
MIX_ENV=prod mix release idle
```

The release will be at `_build/prod/rel/idle/`.

### Hook Integration

Hooks should check for and spawn the runtime:

```bash
# In SessionStart hook
SOCKET_PATH="${HOME}/.idle/runtime.sock"

if [ ! -S "$SOCKET_PATH" ]; then
    # Start the runtime
    idle_runtime daemon
    # Wait for socket
    for i in {1..10}; do
        [ -S "$SOCKET_PATH" ] && break
        sleep 0.1
    done
fi

# Connect and register session
idle-client session_start "$SESSION_ID"
```

## Future: Burrito Integration

Once the dependency conflict is resolved:

```elixir
defp deps do
  [
    {:absynthe, path: "../../absynthe"},
    {:jason, "~> 1.4"},
    {:burrito, "~> 1.0"}  # Re-enable when conflict resolved
  ]
end

defp releases do
  [
    idle: [
      steps: [:assemble, &Burrito.wrap/1],
      burrito: [
        targets: [
          macos_arm: [os: :darwin, cpu: :aarch64],
          macos_x86: [os: :darwin, cpu: :x86_64],
          linux_x86: [os: :linux, cpu: :x86_64],
          linux_arm: [os: :linux, cpu: :aarch64]
        ]
      ]
    ]
  ]
end
```

This will produce single-file executables for each platform.

## Testing Distribution

```bash
# Build release
MIX_ENV=prod mix release idle

# Test release
_build/prod/rel/idle/bin/idle start

# In another terminal, verify
idle-client ping
```
