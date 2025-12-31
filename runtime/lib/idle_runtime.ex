defmodule IdleRuntime do
  @moduledoc """
  Idle Runtime - Absynthe-based background daemon for Claude Code.

  Provides reactive coordination for the idle agent harness:
  - Loop state management
  - Session tracking
  - Multi-agent coordination

  ## Architecture

  ```
  ┌─────────────┐       ┌─────────────────────┐
  │ Claude Code │       │   Idle Runtime      │
  │             │       │                     │
  │ SessionStart ──────> spawn if needed      │
  │             │       │                     │
  │ Stop Hook   ──────> loop_event            │
  │             │ JSON  │  ┌─────────────┐    │
  │             │ <────── │LoopState    │    │
  │             │       │  └─────────────┘    │
  └─────────────┘       └─────────────────────┘
  ```

  ## Usage

  Start the runtime:

      idle_runtime start

  Check status:

      idle_runtime status

  Connect from hook:

      echo '{"type":"ping"}' | nc -U ~/.idle/runtime.sock
  """

  @doc """
  Check if the runtime daemon is running.
  """
  def running? do
    socket_path = IdleRuntime.Application.socket_path()
    File.exists?(socket_path)
  end

  @doc """
  Get the socket path for IPC.
  """
  def socket_path do
    IdleRuntime.Application.socket_path()
  end
end
