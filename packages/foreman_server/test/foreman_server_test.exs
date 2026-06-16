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

    assert {:ok, %{event: %{type: "CommandAccepted"}, projection: projection}} =
             ForemanServer.handle_command(%{command_id: "cmd-1", command_type: "task.create"})

    assert projection.commands["cmd-1"].status == "accepted"
    assert File.exists?(event_log_path)

    assert [%{type: "CommandAccepted", payload: %{command_id: "cmd-1"}}] =
             ForemanServer.EventStore.all()
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
end
