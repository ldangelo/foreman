defmodule ForemanServer.CommandRouterTest do
  use ExUnit.Case

  alias ForemanServer.{CommandRouter, EventStore, ProjectionStore}

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "foreman-command-router-test-#{System.unique_integer([:positive])}")
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
    assert {:ok, _} = EventStore.append(%{
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
end
