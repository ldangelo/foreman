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

  @doc false
  def metrics(events, snapshot) when is_list(events) and is_map(snapshot) do
    phase_durations_list = phase_durations(events)
    total_time_ms = total_time_ms(phase_durations_list)
    total_cost_usd = total_cost_usd(events)
    total_turns = total_turns(events)

    %{
      counters: counters(events),
      timers: %{phase_duration_ms: phase_durations_list},
      gauges: %{projection_lag: projection_lag(events, snapshot)},
      projection_lag: projection_lag(events, snapshot),
      total_cost_usd: total_cost_usd,
      total_turns: total_turns,
      total_time_ms: total_time_ms,
      cost_per_turn: cost_per_turn(total_cost_usd, total_turns),
      time_per_turn_ms: time_per_turn_ms(total_time_ms, total_turns),
      emitted_at: DateTime.utc_now()
    }
  end

  defp total_cost_usd(events) do
    events
    |> Enum.filter(&(&1.event_type == "PhaseCompleted"))
    |> Enum.map(&extract_cost/1)
    |> Enum.sum()
  end

  defp extract_cost(%Event{} = event) do
    payload = event.payload
    details = Map.get(payload, :details, %{})

    # Try atom key first, then string key for costUsd
    cost =
      Map.get(payload, :cost_usd) ||
        Map.get(details, :cost_usd) ||
        Map.get(details, "costUsd") ||
        Map.get(details, :costUsd) ||
        0

    to_number(cost)
  end

  defp total_turns(events) do
    events
    |> Enum.filter(&(&1.event_type == "PhaseCompleted"))
    |> Enum.map(&extract_turns/1)
    |> Enum.sum()
  end

  defp extract_turns(%Event{} = event) do
    payload = event.payload
    details = Map.get(payload, :details, %{})

    # Try atom key first, then string key
    turns =
      Map.get(payload, :turns) ||
        Map.get(details, :turns) ||
        Map.get(details, "turns") ||
        0

    to_number(turns)
  end

  defp to_number(value) when is_number(value), do: value
  defp to_number(value) when is_binary(value), do: String.to_float(value)
  defp to_number(_), do: 0

  defp total_time_ms(phase_durations_list) when is_list(phase_durations_list) do
    phase_durations_list
    |> Enum.map(&Map.get(&1, :duration_ms, 0))
    |> Enum.sum()
  end

  defp cost_per_turn(_total_cost, 0), do: 0
  defp cost_per_turn(total_cost, total_turns) when total_turns > 0 do
    total_cost / total_turns
  end

  defp time_per_turn_ms(_total_time, 0), do: 0
  defp time_per_turn_ms(total_time, total_turns) when total_turns > 0 do
    total_time / total_turns
  end

  defp counters(events) do
    %{
      phases_started: count(events, "PhaseStarted"),
      phases_completed: count(events, "PhaseCompleted"),
      retries: count(events, "PhaseRetried"),
      failures: Enum.count(events, &MapSet.member?(@failure_events, &1.event_type)),
      recoveries: Enum.count(events, &MapSet.member?(@recovery_events, &1.event_type)),
      worker_restarts: count(events, "WorkerRestarted")
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
end
