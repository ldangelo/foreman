defmodule ForemanServer.Operations do
  @moduledoc "Operational doctor checks, metrics, and projection lag reporting."

  alias ForemanServer.{Event, EventStore, ProjectionStore, ProviderRegistry, VcsAdapter}

  @failure_events MapSet.new(["PhaseFailed", "PhaseTimedOut", "RunFailed", "MergeFailed"])
  @recovery_events MapSet.new([
                     "WorkerFailureSimulated",
                     "WorkerRecoveryRequired",
                     "ExternalWorkerObserved",
                     "WorkerReattached",
                     "WorkerRestarted",
                     "NeedsOperator"
                   ])

  @spec doctor() :: {:ok, map()}
  def doctor do
    events = EventStore.all()
    snapshot = ProjectionStore.snapshot()
    metrics = metrics(events, snapshot)

    checks = %{
      db: check_db(events),
      projections: check_projections(events, snapshot, metrics.projection_lag),
      workers: check_workers(snapshot),
      vcs: check_vcs(),
      provider_adapters: check_provider_adapters(),
      integrations: check_integrations(snapshot)
    }

    {:ok,
     %{
       ok: Enum.all?(checks, fn {_name, check} -> check.ok end),
       checks: checks,
       metrics: metrics,
       checked_at: DateTime.utc_now()
     }}
  end

  @spec metrics() :: {:ok, map()}
  def metrics do
    {:ok, metrics(EventStore.all(), ProjectionStore.snapshot())}
  end

  defp check_db(events) do
    %{ok: true, event_count: length(events), message: "event store readable"}
  rescue
    error -> %{ok: false, message: Exception.message(error)}
  end

  defp check_projections(events, snapshot, lag) do
    %{
      ok: lag == 0,
      event_count: length(events),
      last_sequence: Map.get(snapshot, :last_sequence, 0),
      projection_lag: lag,
      message: if(lag == 0, do: "projections caught up", else: "projections lag event store")
    }
  end

  defp check_workers(snapshot) do
    workers = snapshot |> Map.get(:worker_sequences, %{}) |> map_size()
    heartbeats = snapshot |> Map.get(:worker_heartbeats, %{}) |> map_size()

    %{
      ok: true,
      worker_sequences: workers,
      heartbeats: heartbeats,
      message: "worker projection readable"
    }
  end

  defp check_vcs do
    adapters = VcsAdapter.adapters()

    %{
      ok: Enum.any?(adapters, &(&1.backend == "git")),
      adapters: Enum.map(adapters, & &1.backend),
      message: "vcs adapters registered"
    }
  rescue
    error -> %{ok: false, adapters: [], message: Exception.message(error)}
  end

  defp check_provider_adapters do
    adapters = ProviderRegistry.adapters()
    pi_ready = Enum.any?(adapters, &(&1.id == "pi_sdk" and &1.production_ready))

    %{
      ok: pi_ready,
      adapters: Enum.map(adapters, &Map.take(&1, [:id, :production_ready, :worker_protocol])),
      message: "provider adapters registered"
    }
  rescue
    error -> %{ok: false, adapters: [], message: Exception.message(error)}
  end

  defp check_integrations(snapshot) do
    %{
      ok: true,
      commands: snapshot |> Map.get(:integration_commands, %{}) |> map_size(),
      dedupe_keys: snapshot |> Map.get(:integration_dedupe, %{}) |> map_size(),
      message: "integration projections readable"
    }
  end

  @spec pipeline_metrics() :: {:ok, map()}
  def pipeline_metrics do
    {:ok, pipeline_metrics(EventStore.all())}
  end

  @doc false
  def pipeline_metrics(events) when is_list(events) do
    by_phase = aggregate_by_phase(events)
    top_failures = top_failure_reasons(events, 5)
    stuck_by_reason = stuck_by_reason(events)
    bottlenecks = recent_bottlenecks(events, 5)
    blocked_reasons = blocked_reasons(events)

    %{
      phases: by_phase,
      top_failure_reasons: top_failures,
      stuck_by_reason: stuck_by_reason,
      blocked_by_reason: blocked_reasons,
      retry_details: %{
        stuck_by_reason: stuck_by_reason,
        blocked_by_reason: blocked_reasons,
        qa_environment_blocked: count_qa_environment_blocked(events)
      },
      counters: counters(events),
      recent_bottlenecks: bottlenecks,
      emitted_at: DateTime.utc_now()
    }
  end

  @doc false
  def metrics(events, snapshot) when is_list(events) and is_map(snapshot) do
    %{
      counters: counters(events),
      timers: %{phase_duration_ms: phase_durations(events)},
      gauges: %{projection_lag: projection_lag(events, snapshot)},
      projection_lag: projection_lag(events, snapshot),
      emitted_at: DateTime.utc_now()
    }
  end

  defp counters(events) do
    %{
      phases_started: count(events, "PhaseStarted"),
      phases_completed: count(events, "PhaseCompleted"),
      retries: count(events, "PhaseRetried"),
      failures: Enum.count(events, &MapSet.member?(@failure_events, &1.event_type)),
      recoveries: Enum.count(events, &MapSet.member?(@recovery_events, &1.event_type)),
      worker_restarts: count(events, "WorkerRestarted"),
      circuit_breaker_hits: count(events, "CircuitBreakerTripped"),
      qa_environment_blocked: count_qa_environment_blocked(events)
    }
  end

  defp count(events, type), do: Enum.count(events, &(&1.event_type == type))

  defp phase_durations(events) do
    events
    |> Enum.reduce(%{}, fn %Event{} = event, acc ->
      payload = event.payload
      key = {Map.get(payload, :run_id), Map.get(payload, :phase_id)}

      cond do
        event.event_type == "PhaseStarted" and valid_phase_key?(key) ->
          Map.put(acc, key, %{started_at: event.occurred_at})

        event.event_type in ["PhaseCompleted", "PhaseFailed", "PhaseTimedOut"] and
            valid_phase_key?(key) ->
          Map.update(
            acc,
            key,
            %{ended_at: event.occurred_at, status: terminal_status(event)},
            fn value ->
              value
              |> Map.put(:ended_at, event.occurred_at)
              |> Map.put(:status, terminal_status(event))
            end
          )

        true ->
          acc
      end
    end)
    |> Enum.flat_map(fn {{run_id, phase_id}, value} ->
      with %DateTime{} = started_at <- Map.get(value, :started_at),
           %DateTime{} = ended_at <- Map.get(value, :ended_at) do
        [
          %{
            run_id: run_id,
            phase_id: phase_id,
            status: Map.get(value, :status),
            duration_ms: DateTime.diff(ended_at, started_at, :millisecond)
          }
        ]
      else
        _ -> []
      end
    end)
    |> Enum.sort_by(&{&1.run_id, &1.phase_id})
  end

  defp projection_lag([], _snapshot), do: 0

  defp projection_lag(events, snapshot) do
    last_event_id = get_in(snapshot, [:checkpoint, :last_event_id])

    case Enum.find_index(events, &(&1.event_id == last_event_id)) do
      nil -> length(events)
      index -> max(length(events) - index - 1, 0)
    end
  end

  defp valid_phase_key?({run_id, phase_id}), do: is_binary(run_id) and is_binary(phase_id)

  defp terminal_status(%Event{event_type: "PhaseCompleted"}), do: "completed"
  defp terminal_status(%Event{event_type: "PhaseTimedOut"}), do: "timed_out"
  defp terminal_status(%Event{event_type: "PhaseFailed"}), do: "failed"

  # ── Pipeline metrics helpers ────────────────────────────────────────────────

  defp aggregate_by_phase(events) do
    events
    |> Enum.reduce(%{}, fn %Event{} = event, acc ->
      phase_id = Map.get(event.payload, :phase_id)

      if is_binary(phase_id) and phase_id != "" do
        key = phase_id

        case event.event_type do
          "PhaseStarted" ->
            Map.update(
              acc,
              key,
              %{
                started: 1,
                completed: 0,
                failed: 0,
                timed_out: 0,
                retries: 0,
                total_turns: 0,
                total_cost: 0.0,
                observations: 0
              },
              fn v ->
                %{v | started: v.started + 1}
              end
            )

          "PhaseCompleted" ->
            Map.update(
              acc,
              key,
              %{
                started: 0,
                completed: 1,
                failed: 0,
                timed_out: 0,
                retries: 0,
                total_turns: 0,
                total_cost: 0.0,
                observations: 0
              },
              fn v ->
                %{v | completed: v.completed + 1}
              end
            )

          type when type in ["PhaseFailed", "PhaseTimedOut"] ->
            status_key = if type == "PhaseTimedOut", do: :timed_out, else: :failed

            Map.update(
              acc,
              key,
              %{
                started: 0,
                completed: 0,
                failed: 0,
                timed_out: 0,
                retries: 0,
                total_turns: 0,
                total_cost: 0.0,
                observations: 0
              },
              fn v ->
                Map.update!(v, status_key, &(&1 + 1))
              end
            )

          "PhaseRetried" ->
            Map.update(
              acc,
              key,
              %{
                started: 0,
                completed: 0,
                failed: 0,
                timed_out: 0,
                retries: 0,
                total_turns: 0,
                total_cost: 0.0,
                observations: 0
              },
              fn v ->
                %{v | retries: v.retries + 1}
              end
            )

          "ToolCallFinished" ->
            turns = Map.get(event.payload, :turns, 0) |> clamp_integer()
            cost = Map.get(event.payload, :cost, 0.0) |> clamp_float()

            Map.update(
              acc,
              key,
              %{
                started: 0,
                completed: 0,
                failed: 0,
                timed_out: 0,
                retries: 0,
                total_turns: 0,
                total_cost: 0.0,
                observations: 0
              },
              fn v ->
                %{
                  v
                  | total_turns: v.total_turns + turns,
                    total_cost: v.total_cost + cost,
                    observations: v.observations + 1
                }
              end
            )

          _ ->
            acc
        end
      else
        acc
      end
    end)
    |> Enum.map(fn {phase_id, counts} ->
      # pass_rate is completed / (completed + failed + timed_out); started is not a terminal state
      terminals = max(counts.completed + counts.failed + counts.timed_out, 1)
      total = max(counts.started + counts.completed + counts.failed + counts.timed_out, 1)
      pass_rate = counts.completed / terminals
      observations = max(counts.observations, 1)
      avg_turns = counts.total_turns / observations
      avg_cost = counts.total_cost / observations

      {phase_id,
       %{
         pass_rate: pass_rate,
         fail_count: counts.failed,
         timed_out_count: counts.timed_out,
         retry_count: counts.retries,
         avg_turns: avg_turns,
         avg_cost: avg_cost,
         total_runs: total,
         phases_started: counts.started,
         phases_completed: counts.completed
       }}
    end)
    |> Map.new()
  end

  defp top_failure_reasons(events, limit) do
    events
    |> Enum.filter(fn %Event{} = e ->
      e.event_type in ["PhaseFailed", "PhaseTimedOut", "RunFailed"]
    end)
    |> Enum.map(fn %Event{} = e ->
      reason = Map.get(e.payload, :failure_reason) || Map.get(e.payload, :reason) || "unknown"
      phase = Map.get(e.payload, :phase_id) || "unknown"
      %{reason: reason, phase: phase, count: 1}
    end)
    |> Enum.group_by(&{&1.reason, &1.phase})
    |> Enum.map(fn {{reason, phase}, items} ->
      %{reason: reason, phase: phase, count: length(items)}
    end)
    |> Enum.sort_by(&(-&1.count))
    |> Enum.take(limit)
  end

  defp stuck_by_reason(events) do
    events
    |> Enum.filter(fn %Event{} = e ->
      e.event_type in ["PhaseFailed", "PhaseTimedOut"] and
        Map.get(e.payload, :stuck) == true
    end)
    |> Enum.map(fn %Event{} = e ->
      reason = Map.get(e.payload, :failure_reason) || "unknown"
      phase = Map.get(e.payload, :phase_id) || "unknown"
      %{reason: reason, phase: phase, count: 1}
    end)
    |> Enum.group_by(&{&1.reason, &1.phase})
    |> Enum.map(fn {{reason, phase}, items} ->
      %{reason: reason, phase: phase, count: length(items)}
    end)
    |> Enum.sort_by(&(-&1.count))
  end

  defp blocked_reasons(events) do
    events
    |> Enum.filter(fn %Event{} = e ->
      e.event_type in ["PhaseFailed", "PhaseTimedOut"] and
        Map.get(e.payload, :blocked) == true
    end)
    |> Enum.map(fn %Event{} = e ->
      reason = Map.get(e.payload, :failure_reason) || "unknown"
      phase = Map.get(e.payload, :phase_id) || "unknown"
      %{reason: reason, phase: phase, count: 1}
    end)
    |> Enum.group_by(&{&1.reason, &1.phase})
    |> Enum.map(fn {{reason, phase}, items} ->
      %{reason: reason, phase: phase, count: length(items)}
    end)
    |> Enum.sort_by(&(-&1.count))
  end

  defp count_qa_environment_blocked(events) do
    Enum.count(events, fn %Event{} = e ->
      phase_id = Map.get(e.payload, :phase_id)

      e.event_type in ["PhaseFailed", "PhaseTimedOut"] and
        is_binary(phase_id) and
        String.contains?(phase_id, "qa") and
        Map.get(e.payload, :environment_blocked) == true
    end)
  end

  defp recent_bottlenecks(events, limit) do
    events
    |> Enum.filter(fn %Event{} = e ->
      e.event_type == "PhaseStarted"
    end)
    |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})
    |> Enum.take(limit * 2)
    |> Enum.map(fn %Event{} = e ->
      phase_id = Map.get(e.payload, :phase_id)
      run_id = Map.get(e.payload, :run_id)
      %{phase_id: phase_id, run_id: run_id, started_at: e.occurred_at}
    end)
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  defp clamp_integer(n) when is_integer(n) and n >= 0, do: n
  defp clamp_integer(_), do: 0

  defp clamp_float(n) when is_float(n) and n >= 0.0, do: n
  defp clamp_float(n) when is_integer(n) and n >= 0, do: :erlang.float(n)
  defp clamp_float(_), do: 0.0
end
