defmodule ForemanServer.OperationsTest do
  use ExUnit.Case

  alias ForemanServer.{DebugViews, EventStore, Operations, ProjectionStore}

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "foreman-ops-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    assert :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    :ok
  end

  test "doctor validates operational dependencies and projection lag" do
    task_run_events("run-doctor")

    assert {:ok, doctor} = Operations.doctor()
    assert doctor.ok == true
    assert doctor.checks.db.ok == true
    assert doctor.checks.projections.ok == true
    assert doctor.checks.projections.projection_lag == 0
    assert doctor.checks.workers.ok == true
    assert doctor.checks.vcs.ok == true
    assert doctor.checks.provider_adapters.ok == true
    assert doctor.checks.integrations.ok == true
    assert doctor.metrics.projection_lag == 0
  end

  test "metrics include phase timers, retries, failures, recoveries, worker restarts, and lag" do
    task_run_events("run-metrics")

    append_run_event("PhaseRetried", %{
      run_id: "run-metrics",
      phase_id: "build",
      retry_history: [%{attempt: 2}]
    })

    append_run_event("PhaseFailed", %{run_id: "run-metrics", phase_id: "build", reason: "failed"})

    append_recovery_event("WorkerRestarted", %{run_id: "run-metrics", worker_id: "worker-metrics"})

    assert {:ok, metrics} = Operations.metrics()
    assert metrics.counters.retries == 1
    assert metrics.counters.failures == 1
    assert metrics.counters.recoveries == 1
    assert metrics.counters.worker_restarts == 1
    assert metrics.gauges.projection_lag == 0

    assert [%{run_id: "run-metrics", phase_id: "build", duration_ms: duration}] =
             metrics.timers.phase_duration_ms

    assert duration >= 1_000
  end

  test "metrics include cost and turn aggregations from PhaseCompleted events" do
    # Start a run with timing
    append_run_event(
      "RunStarted",
      %{run_id: "run-cost", phase_order: ["build"]},
      ~U[2026-01-01 00:00:00Z]
    )

    append_run_event(
      "PhaseStarted",
      %{run_id: "run-cost", phase_id: "build"},
      ~U[2026-01-01 00:00:01Z]
    )

    # PhaseCompleted with cost_usd and turns
    append_run_event(
      "PhaseCompleted",
      %{run_id: "run-cost", phase_id: "build", status: "completed", cost_usd: 1.25, turns: 5},
      ~U[2026-01-01 00:00:06Z]
    )

    # Another phase with different cost
    append_run_event(
      "PhaseStarted",
      %{run_id: "run-cost", phase_id: "test"},
      ~U[2026-01-01 00:00:07Z]
    )

    append_run_event(
      "PhaseCompleted",
      %{run_id: "run-cost", phase_id: "test", status: "completed", cost_usd: 0.75, turns: 3},
      ~U[2026-01-01 00:00:12Z]
    )

    # Complete the run
    append_run_event("RunCompleted", %{run_id: "run-cost"}, ~U[2026-01-01 00:00:13Z])

    assert {:ok, metrics} = Operations.metrics()

    # total_turns should be sum of turns from PhaseCompleted events
    assert metrics.total_turns == 8

    # total_cost should be sum of cost_usd from PhaseCompleted events
    assert metrics.total_cost == 2.0

    # cost_per_turn should be total_cost / total_turns
    assert metrics.cost_per_turn == "0.250000"

    # total_time_seconds should be sum of phase durations in seconds
    # Build phase: 5s (6000-1000) = 5000ms, Test phase: 5s (12000-7000) = 5000ms
    assert metrics.total_time_seconds == 10.0

    # time_per_turn_seconds should be total_time_seconds / total_turns (rounded to 2 decimals)
    assert metrics.time_per_turn_seconds == "1.25"
  end

  test "metrics handle edge cases: zero turns returns nil for per-turn metrics" do
    # Start a run
    append_run_event(
      "RunStarted",
      %{run_id: "run-empty", phase_order: ["build"]},
      ~U[2026-01-01 00:00:00Z]
    )

    append_run_event(
      "PhaseStarted",
      %{run_id: "run-empty", phase_id: "build"},
      ~U[2026-01-01 00:00:01Z]
    )

    # PhaseCompleted with zero cost and turns
    append_run_event(
      "PhaseCompleted",
      %{run_id: "run-empty", phase_id: "build", status: "completed", cost_usd: 0, turns: 0},
      ~U[2026-01-01 00:00:03Z]
    )

    append_run_event("RunCompleted", %{run_id: "run-empty"}, ~U[2026-01-01 00:00:04Z])

    assert {:ok, metrics} = Operations.metrics()

    assert metrics.total_turns == 0
    # cost_per_turn should be 0 when turns is 0
    assert metrics.cost_per_turn == 0
    # time_per_turn_seconds should be 0 when turns is 0
    assert metrics.time_per_turn_seconds == 0
  end

  test "debug timeline identifies first inconsistent transition" do
    append_run_event("RunStarted", %{run_id: "run-anomaly", phase_order: ["build"]})

    append_run_event("PhaseCompleted", %{
      run_id: "run-anomaly",
      phase_id: "build",
      status: "completed"
    })

    append_run_event("RunCompleted", %{run_id: "run-anomaly"})

    append_run_event("WorkerHeartbeat", %{
      run_id: "run-anomaly",
      phase_id: "build",
      worker_id: "worker-anomaly"
    })

    assert {:ok, debug} = DebugViews.debug_timeline("run-anomaly")
    assert debug.anomalies.count == 2
    assert debug.anomalies.first.reason == "phase_terminal_before_phase_start"
    assert debug.anomalies.first.type == "PhaseCompleted"
  end

  test "projection lag reports when projection checkpoint trails event store" do
    task_run_events("run-lag")
    events = EventStore.all()
    assert {:ok, lagging_projection} = ProjectionStore.rebuild(Enum.drop(events, -1))

    metrics = :erlang.apply(Operations, :metrics, [events, lagging_projection])
    assert metrics.projection_lag == 1
  end

  defp task_run_events(run_id) do
    append_run_event(
      "RunStarted",
      %{run_id: run_id, phase_order: ["build"]},
      ~U[2026-01-01 00:00:00Z]
    )

    append_run_event(
      "PhaseStarted",
      %{run_id: run_id, phase_id: "build"},
      ~U[2026-01-01 00:00:01Z]
    )

    append_worker_event("WorkerStarted", %{
      run_id: run_id,
      phase_id: "build",
      worker_id: "worker-#{run_id}",
      adapter: "pi_sdk",
      sequence: 0
    })

    append_run_event(
      "PhaseCompleted",
      %{run_id: run_id, phase_id: "build", status: "completed"},
      ~U[2026-01-01 00:00:03Z]
    )
  end

  defp append_run_event(type, payload, occurred_at \\ DateTime.utc_now()) do
    assert {:ok, _event} =
             EventStore.append(%{
               stream_id: "run:#{payload.run_id}",
               event_type: type,
               payload: payload,
               occurred_at: occurred_at,
               metadata: %{
                 correlation_id: payload.run_id,
                 idempotency_key: "#{type}:#{System.unique_integer()}"
               }
             })
  end

  defp append_worker_event(type, payload) do
    assert {:ok, _event} =
             EventStore.append(%{
               stream_id: "worker:#{payload.run_id}:#{payload.worker_id}",
               event_type: type,
               payload: Map.put(payload, :observed_at, DateTime.utc_now()),
               metadata: %{
                 correlation_id: payload.run_id,
                 idempotency_key: "#{type}:#{System.unique_integer()}"
               }
             })
  end

  defp append_recovery_event(type, payload) do
    assert {:ok, _event} =
             EventStore.append(%{
               stream_id: "recovery:#{payload.run_id}",
               event_type: type,
               payload: Map.put(payload, :observed_at, DateTime.utc_now()),
               metadata: %{
                 correlation_id: payload.run_id,
                 idempotency_key: "#{type}:#{System.unique_integer()}"
               }
             })
  end
end
