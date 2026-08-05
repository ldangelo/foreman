defmodule ForemanServer.Operations do
  @moduledoc """
  TRD-027: Operator-facing façade for inspecting run state and dispatching
  manual recovery/completion commands.

  All mutating operations route through `CommandRouter.dispatch/1` — never
  directly touch the projection store or aggregates.
  """

  alias ForemanServer.Commands.{CompleteRun}

  alias ForemanServer.{CommandGateway, ProjectionStore}

  @doc """
  Read the projected state for a run_id from `ProjectionStore`.

  Returns the projected run map (status, task_id, phase, etc.) or
  `{:error, :not_found}` when the run is unknown.
  """
  @spec inspect_run(String.t()) :: map() | {:error, :not_found}
  def inspect_run(run_id) when is_binary(run_id) do
    case ProjectionStore.run_projection(run_id) do
      nil -> {:error, :not_found}
      projection -> projection
    end
  end

  @doc """
  Dispatch a `recovery.detected` command through `CommandRouter` for the
  given run_id, marking it for recovery by the recovery aggregate.
  """
  @spec mark_recovered(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def mark_recovered(run_id, opts \\ []) when is_binary(run_id) do
    payload =
      %{run_id: run_id}
      |> maybe_put(:detected_at_ms, Keyword.get(opts, :detected_at_ms))
      |> maybe_put(:detector, Keyword.get(opts, :detector))
    CommandGateway.dispatch_system(%{
      aggregate_id: "recovery:#{run_id}",
      type: "recovery.detected",
      payload: payload
    })
  end

  @doc """
  Dispatch a `run.complete` command through `CommandRouter` for the given
  run_id, forcing the run into terminal state.
  """
  @spec force_complete(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def force_complete(run_id, opts \\ []) when is_binary(run_id) do
    payload =
      %{run_id: run_id, sequence: Keyword.get(opts, :sequence, 1)}
      |> maybe_put(:status, Keyword.get(opts, :status, "completed"))

    CommandGateway.dispatch_system(%{
      aggregate_id: "run:#{run_id}",
      type: "run.complete",
      payload: payload
    })
  end

  @doc """
  Build a `%CompleteRun{}` command struct for a run_id. Useful when the
  caller wants to inspect the command before dispatch.
  """
  @spec complete_run_command(String.t()) :: %CompleteRun{}
  def complete_run_command(run_id) when is_binary(run_id) do
    %CompleteRun{run_id: run_id}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
