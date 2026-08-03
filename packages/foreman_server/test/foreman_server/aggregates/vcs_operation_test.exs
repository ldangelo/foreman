defmodule ForemanServer.Aggregates.VcsOperationTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.VcsOperation
  alias ForemanServer.Aggregates.VcsOperation.State

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
    test "emits WorktreeCreated event" do
      cmd = %{type: "vcs.worktree.create", payload: %{operation_id: "op-1"}}

      assert {:ok, spec} = VcsOperation.handle_command(default_state(), cmd)
      assert spec.event_type == "WorktreeCreated"
      assert spec.stream_id == "vcs:op-1"
      assert spec.payload.operation_id == "op-1"
    end

    test "rejects when operation_id is missing" do
      cmd = %{type: "vcs.worktree.create", payload: %{}}

      assert {:error, {:missing_or_invalid, :operation_id}} =
               VcsOperation.handle_command(default_state(), cmd)
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
