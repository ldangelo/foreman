defmodule ForemanServer.Aggregates.TaskPruneTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Task

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
  end

  describe "apply_event/2 — historical pruned-event streams replay correctly (read path survives)" do
    # Task.apply_event uses Aggregate.event_payload/1 and Aggregate.event_type/1 to
    # extract from events. It receives either:
    #   - %RecordedEvent{data: payload}  (from stream replay)
    #   - %{type: "EventName", payload: %{...}}  (from handle_command output after append)
    # Both give event_payload = the data map and event_type = "EventName".
    # Raw structs do NOT work here — Task's apply_event has no direct struct-pattern
    # clauses (unlike RunSlots which has both patterns).

    test "TaskUpdated events replay to correct state" do
      state0 = Task.initial_state()

      created = %{
        type: "TaskCreated",
        payload: %{
          task_id: "t-1",
          project_id: "p-1",
          title: "Original",
          description: "Desc",
          status: "open",
          task_type: "default"
        }
      }

      updated = %{
        type: "TaskUpdated",
        payload: %{task_id: "t-1", status: "blocked", title: "Updated title", priority: "high"}
      }

      state1 = Task.apply_event(state0, created)
      state2 = Task.apply_event(state1, updated)

      assert state2.exists? == true
      assert state2.task_id == "t-1"
      assert state2.status == "blocked"
      assert state2.title == "Updated title"
      assert state2.priority == "high"
    end

    test "TaskAnnotated events replay and accumulate annotations" do
      state0 = Task.initial_state()

      created = %{
        type: "TaskCreated",
        payload: %{
          task_id: "t-1",
          project_id: "p-1",
          status: "open",
          task_type: "default",
          title: "T"
        }
      }

      ann1 = %{
        type: "TaskAnnotated",
        payload: %{task_id: "t-1", body: "First note", author: "alice"}
      }

      ann2 = %{
        type: "TaskAnnotated",
        payload: %{task_id: "t-1", body: "Second note", author: "bob"}
      }

      state1 = Task.apply_event(state0, created)
      state2 = Task.apply_event(state1, ann1)
      state3 = Task.apply_event(state2, ann2)

      assert length(state3.annotations) == 2
      assert hd(state3.annotations).body == "First note"
      assert hd(tl(state3.annotations)).body == "Second note"
    end

    test "TaskDependencyAdded events replay and accumulate dependencies" do
      state0 = Task.initial_state()

      created = %{
        type: "TaskCreated",
        payload: %{
          task_id: "t-1",
          project_id: "p-1",
          status: "open",
          task_type: "default",
          title: "T"
        }
      }

      dep1 = %{type: "TaskDependencyAdded", payload: %{task_id: "t-1", depends_on: "t-0"}}
      dep2 = %{type: "TaskDependencyAdded", payload: %{task_id: "t-1", depends_on: "t-2"}}

      state1 = Task.apply_event(state0, created)
      state2 = Task.apply_event(state1, dep1)
      state3 = Task.apply_event(state2, dep2)

      assert state3.dependencies == ["t-0", "t-2"]
    end

    test "mixed historical stream replays to correct final state (full integration)" do
      state0 = Task.initial_state()

      created = %{
        type: "TaskCreated",
        payload: %{
          task_id: "t-1",
          project_id: "p-1",
          title: "My Task",
          priority: "low",
          status: "open",
          task_type: "default"
        }
      }

      updated = %{
        type: "TaskUpdated",
        payload: %{task_id: "t-1", status: "open", priority: "high"}
      }

      ann = %{
        type: "TaskAnnotated",
        payload: %{task_id: "t-1", body: "Look at this", author: "carol"}
      }

      dep = %{type: "TaskDependencyAdded", payload: %{task_id: "t-1", depends_on: "t-preexist"}}

      final =
        state0
        |> Task.apply_event(created)
        |> Task.apply_event(updated)
        |> Task.apply_event(ann)
        |> Task.apply_event(dep)

      assert final.exists? == true
      assert final.task_id == "t-1"
      assert final.status == "open"
      assert final.title == "My Task"
      assert final.priority == "high"
      assert length(final.annotations) == 1
      assert hd(final.annotations).body == "Look at this"
      assert final.dependencies == ["t-preexist"]
    end
  end
end
