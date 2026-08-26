defmodule ForemanServer.Workflow.RunSupervisor do
  @moduledoc """
  DynamicSupervisor that manages one `RunExecutor` per `run_id`.

  Each new run starts with `start_run/2`, which calls into the supervisor
  via `start_child/2`. Restarting the executor is `transient` — a crash
  during execution is reported via `task.execution_fail` and not retried
  here, so the parent supervisor can decide policy.
  """

  use DynamicSupervisor

  alias ForemanServer.Workflow.RunExecutor

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(init_arg \\ []) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @spec start_run(String.t(), map()) :: DynamicSupervisor.on_start_child()
  def start_run(run_id, task_projection) do
    child_spec = %{
      id: RunExecutor,
      start: {RunExecutor, :start_link, [run_id, task_projection]},
      restart: :transient,
      shutdown: 5_000,
      type: :worker
    }

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @spec which_runs() :: [Supervisor.child_spec()]
  def which_runs, do: DynamicSupervisor.which_children(__MODULE__)

  @impl true
  def init(_init_arg), do: DynamicSupervisor.init(strategy: :one_for_one)
end
