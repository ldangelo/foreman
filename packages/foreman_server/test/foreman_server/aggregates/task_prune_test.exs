defmodule ForemanServer.Aggregates.TaskPruneTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Task
  alias ForemanServer.Aggregates.Task.State

  # Minimal command structs for the 5 pruned commands — mirrors the pattern
  # used by other Commands modules in the codebase (e.g. CreateTask, CloseTask).
  # Must be structs so cmd.__struct__ returns a useful value in the catch-all.

  defmodule TaskBlock do
    defstruct [:task_id]
  end

  defmodule TaskClose do
    defstruct [:task_id]
  end

  defmodule TaskUpdate do
    defstruct [:task_id, :status]
  end

  defmodule TaskAnnotate do
    defstruct [:task_id, :body, :author]
  end

  defmodule TaskAddDependency do
    defstruct [:task_id, :depends_on]
  end

  defmodule UnknownCommand do
    defstruct [:type, :payload]
  end

  describe "handle_command/2 — pruned commands return unsupported_command error" do
    test "task.block is unsupported" do
      state = Task.initial_state()
      cmd = %TaskBlock{task_id: "t-1"}

      assert {:error, {:unsupported_command, ForemanServer.Aggregates.TaskPruneTest.TaskBlock}} =
               Task.handle_command(state, cmd)
    end

    test "task.close is unsupported" do
      state = Task.initial_state()
      cmd = %TaskClose{task_id: "t-1"}

      assert {:error, {:unsupported_command, ForemanServer.Aggregates.TaskPruneTest.TaskClose}} =
               Task.handle_command(state, cmd)
    end

    test "task.update is unsupported" do
      state = Task.initial_state()
      cmd = %TaskUpdate{task_id: "t-1", status: "ready"}

      assert {:error, {:unsupported_command, ForemanServer.Aggregates.TaskPruneTest.TaskUpdate}} =
               Task.handle_command(state, cmd)
    end

    test "task.annotate is unsupported" do
      state = Task.initial_state()
      cmd = %TaskAnnotate{task_id: "t-1", body: "fix something", author: "alice"}

      assert {:error, {:unsupported_command, ForemanServer.Aggregates.TaskPruneTest.TaskAnnotate}} =
               Task.handle_command(state, cmd)
    end

    test "task.add_dependency is unsupported" do
      state = Task.initial_state()
      cmd = %TaskAddDependency{task_id: "t-1", depends_on: "t-0"}

      assert {:error,
              {:unsupported_command, ForemanServer.Aggregates.TaskPruneTest.TaskAddDependency}} =
               Task.handle_command(state, cmd)
    end
  end

  describe "handle_command/2 — supported commands still work" do
    test "task.create still works" do
      state = Task.initial_state()

      assert {:ok, event_spec} =
               Task.handle_command(state, %{
                 type: "task.create",
                 payload: %{task_id: "t-1", project_id: "p-1"}
               })

      assert event_spec.event_type == "TaskCreated"
      assert event_spec.stream_id == "task:t-1"
    end

    test "task.approve still works" do
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
                   approved_by: "alice",
                   approval_id: "a-1",
                   run_id: "r-1",
                   approved_at: "2024-01-01T00:00:00Z",
                   workflow_snapshot: %{"phase" => "approve"}
                 }
               })

      assert event_spec.event_type == "TaskApproved"
    end

    test "task.dispatch still works" do
      state = %State{
        Task.initial_state()
        | exists?: true,
          task_id: "t-1",
          status: "ready",
          run_id: "r-1",
          approval_id: "a-1"
      }

      assert {:ok, event_spec} =
               Task.handle_command(state, %{
                 type: "task.dispatch",
                 payload: %{task_id: "t-1"}
               })

      assert event_spec.event_type == "TaskDispatched"
    end

    test "unknown command returns unsupported_command error" do
      # Must use a %State{} struct (not a plain map) because the catch-all
      # requires %State{} as the first argument.
      state = Task.initial_state()
      unknown_cmd = %UnknownCommand{type: "x", payload: %{}}

      assert {:error, {:unsupported_command, ForemanServer.Aggregates.TaskPruneTest.UnknownCommand}} =
               Task.handle_command(state, unknown_cmd)
    end
  end
end
