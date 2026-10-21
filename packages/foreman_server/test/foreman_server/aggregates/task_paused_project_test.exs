defmodule ForemanServer.Aggregates.TaskPausedProjectTest do
  # `task.create` is refused while the project is paused. Non-terminal: the
  # BeadsWatcher holds the bead line, and creation works again after resume.
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.Task
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectRegistered", payload: %{project_id: "pz-1", path: "/tmp/pz-1"}}
      ])
  end

  defp create_in(project_id) do
    Task.handle_command(Task.initial_state(), %{
      type: "task.create",
      payload: %{task_id: "t-pz", project_id: project_id}
    })
  end

  test "refused while paused and accepted after resume" do
    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectPaused", payload: %{project_id: "pz-1"}}
      ])

    assert {:error, {:project_paused, "pz-1"}} = create_in("pz-1")

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectResumed", payload: %{project_id: "pz-1"}}
      ])

    assert {:ok, %{event_type: "TaskCreated"}} = create_in("pz-1")
  end

  test "archived stays distinct from paused" do
    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectArchived", payload: %{project_id: "pz-1"}}
      ])

    assert {:error, {:project_archived, "pz-1"}} = create_in("pz-1")
  end
end
