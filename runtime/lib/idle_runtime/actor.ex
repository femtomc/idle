defmodule IdleRuntime.Actor do
  @moduledoc """
  Main Absynthe actor hosting the idle dataspace and entities.

  Spawns and manages:
  - LoopState entity - loop command state machine
  - Session entity - session tracking and cleanup
  - IssueTracker entity - tissue integration
  - TranscriptSync entity - background transcript syncing

  Each entity that needs to observe dataspace assertions has an Observe
  pattern asserted to the dataspace, routing matching assertions to the entity.
  """

  use GenServer

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  def get_dataspace(server \\ __MODULE__) do
    GenServer.call(server, :get_dataspace)
  end

  def get_actor(server \\ __MODULE__) do
    GenServer.call(server, :get_actor)
  end

  def get_entity_refs(server \\ __MODULE__) do
    GenServer.call(server, :get_entity_refs)
  end

  @doc """
  Query the loop state synchronously.
  Returns the current state map from the LoopState entity.
  """
  def get_loop_state(server \\ __MODULE__) do
    GenServer.call(server, :get_loop_state)
  end

  @doc """
  Evaluate whether to stop a loop iteration.
  Returns :continue, :allow_exit, or :complete.
  """
  def evaluate_loop_stop(server \\ __MODULE__, msg) do
    GenServer.call(server, {:evaluate_loop_stop, msg})
  end

  @doc """
  Start a new loop with the given options.
  """
  def start_loop(server \\ __MODULE__, opts) do
    GenServer.call(server, {:start_loop, opts})
  end

  @impl true
  def init(_opts) do
    # Start an Absynthe actor
    {:ok, actor} = Absynthe.start_actor(id: :idle_main)

    # Create the main dataspace
    dataspace = Absynthe.new_dataspace()
    {:ok, ds_ref} = Absynthe.spawn_entity(actor, :root, dataspace)

    # Spawn core entities
    {:ok, loop_ref} = spawn_entity(actor, ds_ref, IdleRuntime.Entities.LoopState)
    {:ok, session_ref} = spawn_entity(actor, ds_ref, IdleRuntime.Entities.Session)
    {:ok, issue_ref} = spawn_entity(actor, ds_ref, IdleRuntime.Entities.IssueTracker)
    {:ok, transcript_ref} = spawn_entity(actor, ds_ref, IdleRuntime.Entities.TranscriptSync)

    # Subscribe entities to their relevant patterns in the dataspace
    # Note: LoopState receives events via direct messages (not assertions)
    # to avoid unbounded assertion accumulation

    # Session observes SessionActive records
    session_observe = Absynthe.observe(
      Absynthe.record(:SessionActive, [
        Absynthe.wildcard(),  # session_id
        Absynthe.wildcard()   # timestamp
      ]),
      session_ref
    )
    {:ok, _} = Absynthe.assert_to(actor, ds_ref, session_observe)

    Logger.info("Idle actor initialized with dataspace and entities")

    {:ok, %{
      actor: actor,
      dataspace_ref: ds_ref,
      entity_refs: %{
        loop_state: loop_ref,
        session: session_ref,
        issue_tracker: issue_ref,
        transcript_sync: transcript_ref
      },
      # Cached loop state for synchronous queries
      # This is the authoritative state, updated via commands
      loop_state: %{
        status: :idle,
        run_id: nil,
        mode: nil,
        iteration: 0,
        max_iterations: 10,
        issue_id: nil,
        worktree_path: nil,
        consecutive_failures: 0,
        completion_reason: nil
      }
    }}
  end

  @impl true
  def handle_call(:get_dataspace, _from, state) do
    {:reply, state.dataspace_ref, state}
  end

  @impl true
  def handle_call(:get_actor, _from, state) do
    {:reply, state.actor, state}
  end

  @impl true
  def handle_call(:get_entity_refs, _from, state) do
    {:reply, state.entity_refs, state}
  end

  @impl true
  def handle_call(:get_loop_state, _from, state) do
    {:reply, state.loop_state, state}
  end

  @impl true
  def handle_call({:start_loop, opts}, _from, state) do
    new_loop_state = %{
      status: :running,
      run_id: opts[:run_id],
      mode: opts[:mode] || :task,
      iteration: 1,
      max_iterations: opts[:max_iterations] || 10,
      issue_id: opts[:issue_id],
      worktree_path: opts[:worktree_path],
      consecutive_failures: 0,
      completion_reason: nil
    }

    # Also send to entity for dataspace reactivity
    Absynthe.send_to(state.actor, state.entity_refs.loop_state, {:command, :start_loop, opts})

    {:reply, :ok, %{state | loop_state: new_loop_state}}
  end

  @impl true
  def handle_call({:evaluate_loop_stop, msg}, _from, state) do
    loop = state.loop_state

    {decision, new_loop_state} = cond do
      loop.status == :idle ->
        {:allow_exit, loop}

      completion_signal?(msg) ->
        handle_completion_signal(msg, loop)

      loop.iteration >= (loop.max_iterations || 10) ->
        {:allow_exit, loop}

      loop.consecutive_failures >= 3 ->
        {:allow_exit, loop}

      true ->
        {:continue, %{loop | iteration: (loop.iteration || 0) + 1}}
    end

    {:reply, decision, %{state | loop_state: new_loop_state}}
  end

  # Completion signal detection
  defp completion_signal?(msg) do
    case msg["transcript_content"] do
      nil -> false
      content -> String.contains?(content, "<loop-done>")
    end
  end

  defp handle_completion_signal(msg, loop) do
    content = msg["transcript_content"] || ""

    cond do
      String.contains?(content, "COMPLETE") ->
        {:complete, %{loop | status: :complete, completion_reason: :complete}}

      String.contains?(content, "STUCK") ->
        {:allow_exit, %{loop | status: :complete, completion_reason: :stuck}}

      String.contains?(content, "MAX_ITERATIONS") ->
        {:allow_exit, %{loop | status: :complete, completion_reason: :max_iterations}}

      true ->
        {:continue, loop}
    end
  end

  defp spawn_entity(actor, ds_ref, module) do
    entity = module.new(ds_ref)
    Absynthe.spawn_entity(actor, :root, entity)
  end
end
