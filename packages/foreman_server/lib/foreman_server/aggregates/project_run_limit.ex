defmodule ForemanServer.Aggregates.ProjectRunLimit do
  @moduledoc """
  TRD-041 / REQ-022: project-scoped run-limit aggregate.

  Enforces a per-project ceiling on concurrent active runs. Every
  `run.start` that names a `project_id` MUST first reserve a slot via
  this aggregate before the `RunStarted` event is appended. Releases
  happen via `run_limit.release` when a run reaches terminal state.

  The aggregate is the source of truth for `active_run_count` — the
  projection store is NEVER consulted for limit checks. The two-state
  invariant:

      active_run_count <= @max_concurrent_runs

  is preserved atomically because every transition goes through
  `handle_command/2` and `apply_event/2` (single-writer actor).

  ## Stream id

      project_run_limit:<project_id>

  ## Commands

      * `run_limit.reserve`  — increments count; rejects with
        `:run_limit_exceeded` at the ceiling; emits either
        `RunLimitReserved` (success) or `ProjectRunLimitRejected` (rejection).
      * `run_limit.release`  — decrements count (clamped at zero); emits
        `RunLimitReleased`.

  The rejection audit event is useful for downstream observability
  without mutating the active count.
  """

  alias ForemanServer.Aggregate

  @behaviour ForemanServer.Aggregate

  @max_concurrent_runs 100

  defmodule State do
    @moduledoc "Per-project run limit state."
    @enforce_keys [:exists?, :project_id]
    defstruct [
      :exists?,
      :project_id,
      :active_run_count,
      :rejection_count
    ]
  end

  @impl true
  def initial_state do
    %State{
      exists?: false,
      project_id: nil,
      active_run_count: 0,
      rejection_count: 0
    }
  end

  @impl true
  def handle_command(state, %{type: "run_limit.reserve", payload: payload}) do
    case Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id) do
      {:ok, project_id} ->
        if state.active_run_count >= @max_concurrent_runs do
          {:error, :run_limit_exceeded}
        else
          {:ok,
           %{
             stream_id: stream_id(project_id),
             event_type: "RunLimitReserved",
             payload:
               payload
               |> Map.put(:project_id, project_id)
               |> Map.put(:active_run_count_after, state.active_run_count + 1)
           }}
        end

      error ->
        error
    end
  end

  def handle_command(state, %{type: "run_limit.release", payload: payload}) do
    with {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id) do
      {:ok,
       %{
         stream_id: stream_id(project_id),
         event_type: "RunLimitReleased",
         payload:
           payload
           |> Map.put(:project_id, project_id)
           |> Map.put(:active_run_count_after, max(state.active_run_count - 1, 0))
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  @impl true
  def apply_event(%State{} = state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "RunLimitReserved" ->
        %State{
          state
          | exists?: true,
            project_id: Aggregate.get(payload, :project_id) || state.project_id,
            active_run_count: state.active_run_count + 1
        }

      "RunLimitReleased" ->
        %State{
          state
          | exists?: true,
            project_id: Aggregate.get(payload, :project_id) || state.project_id,
            active_run_count: max(state.active_run_count - 1, 0)
        }

      "ProjectRunLimitRejected" ->
        %State{
          state
          | exists?: true,
            project_id: Aggregate.get(payload, :project_id) || state.project_id,
            rejection_count: state.rejection_count + 1
        }

      _ ->
        state
    end
  end

  @doc "Build the stream id for a project_id."
  @spec stream_id(String.t()) :: String.t()
  def stream_id(project_id) when is_binary(project_id), do: "project_run_limit:#{project_id}"

  @doc "Return the configured maximum concurrent runs."
  @spec max_concurrent_runs() :: pos_integer()
  def max_concurrent_runs, do: @max_concurrent_runs

  @doc "Read-only check — does the project have spare capacity?"
  @spec has_capacity?(State.t()) :: boolean()
  def has_capacity?(%State{active_run_count: count}), do: count < @max_concurrent_runs
end
