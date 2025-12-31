defmodule IdleRuntime.Application do
  @moduledoc """
  Idle Runtime - Absynthe-based daemon for Claude Code coordination.

  Starts:
  - Absynthe actor system with main dataspace
  - Unix socket listener for hook communication
  - Core entities (LoopState, Session, etc.)
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    socket_path = socket_path()

    # Clean up stale socket if exists
    File.rm(socket_path)

    children = [
      # Task.Supervisor for background tasks (e.g., TranscriptSync)
      {Task.Supervisor, name: IdleRuntime.TaskSupervisor},
      # Absynthe actor for the main dataspace (hosts all entities)
      {IdleRuntime.Actor, name: IdleRuntime.Actor},
      # Unix socket listener
      {IdleRuntime.Listener, socket_path: socket_path}
    ]

    opts = [strategy: :one_for_one, name: IdleRuntime.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("Idle runtime started, socket: #{socket_path}")
        write_pidfile()
        {:ok, pid}
      error ->
        error
    end
  end

  @impl true
  def stop(_state) do
    File.rm(socket_path())
    File.rm(pidfile_path())
    :ok
  end

  def socket_path do
    case System.get_env("IDLE_SOCKET") do
      nil ->
        # Default: ~/.idle/runtime.sock
        idle_dir = Path.join(System.user_home!(), ".idle")
        File.mkdir_p!(idle_dir)
        Path.join(idle_dir, "runtime.sock")
      path ->
        path
    end
  end

  def pidfile_path do
    Path.join(Path.dirname(socket_path()), "runtime.pid")
  end

  defp write_pidfile do
    File.write!(pidfile_path(), "#{System.pid()}")
  end
end
