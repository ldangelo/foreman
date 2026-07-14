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

  test "metrics include total_cost_usd, total_turns, total_time_ms, cost_per_turn, and time_per_turn_ms" do
    # Create a task run with cost and turns data
    append_run_event(
      "RunStarted",
      %{run_id: "run-cost", phase_order: ["build", "test"]},
      ~U[2026-01-01 00:00:00Z]
    )

    # Phase 1: build with cost and turns
    append_run_event(
      "PhaseStarted",
      %{run_id: "run-cost", phase_id: "build"},
      ~U[2026-01-01 00:00:01Z]
    )

    append_run_event(
      "PhaseCompleted",
      %{run_id: "run-cost", phase_id: "build", status: "completed", details: %{"costUsd" => 0.05, "turns" => 10}},
      ~U[2026-01-01 00:00:05Z]
    )

    # Phase 2: test with cost and turns
    append_run_event(
      "PhaseStarted",
      %{run_id: "run-cost", phase_id: "test"},
      ~U[2026-01-01 00:00:06Z]
    )

    append_run_event(
      "PhaseCompleted",
      %{run_id: "run-cost", phase_id: "test", status: "completed", details: %{"costUsd" => 0.10, "turns" => 20}},
      ~U[2026-01-01 00:00:11Z]
    )

    assert {:ok, metrics} = Operations.metrics()

    # Verify total_cost_usd (0.05 + 0.10)
    assert_in_delta metrics.total_cost_usd, 0.15, 0.001

    # Verify total_turns (10 + 20)
    assert metrics.total_turns == 30

    # Verify total_time_ms: 4 seconds for build + 5 seconds for test = 9000ms
    assert metrics.total_time_ms >= 9000

    # Verify cost_per_turn: 0.15 / 30 = 0.005
    assert_in_delta metrics.cost_per_turn, 0.005, 0.0001

    # Verify time_per_turn_ms: 9000 / 30 = 300
    assert_in_delta metrics.time_per_turn_ms, 300.0, 0.1
  end

  test "metrics handle zero turns gracefully" do
    append_run_event(
      "RunStarted",
      %{run_id: "run-no-turns", phase_order: ["build"]},
      ~U[2026-01-01 00:00:00Z]
    )

    append_run_event(
      "PhaseStarted",
      %{run_id: "run-no-turns", phase_id: "build"},
      ~U[2026-01-01 00:00:01Z]
    )

    # Phase with no cost or turns data
    append_run_event(
      "PhaseCompleted",
      %{run_id: "run-no-turns", phase_id: "build", status: "completed"},
      ~U[2026-01-01 00:00:03Z]
    )

    assert {:ok, metrics} = Operations.metrics()

    # Should default to 0 when no data
    assert metrics.total_cost_usd == 0
    assert metrics.total_turns == 0
    assert metrics.cost_per_turn == 0
    assert metrics.time_per_turn_ms == 0
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
