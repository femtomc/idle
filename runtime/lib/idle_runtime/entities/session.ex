defmodule IdleRuntime.Entities.Session do
  @moduledoc """
  Session entity - tracks active Claude Code sessions.

  Implements the Absynthe.Core.Entity protocol to:
  - Track session lifecycle (start/stop)
  - Clean up assertions when sessions disconnect
  - Manage assertion handles for proper retraction

  ## State

  - `sessions` - Map of session_id -> session_data
  - `handles` - Map of handle -> {session_id, assertion_type}
  - `dataspace_ref` - Reference to the dataspace

  ## Assertions Tracked

  - `SessionActive` - Published when session starts
  - Tracks all handles to retract on session stop
  """

  alias Absynthe.Core.Turn
  alias Absynthe.Protocol.Event

  defstruct [
    :dataspace_ref,
    :sessions,      # session_id -> %{started_at: timestamp, handles: [handle]}
    :handles        # handle -> {session_id, type}
  ]

  @doc """
  Create a new Session entity.
  """
  def new(dataspace_ref) do
    %__MODULE__{
      dataspace_ref: dataspace_ref,
      sessions: %{},
      handles: %{}
    }
  end

  defimpl Absynthe.Core.Entity do
    @doc """
    Handle published assertions - track session-related assertions.
    """
    def on_publish(entity, assertion, handle, turn) do
      case assertion do
        {:record, {{:symbol, "SessionActive"}, [session_id, _timestamp]}} ->
          # Track this session assertion
          sessions = Map.update(
            entity.sessions || %{},
            session_id,
            %{started_at: System.system_time(:second), handles: [handle]},
            fn session -> %{session | handles: [handle | session.handles]} end
          )
          handles = Map.put(entity.handles || %{}, handle, {session_id, :session_active})
          {%{entity | sessions: sessions, handles: handles}, turn}

        _ ->
          {entity, turn}
      end
    end

    @doc """
    Handle retracted assertions - clean up handle tracking.
    """
    def on_retract(entity, handle, turn) do
      case Map.get(entity.handles || %{}, handle) do
        {session_id, _type} ->
          # Remove handle from session and from handles map
          sessions = Map.update(
            entity.sessions || %{},
            session_id,
            %{handles: []},
            fn session -> %{session | handles: List.delete(session.handles, handle)} end
          )
          handles = Map.delete(entity.handles || %{}, handle)
          {%{entity | sessions: sessions, handles: handles}, turn}

        nil ->
          {entity, turn}
      end
    end

    @doc """
    Handle direct messages - session queries and commands.
    """
    def on_message(entity, message, turn) do
      case message do
        {:query, :sessions, reply_ref} ->
          session_list = Map.keys(entity.sessions || %{})
          turn = Turn.add_action(turn, Event.message(reply_ref, {:sessions, session_list}))
          {entity, turn}

        {:query, :session, session_id, reply_ref} ->
          session_data = Map.get(entity.sessions || %{}, session_id)
          turn = Turn.add_action(turn, Event.message(reply_ref, {:session, session_data}))
          {entity, turn}

        {:command, :cleanup_session, session_id} ->
          # Retract all assertions for this session
          {new_entity, new_turn} = cleanup_session(entity, session_id, turn)
          {new_entity, new_turn}

        {:command, :register_handle, session_id, handle, type} ->
          # Register an assertion handle for a session
          sessions = Map.update(
            entity.sessions || %{},
            session_id,
            %{started_at: System.system_time(:second), handles: [handle]},
            fn session -> %{session | handles: [handle | session.handles]} end
          )
          handles = Map.put(entity.handles || %{}, handle, {session_id, type})
          {%{entity | sessions: sessions, handles: handles}, turn}

        _ ->
          {entity, turn}
      end
    end

    @doc """
    Handle sync - default behavior.
    """
    def on_sync(entity, peer_ref, turn) do
      action = Event.message(peer_ref, {:symbol, "synced"})
      turn = Turn.add_action(turn, action)
      {entity, turn}
    end

    # Private helpers

    defp cleanup_session(entity, session_id, turn) do
      case Map.get(entity.sessions || %{}, session_id) do
        nil ->
          {entity, turn}

        session ->
          # Retract all handles for this session
          turn = Enum.reduce(session.handles, turn, fn handle, acc_turn ->
            Turn.add_action(acc_turn, Event.retract(entity.dataspace_ref, handle))
          end)

          # Remove session from tracking
          sessions = Map.delete(entity.sessions || %{}, session_id)
          handles = Enum.reduce(session.handles, entity.handles || %{}, fn handle, acc ->
            Map.delete(acc, handle)
          end)

          {%{entity | sessions: sessions, handles: handles}, turn}
      end
    end
  end
end
