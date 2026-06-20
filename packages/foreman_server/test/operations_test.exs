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
    seed_run_events("run-doctor")

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
    seed_run_events("run-metrics")

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
    seed_run_events("run-lag")
    events = EventStore.all()
    assert {:ok, lagging_projection} = ProjectionStore.rebuild(Enum.drop(events, -1))

    metrics = :erlang.apply(Operations, :metrics, [events, lagging_projection])
    assert metrics.projection_lag == 1
  end

  test "pipeline_metrics aggregates per-phase pass rate, failures, retries, turns, and cost" do
    # Explorer phase: started, then failed
    append_run_event(
      "RunStarted",
      %{run_id: "pm-ex", phase_order: ["explorer"]},
      ~U[2026-01-01 00:00:00Z]
    )

    append_run_event(
      "PhaseStarted",
      %{run_id: "pm-ex", phase_id: "explorer"},
      ~U[2026-01-01 00:00:01Z]
    )

    append_run_event(
      "ToolCallFinished",
      %{run_id: "pm-ex", phase_id: "explorer", worker_id: "w-ex", turns: 5, cost: 0.30},
      ~U[2026-01-01 00:00:02Z]
    )

    append_run_event(
      "PhaseFailed",
      %{run_id: "pm-ex", phase_id: "explorer", failure_reason: "explorer timeout"},
      ~U[2026-01-01 00:00:03Z]
    )

    # Developer phase: started, retried, then completed
    append_run_event(
      "RunStarted",
      %{run_id: "pm-dv", phase_order: ["developer"]},
      ~U[2026-01-01 01:00:00Z]
    )

    append_run_event(
      "PhaseStarted",
      %{run_id: "pm-dv", phase_id: "developer"},
      ~U[2026-01-01 01:00:01Z]
    )

    append_run_event(
      "PhaseRetried",
      %{run_id: "pm-dv", phase_id: "developer", attempt: 2, retry_history: [%{attempt: 2}]},
      ~U[2026-01-01 01:00:02Z]
    )

    append_run_event(
      "ToolCallFinished",
      %{run_id: "pm-dv", phase_id: "developer", worker_id: "w-dv", turns: 10, cost: 0.60},
      ~U[2026-01-01 01:00:03Z]
    )

    append_run_event(
      "PhaseCompleted",
      %{run_id: "pm-dv", phase_id: "developer", status: "completed"},
      ~U[2026-01-01 01:00:04Z]
    )

    # QA phase: started, timed out
    append_run_event(
      "RunStarted",
      %{run_id: "pm-qa", phase_order: ["qa"]},
      ~U[2026-01-01 02:00:00Z]
    )

    append_run_event("PhaseStarted", %{run_id: "pm-qa", phase_id: "qa"}, ~U[2026-01-01 02:00:01Z])

    append_run_event(
      "PhaseTimedOut",
      %{run_id: "pm-qa", phase_id: "qa", failure_reason: "timeout"},
      ~U[2026-01-01 02:00:05Z]
    )

    assert {:ok, pm} = Operations.pipeline_metrics()

    # explorer: 1 failed, 0 completed
    explorer = Map.fetch!(pm.phases, "explorer")
    assert explorer.fail_count == 1
    assert explorer.phases_completed == 0
    assert explorer.pass_rate == 0.0
    assert explorer.retry_count == 0
    assert explorer.avg_turns == 5.0
    assert explorer.avg_cost == 0.30

    # developer: 1 completed, 0 failed (retried once)
    developer = Map.fetch!(pm.phases, "developer")
    assert developer.phases_completed == 1
    assert developer.fail_count == 0
    assert developer.pass_rate == 1.0
    assert developer.retry_count == 1
    assert developer.avg_turns == 10.0
    assert developer.avg_cost == 0.60

    # qa: 1 timed_out, 0 completed
    qa = Map.fetch!(pm.phases, "qa")
    assert qa.timed_out_count == 1
    assert qa.phases_completed == 0
    # pass_rate = completed / (completed + failed + timed_out) = 0 / 1 = 0.0
    assert qa.pass_rate == 0.0

    # top failure reasons: "explorer timeout" should appear first
    assert length(pm.top_failure_reasons) >= 2

    assert Enum.any?(
             pm.top_failure_reasons,
             &(&1.reason == "explorer timeout" and &1.phase == "explorer")
           )

    # stuck_by_reason: neither phase was stuck
    assert pm.stuck_by_reason == []

    # recent bottlenecks: most recent is qa phase
    assert length(pm.recent_bottlenecks) >= 1
  end

  defp seed_run_events(run_id) do
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
