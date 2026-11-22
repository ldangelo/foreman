defmodule ForemanServer.Overwatch.WorkerSupervisor do
  @moduledoc """
  `DynamicSupervisor` that hosts `ForemanServer.Overwatch.LaunchWorker`
  children with a `:one_for_one` strategy and `restart: :transient` per
  the TRD-011 requirement: every launched worker is critical and must be
  restarted immediately when it *crashes*.

  `:transient` — not `:permanent` — is what expresses that requirement.
  A LaunchWorker whose worker finished the phase and delivered its
  result exits `:normal`; one the operator or `RunExecutor` tore down
  exits `:shutdown`. Under `:permanent` the supervisor relaunched both,
  spawning a second agent process for a phase that was already over:
  `RunExecutor.wait_for_worker_result/4` compensates by removing the
  child spec from a detached task, but that is a race, and it loses.
  run-de055c18749db5e9c702d24950268cf9 is the proof — `RunFailed`
  landed at 22:25:26.060334Z, the supervisor relaunched at
  22:25:26.062664Z (`WorkerStarted` sequence 181 on the worker stream),
  and the pi process that relaunch started ran another 8m42s against
  the already-failed run, overwriting its phase artifact at 22:33:57Z.
  `LaunchWorker` now propagates its worker's exit reason so the two
  cases are distinguishable: a completed or torn-down worker ends the
  child, a crashed one is still relaunched and still counted by
  `CrashLoopDetector`.

  Workers register in `ForemanServer.Overwatch.WorkerRegistry` so callers
  can look them up by `(run_id, worker_id)`. The Registry is a sibling
  child of `WorkerSupervisor` under `ForemanServer.Overwatch`, not a
  child of this supervisor.

  The Tracker monitors the actual worker pid (not the LaunchWorker pid)
  so that worker crashes surface as `WorkerExited` events.
  """

  use DynamicSupervisor

  require Logger

  alias ForemanServer.Overwatch.LaunchWorker
  alias ForemanServer.Overwatch.StopReport

  # How often `await_run_workers_exit/2` looks at the registry again.
  @worker_poll_ms 50

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
      restart: :transient,
      # `LaunchWorker.terminate/2` stops the worker it supervises, and that stop
      # waits for the agent's OS process: the harness escalates SIGINT, SIGTERM,
      # SIGKILL (15s wait in `Driver.stop/2`), `LaunchWorker` allows the worker
      # 18s, and this budget has to outlast both. While one child is shutting
      # down this supervisor serves no other call.
      shutdown: 20_000,
      type: :worker
    }

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc """
  Authoritatively stop the `LaunchWorker` child for `(worker_id, run_id)`.
  `DynamicSupervisor.terminate_child/2` removes the child from the
  supervisor's list of children, so not even a crash-exit relaunch can
  re-introduce a live worker. The bounded Registry poll bridges the gap
  between the previous child exiting and the next generation
  registering (a crashed child is restarted immediately, so the gap is
  small but real). Returns `:ok` whether or not a child was eventually
  found.
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

  @doc """
  Return every live LaunchWorker pid for a given `run_id`. The WorkerRegistry
  key format is `"run_id:worker_id"`, so we filter by key prefix.

  Returns `[]` when the WorkerRegistry has not started (e.g. Overwatch is
  disabled in this deployment). BootReconciliation runs before Overwatch
  in the application supervision tree, so the guard is required.
  """
  @spec list_pids_for_run(String.t()) :: [pid()]
  def list_pids_for_run(run_id) when is_binary(run_id) and run_id != "" do
    case Process.whereis(ForemanServer.Overwatch.WorkerRegistry) do
      nil ->
        []

      _registry ->
        Registry.select(
          ForemanServer.Overwatch.WorkerRegistry,
          [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}]
        )
        |> Enum.filter(fn {key, _pid} -> String.starts_with?(key, run_id <> ":") end)
        |> Enum.map(fn {_key, pid} -> pid end)
    end
  end

  def list_pids_for_run(_), do: []

  @doc """
  Stop every live worker of `run_id` and report what happened.

  This is the authoritative stop path for a terminal or paused run: the
  Overwatch registry, not `RunControl`, knows which workers are alive.
  `RunControl` is an ETS cache the executor clears when the run ends, so
  `RunControl.cancel_agent/1` can legitimately find no agent to cancel
  while the worker is still running.

  Each worker is stopped through this supervisor, which removes its child
  spec (nothing is relaunched) and runs `LaunchWorker.terminate/2`: the worker
  and the agent it owns go down with it. A worker still alive afterwards is
  reported in `:unstopped` and logged instead of being folded into a
  plausible success.
  """
  @spec stop_run_workers(String.t()) :: StopReport.t()
  def stop_run_workers(run_id) when is_binary(run_id) and run_id != "" do
    pids = live_pids_for_run(run_id)
    Enum.each(pids, &terminate_worker/1)

    # What is registered and alive now decides, not what each termination
    # answered: a worker the supervisor restarted meanwhile is a live second
    # writer and has to show up here.
    unstopped = live_pids_for_run(run_id)

    if unstopped != [] do
      Logger.error(
        "Overwatch: run #{run_id} keeps #{length(unstopped)} live worker(s) after the stop attempt: #{inspect(unstopped)}",
        run_id: run_id,
        operation: "worker_supervisor.stop_run_workers"
      )
    end

    %StopReport{run_id: run_id, stopped: pids -- unstopped, unstopped: unstopped}
  end

  defp terminate_worker(pid) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      supervisor -> DynamicSupervisor.terminate_child(supervisor, pid)
    end
  end

  @doc """
  Wait up to `timeout_ms` for every worker of `run_id` to exit on its own.

  `:ok` as soon as none is alive, `{:error, :timeout}` when one still is at the
  deadline. Nothing is stopped: this is how a caller gives a worker that is
  already winding down (a cancelled agent recording its last events) the time
  to finish before it stops that worker, or starts a second one beside it.
  """
  @spec await_run_workers_exit(String.t(), non_neg_integer()) :: :ok | {:error, :timeout}
  def await_run_workers_exit(run_id, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms >= 0 do
    await_workers_exit_until(run_id, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp await_workers_exit_until(run_id, deadline) do
    cond do
      live_pids_for_run(run_id) == [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(@worker_poll_ms)
        await_workers_exit_until(run_id, deadline)
    end
  end

  # The registry can still list a worker that has just died, until it has
  # handled that exit; a dead worker writes nothing, so only live pids count.
  defp live_pids_for_run(run_id),
    do: run_id |> list_pids_for_run() |> Enum.filter(&Process.alive?/1)
end
