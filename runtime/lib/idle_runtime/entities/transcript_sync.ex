defmodule IdleRuntime.Entities.TranscriptSync do
  @moduledoc """
  Transcript sync entity - fire-and-forget syncing of Claude transcripts to jwz.

  Implements the Absynthe.Core.Entity protocol to:
  - Accept transcript sync requests
  - Launch supervised background tasks for syncing
  - Track which paths have been synced (deduplication)

  ## Design

  Uses fire-and-forget semantics: each sync request spawns a supervised task
  that runs independently. No queue stalling - tasks complete or fail without
  blocking new requests. The `synced` set prevents duplicate syncs.

  ## State

  - `synced` - Set of already synced transcript paths (for deduplication)
  - `dataspace_ref` - Reference to the dataspace

  ## Messages

  - `{:command, :sync_transcript, path, session_id}` - Sync transcript to jwz
  - `{:query, :status, reply_ref}` - Get sync count
  """

  alias Absynthe.Core.Turn
  alias Absynthe.Protocol.Event

  require Logger

  defstruct [
    :dataspace_ref,
    :synced
  ]

  @doc """
  Create a new TranscriptSync entity.
  """
  def new(dataspace_ref) do
    %__MODULE__{
      dataspace_ref: dataspace_ref,
      synced: MapSet.new()
    }
  end

  defimpl Absynthe.Core.Entity do
    def on_publish(entity, _assertion, _handle, turn) do
      {entity, turn}
    end

    def on_retract(entity, _handle, turn) do
      {entity, turn}
    end

    def on_message(entity, message, turn) do
      case message do
        {:command, :sync_transcript, path, session_id} ->
          # Skip if already synced (deduplication)
          if MapSet.member?(entity.synced, path) do
            {entity, turn}
          else
            # Mark as synced immediately to prevent duplicates
            new_synced = MapSet.put(entity.synced, path)

            # Fire-and-forget: spawn supervised task
            Task.Supervisor.start_child(IdleRuntime.TaskSupervisor, fn ->
              result = sync_transcript_to_jwz(path, session_id)
              Logger.info("Transcript sync #{if result == :ok, do: "succeeded", else: "failed"}: #{path}")
            end)

            {%{entity | synced: new_synced}, turn}
          end

        {:query, :status, reply_ref} ->
          status = %{
            synced_count: MapSet.size(entity.synced)
          }
          turn = Turn.add_action(turn, Event.message(reply_ref, {:sync_status, status}))
          {entity, turn}

        _ ->
          {entity, turn}
      end
    end

    def on_sync(entity, peer_ref, turn) do
      action = Event.message(peer_ref, {:symbol, "synced"})
      turn = Turn.add_action(turn, action)
      {entity, turn}
    end

    # Private helpers

    defp sync_transcript_to_jwz(path, session_id) do
      # Read transcript and post to jwz
      case File.read(path) do
        {:ok, content} ->
          topic = "transcript:#{session_id}"

          case System.cmd("jwz", ["post", topic, "-m", content], stderr_to_stdout: true) do
            {_, 0} -> :ok
            _ -> :error
          end

        {:error, _} ->
          :error
      end
    rescue
      _ -> :error
    end
  end
end
