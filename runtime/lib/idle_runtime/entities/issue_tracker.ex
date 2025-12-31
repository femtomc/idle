defmodule IdleRuntime.Entities.IssueTracker do
  @moduledoc """
  Issue tracker entity - wraps tissue CLI for reactive issue state.

  Implements the Absynthe.Core.Entity protocol to:
  - Maintain cached issue state
  - Respond to issue queries
  - Sync with tissue CLI on demand

  ## State

  - `issues` - Cached issue data (id -> issue_map)
  - `ready_issues` - List of issue IDs ready to work
  - `last_sync` - Timestamp of last tissue sync
  - `dataspace_ref` - Reference to the dataspace

  ## Messages

  - `{:query, :ready}` - Get issues ready to work
  - `{:query, :issue, id}` - Get specific issue details
  - `{:command, :sync}` - Force sync with tissue
  - `{:command, :update_status, id, status}` - Update issue status
  """

  alias Absynthe.Core.Turn
  alias Absynthe.Protocol.Event

  require Logger

  defstruct [
    :dataspace_ref,
    :issues,
    :ready_issues,
    :last_sync
  ]

  @doc """
  Create a new IssueTracker entity.
  """
  def new(dataspace_ref) do
    %__MODULE__{
      dataspace_ref: dataspace_ref,
      issues: %{},
      ready_issues: [],
      last_sync: nil
    }
  end

  defimpl Absynthe.Core.Entity do
    @doc """
    Handle published assertions - could observe issue-related assertions.
    """
    def on_publish(entity, _assertion, _handle, turn) do
      {entity, turn}
    end

    @doc """
    Handle retracted assertions.
    """
    def on_retract(entity, _handle, turn) do
      {entity, turn}
    end

    @doc """
    Handle direct messages - issue queries and commands.
    """
    def on_message(entity, message, turn) do
      case message do
        {:query, :ready, reply_ref} ->
          {entity, ready} = ensure_synced(entity)
          turn = Turn.add_action(turn, Event.message(reply_ref, {:ready_issues, ready}))
          {entity, turn}

        {:query, :issue, id, reply_ref} ->
          {entity, _} = ensure_synced(entity)
          issue = Map.get(entity.issues || %{}, id)
          turn = Turn.add_action(turn, Event.message(reply_ref, {:issue, issue}))
          {entity, turn}

        {:query, :all, reply_ref} ->
          {entity, _} = ensure_synced(entity)
          turn = Turn.add_action(turn, Event.message(reply_ref, {:issues, entity.issues}))
          {entity, turn}

        {:command, :sync} ->
          {synced_entity, _} = sync_with_tissue(entity)
          {synced_entity, turn}

        {:command, :update_status, id, status} ->
          case run_tissue_command(["status", id, to_string(status)]) do
            {:ok, _} ->
              # Invalidate cache
              {%{entity | last_sync: nil}, turn}
            {:error, _} ->
              {entity, turn}
          end

        {:command, :new_issue, title, opts} ->
          args = ["new", title]
          args = if opts[:tag], do: args ++ ["-t", opts[:tag]], else: args
          args = if opts[:priority], do: args ++ ["-p", to_string(opts[:priority])], else: args

          case run_tissue_command(args) do
            {:ok, output} ->
              # Extract issue ID from output
              issue_id = String.trim(output)
              turn = Turn.add_action(turn, Event.message(opts[:reply_ref], {:new_issue, issue_id}))
              {%{entity | last_sync: nil}, turn}
            {:error, reason} ->
              new_turn = if opts[:reply_ref] do
                Turn.add_action(turn, Event.message(opts[:reply_ref], {:error, reason}))
              else
                turn
              end
              {entity, new_turn}
          end

        {:command, :comment, id, message} ->
          case run_tissue_command(["comment", id, "-m", message]) do
            {:ok, _} -> {entity, turn}
            {:error, _} -> {entity, turn}
          end

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

    defp ensure_synced(entity) do
      # Sync if cache is stale (>60 seconds)
      now = System.system_time(:second)
      if entity.last_sync && (now - entity.last_sync) < 60 do
        {entity, entity.ready_issues}
      else
        sync_with_tissue(entity)
      end
    end

    defp sync_with_tissue(entity) do
      ready_issues = case run_tissue_command(["ready", "--format=id"]) do
        {:ok, output} ->
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
        {:error, _} ->
          []
      end

      # Fetch details for each ready issue
      issues = Enum.reduce(ready_issues, entity.issues || %{}, fn id, acc ->
        case fetch_issue(id) do
          {:ok, issue} -> Map.put(acc, id, issue)
          {:error, _} -> acc
        end
      end)

      new_entity = %{entity |
        issues: issues,
        ready_issues: ready_issues,
        last_sync: System.system_time(:second)
      }

      {new_entity, ready_issues}
    end

    defp fetch_issue(id) do
      case run_tissue_command(["show", id]) do
        {:ok, output} ->
          # Parse tissue show output (simple format)
          {:ok, %{id: id, raw: output}}
        {:error, reason} ->
          {:error, reason}
      end
    end

    defp run_tissue_command(args) do
      case System.cmd("tissue", args, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, _} -> {:error, output}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end
end
