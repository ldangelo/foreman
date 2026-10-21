defmodule ForemanServerWeb.ProjectAttentionTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "project-attention-test-token"

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

    reg = fn id ->
      %{
        event_type: "ProjectRegistered",
        payload: %{project_id: id, path: "/tmp/" <> id, task_provider: %{type: "beads"}}
      }
    end

    :ok =
      ProjectionStore.apply_events([
        reg.("failing"),
        reg.("working"),
        reg.("archived"),
        %{event_type: "ProjectArchived", payload: %{project_id: "archived"}},
        %{
          event_type: "RunStarted",
          payload: %{run_id: "r1", task_id: "t1", project_id: "failing"}
        },
        %{event_type: "RunFailed", payload: %{run_id: "r1", project_id: "failing", reason: "x"}},
        %{
          event_type: "RunStarted",
          payload: %{run_id: "r2", task_id: "t2", project_id: "working"}
        },
        %{
          event_type: "RunStarted",
          payload: %{run_id: "r3", task_id: "t3", project_id: "archived"}
        },
        %{event_type: "RunFailed", payload: %{run_id: "r3", project_id: "archived", reason: "x"}}
      ])

    :ok
  end

  defp api_get(path) do
    build_conn() |> put_req_header("authorization", "Bearer #{@token}") |> get(path)
  end

  test "list carries attention per project, archived projects never need attention" do
    %{"projects" => projects} = json_response(api_get("/api/projects?include_archived=true"), 200)
    by_id = Map.new(projects, &{&1["project_id"], &1})

    assert by_id["failing"]["attention"] == %{
             "needed" => true,
             "count" => 1,
             "reasons" => ["failed"]
           }

    assert by_id["failing"]["attention_count"] == 1
    assert by_id["working"]["attention"]["needed"] == false
    assert by_id["working"]["attention_count"] == 0
    assert by_id["archived"]["attention"]["needed"] == false

    # existing keys are untouched
    assert by_id["failing"]["path"] == "/tmp/failing"
  end

  test "show carries the same attention fields" do
    %{"project" => project} = json_response(api_get("/api/projects/failing"), 200)
    assert project["attention_count"] == 1
    assert project["attention"]["needed"] == true
    assert project["project_id"] == "failing"
  end
end
