defmodule ForemanServer.Threads.PartialTaskTest do
  # A lifecycle event for a task whose TaskCreated was never projected leaves a
  # task-id-less fragment in the projection; building threads must not crash on it.
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Threads

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  test "a partial task entry is skipped and real threads still build" do
    :ok =
      ProjectionStore.apply_events([
        %{event_type: "TaskExecutionCompleted", payload: %{task_id: "ghost", run_id: "rg"}},
        %{event_type: "RunStarted", payload: %{run_id: "r1", task_id: "t1", project_id: "p"}}
      ])

    assert Enum.any?(ProjectionStore.thread_inputs().tasks, &(not is_map_key(&1, :task_id)))
    assert [%{id: "run:r1"}] = Threads.list("p")
  end
end
