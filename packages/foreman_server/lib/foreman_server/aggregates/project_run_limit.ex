defmodule ForemanServer.Aggregates.ProjectRunLimit do
  @moduledoc """
  Project-level active-run slot accountant.

  TRD-041 / AC-022-1, AC-022-2: each project has at most 100 simultaneously
  active runs. Slots are tracked as a `MapSet` of `run_id`s (NOT a bare
  counter) so that:

    * duplicate `run.start` for the same `run_id` does not consume a second
      slot, and
    * duplicate terminal `run.complete` / `run.fail` / `run.cancel` does not
      double-release a slot.

  State is rebuilt from one stream per project (`project_run_limit:<project_id>`).
  Idempotency on replay is preserved: `apply_event/2` is a no-op when the
  same `run_id` is added twice or removed while absent.
  """
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  @max_active_runs 100

  defmodule State do
    @moduledoc false
    defstruct active_run_ids: MapSet.new()
  end

  @impl true
  def initial_state, do: %State{active_run_ids: MapSet.new()}

  @impl true
  def apply_event(%State{active_run_ids: active_run_ids} = state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "ProjectRunStarted" ->
        run_id = Aggregate.get(payload, :run_id)

        if is_binary(run_id) and run_id != "" do
          %State{state | active_run_ids: MapSet.put(active_run_ids, run_id)}
        else
          state
        end

      "ProjectRunCompleted" ->
        run_id = Aggregate.get(payload, :run_id)

        if is_binary(run_id) and run_id != "" do
          %State{state | active_run_ids: MapSet.delete(active_run_ids, run_id)}
        else
          state
        end

      "ProjectRunSlotReleased" ->
        # TRD-041-FOLLOWUP (`for-k1l`): compensating event emitted by
        # `ProjectRunLimitSweeper` when a slot was leaked (gap-guard refused
        # the original release). Distinct from `ProjectRunCompleted` so the
        # audit trail shows the recovery path. Same idempotent MapSet.delete
        # semantics.
        run_id = Aggregate.get(payload, :run_id)

        if is_binary(run_id) and run_id != "" do
          %State{state | active_run_ids: MapSet.delete(active_run_ids, run_id)}
        else
          state
        end

      _ ->
        state
    end
  end

  @impl true
  def handle_command(state, %{type: "run.start", payload: payload}) do
    with {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         {:ok, run_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id) do
      cond do
        MapSet.member?(state.active_run_ids, run_id) ->
          # Slot was already counted for this run_id (idempotent re-dispatch).
          # Returning :unhandled signals to the saga that THIS call did not
          # acquire a fresh slot — compensation must NOT release it.
          :unhandled

        MapSet.size(state.active_run_ids) >= @max_active_runs ->
          {:error, :run_limit_exceeded}

        true ->
          {:ok,
           %{
             stream_id: "project_run_limit:#{project_id}",
             event_type: "ProjectRunStarted",
             payload:
               payload
               |> Map.put(:project_id, project_id)
               |> Map.put(:run_id, run_id)
               |> Map.put_new(:reserved_at, DateTime.utc_now())
           }}
      end
    end
  end

  def handle_command(state, %{type: type, payload: payload})
      when type in ["run.complete", "run.fail", "run.cancel"] do
    with {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         {:ok, run_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id) do
      if MapSet.member?(state.active_run_ids, run_id) do
        {:ok,
         %{
           stream_id: "project_run_limit:#{project_id}",
           event_type: "ProjectRunCompleted",
           payload:
             payload
             |> Map.put(:project_id, project_id)
             |> Map.put(:run_id, run_id)
             |> Map.put(:released_by, type)
             |> Map.put_new(:released_at, DateTime.utc_now())
         }}
      else
        # Slot was never acquired for this run_id, or already released.
        # Returning :unhandled is the idempotent no-op that the saga
        # relies on for repeated terminal events.
        :unhandled
      end
    end
  end

  # TRD-041-FOLLOWUP (`for-k1l`): compensating release command dispatched by
  # `ProjectRunLimitSweeper`. Emits `ProjectRunSlotReleased` (NOT
  # `ProjectRunCompleted`) so the audit trail distinguishes recovery from
  # the normal terminal saga. Idempotent: `:unhandled` when the slot was
  # never reserved or already released.
  def handle_command(state, %{type: "project_run_limit.reconcile", payload: payload}) do
    with {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         {:ok, run_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id) do
      if MapSet.member?(state.active_run_ids, run_id) do
        {:ok,
         %{
           stream_id: "project_run_limit:#{project_id}",
           event_type: "ProjectRunSlotReleased",
           payload:
             payload
             |> Map.put(:project_id, project_id)
             |> Map.put(:run_id, run_id)
             |> Map.put(:released_by, "project_run_limit.reconcile")
             |> Map.put_new(:released_at, DateTime.utc_now())
         }}
      else
        :unhandled
      end
    end
  end

  def handle_command(_state, _command), do: :unhandled
end
