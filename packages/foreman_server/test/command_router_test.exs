defmodule ForemanServer.CommandRouterTest do
  use ExUnit.Case

  alias ForemanServer.{CommandRouter, EventStore, ProjectionStore}

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-command-router-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    assert :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    :ok
  end

  test "task.update rejects phase names as task statuses" do
    assert {:ok, _} =
             EventStore.append(%{
               stream_id: "task:task-1",
               event_type: "TaskCreated",
               payload: %{task_id: "task-1", title: "Task", status: "in_progress"},
               metadata: %{idempotency_key: "task-1:create"}
             })

    assert {:error, {:invalid_task_status, "documentation"}} =
             CommandRouter.handle(%{
               command_id: "cmd-task-phase-status",
               command_type: "task.update",
               payload: %{task_id: "task-1", status: "documentation"}
             })

    assert ProjectionStore.task("task-1").status == "in_progress"
  end

  test "run retry and reset requeue the selected run task without mutating terminal run" do
    assert {:ok, _} =
             EventStore.append(%{
               stream_id: "task:task-requeue",
               event_type: "TaskCreated",
               payload: %{task_id: "task-requeue", title: "Task", status: "failed"},
               metadata: %{idempotency_key: "task-requeue:create"}
             })

    assert {:ok, _} =
             EventStore.append(%{
               stream_id: "run:run-requeue",
               event_type: "RunStarted",
               payload: %{run_id: "run-requeue", task_id: "task-requeue"},
               metadata: %{idempotency_key: "run-requeue:start"}
             })

    assert {:ok, _} =
             EventStore.append(%{
               stream_id: "run:run-requeue",
               event_type: "RunFailed",
               payload: %{run_id: "run-requeue", task_id: "task-requeue", reason: "failed"},
               metadata: %{idempotency_key: "run-requeue:failed"}
             })

    assert {:ok, _} =
             CommandRouter.handle(%{
               command_id: "cmd-run-retry",
               command_type: "run.retry",
               payload: %{
                 run_id: "run-requeue",
                 task_id: "task-requeue",
                 reason: "operator retry"
               }
             })

    assert ProjectionStore.task("task-requeue").status == "ready"
    assert ProjectionStore.task("task-requeue").reason == "operator retry"
    assert ProjectionStore.snapshot().runs["run-requeue"].status == "failed"

    assert {:ok, _} =
             CommandRouter.handle(%{
               command_id: "cmd-run-reset",
               command_type: "run.reset",
               payload: %{run_id: "run-requeue", task_id: "task-requeue"}
             })

    assert ProjectionStore.task("task-requeue").status == "ready"
    assert ProjectionStore.task("task-requeue").reason == "reset requested"
  end

  test "run retry requires both selected run and task to exist" do
    assert {:error, {:not_found, :run, "missing-run"}} =
             CommandRouter.handle(%{
               command_id: "cmd-run-retry-missing-run",
               command_type: "run.retry",
               payload: %{run_id: "missing-run", task_id: "missing-task"}
             })

    assert {:ok, _} =
             EventStore.append(%{
               stream_id: "run:run-no-task",
               event_type: "RunStarted",
               payload: %{run_id: "run-no-task", task_id: "missing-task"},
               metadata: %{idempotency_key: "run-no-task:start"}
             })

    assert {:error, {:not_found, :task, "missing-task"}} =
             CommandRouter.handle(%{
               command_id: "cmd-run-retry-missing-task",
               command_type: "run.retry",
               payload: %{run_id: "run-no-task", task_id: "missing-task"}
             })
  end
end
