defmodule ForemanServer.Overwatch.Tracker do
  @moduledoc """
  Worker liveness tracker: manages 60-second heartbeat timeouts and Process.monitor
  DOWN cleanup for all live workers.

  State keyed by `{run_id, worker_id}` to avoid cross-run collisions.

  Two independent tokens per entry:
  - `session_token` — bumped on re-track. Any timeout from a previous pid under the
    same key carries a stale session_token and is ignored.
  - `heartbeat_gen` — incremented on each heartbeat reset. Any queued timeout from
    before the heartbeat carries a stale heartbeat_gen and is ignored.

  DOWN messages for unknown monitor refs are a silent no-op.

  The tracked `worker_pid` is verified on every heartbeat: a delayed heartbeat from
  an old (re-tracked) pid is silently ignored.
  """

  use GenServer

  alias ForemanServer.{CommandRouter, WorkerProtocol}

  @heartbeat_timeout_ms 60_000

  @type worker_key :: {String.t(), String.t()}

  # ─── Client API (delegated from ForemanServer.Overwatch) ─────────────────────

  @spec track(pid(), String.t(), String.t(), String.t(), module()) :: :ok
  def track(pid, run_id, worker_id, phase_id, worker_module) do
    GenServer.cast(__MODULE__, {:track, pid, run_id, worker_id, phase_id, worker_module})
  end

  @spec worker_heartbeat(pid(), String.t(), String.t(), integer(), DateTime.t()) :: :ok
  def worker_heartbeat(pid, run_id, worker_id, sequence, observed_at) do
    GenServer.cast(__MODULE__, {:heartbeat, pid, run_id, worker_id, sequence, observed_at})
  end

  # ─── GenServer ───────────────────────────────────────────────────────────────

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    {:ok, %{session_token_counter: 0, workers: %{}, crash_history: %{}}}
  end

  # ─── :track ────────────────────────────────────────────────────────────────

  @impl true
  def handle_cast({:track, pid, run_id, worker_id, phase_id, _worker_module}, state) do
    key = {run_id, worker_id}

    # Tear down any prior timer/monitor for this key before registering the new pid.
    # This prevents an old DOWN or queued timeout from the previous worker from
    # interfering with the new one.
    state =
      with %{timer_ref: old_timer, monitor_ref: old_ref} <- Map.get(state.workers, key) do
        if is_reference(old_timer), do: Process.cancel_timer(old_timer)
        if is_reference(old_ref), do: Process.demonitor(old_ref, [:flush])
        update_in(state.workers, &Map.delete(&1, key))
      else
        _ -> state
      end

    # Bump session token so any pending timeout from a previous worker under this key
    # is permanently ignored.
    session_token = state.session_token_counter + 1

    timer_ref =
      Process.send_after(self(), {:worker_timeout, key, session_token, 0}, @heartbeat_timeout_ms)

    monitor_ref = Process.monitor(pid)

    entry = %{
      run_id: run_id,
      worker_id: worker_id,
      phase_id: phase_id,
      worker_pid: pid,
      timer_ref: timer_ref,
      session_token: session_token,
      heartbeat_gen: 0,
      monitor_ref: monitor_ref,
      started_at: DateTime.utc_now()
    }

    workers = Map.put(state.workers, key, entry)
    {:noreply, %{state | session_token_counter: session_token, workers: workers}}
  end

  # ─── :heartbeat ────────────────────────────────────────────────────────────

  @impl true
  def handle_cast({:heartbeat, pid, run_id, worker_id, sequence, observed_at}, state) do
    key = {run_id, worker_id}

    # Verify the pid matches the currently tracked worker. A stale heartbeat
    # from an old pid (before re-track) is silently ignored.
    with %{
           worker_pid: ^pid,
           timer_ref: old_timer,
           session_token: session_token,
           heartbeat_gen: old_gen
         } <-
           Map.get(state.workers, key) do
      # Always cancel the old timer and start a fresh one, regardless of emit outcome.
      # Concurrent/duplicate heartbeats may produce out-of-order or duplicate errors;
      # we do not let those prevent liveness tracking.
      if is_reference(old_timer), do: Process.cancel_timer(old_timer)

      # Emit heartbeat through WorkerProtocol so sequence validation applies.
      _ =
        WorkerProtocol.emit("WorkerHeartbeat", %{
          run_id: run_id,
          worker_id: worker_id,
          sequence: sequence,
          observed_at: observed_at,
          pid: pid
        })

      # Start a fresh timer with incremented heartbeat_gen (same session_token).
      new_gen = old_gen + 1

      new_timer_ref =
        Process.send_after(
          self(),
          {:worker_timeout, key, session_token, new_gen},
          @heartbeat_timeout_ms
        )

      entry = %{state.workers[key] | timer_ref: new_timer_ref, heartbeat_gen: new_gen}
      {:noreply, %{state | workers: Map.put(state.workers, key, entry)}}
    else
      _ -> {:noreply, state}
    end
  end
  # ─── Private ────────────────────────────────────────────────────────────────

  # Returns true for truly abnormal exits that indicate a crash loop.
  # Excludes OTP's graceful shutdown signals (:normal, :shutdown, {:shutdown, _}).
  defp abnormal_exit?(:normal), do: false
  defp abnormal_exit?(:shutdown), do: false
  defp abnormal_exit?({:shutdown, _}), do: false
  defp abnormal_exit?(_), do: true

  # ─── :DOWN ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    # Silent no-op if the monitor ref is unknown (e.g. from a previous pid under
    # the same key that was already re-tracked and demonitored).
    case Enum.find(state.workers, fn {_key, w} -> w.monitor_ref == ref end) do
      {key, entry} ->
        if is_reference(entry.timer_ref), do: Process.cancel_timer(entry.timer_ref)

        # Emit may fail if the run is already terminal; log and continue cleanup.
        _ =
          WorkerProtocol.emit("WorkerExited", %{
            run_id: entry.run_id,
            worker_id: entry.worker_id,
            sequence: nil,
            reason: reason,
            exited_at: DateTime.utc_now()
          })

        # AC-002-1: 4th abnormal exit → WorkerCrashed + run.pause.
        # AC-002-2: If run is terminal, WorkerCrashed.emit fails → skip run.pause.
        # Crash history is recorded only for abnormal exits; clean exits are not crashes.
        state =
          if abnormal_exit?(reason) do
            now_ms = System.monotonic_time(:millisecond)
            window_ms = 5 * 60 * 1_000

            timestamps =
              state.crash_history
              |> Map.get(key, [])
              |> Enum.filter(fn ts -> now_ms - ts < window_ms end)
              |> then(fn existing -> [now_ms | existing] end)

            crash_history = Map.put(state.crash_history, key, timestamps)

            if length(timestamps) > 3 do
              case WorkerProtocol.emit("WorkerCrashed", %{
                     run_id: entry.run_id,
                     worker_id: entry.worker_id,
                     phase_id: entry.phase_id,
                     sequence: nil,
                     reason: "exceeded crash threshold (4 in 5 min)",
                     detected_at: DateTime.utc_now()
                   }) do
                {:ok, _} ->
                  _ =
                    CommandRouter.handle(%{
                      command_id: "run.pause:#{entry.run_id}:#{entry.worker_id}:#{now_ms}",
                      command_type: "run.pause",
                      payload: %{
                        run_id: entry.run_id,
                        reason: "worker crash loop detected"
                      }
                    })

                {:error, _} ->
                  :ok
              end

              # Clear history after emit to prevent re-triggering on next crash.
              Map.delete(crash_history, key)
            else
              crash_history
            end
            |> then(fn ch -> %{state | crash_history: ch} end)
          else
            state
          end

        {:noreply, update_in(state.workers, &Map.delete(&1, key))}

      nil ->
        {:noreply, state}
    end
  end

  # ─── :worker_timeout ───────────────────────────────────────────────────────

  @impl true
  def handle_info({:worker_timeout, key, session_token, heartbeat_gen}, state) do
    with %{
           session_token: ^session_token,
           heartbeat_gen: ^heartbeat_gen,
           run_id: run_id,
           worker_id: worker_id,
           phase_id: phase_id
         } <- Map.get(state.workers, key) do
      # Emit may fail if the run is already terminal; only trigger recovery after
      # WorkerUnresponsive is confirmed persisted, so aggregate idempotency applies.
      case WorkerProtocol.emit("WorkerUnresponsive", %{
             run_id: run_id,
             worker_id: worker_id,
             sequence: nil,
             reason: "no heartbeat for #{@heartbeat_timeout_ms}ms",
             detected_at: DateTime.utc_now()
           }) do
        {:ok, _} ->
          _ =
            CommandRouter.handle(%{
              command_id: "recovery.require:#{run_id}:#{worker_id}:#{session_token}",
              command_type: "recovery.require",
              payload: %{
                run_id: run_id,
                worker_id: worker_id,
                phase_id: phase_id,
                reason: "no heartbeat for #{@heartbeat_timeout_ms}ms"
              }
            })

        {:error, _} ->
          :ok
      end

      {:noreply, update_in(state.workers, &Map.delete(&1, key))}
    else
      # One or both tokens stale — heartbeat or re-track arrived before this message
      # was processed; ignore it silently.
      _ -> {:noreply, state}
    end
  end
end
