defmodule ForemanServer.ProjectionStoreTest do
  use ExUnit.Case

  alias ForemanServer.{EventStore, ProjectionStore}

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-projection-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    assert :ok = Application.start(:foreman_server)
    :ok
  end

  test "task projections render task show/list state from events" do
    append!("task:task-1", "TaskCreated", %{
      task_id: "task-1",
      title: "Implement server",
      status: "open"
    })

    append!("task:task-1", "TaskUpdated", %{task_id: "task-1", status: "in_progress"})

    append!("task:task-2", "TaskCreated", %{
      task_id: "task-2",
      title: "Verify server",
      status: "open"
    })

    assert ProjectionStore.task("task-1") == %{
             task_id: "task-1",
             title: "Implement server",
             status: "in_progress",
             updated_at: nil,
             failure_reason: nil,
             failure_output: nil
           }

    assert Enum.map(ProjectionStore.task_list(), & &1.task_id) == ["task-1", "task-2"]
  end

  test "active task updates clear stale failure metadata" do
    append!("task:task-1", "TaskCreated", %{
      task_id: "task-1",
      title: "Implement server",
      status: "failed"
    })

    append!("task:task-1", "TaskUpdated", %{
      task_id: "task-1",
      status: "failed",
      failure_reason: "worker_failed",
      failure_output: "boom"
    })

    append!("task:task-1", "TaskUpdated", %{task_id: "task-1", status: "ready"})

    assert ProjectionStore.task("task-1").status == "ready"
    assert ProjectionStore.task("task-1").failure_reason == nil
    assert ProjectionStore.task("task-1").failure_output == nil
  end

  test "terminal run events update the associated active task" do
    append!("task:task-1", "TaskCreated", %{
      task_id: "task-1",
      title: "Implement server",
      status: "open"
    })

    append!("task:task-1", "TaskUpdated", %{
      task_id: "task-1",
      status: "in_progress",
      run_id: "run-1",
      failure_reason: "old",
      failure_output: "old output"
    })

    append!("run:run-1", "RunStarted", %{run_id: "run-1", task_id: "task-1"})
    append!("run:run-1", "RunCompleted", %{run_id: "run-1"})

    task = ProjectionStore.task("task-1")
    assert task.status == "completed"
    assert task.run_id == "run-1"
    assert task.failure_reason == nil
    assert task.failure_output == nil
  end

  test "terminal run events do not overwrite tasks moved to a newer run" do
    append!("task:task-1", "TaskCreated", %{
      task_id: "task-1",
      title: "Implement server",
      status: "open"
    })

    append!("task:task-1", "TaskUpdated", %{
      task_id: "task-1",
      status: "in_progress",
      run_id: "run-2"
    })

    append!("run:run-1", "RunStarted", %{run_id: "run-1", task_id: "task-1"})
    append!("run:run-1", "RunCompleted", %{run_id: "run-1"})

    task = ProjectionStore.task("task-1")
    assert task.status == "in_progress"
    assert task.run_id == "run-2"
  end

  test "run projection exposes status counts without log inference" do
    append!("run:active", "RunStarted", %{run_id: "active", task_id: "task-1"})
    append!("run:active", "PhaseStarted", %{run_id: "active", phase_id: "developer"})

    append!("run:active", "WorkerStatusChanged", %{
      run_id: "active",
      worker_id: "worker-1",
      status: "running"
    })

    append!("run:done", "RunStarted", %{run_id: "done", task_id: "task-2"})
    append!("run:done", "RunCompleted", %{run_id: "done"})

    append!("run:failed", "RunStarted", %{run_id: "failed", task_id: "task-3"})
    append!("run:failed", "RunFailed", %{run_id: "failed"})

    assert ProjectionStore.status_counts() == %{
             active: 1,
             in_progress: 1,
             failed: 1,
             blocked: 0,
             completed: 1
           }

    snapshot = ProjectionStore.snapshot()
    assert snapshot.runs["active"].phase_status["developer"] == "in_progress"
    assert snapshot.runs["active"].worker_status["worker-1"] == "running"
  end

  test "projection rebuild drops corrupted state and replays from events" do
    append!("task:task-1", "TaskCreated", %{
      task_id: "task-1",
      title: "From events",
      status: "open"
    })

    append!("run:blocked", "RunStarted", %{run_id: "blocked", task_id: "task-1"})
    append!("run:blocked", "RunBlocked", %{run_id: "blocked"})

    assert {:ok, corrupted} = ProjectionStore.rebuild([])
    assert corrupted.tasks == %{}
    assert corrupted.status_counts.blocked == 0

    assert {:ok, rebuilt} = EventStore.rebuild_projections()
    assert rebuilt.tasks["task-1"].title == "From events"
    assert rebuilt.status_counts.blocked == 1
    assert ProjectionStore.snapshot().tasks["task-1"].title == "From events"
  end

  defp append!(stream_id, event_type, payload) do
    {:ok, event} =
      EventStore.append(%{
        stream_id: stream_id,
        event_type: event_type,
        payload: payload,
        metadata: %{}
      })

    event
  end
end
