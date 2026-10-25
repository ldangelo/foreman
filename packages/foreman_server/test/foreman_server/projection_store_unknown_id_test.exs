defmodule ForemanServer.ProjectionStoreUnknownIdTest do
  @moduledoc """
  An event for a task/phase id the store has never seen must not mint a partial
  entry (foreman-03acm, AGENTS.md 5.3): `TaskRunTerminated` for an unknown task
  used to project a task with no `:task_id`, which broke every reader that
  assumed the identity key. The same events, in creation-first order, must
  still project (replay ordering).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TelemetryTest.Handler
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @at "2026-08-10T00:00:00Z"

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  defp task_events(task_id, run_id) do
    [
      {"TaskUpdated", %{task_id: task_id, title: "renamed"}},
      {"TaskApproved",
       %{
         task_id: task_id,
         run_id: run_id,
         approval_id: "a-1",
         approved_by: "t",
         approved_at: @at,
         workflow_snapshot: nil
       }},
      {"TaskDispatched", %{task_id: task_id, run_id: run_id, approval_id: "a-1"}},
      {"TaskExecutionCompleted", %{task_id: task_id, run_id: run_id}},
      {"TaskExecutionFailed", %{task_id: task_id, run_id: run_id, reason: "boom"}},
      {"TaskRunTerminated", %{task_id: task_id, run_id: run_id, acknowledged_at: @at}},
      {"TaskRetried", %{task_id: task_id, previous_run_id: run_id}}
    ]
  end

  defp phase_events(phase_id, run_id) do
    [
      {"PhaseCompleted",
       %{
         phase_id: phase_id,
         run_id: run_id,
         index: 0,
         artifact_path: "p",
         artifact_sha256: "s",
         artifact_bytes: 1
       }},
      {"PhaseFailed", %{phase_id: phase_id, run_id: run_id, index: 0, reason: "x"}}
    ]
  end

  defp phases, do: :sys.get_state(ProjectionStore).phases

  defp apply!(events) do
    assert :ok =
             ProjectionStore.apply_events(
               for {type, payload} <- events, do: %{event_type: type, payload: payload}
             )
  end

  test "task events for an unknown task id create no entry" do
    log =
      capture_log(fn ->
        for {type, payload} <- task_events("task-ghost", "run-ghost") do
          apply!([{type, payload}])
          assert ProjectionStore.task_projection("task-ghost") == nil, "#{type} minted a task"
        end
      end)

    assert ProjectionStore.list_tasks() == []
    assert log =~ "dropped TaskRunTerminated for unknown tasks id \"task-ghost\""
  end

  test "phase events for an unknown phase id create no entry" do
    log =
      capture_log(fn ->
        for {type, payload} <- phase_events("phase-ghost", "run-ghost") do
          apply!([{type, payload}])
        end
      end)

    assert phases() == %{}
    assert log =~ "dropped PhaseCompleted for unknown phases id \"phase-ghost\""
  end

  test "a stall for an unknown task or phase creates no task/phase entry" do
    capture_log(fn ->
      apply!([
        {"RunStallReported",
         %{
           run_id: "run-s",
           phase_id: "phase-ghost",
           task_id: "task-ghost",
           reason: "no_output",
           detected_at: @at
         }}
      ])
    end)

    assert ProjectionStore.task_projection("task-ghost") == nil
    assert phases() == %{}
  end

  test "creation-first replay still projects every task event" do
    apply!([
      {"TaskCreated",
       %{task_id: "task-real", project_id: "p-1", title: "t", status: "open", task_type: "task"}}
      | task_events("task-real", "run-real")
    ])

    assert %{task_id: "task-real", project_id: "p-1", status: "open", title: "renamed"} =
             ProjectionStore.task_projection("task-real")

    # TaskRunTerminated landed on the real entry, not a keyless one.
    assert %{acknowledged_run_id: nil, run_terminal_reason: nil} =
             ProjectionStore.task_projection("task-real")

    assert [%{task_id: "task-real"}] = ProjectionStore.list_tasks()
  end

  test "TaskRunTerminated on a known task records the acknowledgement" do
    apply!([
      {"TaskCreated",
       %{task_id: "task-ack", project_id: "p-1", title: "t", status: "open", task_type: "task"}},
      {"TaskRunTerminated", %{task_id: "task-ack", run_id: "run-1", acknowledged_at: @at}}
    ])

    assert %{task_id: "task-ack", acknowledged_run_id: "run-1"} =
             ProjectionStore.task_projection("task-ack")
  end

  test "phase completion after PhaseStarted still projects" do
    apply!([
      {"RunStarted", %{run_id: "run-p", task_id: "t-1", project_id: "p-1"}},
      {"PhaseStarted",
       %{
         phase_id: "phase-real",
         run_id: "run-p",
         index: 0,
         name: "n",
         attempt: 1,
         artifact_template: %{}
       }}
      | phase_events("phase-real", "run-p")
    ])

    assert %{"phase-real" => %{phase_id: "phase-real", status: "failed", artifact: %{path: "p"}}} =
             phases()
  end

  describe "[:foreman, :projection, :event_dropped] telemetry" do
    @event_dropped [:foreman, :projection, :event_dropped]

    setup do
      {handler_id, ref} = Handler.attach_event_handlers(self(), [@event_dropped])
      on_exit(fn -> :telemetry.detach(handler_id) end)
      %{ref: ref}
    end

    test "every dropped task event reports its type, the collection and the id", %{ref: ref} do
      events = task_events("task-ghost", "run-ghost")
      capture_log(fn -> for event <- events, do: apply!([event]) end)

      for {type, _payload} <- events do
        assert_receive {@event_dropped, ^ref, %{count: 1},
                        %{event_type: ^type, collection: :tasks, id: "task-ghost"}}
      end
    end

    test "every dropped phase event reports its type, the collection and the id", %{ref: ref} do
      events = phase_events("phase-ghost", "run-ghost")
      capture_log(fn -> for event <- events, do: apply!([event]) end)

      for {type, _payload} <- events do
        assert_receive {@event_dropped, ^ref, %{count: 1},
                        %{event_type: ^type, collection: :phases, id: "phase-ghost"}}
      end
    end

    test "a stall for an unknown task and phase reports one drop per collection", %{ref: ref} do
      stall =
        {"RunStallReported",
         %{
           run_id: "run-s",
           phase_id: "phase-ghost",
           task_id: "task-ghost",
           reason: "no_output",
           detected_at: @at
         }}

      capture_log(fn -> apply!([stall]) end)

      assert_receive {@event_dropped, ^ref, %{count: 1},
                      %{event_type: "RunStallReported", collection: :phases, id: "phase-ghost"}}

      assert_receive {@event_dropped, ^ref, %{count: 1},
                      %{event_type: "RunStallReported", collection: :tasks, id: "task-ghost"}}
    end

    test "events for ids the store knows drop nothing", %{ref: ref} do
      apply!([
        {"TaskCreated",
         %{task_id: "task-real", project_id: "p-1", title: "t", status: "open", task_type: "task"}}
        | task_events("task-real", "run-real")
      ])

      refute_receive {@event_dropped, ^ref, _measurements, %{id: "task-real"}}, 100
    end
  end
end
