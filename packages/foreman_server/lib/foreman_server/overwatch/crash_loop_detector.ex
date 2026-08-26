defmodule ForemanServer.Overwatch.CrashLoopDetector do
  @moduledoc """
  TRD-012 — Crash-loop detection for supervised workers.
  TRD-2026-4212be7e / RTE-T004 / TRD-078 — integrated 5-restart backoff loop.

  Observes `Tracker.handle_info({:DOWN, ...})` notifications via
  `observe_down/4` and counts restart events per `(worker_id, run_id)`
  within a sliding window. On each non-orphaned DOWN, two independent
  escalation paths are consulted, most severe first:

    1. Consult `RestartBackoff.next_attempt/1` against the
       consecutive-attempt counter (persists across window boundaries;
       resets only on a successful worker start):
         * attempts 1-5 → `{:retry, delay_ms}` — schedule a delayed
           re-injection of the crash event after exponential backoff,
           then return. The LaunchWorker supervisor continues to
           restart the worker during the backoff window.
         * attempt 6 → `{:blocked, :max_attempts_exceeded}` — seal
           the key and emit:
             (a) `WorkerCrashed` on the worker stream via Tracker
                 (sole-dispatch owner), which seals the Worker stream.
             (b) `run.pause` on the run stream (see "Dual-seal design").
             (c) `run.block` on the run stream, flipping the run to
                 `"blocked"` terminal state.
             (d) `task.block` on every task bound to this run_id,
                 so the operator is notified via the inbox pipeline.
    2. Otherwise (RestartBackoff says retry), consult the configurable
       sliding-window `threshold` (TRD-012, default 5 — chosen to line
       up with RestartBackoff's own 5-retry schedule so both paths
       agree on when a *default*-configured detector escalates).
       Strictly exceeding it (e.g. a caller-supplied smaller threshold,
       used to detect a tighter crash-loop policy per run) seals the
       key and emits `WorkerCrashed` + `run.pause` only — a softer,
       recoverable escalation that does NOT block the run.

  The two paths are independent: the RestartBackoff/block path always
  wins when both would fire on the same DOWN (it is strictly more
  severe), but a caller-supplied `threshold` smaller than 5 lets the
  sliding-window/pause path fire first, well before RestartBackoff
  exhausts its own schedule.

  ## Dual-seal design

  The detector tracks two independent flags per key:

    * `crashed_sealed` — `WorkerCrashed` has been emitted for this key.
      Once set, further DOWN notifications do NOT re-emit a crash event
      (the worker stream is already terminal in the aggregate). This
      also marks the path to terminate the LaunchWorker.
    * `paused_sealed` — `run.pause` has been emitted and confirmed for
      this key. Independent from `crashed_sealed` so a partial-success
      (crash succeeded but pause failed) is recoverable: the next DOWN
      retries the pause without re-emitting the crash event.

  Both the pause-only path and the block path dispatch `run.pause`
  before `run.block` when both apply to the same DOWN (block path
  only). `run.pause` folds to `status: "paused", terminal?: false`;
  `run.block` folds to `status: "blocked", terminal?: true`. Every
  run-mutating command is rejected once `terminal?` is true
  (`reject_terminal_mutation/1` in the Run aggregate), so pausing
  first — while the run is still non-terminal — lets both `RunPaused`
  and `RunBlocked` land; blocking first would permanently reject the
  follow-up pause with `{:error, {:run_terminal, "blocked"}}`.

  ## Orphan semantics

  An "orphan" worker is one whose parent (e.g. the BEAM node or the
  LaunchWorker owner) is gone. The Tracker signals orphan status via
  `Process.monitor` DOWN reasons of `:noconnection`, `:shutdown`, or
  `:exit`. The detector records the orphan observation (telemetry/log)
  for audit but does NOT emit `WorkerCrashed` or `run.pause` — orphan
  cleanup is already handled by `Tracker.cleanup_after_down/2` (slot
  release). All other reasons count toward the threshold.

  ## Architecture

  * This module is a `GenServer` started under a separate supervisor
    (mirroring the `ForemanServer.Overwatch` opt-in pattern). It is
    NOT a child of `ForemanServer.Overwatch` so the TRD-011 moduledoc
    promise of independence ("This is the TRD-011 implementation. It
    does NOT depend on TRD-012") remains accurate.
  * `WorkerCrashed` is sequenced worker-stream traffic — owned by the
    Tracker (which is sole dispatch owner for sequenced worker events).
    `run.block` is run-stream traffic — owned by the Run aggregate's
    CommandRouter path, NOT the Tracker.
  """

  use GenServer

  require Logger

  alias ForemanServer.CommandGateway
  alias ForemanServer.Idempotency.RestartBackoff
  alias ForemanServer.Overwatch.Tracker
  alias ForemanServer.Overwatch.WorkerSupervisor
  alias ForemanServer.ProjectionStore

  @default_window_ms 5 * 60 * 1000
  @default_threshold 5

  @type state :: %{
          window_ms: pos_integer(),
          threshold: pos_integer(),
          restart_history: %{{String.t(), String.t()} => [integer()]},
          attempt_count: %{{String.t(), String.t()} => non_neg_integer()},
          pending_timers: %{{String.t(), String.t()} => reference()},
          crashed_sealed: %{{String.t(), String.t()} => true},
          paused_sealed: %{{String.t(), String.t()} => true}
        }
  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Notify the detector that a worker process went DOWN. Called by
  `ForemanServer.Overwatch.Tracker.handle_info({:DOWN, ...})` after the
  Tracker has already emitted `WorkerExited` and cleaned up its local
  slot. Reasons classified as orphan (`:noconnection`, `:shutdown`,
  `:exit`) are recorded but do NOT trigger crash-loop emission.

  Returns `:ok` synchronously. The actual threshold evaluation and
  dispatch happen inside the GenServer so observers serialize.
  """
  @spec observe_down(GenServer.server(), String.t(), String.t(), term()) :: :ok
  def observe_down(server \\ __MODULE__, worker_id, run_id, reason) do
    GenServer.cast(server, {:observe_down, worker_id, run_id, reason})
    :ok
  end

  @doc "Reset all observed restart history. Test helper."
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  @doc "Read the current restart history snapshot. Test/observability helper."
  @spec restart_history(GenServer.server()) :: %{{String.t(), String.t()} => [integer()]}
  def restart_history(server \\ __MODULE__) do
    GenServer.call(server, :restart_history)
  end

  @doc "Snapshot of sealed/crashed/paused state. Test helper."
  @spec status(GenServer.server()) :: %{crashed: list(), paused: list()}
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc "Read the current consecutive-failure attempt count. Test/observability helper."
  @spec attempt_count(GenServer.server()) :: %{{String.t(), String.t()} => non_neg_integer()}
  def attempt_count(server \\ __MODULE__) do
    GenServer.call(server, :attempt_count)
  end

  @doc "Read the current pending backoff timers. Test/observability helper."
  @spec pending_timers(GenServer.server()) :: %{{String.t(), String.t()} => reference()}
  def pending_timers(server \\ __MODULE__) do
    GenServer.call(server, :pending_timers)
  end
  # ------------------------------------------------------------------
  # GenServer callbacks
  # ------------------------------------------------------------------

  @impl true
  def init(opts) do
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    threshold = Keyword.get(opts, :threshold, @default_threshold)

    state = %{
      window_ms: window_ms,
      threshold: threshold,
      restart_history: %{},
      attempt_count: %{},
      pending_timers: %{},
      crashed_sealed: %{},
      paused_sealed: %{}
    }
    {:ok, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    # Cancel all pending backoff timers before resetting.
    Enum.each(state.pending_timers, fn {_, timer_ref} ->
      _ = Process.cancel_timer(timer_ref)
    end)

    {:reply, :ok,
     %{
       state
       | restart_history: %{},
         attempt_count: %{},
         pending_timers: %{},
         crashed_sealed: %{},
         paused_sealed: %{}
     }}
  end

  def handle_call(:restart_history, _from, state) do
    {:reply, state.restart_history, state}
  end
  def handle_call(:attempt_count, _from, state) do
    {:reply, state.attempt_count, state}
  end

  def handle_call(:pending_timers, _from, state) do
    {:reply, state.pending_timers, state}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       crashed: Map.keys(state.crashed_sealed),
       paused: Map.keys(state.paused_sealed)
     }, state}
  end

  @impl true
  def handle_cast({:observe_down, worker_id, run_id, reason}, state) do
    state =
      case orphan_reason?(reason) do
        true ->
          Logger.info(
            "Overwatch.CrashLoopDetector: orphan worker #{worker_id}/#{run_id} (reason=#{inspect(reason)}) — no events emitted"
          )

          state

        false ->
          record_and_maybe_fire(state, worker_id, run_id)
      end

    {:noreply, state}
  end

  def handle_cast(_msg, state), do: {:noreply, state}

  @impl true
  def handle_info({:backoff_expired, _worker_id, _run_id}, state) do
    # Timer fired but no real crash arrived during the backoff window.
    # The attempt counter already reflects the crash that scheduled this
    # timer — do NOT re-evaluate (record_and_evaluate records a phantom
    # restart that never happened). Just drain the message.
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  # orphan_reason?/1 and record_and_maybe_fire/3 — unchanged
  defp orphan_reason?(:noconnection), do: true
  defp orphan_reason?(:shutdown), do: true
  defp orphan_reason?(:exit), do: true
  defp orphan_reason?(_), do: false

  defp record_and_maybe_fire(state, worker_id, run_id) do
    key = {worker_id, run_id}

    # Cancel any pending backoff timer for this key — a fresh DOWN
    # means the previous backoff schedule is no longer relevant.
    state =
      case Map.get(state.pending_timers, key) do
        nil -> state
        timer_ref ->
          _ = Process.cancel_timer(timer_ref)
          %{state | pending_timers: Map.delete(state.pending_timers, key)}
      end

    cond do
      Map.get(state.paused_sealed, key, false) ->
        # Fully terminal — nothing more to do.
        state

      true ->
        record_and_evaluate(state, key, worker_id, run_id)
    end
  end

  # record_and_evaluate/3 — consults RestartBackoff to decide: retry or block.
  defp record_and_evaluate(state, key, worker_id, run_id) do
    # Update sliding window history (used for the crash-event count).
    now = System.system_time(:millisecond)
    cutoff = now - state.window_ms
    existing = Map.get(state.restart_history, key, [])
    pruned = Enum.filter(existing, &(&1 >= cutoff))
    next_history = [now | pruned]
    window_count = length(next_history)

    state = %{state | restart_history: Map.put(state.restart_history, key, next_history)}

    cond do
      Map.get(state.crashed_sealed, key, false) ->
        # Already crashed-sealed — only retry pause if needed.
        try_pause(state, key, worker_id, run_id)

      true ->
        # Consult RestartBackoff's own consecutive-attempt counter FIRST.
        # It is the more severe, terminal escalation (TRD-078) and must
        # win over the softer sliding-window pause below whenever both
        # are satisfied on the same DOWN — the default threshold of 5 is
        # chosen to line up with RestartBackoff's 5-retry schedule, so
        # the two can coincide on the same event.
        attempt = Map.get(state.attempt_count, key, 0) + 1

        case RestartBackoff.next_attempt(attempt) do
          {:blocked, :max_attempts_exceeded} ->
            # Attempt counter exhausted the 5-retry schedule: block.
            try_crash_and_blocked(state, key, worker_id, run_id, window_count)

          {:retry, delay_ms} ->
            if window_count > state.threshold do
              # Configurable sliding-window threshold breached (TRD-012):
              # softer, recoverable escalation — pause, don't block.
              # Independent of, and normally reached well before, the
              # RestartBackoff exhaustion handled above.
              try_crash_and_pause(state, key, worker_id, run_id, window_count)
            else
              state = %{
                state
                | attempt_count: Map.put(state.attempt_count, key, attempt)
              }

              timer_ref =
                Process.send_after(self(), {:backoff_expired, worker_id, run_id}, delay_ms)

              Logger.warning(
                "Overwatch.CrashLoopDetector: crash retry attempt=#{attempt} for #{worker_id}/#{run_id} — scheduling backoff delay=#{delay_ms}ms"
              )

              %{
                state
                | pending_timers: Map.put(state.pending_timers, key, timer_ref)
              }
            end
        end
    end
  end

  # try_crash_and_blocked/5 — emitted when RestartBackoff exhausts its
  # 5-retry schedule (6th consecutive attempt); the worker stream is
  # sealed and the run is marked "blocked". Operator error is emitted via
  # task.block for every task bound to this run.
  defp try_crash_and_blocked(state, key, worker_id, run_id, window_count) do
    # Emit WorkerCrashed first to seal the worker stream.
    case emit_worker_crashed(worker_id, run_id, window_count, state.window_ms) do
      :ok ->
        # CRITICAL: stop the LaunchWorker to prevent permanent-restart churn.
        terminate_launch_worker(worker_id, run_id)

        state = %{
          state
          | crashed_sealed: Map.put(state.crashed_sealed, key, true),
            # Mark attempt_count so subsequent DOWNs know we're terminal.
            attempt_count: Map.put(state.attempt_count, key, 999)
        }

        Logger.error(
          "Overwatch.CrashLoopDetector: max restart attempts exceeded for #{worker_id}/#{run_id} (#{window_count} restarts); emitting RunBlocked + operator error"
        )

        # Pause BEFORE block: run.pause is rejected once the run is
        # terminal, and run.block makes the run terminal (`terminal?:
        # true`). Pausing first is a non-terminal transition, so both
        # RunPaused and RunBlocked land; blocking second still succeeds
        # because `terminal?` is still false immediately after a pause.
        state = try_pause(state, key, worker_id, run_id)

        # Emit run.block — Run aggregate transitions to status "blocked".
        emit_run_blocked(worker_id, run_id)

        # Emit task.block for every task bound to this run — notifies operator.
        emit_task_blocked(run_id)

        state

      {:error, reason} ->
        Logger.error(
          "Overwatch.CrashLoopDetector: WorkerCrashed dispatch failed for #{worker_id}/#{run_id}: #{inspect(reason)} — NOT sealing; will retry on next DOWN"
        )

        state
    end
  end

  # Strict-greater-than semantics: the threshold-th restart does NOT fire;
  # the (threshold+1)-th restart fires.
  defp try_crash_and_pause(state, key, worker_id, run_id, count) do
    case emit_worker_crashed(worker_id, run_id, count, state.window_ms) do
      :ok ->
        # CRITICAL: stop the LaunchWorker so the permanent-restart
        # policy does not churn against the now-sealed worker stream.
        terminate_launch_worker(worker_id, run_id)

        state = %{state | crashed_sealed: Map.put(state.crashed_sealed, key, true)}

        Logger.warning(
          "Overwatch.CrashLoopDetector: crash-loop detected for #{worker_id}/#{run_id} (#{count} restarts in #{state.window_ms}ms); emitted WorkerCrashed + terminated LaunchWorker"
        )

        try_pause(state, key, worker_id, run_id)

      {:error, reason} ->
        Logger.error(
          "Overwatch.CrashLoopDetector: WorkerCrashed dispatch failed for #{worker_id}/#{run_id}: #{inspect(reason)} — NOT sealing; will retry on next DOWN"
        )

        state
    end
  end

  defp try_pause(state, key, worker_id, run_id) do
    case emit_run_paused(worker_id, run_id) do
      :ok ->
        Logger.info("Overwatch.CrashLoopDetector: run.pause accepted for #{worker_id}/#{run_id}")

        %{state | paused_sealed: Map.put(state.paused_sealed, key, true)}

      {:error, reason} ->
        Logger.error(
          "Overwatch.CrashLoopDetector: run.pause dispatch failed for #{worker_id}/#{run_id}: #{inspect(reason)} — will retry on next DOWN"
        )

        state
    end
  end

  # WorkerCrashed is sequenced worker-stream traffic. The Tracker owns
  # the per-(worker_id, run_id) sequence mirror and is the sole dispatch
  # owner for sequenced worker events. `dispatch_lifecycle/3` allocates
  # the next sequence atomically and routes through CommandRouter; the
  # payload here omits `sequence` so the Tracker fills it in.
  defp emit_worker_crashed(worker_id, run_id, count, window_ms) do
    payload = %{
      worker_id: worker_id,
      run_id: run_id,
      restarts_in_window: count,
      window_ms: window_ms,
      reason: "crash_loop"
    }

    Tracker.dispatch_lifecycle("WorkerCrashed", payload)
  end

  # run.pause is run-stream traffic — not owned by Tracker. CommandRouter
  # handles the dispatch; the Run aggregate's `run.pause` handler folds
  # the event as `RunPaused` (status: "paused", terminal?: false).
  defp emit_run_paused(worker_id, run_id) do
    command_id = "crash-loop-pause:#{run_id}:#{worker_id}"

    command = %{
      aggregate_id: "run:#{run_id}",
      type: "run.pause",
      payload: %{
        "run_id" => run_id,
        "reason" => "crash_loop",
        "worker_id" => worker_id
      },
      command_id: command_id
    }

    case CommandGateway.dispatch_system(command) do
      :ok -> :ok
      {:ok, _event_spec} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception ->
      Logger.error(
        "Overwatch.CrashLoopDetector: run.pause dispatch raised: #{Exception.message(exception)}"
      )

      {:error, {:dispatch_raised, exception}}
  end

  # run.block is run-stream traffic. Emitted when the 5-restart backoff loop
  # is exhausted (6th crash within the window). Transitions the run to
  # "blocked" terminal state so the Dispatcher releases the Beads-DB lease
  # and BootReconciliation scans for orphaned tasks.
  defp emit_run_blocked(worker_id, run_id) do
    command_id = "crash-loop-blocked:#{run_id}:#{worker_id}"

    command = %{
      aggregate_id: "run:#{run_id}",
      type: "run.block",
      payload: %{
        "run_id" => run_id,
        "reason" => "max_attempts_exceeded",
        "worker_id" => worker_id
      },
      command_id: command_id
    }

    case CommandGateway.dispatch_system(command) do
      :ok ->
        Logger.info(
          "Overwatch.CrashLoopDetector: RunBlocked accepted for #{worker_id}/#{run_id}"
        )

      {:ok, _event_spec} ->
        Logger.info(
          "Overwatch.CrashLoopDetector: RunBlocked accepted for #{worker_id}/#{run_id}"
        )

      {:error, reason} ->
        Logger.error(
          "Overwatch.CrashLoopDetector: run.block dispatch failed for #{run_id}: #{inspect(reason)}"
        )
    end
  rescue
    exception ->
      Logger.error(
        "Overwatch.CrashLoopDetector: run.block dispatch raised: #{Exception.message(exception)}"
      )
  end

  # task.block is emitted for every task bound to this run. This surfaces
  # the operator error in the inbox pipeline so the operator is notified
  # that the task is blocked due to repeated worker crashes.
  defp emit_task_blocked(run_id) do
    tasks = ProjectionStore.tasks_by_run_id(run_id)

    Enum.each(tasks, fn task ->
      task_id = Map.get(task, :task_id)

      unless is_nil(task_id) do
        command_id = "crash-loop-task-block:#{task_id}:#{run_id}"

        command = %{
          aggregate_id: "task:#{task_id}",
          type: "task.block",
          payload: %{
            "task_id" => task_id,
            "reason" => "max_attempts_exceeded"
          },
          command_id: command_id
        }

        case CommandGateway.dispatch_system(command) do
          :ok ->
            Logger.info(
              "Overwatch.CrashLoopDetector: TaskBlocked emitted for task_id=#{task_id} (run_id=#{run_id})"
            )

          {:ok, _event_spec} ->
            Logger.info(
              "Overwatch.CrashLoopDetector: TaskBlocked emitted for task_id=#{task_id} (run_id=#{run_id})"
            )

          {:error, reason} ->
            Logger.error(
              "Overwatch.CrashLoopDetector: task.block dispatch failed for task_id=#{task_id}: #{inspect(reason)}"
            )
        end
      end
    end)
  rescue
    exception ->
      Logger.error(
        "Overwatch.CrashLoopDetector: task.block scan failed for run_id=#{run_id}: #{Exception.message(exception)}"
      )
  end

  defp terminate_launch_worker(worker_id, run_id) do
    WorkerSupervisor.stop_worker(worker_id, run_id)
  end
end
