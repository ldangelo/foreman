defmodule ForemanServer.Aggregates.RunStallReportedTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Run
  alias ForemanServer.EventCodec

  test "run.report_stall emits durable event with explicit status effect" do
    state =
      Run.initial_state()
      |> Run.apply_event(%{
        event_type: "RunStarted",
        payload: %{run_id: "run-1", task_id: "task-1", project_id: "project-1"}
      })

    payload = %{
      run_id: "run-1",
      phase_id: "phase-1",
      phase_index: 1,
      phase_name: "wait",
      stall_kind: "agent_no_output",
      policy: "fail",
      threshold_ms: 1_000,
      idle_ms: 1_000,
      activity_at_ms: 0,
      detected_at_ms: 1_000,
      idempotency_key: "run-1:phase-1:agent_no_output:0",
      reason: "no output"
    }

    assert {:ok, %{event_type: "RunStallReported", payload: event_payload}} =
             Run.handle_command(state, %{type: "run.report_stall", payload: payload})

    assert event_payload.status_effect == "failed"
    assert event_payload.task_id == "task-1"
  end

  test "duplicate stall idempotency key is a no-op after fold" do
    state =
      Run.initial_state()
      |> Run.apply_event(%{
        event_type: "RunStarted",
        payload: %{run_id: "run-1", project_id: "project-1"}
      })
      |> Run.apply_event(%{
        event_type: "RunStallReported",
        payload: %{
          run_id: "run-1",
          phase_id: "phase-1",
          stall_kind: "messaging_no_progress",
          policy: "attention",
          status_effect: "blocked",
          threshold_ms: 1,
          idle_ms: 1,
          detected_at_ms: 1,
          idempotency_key: "same",
          reason: "no progress"
        }
      })

    assert {:ok, nil} =
             Run.handle_command(state, %{
               type: "run.report_stall",
               payload: %{
                 run_id: "run-1",
                 phase_id: "phase-1",
                 stall_kind: "messaging_no_progress",
                 policy: "attention",
                 threshold_ms: 1,
                 idle_ms: 1,
                 detected_at_ms: 1,
                 idempotency_key: "same",
                 reason: "no progress"
               }
             })
  end

  test "EventCodec registers RunStallReported and rejects unknown fields" do
    payload = %{
      run_id: "run-1",
      phase_id: "phase-1",
      stall_kind: "agent_no_output",
      policy: "fail",
      threshold_ms: 1_000,
      idle_ms: 1_000,
      detected_at_ms: 1_000,
      idempotency_key: "k1",
      reason: "no output"
    }

    assert %ForemanServer.Events.RunStallReported{} =
             EventCodec.decode!("RunStallReported", payload)

    assert_raise ArgumentError, ~r/unknown fields/, fn ->
      EventCodec.decode!("RunStallReported", Map.put(payload, :extra, true))
    end
  end
end
