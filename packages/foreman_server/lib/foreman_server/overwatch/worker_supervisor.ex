defmodule ForemanServer.Overwatch.WorkerSupervisor do
  @moduledoc """
  `DynamicSupervisor` that hosts `ForemanServer.Overwatch.LaunchWorker`
  children. `restart: :permanent` and `:one_for_one` strategy per the
  TRD-011 requirement: every launched worker is critical and must be
  restarted immediately on exit.

  Workers register in `ForemanServer.Overwatch.WorkerRegistry` so callers
  can look them up by `(run_id, worker_id)`. The Registry is a sibling
  child of `WorkerSupervisor` under `ForemanServer.Overwatch`, not a
  child of this supervisor.

  The Tracker monitors the actual worker pid (not the LaunchWorker pid)
  so that worker crashes surface as `WorkerExited` events.
  """

  use DynamicSupervisor

  alias ForemanServer.Overwatch.LaunchWorker

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> DynamicSupervisor.start_link(__MODULE__, opts)
      name -> DynamicSupervisor.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a `LaunchWorker` under this supervisor. The `worker_id` and
  `run_id` are required and become part of the worker registry key.

  ## Options

    * `:adapter` (REQUIRED) — passed through to
      `ForemanServer.Overwatch.WorkerProtocol.start_worker/3`. The
      adapter is responsible for spawning the actual worker pid and
      for calling `WorkerProtocol.emit/2` for any further events.
    * `:worker_id`, `:run_id` (REQUIRED) — identification.
    * Any other option is forwarded to the adapter as part of its
      init args.

  ## Returns

  `{:ok, pid}` on success. The LaunchWorker pid is registered in
  `ForemanServer.Overwatch.WorkerRegistry` under
  `run_id:worker_id`.
  """
  @spec start_worker(keyword()) :: DynamicSupervisor.on_start_child()
  def start_worker(opts) do
    worker_id = Keyword.fetch!(opts, :worker_id)
    run_id = Keyword.fetch!(opts, :run_id)

    child_spec = %{
      id: {LaunchWorker, worker_id, run_id},
      start: {LaunchWorker, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end
end