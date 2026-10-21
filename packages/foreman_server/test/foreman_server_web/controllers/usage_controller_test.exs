defmodule ForemanServerWeb.UsageControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.{CommandGateway, ProjectionStore, ProjectStore}
  alias ForemanServer.MCP.Tools
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "usage-controller-token"

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

    id = "usage-http-#{System.unique_integer([:positive])}"
    assert {:ok, _} = ProjectStore.save(%{project_id: id, path: "/tmp/#{id}", name: "Usage"})

    assert {:ok, _} =
             CommandGateway.dispatch_operator(%{
               command_id: "cap-#{id}",
               aggregate_id: "project:#{id}",
               type: "project.update",
               payload: %{project_id: id, daily_thread_cap: 10}
             })

    {:ok, id: id}
  end

  defp usage_event(id, run, worker, extra) do
    %{
      event_type: "UsageRecorded",
      payload:
        Map.merge(
          %{
            run_id: run,
            worker_id: worker,
            provider: "claude",
            project_id: id,
            model: "m1",
            input_tokens: 10,
            output_tokens: 5,
            total_tokens: 15,
            cost_usd: 0.01,
            at: "2026-01-01T10:00:00Z"
          },
          extra
        )
    }
  end

  defp seed(id) do
    :ok =
      ProjectionStore.apply_events([
        usage_event(id, "run-1", "w1", %{}),
        usage_event(id, "run-1", "w2", %{at: "2026-01-02T10:00:00Z", model: "m2"}),
        usage_event(id, "run-2", "w1", %{cost_usd: nil, total_tokens: 100, model: "m2"}),
        usage_event(id, "run-3", "w1", %{cost_usd: nil, total_tokens: 1, input_tokens: 1})
      ])
  end

  defp get_json(path, status) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> get(path)
    |> json_response(status)
  end

  test "default response has every breakdown, consistent totals and the limits block", %{id: id} do
    seed(id)
    body = get_json("/api/projects/#{id}/usage", 200)

    assert %{"project_id" => ^id, "from" => nil, "to" => nil, "group_by" => nil} = body

    assert Enum.all?(
             ~w(totals by_day by_thread by_model by_provider by_role limits cache_hints),
             &Map.has_key?(body, &1)
           )

    assert body["totals"]["events"] == 4
    assert body["totals"]["total_tokens"] == 131
    assert Enum.sum(Enum.map(body["by_day"], & &1["events"])) == 4

    assert %{"daily_thread_cap" => 10, "remaining_today" => 10, "threads_started_today" => 0} =
             body["limits"]

    assert body["limits"] ==
             ProjectionStore.project_limits(id)
             |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
             |> Map.put("resets_at", body["limits"]["resets_at"])
  end

  test "from/to narrow by whole UTC day and group_by returns only that breakdown", %{id: id} do
    seed(id)
    body = get_json("/api/projects/#{id}/usage?from=2026-01-02&to=2026-01-02&group_by=model", 200)

    assert body["totals"]["events"] == 1
    assert [%{"model" => "m2", "events" => 1}] = body["by_model"]
    refute Map.has_key?(body, "by_day")
    refute Map.has_key?(body, "by_thread")
  end

  test "a bucket with only unknown costs reports null cost, not 0", %{id: id} do
    seed(id)
    body = get_json("/api/projects/#{id}/usage?group_by=thread", 200)
    run2 = Enum.find(body["by_thread"], &(&1["thread_id"] == "run-2"))

    assert run2["cost_usd"] == nil
    assert run2["cost_unknown_events"] == 1
    assert body["totals"]["cost_unknown_events"] == 2
    assert_in_delta body["totals"]["cost_usd"], 0.02, 1.0e-9
  end

  test "limit keeps the highest cost thread, unknown cost last, ties stable", %{id: id} do
    seed(id)
    body = get_json("/api/projects/#{id}/usage?group_by=thread&limit=1", 200)
    assert [%{"thread_id" => "run-1"}] = body["by_thread"]
    assert body["thread_count"] == 3

    all = get_json("/api/projects/#{id}/usage?group_by=thread", 200)
    assert Enum.map(all["by_thread"], & &1["thread_id"]) == ["run-1", "run-2", "run-3"]
  end

  test "invalid params are 422 with distinct codes", %{id: id} do
    base = "/api/projects/#{id}/usage"
    assert %{"error" => "invalid_range"} = get_json(base <> "?from=2026-01-05&to=2026-01-01", 422)
    assert %{"error" => "invalid_range"} = get_json(base <> "?from=yesterday", 422)

    assert %{"error" => "range_too_large"} =
             get_json(base <> "?from=2024-01-01&to=2026-01-01", 422)

    assert %{"error" => "invalid_group_by"} = get_json(base <> "?group_by=planet", 422)
    assert %{"error" => "invalid_limit"} = get_json(base <> "?limit=abc", 422)
    assert %{"error" => "invalid_limit"} = get_json(base <> "?limit=501", 422)
  end

  test "unknown project is 404 with the project-show body" do
    assert get_json("/api/projects/nope/usage", 404) == get_json("/api/projects/nope", 404)
  end

  test "the HTTP payload equals the MCP read tool's payload", %{id: id} do
    seed(id)
    http = get_json("/api/projects/#{id}/usage?group_by=model&from=2026-01-01", 200)

    assert {:ok, mcp} =
             Tools.call_tool("foreman_usage_get", %{
               project_id: id,
               group_by: "model",
               from: "2026-01-01"
             })

    mcp = mcp |> Jason.encode!() |> Jason.decode!()
    # idle_seconds advances with the wall clock between the two reads.
    assert Map.delete(http, "cache_hints") == Map.delete(mcp, "cache_hints")
  end

  test "MCP rejects a bad range with the stable code and an unknown project as not found", %{
    id: id
  } do
    assert {:error, %{code: "invalid_range"}} =
             Tools.call_tool("foreman_usage_get", %{
               project_id: id,
               from: "2026-02-01",
               to: "2026-01-01"
             })

    assert {:error, %{code: "NOT_FOUND"}} =
             Tools.call_tool("foreman_usage_get", %{project_id: "nope"})
  end

  test "foreman_usage_get is a read tool: listed with MCP writes disabled" do
    assert "foreman_usage_get" in Enum.map(
             ForemanServer.MCP.Policy.list_tools(Tools.list_tools()),
             & &1.name
           )
  end
end
