defmodule ForemanServer.Operations.Inspect do
  @moduledoc "Read-only inspection helpers that query the projection store."

  alias ForemanServer.ProjectionStore

  @terminal_statuses MapSet.new([
                        "completed",
                        "failed",
                        "blocked",
                        "merged",
                        "paused"
                      ])

  @doc """
  Returns the full run projection entry for a given run_id, or nil if not found.
  Reads directly from the read-model; no command dispatch required.
  """
  @spec run_state(String.t()) :: map() | nil
  def run_state(run_id) when is_binary(run_id) do
    snapshot = ProjectionStore.snapshot()
    Map.get(snapshot, :runs, %{}) |> Map.get(run_id)
  end

  @doc """
  Returns all non-terminal runs from the projection store.
  Terminal statuses are: completed, failed, blocked, merged, paused.
  """
  @spec list_active_runs() :: [map()]
  def list_active_runs do
    snapshot = ProjectionStore.snapshot()

    snapshot
    |> Map.get(:runs, %{})
    |> Enum.reject(fn {_run_id, run} ->
      status = Map.get(run, :status, "")
      MapSet.member?(@terminal_statuses, status)
    end)
    |> Enum.map(fn {_run_id, run} -> run end)
  end
end
