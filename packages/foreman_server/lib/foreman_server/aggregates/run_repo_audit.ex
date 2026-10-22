defmodule ForemanServer.Aggregates.RunRepoAudit do
  @moduledoc """
  Append-only audit aggregate for `run.repo.request` (a thread adding a
  repository to its own run), one stream per run: `run_repo_audit:<run_id>`
  (`stream_id/1`). The `"run_repo_audit:"` prefix is routed here by
  `CommandRouter.aggregate_module_for/1`; it does not start with `"run:"`.

  Command `run.repo.audit.record` is system-only (dispatched by
  `ForemanServer.Workflow.RunRepoRequest` through
  `CommandGateway.dispatch_system/2`, never in the operator allowlist) and
  emits `RunRepoRequested`. State only keeps counters; the event stream is the
  audit log. Idempotency by `command_id` is handled by `CommandRouter`.
  """

  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate
  alias ForemanServer.Events.RunRepoRequested

  @decisions ~w(allowed denied)

  @doc "The audit stream id of one run."
  @spec stream_id(String.t()) :: String.t()
  def stream_id(run_id) when is_binary(run_id), do: "run_repo_audit:" <> run_id

  defmodule State do
    @moduledoc "Counters over one run's repository-request audit stream."
    defstruct total: 0, allowed: 0, denied: 0
  end

  @impl true
  def initial_state, do: %State{}

  @impl true
  def apply_event(%State{} = state, event) do
    case Aggregate.event_type(event) do
      "RunRepoRequested" ->
        case event |> Aggregate.event_payload() |> Aggregate.get(:decision) do
          "allowed" -> %State{state | total: state.total + 1, allowed: state.allowed + 1}
          "denied" -> %State{state | total: state.total + 1, denied: state.denied + 1}
          _ -> state
        end

      _ ->
        state
    end
  end

  @impl true
  def handle_command(_state, %{type: "run.repo.audit.record", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         {:ok, requested_path} <-
           Aggregate.required_binary(Aggregate.get(payload, :requested_path), :requested_path),
         {:ok, decision} <- validate_decision(Aggregate.get(payload, :decision)),
         {:ok, reason} <- Aggregate.required_binary(Aggregate.get(payload, :reason), :reason),
         {:ok, requested_by} <-
           Aggregate.required_binary(Aggregate.get(payload, :requested_by), :requested_by),
         {:ok, repo_id} <- validate_repo_id(Aggregate.get(payload, :repo_id)) do
      {:ok,
       %{
         stream_id: stream_id(run_id),
         event_type: "RunRepoRequested",
         payload: %RunRepoRequested{
           run_id: run_id,
           project_id: project_id,
           requested_path: requested_path,
           repo_id: repo_id,
           decision: decision,
           reason: reason,
           requested_by: requested_by,
           at: Aggregate.get(payload, :at) || DateTime.to_iso8601(DateTime.utc_now())
         }
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp validate_decision(value) when value in @decisions, do: {:ok, value}

  defp validate_decision(value) when is_binary(value) and value != "",
    do: {:error, {:invalid_decision, value}}

  defp validate_decision(_), do: {:error, {:missing_or_invalid, :decision}}

  defp validate_repo_id(nil), do: {:ok, nil}
  defp validate_repo_id(value) when is_binary(value) and value != "", do: {:ok, value}
  defp validate_repo_id(_), do: {:error, {:missing_or_invalid, :repo_id}}
end
