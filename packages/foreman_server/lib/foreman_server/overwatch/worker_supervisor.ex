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
    # CrashLoopDetector's threshold is 3 (default). To prevent the
    # supervisor's restart intensity from terminating the WHOLE
    # dynamic supervisor before the detector can authoritatively
    # stop the offending child, raise max_restarts well above the
    # detector boundary. The detector is the sole authority on
    # crash-loop shutdown.
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 1_000,
      max_seconds: 1
    )
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

  @doc """
  Authoritatively stop the `LaunchWorker` child for `(worker_id, run_id)`.
  `DynamicSupervisor.terminate_child/2` removes the child from the
  supervisor's list of children, so the `restart: :permanent` policy
  does NOT re-introduce a live worker. The bounded Registry poll
  bridges the gap between the previous child exiting and the next
  generation registering (the supervisor restarts immediately, so the
  gap is small but real). Returns `:ok` whether or not a child was
  eventually found.
  """
  @spec stop_worker(String.t(), String.t()) :: :ok
  def stop_worker(worker_id, run_id) do
    terminate_loop(worker_id, run_id, 30)
  end

  defp terminate_loop(_worker_id, _run_id, 0), do: :ok

  defp terminate_loop(worker_id, run_id, attempts_remaining) do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      sup ->
        case LaunchWorker.pid_for(worker_id, run_id) do
          nil ->
            Process.sleep(50)
            terminate_loop(worker_id, run_id, attempts_remaining - 1)

          pid when is_pid(pid) ->
            case DynamicSupervisor.terminate_child(sup, pid) do
              :ok ->
                :ok

              {:error, :not_found} ->
                Process.sleep(50)
                terminate_loop(worker_id, run_id, attempts_remaining - 1)

              {:error, _reason} ->
                Process.sleep(50)
                terminate_loop(worker_id, run_id, attempts_remaining - 1)
            end
        end
    end
  end
end