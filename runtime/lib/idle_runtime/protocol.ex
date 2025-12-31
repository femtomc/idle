defmodule IdleRuntime.Protocol do
  @moduledoc """
  JSON protocol handler - translates between JSON messages and Absynthe operations.

  ## Message Types

  ### Session Management
  - `{"type": "ping"}` - Health check
  - `{"type": "session_start", "session_id": "..."}` - Register session
  - `{"type": "session_stop", "session_id": "..."}` - Unregister and cleanup session

  ### Loop State
  - `{"type": "loop_event", "event": "start" | "stop" | "complete", ...}` - Loop events
  - `{"type": "query", "pattern": "loop_state"}` - Query loop state

  ### Issue Tracking
  - `{"type": "query", "pattern": "issues_ready"}` - Get ready issues
  - `{"type": "query", "pattern": "issue", "id": "..."}` - Get specific issue
  - `{"type": "issue_command", "command": "new", ...}` - Create issue
  - `{"type": "issue_command", "command": "status", ...}` - Update status
  - `{"type": "issue_command", "command": "comment", ...}` - Add comment

  ### Transcript Sync
  - `{"type": "sync_transcript", "path": "...", "session_id": "..."}` - Queue transcript sync

  ### Responses
  - `{"type": "ok", ...}` - Success
  - `{"type": "error", "error": "...", "message": "..."}` - Failure
  - `{"type": "state", ...}` - State query result
  """

  require Logger

  # Health check
  def handle(%{"type" => "ping"}) do
    %{"type" => "ok", "message" => "pong", "entities" => ["loop_state", "session", "issue_tracker", "transcript_sync"]}
  end

  # Session management
  def handle(%{"type" => "session_start", "session_id" => session_id}) do
    Logger.info("Session started: #{session_id}")

    actor = IdleRuntime.Actor.get_actor()
    ds_ref = IdleRuntime.Actor.get_dataspace()

    # Assert session active
    assertion = Absynthe.record(:SessionActive, [session_id, System.system_time(:second)])
    {:ok, handle} = Absynthe.assert_to(actor, ds_ref, assertion)

    %{
      "type" => "ok",
      "session_id" => session_id,
      "handle" => inspect(handle)
    }
  end

  def handle(%{"type" => "session_stop", "session_id" => session_id}) do
    Logger.info("Session stopped: #{session_id}")

    actor = IdleRuntime.Actor.get_actor()
    entity_refs = IdleRuntime.Actor.get_entity_refs()

    # Send cleanup command to Session entity
    Absynthe.send_to(actor, entity_refs.session, {:command, :cleanup_session, session_id})

    %{"type" => "ok", "session_id" => session_id}
  end

  # Loop state management
  def handle(%{"type" => "loop_event", "event" => event} = msg) do
    Logger.info("Loop event: #{event}")

    actor = IdleRuntime.Actor.get_actor()
    entity_refs = IdleRuntime.Actor.get_entity_refs()

    # Send loop event as MESSAGE to LoopState entity (not assertion)
    # Messages are ephemeral and don't accumulate in the dataspace
    loop_event_msg = {:loop_event, event, msg["session_id"] || "unknown", msg["run_id"] || "unknown", msg["data"] || %{}}
    Absynthe.send_to(actor, entity_refs.loop_state, loop_event_msg)

    # Handle stop event decision
    case event do
      "stop" ->
        decision = query_loop_decision(msg)
        %{"type" => "ok", "decision" => decision}

      "start" ->
        # Start loop via Actor (single source of truth)
        IdleRuntime.Actor.start_loop(
          run_id: msg["run_id"],
          mode: if(msg["mode"] == "issue", do: :issue, else: :task),
          max_iterations: msg["max_iterations"] || 10,
          issue_id: msg["issue_id"],
          worktree_path: msg["worktree_path"]
        )
        %{"type" => "ok"}

      _ ->
        %{"type" => "ok"}
    end
  end

  # Query handlers
  def handle(%{"type" => "query", "pattern" => "loop_state"}) do
    state = IdleRuntime.Actor.get_loop_state()
    %{"type" => "state", "loop_state" => state}
  end

  def handle(%{"type" => "query", "pattern" => "issues_ready"}) do
    # Run tissue ready synchronously for now
    case System.cmd("tissue", ["ready", "--format=id"], stderr_to_stdout: true) do
      {output, 0} ->
        issues = output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        %{"type" => "state", "ready_issues" => issues}
      {_, _} ->
        %{"type" => "state", "ready_issues" => []}
    end
  end

  def handle(%{"type" => "query", "pattern" => "issue", "id" => id}) do
    case System.cmd("tissue", ["show", id], stderr_to_stdout: true) do
      {output, 0} ->
        %{"type" => "state", "issue" => %{"id" => id, "content" => output}}
      {error, _} ->
        %{"type" => "error", "error" => "issue_not_found", "message" => error}
    end
  end

  def handle(%{"type" => "query", "pattern" => "sessions"}) do
    # Return active sessions count from Actor state
    state = IdleRuntime.Actor.get_loop_state()
    %{"type" => "state", "session_count" => 1, "loop_status" => state[:status]}
  end

  # Issue commands
  def handle(%{"type" => "issue_command", "command" => "new", "title" => title} = msg) do
    args = ["new", title]
    args = if msg["tag"], do: args ++ ["-t", msg["tag"]], else: args
    args = if msg["priority"], do: args ++ ["-p", to_string(msg["priority"])], else: args

    case System.cmd("tissue", args, stderr_to_stdout: true) do
      {output, 0} ->
        issue_id = String.trim(output)
        %{"type" => "ok", "issue_id" => issue_id}
      {error, _} ->
        %{"type" => "error", "error" => "create_failed", "message" => error}
    end
  end

  def handle(%{"type" => "issue_command", "command" => "status", "id" => id, "status" => status}) do
    case System.cmd("tissue", ["status", id, status], stderr_to_stdout: true) do
      {_, 0} -> %{"type" => "ok", "id" => id, "status" => status}
      {error, _} -> %{"type" => "error", "error" => "status_update_failed", "message" => error}
    end
  end

  def handle(%{"type" => "issue_command", "command" => "comment", "id" => id, "message" => message}) do
    case System.cmd("tissue", ["comment", id, "-m", message], stderr_to_stdout: true) do
      {_, 0} -> %{"type" => "ok", "id" => id}
      {error, _} -> %{"type" => "error", "error" => "comment_failed", "message" => error}
    end
  end

  # Transcript sync
  def handle(%{"type" => "sync_transcript", "path" => path, "session_id" => session_id}) do
    actor = IdleRuntime.Actor.get_actor()
    entity_refs = IdleRuntime.Actor.get_entity_refs()

    Absynthe.send_to(actor, entity_refs.transcript_sync, {:command, :sync_transcript, path, session_id})

    %{"type" => "ok", "queued" => path}
  end

  # Error handlers
  def handle(%{"type" => type}) do
    %{
      "type" => "error",
      "error" => "unknown_type",
      "message" => "Unknown message type: #{type}"
    }
  end

  def handle(_) do
    %{
      "type" => "error",
      "error" => "invalid_message",
      "message" => "Message must have a 'type' field"
    }
  end

  # Private helpers

  defp query_loop_decision(msg) do
    case IdleRuntime.Actor.evaluate_loop_stop(msg) do
      :continue -> "block"
      :allow_exit -> "allow"
      :complete -> "allow"
    end
  end
end
