defmodule ForemanServerWeb.RecommendationsControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.MCP.Tools
  alias ForemanServer.ProjectionStore

  @endpoint ForemanServerWeb.Endpoint
  @token "recommendations-controller-token"
  @moduletag :tmp_dir

  defmodule NoGh do
    @behaviour ForemanServer.Projects.Recommendations.Facts.Probe
    alias ForemanServer.Projects.Recommendations.Facts.Probe
    defdelegate exists?(p), to: Probe.System
    defdelegate glob(p), to: Probe.System
    defdelegate read_head(p, n), to: Probe.System
    def find_executable(_), do: nil
    def cmd(_e, _a, _t), do: {:error, :failed}
    def call(fun, t) when is_function(fun), do: Probe.System.call(fun, t)
  end

  defmodule Slow do
    @behaviour ForemanServer.Projects.Recommendations.Facts.Probe
    alias ForemanServer.Projects.Recommendations.Facts.Probe
    defdelegate exists?(p), to: Probe.System
    defdelegate glob(p), to: Probe.System
    defdelegate read_head(p, n), to: Probe.System

    def find_executable(_),
      do:
        (
          Process.sleep(:infinity)
          nil
        )

    def cmd(_e, _a, _t), do: {:error, :failed}
    def call(fun, t), do: Probe.System.call(fun, t)
  end

  setup %{tmp_dir: repo} do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)
    Application.put_env(:foreman_server, :recommendations, probe: NoGh, probe_timeout_ms: 500)

    on_exit(fn ->
      Application.delete_env(:foreman_server, :recommendations)

      if previous == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous)
    end)

    id = "rec-http-#{System.unique_integer([:positive])}"

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectRegistered", payload: %{project_id: id, path: repo}}
      ])

    %{id: id}
  end

  defp get_json(path, status) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> @token)
    |> get(path)
    |> json_response(status)
  end

  test "200 with the whitelisted shape; the empty repo gets setup advice", %{id: id} do
    body = get_json("/api/projects/#{id}/recommendations", 200)
    assert Map.keys(body) |> Enum.sort() == ["generated_at", "project_id", "recommendations"]
    assert body["project_id"] == id

    by_id = Map.new(body["recommendations"], &{&1["id"], &1})

    assert %{"severity" => "warn", "fix" => %{"kind" => "manual"}} =
             by_id["repo.agents_md_missing"]

    for rec <- body["recommendations"] do
      assert Map.keys(rec) |> Enum.sort() ==
               ["detail", "evidence", "fix", "id", "severity", "title"]
    end
  end

  test "404 for an unknown project" do
    assert %{"error" => "project_not_found"} = get_json("/api/projects/nope/recommendations", 404)
  end

  test "the MCP tool returns the same payload (read-only, not a write tool)", %{id: id} do
    http = get_json("/api/projects/#{id}/recommendations", 200)
    assert {:ok, mcp} = Tools.call_tool("foreman_project_recommendations", %{project_id: id})
    mcp = mcp |> Jason.encode!() |> Jason.decode!()
    assert Map.delete(http, "generated_at") == Map.delete(mcp, "generated_at")
    previous = Application.get_env(:foreman_server, :mcp, [])

    Application.put_env(
      :foreman_server,
      :mcp,
      Keyword.put(previous, :allow_workflow_writes, false)
    )

    on_exit(fn -> Application.put_env(:foreman_server, :mcp, previous) end)
    assert ForemanServer.MCP.Policy.authorized?("foreman_project_recommendations")
    refute ForemanServer.MCP.Policy.authorized?("foreman_project_pause")
  end

  test "504 when the whole collection exceeds its budget", %{id: id} do
    Application.put_env(:foreman_server, :recommendations,
      probe: Slow,
      probe_timeout_ms: 50,
      total_timeout_ms: 100
    )

    assert %{"error" => "recommendations_timeout"} =
             get_json("/api/projects/#{id}/recommendations", 504)
  end

  test "GET never mutates: no event is appended", %{id: id} do
    before = ProjectionStore.project(id)
    get_json("/api/projects/#{id}/recommendations", 200)
    assert ProjectionStore.project(id) == before
  end
end
