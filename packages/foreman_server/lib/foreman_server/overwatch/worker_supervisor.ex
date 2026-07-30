defmodule ForemanServer.Overwatch.WorkerSupervisor do
  @moduledoc """
  Dynamic one-for-one supervisor for worker processes managed by Overwatch.

  Workers are started at runtime via `start_worker/5`.  Each is independently
  restartable on crash (`:one_for_one` strategy, `:permanent` restart).
  Crash-loop detection is owned by the Tracker: on restart `LaunchWorker.start_link`
  re-registers with the Tracker under the same `{run_id, worker_id}` key.
  """

  use DynamicSupervisor

  def start_link(arg) do
    DynamicSupervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 100, max_seconds: 60)
  end

  @doc "Starts a worker and registers it with the Tracker."
  @spec start_worker(String.t(), String.t(), String.t(), module(), map()) ::
          {:ok, pid()} | :ignore | {:error, term()}
  def start_worker(run_id, worker_id, phase_id, worker_module, env_opts \\ %{}) do
    spec = ForemanServer.Overwatch.LaunchWorker.child_spec({run_id, worker_id, phase_id, worker_module, env_opts})
    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
