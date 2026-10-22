defmodule ForemanServer.Threads.PartialTaskTest do
  # A lifecycle event for a task whose TaskCreated was never projected is dropped
  # by the projection (foreman-03acm) instead of leaving a task-id-less fragment;
  # building threads must keep working alongside it.
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Threads

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  test "an event for an unknown task leaves no partial entry and real threads still build" do
    :ok =
      ProjectionStore.apply_events([
        %{event_type: "TaskExecutionCompleted", payload: %{task_id: "ghost", run_id: "rg"}},
        %{event_type: "RunStarted", payload: %{run_id: "r1", task_id: "t1", project_id: "p"}}
      ])

    assert Enum.all?(ProjectionStore.thread_inputs().tasks, &is_map_key(&1, :task_id))
    refute Enum.any?(ProjectionStore.thread_inputs().tasks, &(&1[:task_id] == "ghost"))
    assert [%{id: "run:r1"}] = Threads.list("p")
  end
end
