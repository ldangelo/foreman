defmodule ForemanServer.Overwatch.LaunchWorker do
  @moduledoc """
  Supervised launcher for a single worker runtime. Owns:

    * spawning the actual worker pid via `ForemanServer.Overwatch.WorkerProtocol.start_worker/3`,
    * registering that pid with `ForemanServer.Overwatch.Tracker`,
    * emitting the initial `WorkerStarted` event through `WorkerProtocol.emit/2`,
    * activating the spawned worker so its adapter may begin emitting,
    * monitoring the spawned pid so the LaunchWorker terminates when
      the worker runtime goes down.

  ## Two-phase startup (contract)

  The adapter contract requires that `start_link/1` returns a worker
  pid which has **not yet emitted any `WorkerProtocol.emit/2` event**.
  Side-effecting emits happen only after LaunchWorker explicitly
  activates the worker.

  Sequence:

    1. `WorkerProtocol.start_worker/3` spawns the adapter's pid —
       adapter `init/1` may set up state but must NOT call
       `WorkerProtocol.emit/2`.
    2. `Tracker.register/4` registers the pid for liveness. From this
       point `:heartbeat` emits resolve correctly.
    3. `WorkerProtocol.emit(:worker_started, ...)` appends `WorkerStarted`
       with the next sequence (initial aggregate `last_sequence` is `-1`,
       so the first appended sequence is `0`).
    4. LaunchWorker sends `{:overwatch_activate, worker_id, run_id, launcher_pid}`
       to the spawned pid and waits for `{:overwatch_activated, ref}`.
       **This is the activation handshake** — adapters may begin calling
       `WorkerProtocol.emit/2` only after sending `{:overwatch_activated,
       ref}` back to the launcher.

  Adapters that ignore the activation handshake and emit during
  `init/1` violate the contract: they will see `:not_registered` for
  `:heartbeat` or out-of-order sequence for any other event.

  ## Configuration

    * `:adapter` (REQUIRED) — module implementing `start_link/1`.
    * `:worker_id`, `:run_id` (REQUIRED).
    * `:activation_timeout_ms` (optional, default 5_000) — how long
      LaunchWorker waits for the adapter to acknowledge activation
      before considering startup failed.

  ## Failure modes

    * `start_worker/3` returns `{:error, _}` → exit
      `{:worker_spawn_failed, reason}`.
    * `Tracker.register/4` fails → exit `{:tracker_register_failed, reason}`
      and the spawned pid is killed.
    * `WorkerProtocol.emit(:worker_started, ...)` fails → exit
      `{:worker_started_failed, reason}`, worker is unregistered and
      killed.
    * Activation handshake not completed within timeout → exit
      `{:activation_timeout, _}`.

  ## Exit reason contract

  The `WorkerSupervisor` child spec is `restart: :transient`, so
  LaunchWorker's own exit reason IS the relaunch decision:

    * worker DOWN with `:normal`, `:shutdown`, or `{:shutdown, _}` — the
      phase delivered its result, or the worker was torn down on purpose
      → exit `:normal`, child ends, no relaunch.
    * worker DOWN with any other reason — a real crash → exit
      `{:worker_crashed, reason}`, child is relaunched and
      `CrashLoopDetector` counts the restart.

  Every failure mode above is abnormal, so a LaunchWorker that cannot
  start or activate its worker is relaunched as before.
  """

  use GenServer

  require Logger

  alias ForemanServer.Overwatch.Tracker
  alias ForemanServer.Overwatch.WorkerProtocol

  @default_activation_timeout_ms 5_000

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  def start_link(opts) do
    worker_id = Keyword.fetch!(opts, :worker_id)
    run_id = Keyword.fetch!(opts, :run_id)
    name = via_name(worker_id, run_id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Look up a LaunchWorker pid by `(worker_id, run_id)`."
  @spec pid_for(String.t(), String.t()) :: pid() | nil
  def pid_for(worker_id, run_id) do
    case Registry.lookup(ForemanServer.Overwatch.WorkerRegistry, "#{run_id}:#{worker_id}") do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp via_name(worker_id, run_id) do
    {:via, Registry, {ForemanServer.Overwatch.WorkerRegistry, "#{run_id}:#{worker_id}"}}
  end

  # ------------------------------------------------------------------
  # GenServer
  # ------------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    worker_id = Keyword.fetch!(opts, :worker_id)
    run_id = Keyword.fetch!(opts, :run_id)

    # Pre-flight: refuse re-launch when the Worker aggregate for this
    # (worker_id, run_id) is already terminal. LaunchWorker has
    # restart: :permanent, so without this guard a crashed-then-restarted
    # LaunchWorker would loop on WorkerStarted dispatch forever —
    # `allow_after_terminal/2` in the Worker aggregate rejects the
    # re-launch as `:worker_terminal` and the run dies at p001 with
    # `{:initialization_failed, :phase_terminal}` (see TRD-2026-80ba0665).
    case Tracker.terminal?(worker_id, run_id) do
      {:ok, true} ->
        Logger.warning(
          "LaunchWorker: refusing re-launch on terminal stream " <>
            "#{worker_id}/#{run_id}"
        )

        :telemetry.execute(
          [:foreman_server, :overwatch, :worker_already_terminal],
          %{},
          %{worker_id: worker_id, run_id: run_id}
        )

        {:stop, {:worker_already_terminal, {worker_id, run_id}}}

      _other ->
        # :fresh, {:ok, false}, or :error all mean "proceed". The
        # subsequent dispatch will surface any actual rejection from
        # the Worker aggregate if the stream really is sealed.
        do_init(opts, worker_id, run_id)
    end
  end

  defp do_init(opts, worker_id, run_id) do
    case WorkerProtocol.start_worker(worker_id, run_id, opts) do
      {:ok, worker_pid} ->
        # Step 1: spawn succeeded. Adapter must NOT have emitted anything yet.
        case Tracker.register(worker_id, run_id, worker_pid) do
          :ok ->
            # Step 2: registered. Heartbeats will now resolve correctly.
            started_payload = %{
              worker_id: worker_id,
              run_id: run_id,
              session_id: Keyword.fetch!(opts, :session_id),
              adapter: Keyword.fetch!(opts, :adapter_name) |> to_string(),
              prompt_path: Keyword.fetch!(opts, :prompt_path),
              tool_names: Keyword.get(opts, :tool_names, []),
              artifact_paths: Keyword.get(opts, :artifact_paths, [])
            }

            case WorkerProtocol.emit(:worker_started, started_payload) do
              :ok ->
                # Step 3: WorkerStarted appended with the next sequence.
                # Schedule activation timeout; we wait for the adapter to
                # acknowledge activation in :continue.
                activation_timeout_ms =
                  Keyword.get(opts, :activation_timeout_ms, @default_activation_timeout_ms)

                activation_ref =
                  Process.send_after(self(), :activation_timeout, activation_timeout_ms)

                send(
                  worker_pid,
                  {:overwatch_activate, worker_id, run_id, self()}
                )

                Process.monitor(worker_pid)

                state = %{
                  worker_id: worker_id,
                  run_id: run_id,
                  worker_pid: worker_pid,
                  activation_ref: activation_ref,
                  activated?: false
                }

                {:ok, state}

              {:error, reason} ->
                Logger.error(
                  "LaunchWorker: WorkerStarted dispatch failed for " <>
                    "#{worker_id}/#{run_id}: #{inspect(reason)}"
                )

                _ = Tracker.unregister(worker_id, run_id)
                safe_stop(worker_pid)
                {:stop, {:worker_started_failed, reason}}
            end

          {:error, reason} ->
            Logger.error(
              "LaunchWorker: Tracker.register failed for " <>
                "#{worker_id}/#{run_id}: #{inspect(reason)}"
            )

            safe_stop(worker_pid)
            {:stop, {:tracker_register_failed, reason}}
        end

      {:error, reason} ->
        Logger.error(
          "LaunchWorker: start_worker failed for " <>
            "#{worker_id}/#{run_id}: #{inspect(reason)}"
        )

        {:stop, {:worker_spawn_failed, reason}}
    end
  end

  @impl true
  def handle_info({:overwatch_activated, pid}, %{worker_pid: pid} = state) do
    Process.cancel_timer(state.activation_ref)
    {:noreply, %{state | activated?: true}}
  end

  def handle_info({:overwatch_activated, _other_pid}, state) do
    # Stale activation from a previous worker pid; ignore.
    {:noreply, state}
  end

  def handle_info(:activation_timeout, state) do
    Logger.error("LaunchWorker: activation timeout for #{state.worker_id}/#{state.run_id}")

    _ = Tracker.unregister(state.worker_id, state.run_id)
    safe_stop(state.worker_pid)
    {:stop, {:activation_timeout, state.worker_id}, state}
  end

  # Worker went DOWN. Tracker already emitted WorkerExited through its own
  # monitor. LaunchWorker exits with a reason the `restart: :transient`
  # child spec (worker_supervisor.ex) can act on, because the supervisor
  # has no other way to tell a finished phase from a crashed one.
  #
  # `:normal` is `JidoHarnessWorker`'s exit after it has sent
  # `{:worker_result, _}` — on the success path AND on the task-crash path,
  # both of which report to RunExecutor first. `:shutdown` /
  # `{:shutdown, _}` is a deliberate teardown (`WorkerSupervisor.stop_worker/2`,
  # operator cancel). Neither may relaunch: run-de055c18749db5e9c702d24950268cf9
  # relaunched 2.3ms after `RunFailed` under the old `:permanent` policy and
  # leaked a pi agent that ran 8m42s past the run's terminal state.
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state)
      when reason in [:normal, :shutdown] do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, {:shutdown, _}}, state) do
    {:stop, :normal, state}
  end

  # Any other reason is a genuine worker crash: exit abnormally so the
  # `:transient` policy relaunches, exactly as TRD-011 and
  # `CrashLoopDetector`'s backoff schedule require. The Tracker's own
  # monitor is what feeds `observe_down/4`, so counting is unaffected.
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.error(
      "LaunchWorker: worker crashed for #{state.worker_id}/#{state.run_id}: " <>
        "#{inspect(reason)}"
    )

    {:stop, {:worker_crashed, reason}, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp safe_stop(pid) when is_pid(pid), do: Process.exit(pid, :kill)
  defp safe_stop(_), do: :ok
end
