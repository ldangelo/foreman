defmodule ForemanServer.Aggregates.TaskTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Task
  alias ForemanServer.Aggregates.Task.State

  describe "initial_state/0" do
    test "returns a non-existent state" do
      state = Task.initial_state()
      assert state.exists? == false
      assert state.task_id == nil
      assert state.status == nil
      assert state.run_id == nil
      assert state.approval_id == nil
    end
  end

  describe "handle_command/2 — task.create" do
    test "emits TaskCreated with task_id and project_id" do
      state = Task.initial_state()

      assert {:ok, event_spec} =
               Task.handle_command(state, %{
                 type: "task.create",
                 payload: %{task_id: "t-1", project_id: "p-1"}
               })

      assert event_spec.event_type == "TaskCreated"
      assert event_spec.payload.task_id == "t-1"
      assert event_spec.payload.project_id == "p-1"
      assert event_spec.stream_id == "task:t-1"
    end
  end

  describe "handle_command/2 — task.approve" do
    test "emits TaskApproved with required fields" do
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          status: "open"
      }

      assert {:ok, event_spec} =
               Task.handle_command(state, %{
                 type: "task.approve",
                 payload: %{
                   task_id: "t-1",
                   approval_id: "approval-abc",
                   approved_by: "alice",
                   approved_at: "2026-01-01T00:00:00Z",
                   run_id: "run-xyz",
                   workflow_snapshot: %{run_id: "run-xyz", phases: []}
                 }
               })

      assert event_spec.event_type == "TaskApproved"
      assert event_spec.payload.task_id == "t-1"
      assert event_spec.payload.run_id == "run-xyz"
      assert event_spec.payload.approval_id == "approval-abc"
    end

    test "rejects approval when task does not exist" do
      state = Task.initial_state()

      assert {:error, {:not_found, :task, "t-missing"}} =
               Task.handle_command(state, %{
                 type: "task.approve",
                 payload: %{
                   task_id: "t-missing",
                   approval_id: "approval-abc",
                   approved_by: "alice",
                   approved_at: "2026-01-01T00:00:00Z",
                   run_id: "run-xyz",
                   workflow_snapshot: %{run_id: "run-xyz", phases: []}
                 }
               })
    end

    test "rejects approval when approved_by is missing" do
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          status: "open"
      }

      assert {:error, {:missing_or_invalid, :approved_by, nil}} =
               Task.handle_command(state, %{
                 type: "task.approve",
                 payload: %{
                   task_id: "t-1",
                   approval_id: "approval-abc",
                   approved_at: "2026-01-01T00:00:00Z",
                   run_id: "run-xyz",
                   workflow_snapshot: %{run_id: "run-xyz", phases: []}
                 }
               })
    end

    test "rejects approval when workflow_snapshot is empty" do
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          status: "open"
      }

      assert {:error, {:missing_or_invalid, :workflow_snapshot, %{}}} =
               Task.handle_command(state, %{
                 type: "task.approve",
                 payload: %{
                   task_id: "t-1",
                   approval_id: "approval-abc",
                   approved_by: "alice",
                   approved_at: "2026-01-01T00:00:00Z",
                   run_id: "run-xyz",
                   workflow_snapshot: %{}
                 }
               })
    end
  end

  describe "handle_command/2 — task.dispatch" do
    test "emits TaskDispatched when status is ready and approval + run are bound" do
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          status: "ready",
          run_id: "run-xyz",
          approval_id: "approval-abc"
      }

      assert {:ok, event_spec} =
               Task.handle_command(state, %{
                 type: "task.dispatch",
                 payload: %{task_id: "t-1"}
               })

      assert event_spec.event_type == "TaskDispatched"
      assert event_spec.payload.run_id == "run-xyz"
      assert event_spec.payload.approval_id == "approval-abc"
    end

    test "rejects dispatch when task does not exist" do
      state = Task.initial_state()

      assert {:error, {:not_found, :task, "t-missing"}} =
               Task.handle_command(state, %{
                 type: "task.dispatch",
                 payload: %{task_id: "t-missing"}
               })
    end

    test "rejects dispatch when status is not ready" do
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          status: "open",
          run_id: "run-xyz",
          approval_id: "approval-abc"
      }

      assert {:error, {:task_not_dispatchable, "open", "run-xyz", "approval-abc"}} =
               Task.handle_command(state, %{
                 type: "task.dispatch",
                 payload: %{task_id: "t-1"}
               })
    end

    test "rejects dispatch when approval_id is nil even if status is ready" do
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          status: "ready",
          run_id: "run-xyz",
          approval_id: nil
      }

      assert {:error, {:task_not_dispatchable, "ready", "run-xyz", nil}} =
               Task.handle_command(state, %{
                 type: "task.dispatch",
                 payload: %{task_id: "t-1"}
               })
    end

    test "rejects dispatch when run_id is nil even if status is ready" do
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          status: "ready",
          run_id: nil,
          approval_id: "approval-abc"
      }

      assert {:error, {:task_not_dispatchable, "ready", nil, "approval-abc"}} =
               Task.handle_command(state, %{
                 type: "task.dispatch",
                 payload: %{task_id: "t-1"}
               })
    end

    test "rejects dispatch when task is already in_progress" do
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          status: "in_progress",
          run_id: "run-xyz",
          approval_id: "approval-abc"
      }

      assert {:error, {:task_not_dispatchable, "in_progress", "run-xyz", "approval-abc"}} =
               Task.handle_command(state, %{
                 type: "task.dispatch",
                 payload: %{task_id: "t-1"}
               })
    end

    test "rejects dispatch when task is closed" do
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          status: "closed",
          run_id: "run-xyz",
          approval_id: "approval-abc"
      }

      assert {:error, {:task_not_dispatchable, "closed", "run-xyz", "approval-abc"}} =
               Task.handle_command(state, %{
                 type: "task.dispatch",
                 payload: %{task_id: "t-1"}
               })
    end
  end

  describe "handle_command/2 — task.execution_complete" do
    test "emits TaskExecutionCompleted when status is in_progress" do
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          status: "in_progress",
          run_id: "run-xyz"
      }

      assert {:ok, event_spec} =
               Task.handle_command(state, %{
                 type: "task.execution_complete",
                 payload: %{task_id: "t-1"}
               })

      assert event_spec.event_type == "TaskExecutionCompleted"
      assert event_spec.payload.run_id == "run-xyz"
    end

    test "rejects execution_complete when status is ready" do
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          status: "ready",
          run_id: "run-xyz"
      }

      assert {:error, {:task_not_executing, "ready"}} =
               Task.handle_command(state, %{
                 type: "task.execution_complete",
                 payload: %{task_id: "t-1"}
               })
    end

    test "rejects execution_complete when task is closed" do
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          status: "closed",
          run_id: "run-xyz"
      }

      assert {:error, {:task_not_executing, "closed"}} =
               Task.handle_command(state, %{
                 type: "task.execution_complete",
                 payload: %{task_id: "t-1"}
               })
    end
  end

  describe "handle_command/2 — task.execution_fail" do
    test "emits TaskExecutionFailed when status is in_progress" do
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          status: "in_progress",
          run_id: "run-xyz"
      }

      assert {:ok, event_spec} =
               Task.handle_command(state, %{
                 type: "task.execution_fail",
                 payload: %{task_id: "t-1", reason: "boom"}
               })

      assert event_spec.event_type == "TaskExecutionFailed"
      assert event_spec.payload.reason == "boom"
    end

    test "rejects execution_fail when status is ready" do
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          status: "ready",
          run_id: "run-xyz"
      }

      assert {:error, {:task_not_executing, "ready"}} =
               Task.handle_command(state, %{
                 type: "task.execution_fail",
                 payload: %{task_id: "t-1", reason: "boom"}
               })
    end
  end

  describe "handle_command/2 — task.run_terminated" do
    test "emits TaskRunTerminated when run matches bound run" do
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          status: "in_progress",
          run_id: "run-xyz"
      }

      assert {:ok, event_spec} =
               Task.handle_command(state, %{
                 type: "task.run_terminated",
                 payload: %{
                   task_id: "t-1",
                   run_id: "run-xyz",
                   reason: "run_cancelled"
                 }
               })

      assert event_spec.event_type == "TaskRunTerminated"
      assert event_spec.payload.run_id == "run-xyz"
      assert event_spec.payload.reason == "run_cancelled"
    end

    test "rejects when task is not in_progress" do
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          status: "open",
          run_id: "run-xyz"
      }

      assert {:error, {:task_not_in_progress, "open"}} =
               Task.handle_command(state, %{
                 type: "task.run_terminated",
                 payload: %{task_id: "t-1", run_id: "run-xyz"}
               })
    end

    test "rejects when run_id does not match bound run" do
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          status: "in_progress",
          run_id: "run-xyz"
      }

      assert {:error, {:run_id_mismatch, "run-xyz", "run-other"}} =
               Task.handle_command(state, %{
                 type: "task.run_terminated",
                 payload: %{task_id: "t-1", run_id: "run-other"}
               })
    end

    test "rejects when run_id is missing" do
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          status: "in_progress"
      }

      assert {:error, {:missing_or_invalid, :run_id}} =
               Task.handle_command(state, %{
                 type: "task.run_terminated",
                 payload: %{task_id: "t-1"}
               })
    end
  end

  describe "handle_command/2 — task.retry" do
    test "emits TaskRetried when payload carries gateway-attested run evidence" do
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          run_id: "run-xyz",
          status: "in_progress"
      }

      assert {:ok, event_spec} =
               Task.handle_command(state, %{
                 type: "task.retry",
                 payload: %{
                   task_id: "t-1",
                   acknowledged_run_id: "run-xyz",
                   reason: "remediation"
                 }
               })

      assert event_spec.event_type == "TaskRetried"
      assert event_spec.payload.previous_run_id == "run-xyz"
      assert event_spec.payload.reason == "remediation"
    end

    test "rejects when payload has no gateway-attested run evidence" do
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          run_id: "run-xyz",
          status: "in_progress"
      }

      assert {:error, {:missing_or_invalid, :acknowledged_run_id}} =
               Task.handle_command(state, %{
                 type: "task.retry",
                 payload: %{task_id: "t-1"}
               })
    end

    test "rejects when attested run_id does not match bound run" do
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          run_id: "run-xyz",
          status: "in_progress"
      }

      assert {:error, {:run_id_mismatch, "run-xyz", "run-other"}} =
               Task.handle_command(state, %{
                 type: "task.retry",
                 payload: %{
                   task_id: "t-1",
                   acknowledged_run_id: "run-other"
                 }
               })
    end

    test "rejects when no run is bound" do
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          run_id: nil
      }

      assert {:error, {:run_id_mismatch, nil, "run-xyz"}} =
               Task.handle_command(state, %{
                 type: "task.retry",
                 payload: %{
                   task_id: "t-1",
                   acknowledged_run_id: "run-xyz"
                 }
               })
    end

    test "rejects when task is not in_progress" do
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          run_id: "run-xyz",
          status: "open"
      }

      assert {:error, {:task_not_retriable, "open"}} =
               Task.handle_command(state, %{
                 type: "task.retry",
                 payload: %{
                   task_id: "t-1",
                   acknowledged_run_id: "run-xyz"
                 }
               })
    end

    test "accepts the post-invariant failed state (task flipped to failed by emit_phase_failure)" do
      # The `RunExecutor.emit_phase_failure/4` invariant dispatches
      # `run.fail` BEFORE `task.execution_fail`, so a phase timeout
      # leaves the task in `failed` with the run terminal. The retry
      # path is the remediation for that exact state — a stale
      # `require_in_progress` precondition would block it.
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          run_id: "run-xyz",
          status: "failed"
      }

      assert {:ok, event_spec} =
               Task.handle_command(state, %{
                 type: "task.retry",
                 payload: %{
                   task_id: "t-1",
                   acknowledged_run_id: "run-xyz",
                   reason: "phase_timeout_recovery"
                 }
               })

      assert event_spec.event_type == "TaskRetried"
      assert event_spec.payload.previous_run_id == "run-xyz"
      assert event_spec.payload.reason == "phase_timeout_recovery"
    end
  end

  describe "handle_command/2 — unknown" do
    test "returns :unhandled" do
      assert :unhandled ==
               Task.handle_command(Task.initial_state(), %{type: "x", payload: %{}})
    end
  end
end
