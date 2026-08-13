defmodule ForemanServer.Aggregates.VcsOperationTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.VcsOperation
  alias ForemanServer.Aggregates.VcsOperation.State

  alias EventStore.RecordedEvent

  defp default_state, do: VcsOperation.initial_state()

  describe "initial_state/0" do
    test "returns a default State struct" do
      state = VcsOperation.initial_state()
      assert %State{} = state
      assert state.exists? == false
      assert state.operation_id == nil
      assert state.status == nil
      assert state.terminal? == false
    end
  end

  describe "handle_command/2 — vcs.worktree.create" do
    test "emits WorktreeCreated event with correlation tuple and worktree_path" do
      cmd = %{
        type: "vcs.worktree.create",
        payload: %{
          operation_id: "op-1",
          project_id: "proj-1",
          run_id: "run-1",
          phase_id: "phase-1",
          worktree_path: "/tmp/wt",
          branch: "foreman/run-1/phase-1",
          base_ref: "abc123",
          cleanup: "always"
        }
      }

      assert {:ok, spec} = VcsOperation.handle_command(default_state(), cmd)
      assert spec.event_type == "WorktreeCreated"
      assert spec.stream_id == "vcs:op-1"
      assert spec.payload.operation_id == "op-1"
      assert spec.payload.project_id == "proj-1"
      assert spec.payload.run_id == "run-1"
      assert spec.payload.phase_id == "phase-1"
      assert spec.payload.worktree_path == "/tmp/wt"
      assert spec.payload.branch == "foreman/run-1/phase-1"
      assert spec.payload.base_ref == "abc123"
      assert spec.payload.cleanup == "always"
    end

    test "rejects when operation_id is missing" do
      cmd = %{type: "vcs.worktree.create", payload: %{}}

      assert {:error, {:missing_or_invalid, :operation_id}} =
               VcsOperation.handle_command(default_state(), cmd)
    end

    test "rejects when project_id is missing" do
      cmd = %{
        type: "vcs.worktree.create",
        payload: %{operation_id: "op-1", run_id: "r", phase_id: "p", worktree_path: "/x"}
      }

      assert {:error, {:missing_or_invalid, :project_id}} =
               VcsOperation.handle_command(default_state(), cmd)
    end

    test "rejects when run_id is missing" do
      cmd = %{
        type: "vcs.worktree.create",
        payload: %{operation_id: "op-1", project_id: "p", phase_id: "ph", worktree_path: "/x"}
      }

      assert {:error, {:missing_or_invalid, :run_id}} =
               VcsOperation.handle_command(default_state(), cmd)
    end

    test "rejects when phase_id is missing" do
      cmd = %{
        type: "vcs.worktree.create",
        payload: %{operation_id: "op-1", project_id: "p", run_id: "r", worktree_path: "/x"}
      }

      assert {:error, {:missing_or_invalid, :phase_id}} =
               VcsOperation.handle_command(default_state(), cmd)
    end

    test "rejects when worktree_path is missing" do
      cmd = %{
        type: "vcs.worktree.create",
        payload: %{operation_id: "op-1", project_id: "p", run_id: "r", phase_id: "ph"}
      }

      assert {:error, {:missing_or_invalid, :worktree_path}} =
               VcsOperation.handle_command(default_state(), cmd)
    end
  end

  describe "handle_command/2 — vcs.worktree.clean" do
    test "emits WorktreeCleaned event with correlation tuple when operation exists" do
      state = %State{
        default_state()
        | exists?: true,
          operation_id: "op-1",
          project_id: "proj-1",
          run_id: "run-1",
          phase_id: "phase-1",
          status: "created"
      }

      cmd = %{
        type: "vcs.worktree.clean",
        payload: %{
          operation_id: "op-1",
          project_id: "proj-1",
          run_id: "run-1",
          phase_id: "phase-1",
          worktree_path: "/tmp/wt"
        }
      }

      assert {:ok, spec} = VcsOperation.handle_command(state, cmd)
      assert spec.event_type == "WorktreeCleaned"
      assert spec.stream_id == "vcs:op-1"
      assert spec.payload.operation_id == "op-1"
      assert spec.payload.project_id == "proj-1"
      assert spec.payload.run_id == "run-1"
      assert spec.payload.phase_id == "phase-1"
      assert spec.payload.worktree_path == "/tmp/wt"
    end

    test "rejects when correlation fields are missing" do
      cmd = %{type: "vcs.worktree.clean", payload: %{operation_id: "op-1"}}

      assert {:error, {:missing_or_invalid, _}} =
               VcsOperation.handle_command(default_state(), cmd)
    end

    test "rejects when correlation IDs do not match the existing operation" do
      state = %State{
        default_state()
        | exists?: true,
          operation_id: "op-1",
          project_id: "proj-1",
          run_id: "run-1",
          phase_id: "phase-1",
          status: "created"
      }

      cmd = %{
        type: "vcs.worktree.clean",
        payload: %{
          operation_id: "op-2",
          project_id: "proj-1",
          run_id: "run-1",
          phase_id: "phase-1"
        }
      }

      assert {:error, :correlation_mismatch} =
               VcsOperation.handle_command(state, cmd)
    end
  end

  describe "apply_event/2 — WorktreeCreated/WorktreeCleaned (typed codec path)" do
    test "WorktreeCreated populates correlation tuple and worktree config" do
      state = default_state()

      event = %{
        event_type: "WorktreeCreated",
        payload: %{
          operation_id: "wt-1",
          project_id: "proj-1",
          run_id: "run-1",
          phase_id: "phase-1",
          worktree_path: "/tmp/wt",
          branch: "foreman/run-1/phase-1",
          base_ref: "deadbeef",
          cleanup: "always"
        }
      }

      assert %State{} = new_state = VcsOperation.apply_event(state, event)
      assert new_state.exists? == true
      assert new_state.operation_id == "wt-1"
      assert new_state.project_id == "proj-1"
      assert new_state.run_id == "run-1"
      assert new_state.phase_id == "phase-1"
      assert new_state.status == "created"
      assert new_state.worktree_path == "/tmp/wt"
      assert new_state.branch == "foreman/run-1/phase-1"
      assert new_state.base_ref == "deadbeef"
      assert new_state.cleanup == "always"
    end

    test "WorktreeCreated recorded event path also decodes correctly" do
      state = default_state()

      recorded = %RecordedEvent{
        event_id: "00000000-0000-0000-0000-000000000001",
        stream_uuid: "vcs:wt-2",
        stream_version: 1,
        event_type: "WorktreeCreated",
        data: %{
          operation_id: "wt-2",
          project_id: "proj-2",
          run_id: "run-2",
          phase_id: "phase-2",
          worktree_path: "/tmp/wt2"
        }
      }

      assert %State{} = new_state = VcsOperation.apply_event(state, recorded)
      assert new_state.operation_id == "wt-2"
      assert new_state.project_id == "proj-2"
      assert new_state.run_id == "run-2"
      assert new_state.phase_id == "phase-2"
      assert new_state.worktree_path == "/tmp/wt2"
    end

    test "WorktreeCleaned preserves correlation and marks terminal" do
      state = %State{
        exists?: true,
        operation_id: "wt-1",
        project_id: "proj-1",
        run_id: "run-1",
        phase_id: "phase-1",
        status: "created",
        worktree_path: "/tmp/wt",
        branch: "foreman/run-1/phase-1",
        base_ref: "deadbeef",
        cleanup: "always",
        terminal?: false
      }

      event = %{
        event_type: "WorktreeCleaned",
        payload: %{
          operation_id: "wt-1",
          project_id: "proj-1",
          run_id: "run-1",
          phase_id: "phase-1",
          worktree_path: "/tmp/wt"
        }
      }

      assert %State{} = new_state = VcsOperation.apply_event(state, event)
      assert new_state.status == "cleaned"
      assert new_state.terminal? == true
      assert new_state.operation_id == "wt-1"
      assert new_state.project_id == "proj-1"
      assert new_state.run_id == "run-1"
      assert new_state.phase_id == "phase-1"
      assert new_state.worktree_path == "/tmp/wt"
    end

    test "WorktreeCleaned with nil worktree_path preserves the prior path" do
      state = %State{
        exists?: true,
        operation_id: "wt-1",
        project_id: "proj-1",
        run_id: "run-1",
        phase_id: "phase-1",
        status: "created",
        worktree_path: "/tmp/wt",
        branch: "foreman/run-1/phase-1",
        base_ref: "deadbeef",
        cleanup: "always",
        terminal?: false
      }

      event = %{
        event_type: "WorktreeCleaned",
        payload: %{
          operation_id: "wt-1",
          project_id: "proj-1",
          run_id: "run-1",
          phase_id: "phase-1"
        }
      }

      assert %State{} = new_state = VcsOperation.apply_event(state, event)
      assert new_state.status == "cleaned"
      assert new_state.terminal? == true
      assert new_state.worktree_path == "/tmp/wt"
    end
  end

  describe "handle_command/2 — vcs_operation.start" do
    test "emits VcsOperationStarted with stream_id vcs_operation:<id>" do
      cmd = %{
        type: "vcs_operation.start",
        payload: %{operation_id: "op-2", operation_type: "clone", target: "/tmp/x"}
      }

      assert {:ok, spec} = VcsOperation.handle_command(default_state(), cmd)
      assert spec.event_type == "VcsOperationStarted"
      assert spec.stream_id == "vcs_operation:op-2"
      assert spec.payload.operation_type == "clone"
    end
  end

  describe "handle_command/2 — vcs_operation.complete" do
    test "emits VcsOperationCompleted" do
      cmd = %{
        type: "vcs_operation.complete",
        payload: %{operation_id: "op-3", operation_type: "branch", result: %{branch: "x"}}
      }

      assert {:ok, spec} = VcsOperation.handle_command(default_state(), cmd)
      assert spec.event_type == "VcsOperationCompleted"
      assert spec.stream_id == "vcs_operation:op-3"
    end
  end

  describe "handle_command/2 — vcs_operation.fail" do
    test "emits VcsOperationFailed" do
      cmd = %{
        type: "vcs_operation.fail",
        payload: %{
          operation_id: "op-4",
          operation_type: "clone",
          error: :auth,
          retries: 0
        }
      }

      assert {:ok, spec} = VcsOperation.handle_command(default_state(), cmd)
      assert spec.event_type == "VcsOperationFailed"
      assert spec.stream_id == "vcs_operation:op-4"
    end
  end

  describe "apply_event/2 — VcsOperationStarted/Completed/Failed" do
    test "Started moves state to started" do
      started = %ForemanServer.Events.VcsOperationStarted{operation_id: "op-5"}
      event = wrap("VcsOperationStarted", started)
      state = VcsOperation.apply_event(default_state(), event)
      assert state.status == "started"
      assert state.operation_id == "op-5"
    end

    test "Completed marks terminal?" do
      completed = %ForemanServer.Events.VcsOperationCompleted{operation_id: "op-6", result: %{}}
      event = wrap("VcsOperationCompleted", completed)
      state = VcsOperation.apply_event(default_state(), event)
      assert state.status == "completed"
      assert state.terminal? == true
    end

    test "Failed marks terminal? with failed status" do
      failed = %ForemanServer.Events.VcsOperationFailed{operation_id: "op-7", error: :auth}
      event = wrap("VcsOperationFailed", failed)
      state = VcsOperation.apply_event(default_state(), event)
      assert state.status == "failed"
      assert state.terminal? == true
    end
  end

  describe "handle_command/2 — vcs.worktree.create.orphan_record" do
    test "emits WorktreeCreateOrphanRecorded from the initial state" do
      cmd = %{
        type: "vcs.worktree.create.orphan_record",
        payload: %{
          operation_id: "op-orphan-1",
          project_id: "proj-1",
          run_id: "run-1",
          phase_id: "phase-1",
          worktree_path: "/tmp/wt-orphan",
          reason: "compensation_failed"
        }
      }

      assert {:ok, spec} = VcsOperation.handle_command(default_state(), cmd)
      assert spec.event_type == "WorktreeCreateOrphanRecorded"
      assert spec.stream_id == "vcs:op-orphan-1"
      assert spec.payload.operation_id == "op-orphan-1"
      assert spec.payload.project_id == "proj-1"
      assert spec.payload.run_id == "run-1"
      assert spec.payload.phase_id == "phase-1"
      assert spec.payload.worktree_path == "/tmp/wt-orphan"
      assert spec.payload.reason == "compensation_failed"
    end

    test "rejects when worktree_path is missing on empty stream" do
      cmd = %{
        type: "vcs.worktree.create.orphan_record",
        payload: %{
          operation_id: "op-orphan-2",
          project_id: "proj-1",
          run_id: "run-1",
          phase_id: "phase-1"
        }
      }

      assert {:error, {:missing_or_invalid, :worktree_path}} =
               VcsOperation.handle_command(default_state(), cmd)
    end

    test "rejects when operation_id is missing" do
      cmd = %{
        type: "vcs.worktree.create.orphan_record",
        payload: %{
          project_id: "proj-1",
          run_id: "run-1",
          phase_id: "phase-1",
          worktree_path: "/tmp/wt"
        }
      }

      assert {:error, {:missing_or_invalid, :operation_id}} =
               VcsOperation.handle_command(default_state(), cmd)
    end

    test "rejects when run_id is missing" do
      cmd = %{
        type: "vcs.worktree.create.orphan_record",
        payload: %{
          operation_id: "op-orphan-3",
          project_id: "proj-1",
          phase_id: "phase-1",
          worktree_path: "/tmp/wt"
        }
      }

      assert {:error, {:missing_or_invalid, :run_id}} =
               VcsOperation.handle_command(default_state(), cmd)
    end

    test "rejects when phase_id is missing" do
      cmd = %{
        type: "vcs.worktree.create.orphan_record",
        payload: %{
          operation_id: "op-orphan-4",
          project_id: "proj-1",
          run_id: "run-1",
          worktree_path: "/tmp/wt"
        }
      }

      assert {:error, {:missing_or_invalid, :phase_id}} =
               VcsOperation.handle_command(default_state(), cmd)
    end

    test "apply_event accepts a bare WorktreeCreateOrphanRecorded typed struct" do
      event = %ForemanServer.Events.WorktreeCreateOrphanRecorded{
        operation_id: "op-orphan-5",
        project_id: "proj-1",
        run_id: "run-1",
        phase_id: "phase-1",
        worktree_path: "/tmp/wt-orphan",
        reason: "compensation_failed"
      }

      state = VcsOperation.apply_event(default_state(), event)
      assert state.exists? == true
      assert state.operation_id == "op-orphan-5"
      assert state.project_id == "proj-1"
      assert state.run_id == "run-1"
      assert state.phase_id == "phase-1"
      assert state.status == "create_orphan_recorded"
      assert state.terminal? == false
      assert state.worktree_path == "/tmp/wt-orphan"
    end
  end

  describe "handle_command/2 — vcs.worktree.create.orphan_resolve" do
    defp orphan_recorded_state do
      %ForemanServer.Aggregates.VcsOperation.State{
        exists?: true,
        operation_id: "op-resolve-1",
        project_id: "proj-1",
        run_id: "run-1",
        phase_id: "phase-1",
        status: "create_orphan_recorded",
        terminal?: false,
        worktree_path: "/tmp/wt-resolve"
      }
    end

    test "emits WorktreeCreateOrphanResolved from an orphan-recorded state" do
      cmd = %{
        type: "vcs.worktree.create.orphan_resolve",
        payload: %{
          operation_id: "op-resolve-1",
          project_id: "proj-1",
          run_id: "run-1",
          phase_id: "phase-1",
          resolution: "recovered_via_clean_retry"
        }
      }

      assert {:ok, spec} = VcsOperation.handle_command(orphan_recorded_state(), cmd)
      assert spec.event_type == "WorktreeCreateOrphanResolved"
      assert spec.stream_id == "vcs:op-resolve-1"
      assert spec.payload.operation_id == "op-resolve-1"
      assert spec.payload.project_id == "proj-1"
      assert spec.payload.run_id == "run-1"
      assert spec.payload.phase_id == "phase-1"
      assert spec.payload.resolution == "recovered_via_clean_retry"
    end

    test "rejects when stream is empty (no orphan recorded yet)" do
      cmd = %{
        type: "vcs.worktree.create.orphan_resolve",
        payload: %{
          operation_id: "op-resolve-fresh",
          project_id: "proj-1",
          run_id: "run-1",
          phase_id: "phase-1"
        }
      }

      assert {:error, {:vcs_operation_not_started, "vcs.worktree.create.orphan_resolve"}} =
               VcsOperation.handle_command(default_state(), cmd)
    end

    test "rejects when status is not create_orphan_recorded" do
      created_state = %ForemanServer.Aggregates.VcsOperation.State{
        exists?: true,
        operation_id: "op-resolve-1",
        project_id: "proj-1",
        run_id: "run-1",
        phase_id: "phase-1",
        status: "created",
        terminal?: false
      }

      cmd = %{
        type: "vcs.worktree.create.orphan_resolve",
        payload: %{
          operation_id: "op-resolve-1",
          project_id: "proj-1",
          run_id: "run-1",
          phase_id: "phase-1"
        }
      }

      assert {:error,
              {:invalid_status_for, "vcs.worktree.create.orphan_resolve", "created"}} =
               VcsOperation.handle_command(created_state, cmd)
    end

    test "rejects on correlation mismatch" do
      cmd = %{
        type: "vcs.worktree.create.orphan_resolve",
        payload: %{
          operation_id: "op-resolve-1",
          project_id: "proj-OTHER",
          run_id: "run-1",
          phase_id: "phase-1"
        }
      }

      assert {:error, :correlation_mismatch} =
               VcsOperation.handle_command(orphan_recorded_state(), cmd)
    end

    test "rejects when operation_id is missing" do
      cmd = %{
        type: "vcs.worktree.create.orphan_resolve",
        payload: %{
          project_id: "proj-1",
          run_id: "run-1",
          phase_id: "phase-1"
        }
      }

      assert {:error, {:missing_or_invalid, :operation_id}} =
               VcsOperation.handle_command(orphan_recorded_state(), cmd)
    end

    test "rejects when run_id is missing" do
      cmd = %{
        type: "vcs.worktree.create.orphan_resolve",
        payload: %{
          operation_id: "op-resolve-2",
          project_id: "proj-1",
          phase_id: "phase-1"
        }
      }

      assert {:error, {:missing_or_invalid, :run_id}} =
               VcsOperation.handle_command(orphan_recorded_state(), cmd)
    end

    test "apply_event accepts a bare WorktreeCreateOrphanResolved typed struct" do
      event = %ForemanServer.Events.WorktreeCreateOrphanResolved{
        operation_id: "op-resolve-3",
        project_id: "proj-1",
        run_id: "run-1",
        phase_id: "phase-1",
        worktree_path: "/tmp/wt-resolve",
        resolution: "recovered_via_clean_retry"
      }

      state = VcsOperation.apply_event(orphan_recorded_state(), event)
      assert state.status == "create_orphan_resolved"
      assert state.terminal? == true
      assert state.worktree_path == "/tmp/wt-resolve"
    end
  end

  describe "handle_command/2 — unhandled" do
    test "returns :unhandled for unknown command types" do
      assert :unhandled =
               VcsOperation.handle_command(default_state(), %{type: "wat", payload: %{}})
    end
  end

  defp wrap(event_type, struct) do
    payload = struct |> Map.from_struct() |> Map.put(:event_type, event_type)
    %{event_type: event_type, payload: payload}
  end
end
