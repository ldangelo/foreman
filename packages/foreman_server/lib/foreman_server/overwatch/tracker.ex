defmodule ForemanServer.Overwatch.Tracker do
  @moduledoc """
  Worker liveness tracker. **Sole dispatch owner** for worker lifecycle
  events. All sequenced events — heartbeat, lifecycle (worker_started,
  worker_exited, tool_call_finished, etc.) — are allocated, dispatched,
  and advanced atomically inside this GenServer. No external code
  computes sequences and dispatches.

  ## Public dispatch API

    * `heartbeat/3` — sole producer of `WorkerHeartbeat`. Resets the
      liveness timer. Atomically allocates and dispatches.
    * `dispatch_lifecycle/3` — sole producer of non-heartbeat
      sequenced events (`WorkerStarted`, `WorkerExited`,
      `ToolCallFinished`, `AssistantMessage`, `WorkerStdout`,
      `WorkerStderr`). Atomically allocates and dispatches.
    * `register/4` — registers a worker pid for monitoring.
    * `sequence/3` — read the current sequence mirror.
    * `unregister/3` — full cleanup (drops sequence mirror).
    * `pid_for/3` — look up the active worker pid.

  ## Sequence model

  Sequences are per `(worker_id, run_id)`, NOT per pid. They are
  preserved across reconnects and DOWN events. The authoritative source
  is the Worker aggregate's `last_sequence` after replay; the Tracker
  mirrors that locally and rehydrates on first register/sequence-read.

  ## Timer model

  Each registered worker has one `Process.send_after/3` ref stored in
  Tracker state. Heartbeats cancel and reschedule the timer with the
  configured `heartbeat_timeout_ms` (default 60s). When the timer
  fires, the Tracker emits `WorkerUnresponsive` exactly once per gap.
  """

  use GenServer

  require Logger

  alias ForemanServer.Aggregate.Actor
  alias ForemanServer.Aggregator
  alias ForemanServer.CommandRouter

  @default_heartbeat_timeout_ms 60_000

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
  Register a worker pid for liveness tracking. The Tracker monitors
  the pid via `Process.monitor/1` and arms the heartbeat timer.
  Sequence is rehydrated from the Worker aggregate on first register.
  """
  @spec register(GenServer.server(), String.t(), String.t(), pid()) :: :ok
  def register(server \\ __MODULE__, worker_id, run_id, worker_pid)
      when is_pid(worker_pid) do
    GenServer.call(server, {:register, worker_id, run_id, worker_pid})
  end

  @doc """
  Emit a heartbeat. Atomically allocates the next sequence, dispatches
  `WorkerHeartbeat` via `CommandRouter`, and advances the mirror on
  success. Resets the liveness timer on success.
  """
  @spec heartbeat(GenServer.server(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, atom() | tuple()}
  def heartbeat(server \\ __MODULE__, worker_id, run_id) do
    GenServer.call(server, {:heartbeat, worker_id, run_id})
  end

  @doc """
  Allocate, dispatch, and advance atomically for a non-heartbeat
  sequenced event. The `event_type` string must be one of the registered
  Worker aggregate event types. Returns `:ok` on success or
  `{:error, reason}` on failure. On failure, the sequence mirror is
  NOT advanced — the next `dispatch_lifecycle/3` retries with the
  same sequence (deterministic `command_id` dedupes at CommandRouter).
  """
  @spec dispatch_lifecycle(GenServer.server(), String.t(), map()) ::
          :ok | {:error, atom() | tuple()}
  def dispatch_lifecycle(server \\ __MODULE__, event_type, payload)
      when is_binary(event_type) and is_map(payload) do
    GenServer.call(server, {:dispatch_lifecycle, event_type, payload})
  end

  @doc """
  Read the current sequence mirror for `(worker_id, run_id)`.
  Rehydrates from the Worker aggregate on first read in a fresh
  Tracker lifetime. Returns the Worker's `last_sequence`.
  """
  @spec sequence(GenServer.server(), String.t(), String.t()) :: integer()
  def sequence(server \\ __MODULE__, worker_id, run_id) do
    GenServer.call(server, {:sequence, worker_id, run_id})
  end

  @doc """
  Full cleanup. Cancels timer, demonitors pid, removes liveness state
  AND the sequence mirror. Use only when the worker is fully done.
  """
  @spec unregister(GenServer.server(), String.t(), String.t()) :: :ok
  def unregister(server \\ __MODULE__, worker_id, run_id) do
    GenServer.call(server, {:unregister, worker_id, run_id})
  end

  @doc "Look up the tracked pid for a worker, or `nil` if not registered."
  @spec pid_for(GenServer.server(), String.t(), String.t()) :: pid() | nil
  def pid_for(server \\ __MODULE__, worker_id, run_id) do
    GenServer.call(server, {:pid_for, worker_id, run_id})
  end

  @doc "Worker aggregate stream id. Matches `CommandRouter.aggregate_module_for/1`."
  def stream_id(worker_id, run_id), do: "worker:#{run_id}:#{worker_id}"

  # ------------------------------------------------------------------
  # GenServer
  # ------------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       workers: %{},
       sequences: %{},
       timers: %{},
       monitors: %{},
       heartbeat_timeout_ms: Keyword.get(opts, :heartbeat_timeout_ms, @default_heartbeat_timeout_ms)
     }}
  end

  defp key(worker_id, run_id), do: "#{run_id}:#{worker_id}"

  defp put_worker(state, key, worker) do
    %{state | workers: Map.put(state.workers, key, worker)}
  end

  defp drop_worker(state, key) do
    %{state | workers: Map.delete(state.workers, key)}
  end

  defp put_sequence(state, key, seq) do
    %{state | sequences: Map.put(state.sequences, key, seq)}
  end

  defp get_sequence(state, key) do
    Map.get(state.sequences, key)
  end

  defp rehydrate_sequence_from_aggregate(worker_id, run_id) do
    sid = stream_id(worker_id, run_id)

    case Aggregator.start_aggregate(ForemanServer.Aggregates.Worker, sid) do
      {:ok, actor_pid} ->
        try do
          case Actor.get_state(actor_pid) do
            %{last_sequence: seq} when is_integer(seq) -> seq
            _ -> -1
          end
        catch
          :exit, _ -> -1
        end

      _ ->
        -1
    end
  rescue
    _ -> -1
  end

  @impl true
  def handle_call({:register, worker_id, run_id, worker_pid}, _from, state) do
    k = key(worker_id, run_id)

    sequence =
      case get_sequence(state, k) do
        nil -> rehydrate_sequence_from_aggregate(worker_id, run_id)
        seq -> seq
      end

    state = put_sequence(state, k, sequence)

    if Map.has_key?(state.monitors, k) do
      {:reply, :ok, state}
    else
      monitor_ref = Process.monitor(worker_pid)

      worker = %{
        worker_id: worker_id,
        run_id: run_id,
        pid: worker_pid,
        unresponsive_emitted?: false,
        exited?: false
      }

      state = put_worker(state, k, worker)
      state = %{state | monitors: Map.put(state.monitors, k, monitor_ref)}
      state = arm_timer(state, k)

      {:reply, :ok, state}
    end
  end

  def handle_call({:heartbeat, worker_id, run_id}, _from, state) do
    k = key(worker_id, run_id)

    case Map.get(state.workers, k) do
      nil ->
        {:reply, {:error, :not_registered}, state}

      %{exited?: true} ->
        {:reply, {:error, :exited}, state}

      worker ->
        do_heartbeat(state, k, worker)
    end
  end

  def handle_call({:dispatch_lifecycle, event_type, payload}, _from, state) do
    %{worker_id: worker_id, run_id: run_id} = payload
    k = key(worker_id, run_id)

    current_seq = get_sequence(state, k) || rehydrate_sequence_from_aggregate(worker_id, run_id)
    state = put_sequence(state, k, current_seq)
    new_seq = current_seq + 1

    command_id = command_id_for(worker_id, run_id, event_type, new_seq)

    full_payload = %{
      "event_type" => event_type,
      "worker_id" => worker_id,
      "run_id" => run_id,
      "sequence" => new_seq
    }

    full_payload =
      payload
      |> stringify_payload()
      |> Map.merge(full_payload)

    command = %{
      aggregate_id: stream_id(worker_id, run_id),
      type: "worker.record",
      payload: full_payload,
      command_id: command_id
    }

    case dispatch_command(command) do
      :ok ->
        state = put_sequence(state, k, new_seq)
        {:reply, :ok, state}

      {:error, reason} = err ->
        Logger.warning(
          "Overwatch.Tracker: lifecycle dispatch failed (#{event_type} #{command_id}): #{inspect(reason)}"
        )

        {:reply, err, state}
    end
  end

  def handle_call({:sequence, worker_id, run_id}, _from, state) do
    k = key(worker_id, run_id)

    seq =
      case get_sequence(state, k) do
        nil -> rehydrate_sequence_from_aggregate(worker_id, run_id)
        s -> s
      end

    {:reply, seq, state}
  end

  def handle_call({:unregister, worker_id, run_id}, _from, state) do
    state = full_cleanup(state, key(worker_id, run_id))
    {:reply, :ok, state}
  end

  def handle_call({:pid_for, worker_id, run_id}, _from, state) do
    k = key(worker_id, run_id)

    pid =
      case Map.get(state.workers, k) do
        nil -> nil
        %{pid: pid} -> pid
      end

    {:reply, pid, state}
  end

  @impl true
  def handle_info({:heartbeat_timeout, k}, state) do
    state = %{state | timers: Map.delete(state.timers, k)}

    case Map.get(state.workers, k) do
      nil ->
        {:noreply, state}

      %{unresponsive_emitted?: true, exited?: false} ->
        state = arm_timer(state, k)
        {:noreply, state}

      %{exited?: true} ->
        {:noreply, state}

      worker ->
        current_seq = get_sequence(state, k) || 0
        new_seq = current_seq + 1

        command_id = command_id_for(worker.worker_id, worker.run_id, "WorkerUnresponsive", new_seq)

        payload = %{
          "event_type" => "WorkerUnresponsive",
          "worker_id" => worker.worker_id,
          "run_id" => worker.run_id,
          "sequence" => new_seq,
          "timeout_ms" => state.heartbeat_timeout_ms
        }

        command = %{
          aggregate_id: stream_id(worker.worker_id, worker.run_id),
          type: "worker.record",
          payload: payload,
          command_id: command_id
        }

        case dispatch_command(command) do
          :ok ->
            # Trigger recovery observation: Recovery aggregate observes
            # `WorkerRecoveryRequired` and gates subsequent action commands
            # (reattach / restart / needs_operator / resolve) on having
            # at least one prior observation. The Tracker is the sole
            # place that knows the run is unresponsive, so it owns the
            # downstream cross-aggregate fan-out.
            case trigger_recovery(worker.worker_id, worker.run_id, new_seq) do
              :ok ->
                state = put_sequence(state, k, new_seq)

                worker = %{worker | unresponsive_emitted?: true}
                state = put_worker(state, k, worker)
                {:noreply, state}

              {:error, recovery_reason} ->
                Logger.warning(
                  "Overwatch.Tracker: recovery.require failed " <>
                    "(#{worker.worker_id}/#{worker.run_id} seq=#{new_seq}): " <>
                    "#{inspect(recovery_reason)}; re-arming timer"
                )

                # WorkerUnresponsive was already appended (and the
                # sequence advanced on the Worker stream). The recovery
                # observation is missing — re-arm the timer so the next
                # gap detection retries the cross-aggregate fan-out.
                # Idempotency on the recovery aggregate (deterministic
                # command_id) keeps the retry safe.
                state = arm_timer(state, k)
                {:noreply, state}
            end

          {:error, reason} ->
            Logger.warning(
              "Overwatch.Tracker: unresponsive dispatch failed " <>
                "(#{worker.worker_id}/#{worker.run_id} seq=#{new_seq}): #{inspect(reason)}"
            )

            state = arm_timer(state, k)
            {:noreply, state}
        end
    end
  end


  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    k = find_key_by_monitor_ref(state, ref)
    state =
      case k do
        nil -> state
        _ -> state |> emit_worker_exited_for(k) |> cleanup_after_down(k)
      end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp do_heartbeat(state, k, worker) do
    current_seq = get_sequence(state, k) || 0

    new_seq = current_seq + 1

    now_ms = System.system_time(:millisecond)


    command_id = command_id_for(worker.worker_id, worker.run_id, "WorkerHeartbeat", new_seq)

    payload = %{
      "event_type" => "WorkerHeartbeat",
      "worker_id" => worker.worker_id,
      "run_id" => worker.run_id,
      "sequence" => new_seq,
      "timestamp" => now_ms
    }

    command = %{
      aggregate_id: stream_id(worker.worker_id, worker.run_id),
      type: "worker.record",
      payload: payload,
      command_id: command_id
    }

    case dispatch_command(command) do
      :ok ->
        state = put_sequence(state, k, new_seq)

        worker = %{worker | unresponsive_emitted?: false}
        state = put_worker(state, k, worker)
        state = arm_timer(state, k)

        {:reply, {:ok, new_seq}, state}

      {:error, reason} = err ->
        Logger.warning(
          "Overwatch.Tracker: heartbeat dispatch failed " <>
            "(#{worker.worker_id}/#{worker.run_id} seq=#{new_seq}): #{inspect(reason)}"
        )

        {:reply, err, state}
    end
  end

  defp arm_timer(state, k) do
    case Map.get(state.timers, k) do
      nil -> :ok
      ref -> Process.cancel_timer(ref)
    end

    ref = Process.send_after(self(), {:heartbeat_timeout, k}, state.heartbeat_timeout_ms)
    %{state | timers: Map.put(state.timers, k, ref)}
  end

  defp emit_worker_exited_for(state, k) do
    case Map.get(state.workers, k) do
      nil ->
        state

      worker ->
        current_seq = get_sequence(state, k) || 0
        new_seq = current_seq + 1

        command_id = command_id_for(worker.worker_id, worker.run_id, "WorkerExited", new_seq)

        payload = %{
          "event_type" => "WorkerExited",
          "worker_id" => worker.worker_id,
          "run_id" => worker.run_id,
          "sequence" => new_seq
        }

        command = %{
          aggregate_id: stream_id(worker.worker_id, worker.run_id),
          type: "worker.record",
          payload: payload,
          command_id: command_id
        }

        case dispatch_command(command) do
          :ok ->
            state = put_sequence(state, k, new_seq)
            worker = %{worker | exited?: true}
            put_worker(state, k, worker)

          {:error, reason} ->
            Logger.warning(
              "Overwatch.Tracker: exited dispatch failed " <>
                "(#{worker.worker_id}/#{worker.run_id} seq=#{new_seq}): #{inspect(reason)}"
            )

            worker = %{worker | exited?: true}
            put_worker(state, k, worker)
        end
    end
  end

  defp cleanup_after_down(state, k) do
    state = drop_worker(state, k)

    state =
      case Map.pop(state.timers, k) do
        {nil, timers} -> %{state | timers: timers}
        {ref, timers} ->
          Process.cancel_timer(ref)
          %{state | timers: timers}
      end

    state =
      case Map.pop(state.monitors, k) do
        {nil, monitors} -> %{state | monitors: monitors}
        {ref, monitors} ->
          Process.demonitor(ref, [:flush])
          %{state | monitors: monitors}
      end

    state
  end

  defp full_cleanup(state, k) do
    state = drop_worker(state, k)
    state = %{state | sequences: Map.delete(state.sequences, k)}

    state =
      case Map.pop(state.timers, k) do
        {nil, timers} -> %{state | timers: timers}
        {ref, timers} ->
          Process.cancel_timer(ref)
          %{state | timers: timers}
      end

    state =
      case Map.pop(state.monitors, k) do
        {nil, monitors} -> %{state | monitors: monitors}
        {ref, monitors} ->
          Process.demonitor(ref, [:flush])
          %{state | monitors: monitors}
      end

    state
  end

  defp find_key_by_monitor_ref(state, ref) do
    Enum.find_value(state.monitors, fn {k, r} -> if r == ref, do: k end)
  end

  defp dispatch_command(command) do
    case CommandRouter.dispatch(command) do
      {:ok, _event_spec} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception ->
      Logger.warning(
        "Overwatch.Tracker: dispatch raised: #{Exception.message(exception)}"
      )

      {:error, {:dispatch_raised, exception}}
  end

  defp command_id_for(worker_id, run_id, event_type, seq),
    do: "#{run_id}:#{worker_id}:#{event_type}:#{seq}"

  defp stringify_payload(payload) do
    Enum.reduce(payload, %{}, fn
      {k, v}, acc when is_atom(k) -> Map.put(acc, Atom.to_string(k), v)
      {k, v}, acc when is_binary(k) -> Map.put(acc, k, v)
    end)
  end

  # Dispatches a `recovery.require` command to the Recovery aggregate,
  # producing a `WorkerRecoveryRequired` observation. Returns `:ok` on
  # success, `{:error, reason}` on failure — the caller is responsible
  # for NOT advancing worker state on failure so the timer retries.
  # Deterministic command_id (`recovery:<run_id>:<worker_id>:unresponsive:<seq>`)
  # dedups re-dispatches against the same unresponsive emission.
  defp trigger_recovery(worker_id, run_id, seq) do
    command_id = "recovery:#{run_id}:#{worker_id}:unresponsive:#{seq}"

    command = %{
      aggregate_id: "recovery:#{run_id}",
      type: "recovery.require",
      payload: %{"run_id" => run_id, "worker_id" => worker_id, "sequence" => seq},
      command_id: command_id
    }

    case CommandRouter.dispatch(command) do
      :ok ->
        :ok

      {:ok, _event_spec} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception ->
      Logger.warning(
        "Overwatch.Tracker: recovery.require dispatch raised: #{Exception.message(exception)}"
      )

      {:error, {:dispatch_raised, exception}}
  end
end