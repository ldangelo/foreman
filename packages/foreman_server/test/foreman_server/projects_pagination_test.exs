defmodule ForemanServer.ProjectsPaginationTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.ProjectStore

  @endpoint ForemanServerWeb.Endpoint
  @token "projects-pagination-test-token"

  setup do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)

    reset_projection_store()

    on_exit(fn ->
      reset_projection_store()

      if previous == nil do
        Application.delete_env(:foreman_server, :api_bearer_token)
      else
        Application.put_env(:foreman_server, :api_bearer_token, previous)
      end

      Application.delete_env(:foreman_server, :projects_list_max)
    end)

    :ok
  end

  test "GET /api/projects?limit=3 returns exactly 3 items when 10 projects exist" do
    seed_projects(10)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{@token}")
      |> get("/api/projects?limit=3")

    body = json_response(conn, 200)

    assert length(body["projects"]) == 3
    assert body["meta"] == %{"truncated" => true}
    assert get_resp_header(conn, "x-total-count") == ["10"]
  end

  test "GET /api/projects caps caller limit at the configured max" do
    Application.put_env(:foreman_server, :projects_list_max, 4)
    seed_projects(10)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{@token}")
      |> get("/api/projects?limit=12")

    body = json_response(conn, 200)

    assert length(body["projects"]) == 4
    assert body["meta"] == %{"truncated" => true}
    assert get_resp_header(conn, "x-total-count") == ["10"]
  end

  defp seed_projects(count) do
    Enum.each(1..count, fn index ->
      project_id = unique_project_id(index)

      assert {:ok, _} =
               ProjectStore.save(%{
                 project_id: project_id,
                 path: "/tmp/#{project_id}",
                 task_provider: %{provider: :beads}
               })
    end)
  end

  defp reset_projection_store do
    :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
      %{state | projects: %{}, runs: %{}, project_active_runs: %{}}
    end)
  end

  defp unique_project_id(index) do
    "project-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}-#{index}"
  end
end
