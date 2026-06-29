defmodule ForemanServerTest do
  use ExUnit.Case

  alias ForemanServer.ProjectStore

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "foreman-server-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    project_store_path = Path.join(tmp_dir, "projects.term")
    event_log_path = Path.join(tmp_dir, "events.term.log")

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :project_store_path, project_store_path)
    Application.put_env(:foreman_server, :event_log_path, event_log_path)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :project_store_path)
      Application.delete_env(:foreman_server, :event_log_path)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    {:ok,
     tmp_dir: tmp_dir, project_store_path: project_store_path, event_log_path: event_log_path}
  end

  test "loads configured projects and starts project supervisors", %{
    project_store_path: project_store_path
  } do
    projects = [
      %ForemanServer.Project{id: "alpha", path: "/tmp/alpha"},
      %ForemanServer.Project{id: "beta", path: "/tmp/beta"}
    ]

    Application.put_env(:foreman_server, :project_store_path, project_store_path)
    assert :ok = ProjectStore.save_projects(projects)
    assert :ok = Application.start(:foreman_server)

    assert ForemanServer.active_projects() == ["alpha", "beta"]
    assert %ForemanServer.Project{id: "alpha"} = ForemanServer.ProjectSupervisor.project("alpha")
    assert %ForemanServer.Project{id: "beta"} = ForemanServer.ProjectSupervisor.project("beta")
  end

  test "records validated command outcomes as durable events and projections", %{
    event_log_path: event_log_path
  } do
    assert :ok = Application.start(:foreman_server)

    assert {:ok,
            %{event: %ForemanServer.Event{event_type: "CommandAccepted"}, projection: projection}} =
             ForemanServer.handle_command(%{command_id: "cmd-1", command_type: "task.create"})

    assert projection.commands["cmd-1"].status == "accepted"
    assert File.exists?(event_log_path)

    assert [
             %ForemanServer.Event{
               event_type: "CommandAccepted",
               stream_id: "command:cmd-1",
               stream_version: 1,
               schema_version: 1,
               payload: %{command_id: "cmd-1"}
             }
           ] = ForemanServer.EventStore.all()
  end

  test "rebuilds projection state from durable event log after restart" do
    assert :ok = Application.start(:foreman_server)

    assert {:ok, _result} =
             ForemanServer.handle_command(%{
               command_id: "cmd-restart",
               command_type: "task.approve"
             })

    Application.stop(:foreman_server)
    assert :ok = Application.start(:foreman_server)

    snapshot = ForemanServer.ProjectionStore.snapshot()
    assert snapshot.commands["cmd-restart"].command_type == "task.approve"
    assert snapshot.last_sequence == 1
  end

  test "project registration projects path status default branch config and health" do
    assert :ok = Application.start(:foreman_server)

    assert {:ok,
            %{
              event: %ForemanServer.Event{event_type: "ProjectRegistered"},
              projection: projection
            }} =
             ForemanServer.handle_command(%{
               command_id: "cmd-project",
               command_type: "project.register",
               payload: %{
                 project_id: "alpha",
                 name: "Alpha",
                 path: "/repo/alpha",
                 status: "active",
                 default_branch: "main",
                 github_url: "https://github.com/example/alpha",
                 config: %{max_agents: 3},
                 health: %{ok: true, checks: ["git"]}
               }
             })

    assert projection.projects["alpha"] == %{
             project_id: "alpha",
             name: "Alpha",
             path: "/repo/alpha",
             status: "active",
             default_branch: "main",
             github_url: "https://github.com/example/alpha",
             config: %{max_agents: 3},
             health: %{ok: true, checks: ["git"]},
             updated_at: projection.projects["alpha"].updated_at
           }
  end

  test "project update and archive commands update projection" do
    assert :ok = Application.start(:foreman_server)

    assert {:ok, _} =
             ForemanServer.handle_command(%{
               command_id: "cmd-project-create",
               command_type: "project.register",
               payload: %{project_id: "alpha", name: "Alpha", path: "/repo/alpha"}
             })

    assert {:ok,
            %{
              event: %ForemanServer.Event{event_type: "ProjectUpdated"},
              projection: projection
            }} =
             ForemanServer.handle_command(%{
               command_id: "cmd-project-update",
               command_type: "project.update",
               payload: %{project_id: "alpha", name: "Renamed", default_branch: "dev"}
             })

    assert projection.projects["alpha"].name == "Renamed"
    assert projection.projects["alpha"].default_branch == "dev"

    assert {:ok, %{projection: projection}} =
             ForemanServer.handle_command(%{
               command_id: "cmd-project-archive",
               command_type: "project.archive",
               payload: %{project_id: "alpha"}
             })

    assert projection.projects["alpha"].status == "archived"
  end

  test "run archive and purge commands update projection state" do
    assert :ok = Application.start(:foreman_server)

    assert {:ok,
            %{event: %ForemanServer.Event{event_type: "RunArchived"}, projection: projection}} =
             ForemanServer.handle_command(%{
               command_id: "cmd-run-archive",
               command_type: "run.archive",
               payload: %{run_id: "run-archived", reason: "stale"}
             })

    assert projection.runs["run-archived"].status == "archived"
    assert projection.runs["run-archived"].archive_reason == "stale"

    assert {:ok,
            %{event: %ForemanServer.Event{event_type: "RunPurged"}, projection: projection}} =
             ForemanServer.handle_command(%{
               command_id: "cmd-run-purge",
               command_type: "run.purge",
               payload: %{run_id: "run-archived"}
             })

    refute Map.has_key?(projection.runs, "run-archived")
  end

  test "task lifecycle commands update event and projection state atomically" do
    assert :ok = Application.start(:foreman_server)

    assert {:ok, %{event: %ForemanServer.Event{event_type: "TaskCreated"}}} =
             ForemanServer.handle_command(%{
               command_id: "cmd-task-create",
               command_type: "task.create",
               payload: %{task_id: "task-1", project_id: "alpha", title: "Build server"}
             })

    assert {:ok,
            %{event: %ForemanServer.Event{event_type: "TaskUpdated"}, projection: projection}} =
             ForemanServer.handle_command(%{
               command_id: "cmd-task-approve",
               command_type: "task.approve",
               payload: %{task_id: "task-1"}
             })

    assert projection.tasks["task-1"].status == "ready"

    assert {:ok, %{projection: projection}} =
             ForemanServer.handle_command(%{
               command_id: "cmd-task-note",
               command_type: "task.annotate",
               payload: %{task_id: "task-1", body: "ready for dispatch", author: "test"}
             })

    assert [%{body: "ready for dispatch", author: "test"}] =
             projection.tasks["task-1"].annotations

    assert {:ok, %{projection: projection}} =
             ForemanServer.handle_command(%{
               command_id: "cmd-task-close",
               command_type: "task.close",
               payload: %{task_id: "task-1"}
             })

    assert projection.tasks["task-1"].status == "closed"
  end

  test "dispatchable tasks exclude ready tasks with open blockers" do
    assert :ok = Application.start(:foreman_server)

    assert {:ok, _} =
             ForemanServer.handle_command(%{
               command_id: "cmd-blocker",
               command_type: "task.create",
               payload: %{task_id: "blocker", status: "ready"}
             })

    assert {:ok, _} =
             ForemanServer.handle_command(%{
               command_id: "cmd-dependent",
               command_type: "task.create",
               payload: %{task_id: "dependent", status: "ready", dependencies: ["blocker"]}
             })

    assert Enum.map(ForemanServer.ProjectionStore.dispatchable_tasks(), & &1.task_id) == [
             "blocker"
           ]

    assert {:ok, _} =
             ForemanServer.handle_command(%{
               command_id: "cmd-close-blocker",
               command_type: "task.close",
               payload: %{task_id: "blocker"}
             })

    assert Enum.map(ForemanServer.ProjectionStore.dispatchable_tasks(), & &1.task_id) == [
             "dependent"
           ]
  end

  test "task dependency remove updates projection" do
    assert :ok = Application.start(:foreman_server)

    assert {:ok, _} =
             ForemanServer.handle_command(%{
               command_id: "cmd-blocker",
               command_type: "task.create",
               payload: %{task_id: "blocker", status: "ready"}
             })

    assert {:ok, _} =
             ForemanServer.handle_command(%{
               command_id: "cmd-dependent",
               command_type: "task.create",
               payload: %{task_id: "dependent", status: "ready"}
             })

    assert {:ok, %{projection: projection}} =
             ForemanServer.handle_command(%{
               command_id: "cmd-add-dep",
               command_type: "task.add_dependency",
               payload: %{task_id: "dependent", depends_on: "blocker"}
             })

    assert projection.tasks["dependent"].dependencies == ["blocker"]

    assert {:ok,
            %{
              event: %ForemanServer.Event{event_type: "TaskDependencyRemoved"},
              projection: projection
            }} =
             ForemanServer.handle_command(%{
               command_id: "cmd-remove-dep",
               command_type: "task.remove_dependency",
               payload: %{task_id: "dependent", depends_on: "blocker"}
             })

    assert projection.tasks["dependent"].dependencies == []
  end
end
