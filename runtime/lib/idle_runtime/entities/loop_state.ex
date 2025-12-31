defmodule IdleRuntime.Entities.LoopState do
  @moduledoc """
  Loop state entity - reactive observer for loop events.

  Implements the Absynthe.Core.Entity protocol to:
  - Observe LoopEvent messages routed from the dataspace
  - Log and react to loop state changes

  ## Architecture

  **IdleRuntime.Actor is the AUTHORITATIVE source for loop state.**

  This entity serves as a reactive projection: it receives LoopEvent messages
  via Observe subscription and can trigger side effects (logging, notifications).
  All synchronous queries go through Actor.get_loop_state/1, not this entity.

  The separation:
  - **Actor GenServer**: Holds authoritative cached state, handles sync queries
  - **LoopState Entity**: Reactive observer for dataspace events, side effects

  This design follows the Syndicated Actor Model pattern where dataspaces
  coordinate via assertions, but application-level queries use direct calls.
  """

  alias Absynthe.Core.Turn
  alias Absynthe.Protocol.Event

  require Logger

  defstruct [
    :dataspace_ref,
    # Track observed assertion handles for cleanup
    :observed_handles
  ]

  @doc """
  Create a new LoopState entity.
  """
  def new(dataspace_ref) do
    %__MODULE__{
      dataspace_ref: dataspace_ref,
      observed_handles: %{}
    }
  end

  # Entity Protocol Implementation

  defimpl Absynthe.Core.Entity do
    @doc """
    Handle published assertions - not used for loop events (they're messages now).
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
    Handle direct messages - loop events come as messages.
    """
    def on_message(entity, message, turn) do
      case message do
        {:loop_event, event, session_id, run_id, _data} ->
          Logger.info("[LoopState] Event: #{event}, session: #{session_id}, run: #{run_id}")
          {entity, turn}

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
  end
end
