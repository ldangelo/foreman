defmodule ForemanServer.StallDetectorTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{ProjectionStore, StallDetector}

  @now 1_700_000_000_000

  setup do
    ForemanServer.TestSupport.ProjectionStoreReset.reset!(keep_subscribers: true)
    Process.put(:projection_store_now_ms, fn -> @now end)

    on_exit(fn ->
      Process.delete(:projection_store_now_ms)
      ForemanServer.TestSupport.ProjectionStoreReset.reset!(keep_subscribers: true)
    end)

    :ok
  end

  test "phase start metadata initializes activity and exposes bounded candidates" do
    seed_run("run-stall", "task-stall")
    seed_phase("run-stall", "phase-1", @now, "agent_no_output", 10_000, "fail")

    assert [candidate] = ProjectionStore.stall_candidates(@now + 10_000)
    assert candidate.run_id == "run-stall"
    assert candidate.task_id == "task-stall"
    assert candidate.phase_id == "phase-1"
    assert candidate.stall_kind == "agent_no_output"
    assert candidate.threshold_ms == 10_000
    assert candidate.idle_ms == 10_000
  end

  test "heartbeat does not advance output activity but stdout does" do
    seed_run("run-heartbeat", nil)
    seed_phase("run-heartbeat", "phase-1", @now, "agent_no_output", 10_000, "fail")

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "WorkerHeartbeat",
                 payload: %{run_id: "run-heartbeat", worker_id: "w1", sequence: 1}
               }
             ])

    assert [_] = ProjectionStore.stall_candidates(@now + 10_000)

    Process.put(:projection_store_now_ms, fn -> @now + 9_000 end)

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "WorkerStdout",
                 payload: %{
                   run_id: "run-heartbeat",
                   worker_id: "w1",
                   sequence: 2,
                   line: "progress"
                 }
               }
             ])

    assert [] = ProjectionStore.stall_candidates(@now + 18_999)
    assert [_] = ProjectionStore.stall_candidates(@now + 19_000)
  end

  test "detector dispatches one run.report_stall command at threshold" do
    seed_run("run-detector", nil)
    seed_phase("run-detector", "phase-1", @now, "messaging_no_progress", 1_000, "attention")

    parent = self()

    result =
      StallDetector.scan(
        now_ms_fun: fn -> @now + 1_000 end,
        dispatch_fun: fn command, _timeout ->
          send(parent, command)
          {:ok, :recorded}
        end
      )

    assert [%{dispatch: :ok}] = result
    assert_receive %{type: "run.report_stall", payload: %{stall_kind: "messaging_no_progress"}}
  end

  test "RunStallReported projects latest stall without inbox message fabrication" do
    seed_run("run-projected", "task-projected")
    seed_phase("run-projected", "phase-1", @now, "messaging_no_progress", 1_000, "attention")

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "RunStallReported",
                 payload: %{
                   run_id: "run-projected",
                   task_id: "task-projected",
                   phase_id: "phase-1",
                   phase_index: 1,
                   phase_name: "wait",
                   stall_kind: "messaging_no_progress",
                   policy: "attention",
                   status_effect: "blocked",
                   threshold_ms: 1_000,
                   idle_ms: 1_000,
                   activity_at_ms: @now,
                   detected_at_ms: @now + 1_000,
                   idempotency_key: "k1",
                   reason: "no messages"
                 }
               }
             ])

    assert %{latest_stall: %{reason: "no messages"}, status: "blocked"} =
             ProjectionStore.run("run-projected")

    assert [%{latest_stall: %{reason: "no messages"}}] =
             ProjectionStore.phases_for_run("run-projected")

    assert %{latest_stall: %{reason: "no messages"}, attention_reason: "no messages"} =
             ProjectionStore.task_projection("task-projected")

    assert ProjectionStore.inbox_thread("run-projected") == nil
  end

  defp seed_run(run_id, task_id) do
    ProjectionStore.apply_events([
      %{
        event_type: "RunStarted",
        payload: %{
          run_id: run_id,
          task_id: task_id,
          project_id: "project-1",
          workflow_snapshot: %{}
        }
      }
    ])
  end

  defp seed_phase(run_id, phase_id, event_at_ms, kind, threshold_ms, policy) do
    Process.put(:projection_store_now_ms, fn -> event_at_ms end)

    ProjectionStore.apply_events([
      %{
        event_type: "PhaseStarted",
        payload: %{
          run_id: run_id,
          phase_id: phase_id,
          index: 1,
          name: "wait",
          attempt: 1,
          artifact_template: %{},
          stall_detection_kind: kind,
          stall_threshold_ms: threshold_ms,
          stall_policy: policy
        }
      }
    ])
  end
end
