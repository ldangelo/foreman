defmodule ForemanServerWeb.ProjectSettingsControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.{CommandGateway, ProjectStore}
  alias ForemanServer.MCP.Tools
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "project-settings-controller-token"

  setup do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)
    ProjectionStoreReset.reset!()

    on_exit(fn ->
      ProjectionStoreReset.reset!()

      if previous == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous)
    end)

    id = "settings-http-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             ProjectStore.save(%{
               project_id: id,
               path: "/tmp/#{id}",
               name: "Settings Demo",
               config: %{
                 "env" => %{"API_TOKEN" => "s3cr3t-value"},
                 "database_path" => "/tmp/x.db"
               }
             })

    assert {:ok, _} =
             CommandGateway.dispatch_operator(%{
               command_id: "upd-#{id}",
               aggregate_id: "project:#{id}",
               type: "project.update",
               payload: %{
                 project_id: id,
                 goal: "Ship v2",
                 instructions: "Be terse",
                 thread_model: "opus",
                 daily_thread_cap: 5
               }
             })

    {:ok, id: id}
  end

  defp get_json(path, status) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> get(path)
    |> json_response(status)
  end

  test "GET /api/projects/:id/settings returns typed settings, status and limits", %{id: id} do
    body = get_json("/api/projects/#{id}/settings", 200)

    assert %{
             "project_id" => ^id,
             "status" => "active",
             "settings" => %{
               "goal" => "Ship v2",
               "instructions" => "Be terse",
               "thread_model" => "opus",
               "thread_effort" => nil,
               "coordinator_model" => nil,
               "max_concurrent_runs" => nil,
               "daily_thread_cap" => 5
             },
             "limits" => %{
               "daily_thread_cap" => 5,
               "threads_started_today" => 0,
               "remaining_today" => 5,
               "cap_reached?" => false,
               "deferred_tasks" => 0
             }
           } = body

    refute inspect(body) =~ "s3cr3t"
  end

  test "the HTTP payload equals the MCP read tool's payload", %{id: id} do
    http = get_json("/api/projects/#{id}/settings", 200)
    assert {:ok, mcp} = Tools.call_tool("foreman_project_settings_get", %{project_id: id})
    assert http == mcp |> Jason.encode!() |> Jason.decode!()
  end

  test "unknown project is 404 with the same body as the project read" do
    assert get_json("/api/projects/nope/settings", 404) == get_json("/api/projects/nope", 404)
  end

  test "project reads redact env values but keep keys, name and database_path", %{id: id} do
    %{"project" => project} = get_json("/api/projects/#{id}", 200)
    assert project["config"]["env"] == %{"API_TOKEN" => "[redacted]"}
    assert project["config"]["database_path"] == "/tmp/x.db"
    assert project["name"] == "Settings Demo"

    %{"projects" => projects} = get_json("/api/projects", 200)
    listed = Enum.find(projects, &(&1["project_id"] == id))
    assert listed["config"]["env"] == %{"API_TOKEN" => "[redacted]"}
    refute inspect(projects) =~ "s3cr3t"
  end

  test "the redaction is a read-side view only: the launch env is untouched", %{id: id} do
    assert %{"API_TOKEN" => "s3cr3t-value"} = ForemanServer.WorkerEnvironment.build_env_map(id)
  end
end
