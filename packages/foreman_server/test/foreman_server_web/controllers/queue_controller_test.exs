defmodule ForemanServerWeb.QueueControllerTest do
  # `GET /api/queue?project_id=<id>` (TRD-012): the queue is per project only.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.MCP.Tools
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "queue-controller-test-token"
  @now_ms 1_700_000_000_000

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

    :ok = ProjectionStore.apply_events(project_events("p1") ++ project_events("p2"))
    :ok
  end

  defp project_events(project) do
    [
      %{
        event_type: "ProjectRegistered",
        payload: %{
          project_id: project,
          path: "/tmp/#{project}",
          config: %{max_concurrent_runs: 1}
        }
      },
      %{
        event_type: "RunSlotAcquired",
        payload: %{
          project_id: project,
          run_id: "#{project}-r1",
          capacity: 1,
          acquired_at_ms: 100
        }
      },
      %{
        event_type: "RunSlotQueued",
        payload: %{
          project_id: project,
          run_id: "#{project}-w1",
          position: 1,
          enqueued_at_ms: @now_ms
        }
      }
    ]
  end

  defp api_get(path) do
    build_conn() |> put_req_header("authorization", "Bearer #{@token}") |> get(path)
  end

  test "GET /api/queue returns 401 when the bearer token is missing" do
    conn = build_conn() |> get("/api/queue")

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  describe "un-scoped read is refused (AC-011-2)" do
    test "no project_id answers 422 project_required naming the way to scope it" do
      body = json_response(api_get("/api/queue"), 422)

      assert body["error"] == "project_required"
      assert body["message"] =~ "name a project"
      assert body["message"] =~ "project_id"
    end

    test "a blank project_id answers 422 project_required" do
      assert %{"error" => "project_required"} =
               json_response(api_get("/api/queue?project_id="), 422)

      assert %{"error" => "project_required"} =
               json_response(api_get("/api/queue?project_id=%20"), 422)
    end
  end

  describe "scoped read (AC-010-2)" do
    test "returns only the named project's runs" do
      body = json_response(api_get("/api/queue?project_id=p1"), 200)

      assert body["project_id"] == "p1"
      assert body["running"] == ["p1-r1"]
      assert Enum.map(body["waiting"], & &1["run_id"]) == ["p1-w1"]
      assert body["running_runs"] == 1
      assert body["waiting_runs"] == 1
      assert body["limit"] == 1
      refute inspect(body) =~ "p2-"
    end

    test "an unknown project answers 404 project_not_found" do
      assert %{"error" => "project_not_found"} =
               json_response(api_get("/api/queue?project_id=nope"), 404)
    end
  end

  describe "no surface returns a combined queue (AC-011-1)" do
    test "the projection store has no un-scoped queue_status" do
      Code.ensure_loaded!(ProjectionStore)
      refute function_exported?(ProjectionStore, :queue_status, 0)
      assert function_exported?(ProjectionStore, :queue_status, 1)
    end

    test "the MCP queue tool requires a project_id" do
      schema = Enum.find(Tools.list_tools(), &(&1.name == "foreman_queue_status"))
      assert schema.inputSchema[:required] == ["project_id"]
    end

    test "the MCP queue tool refuses an un-scoped call and scopes a named one" do
      assert {:error, _} = Tools.call_tool("foreman_queue_status", %{})

      assert {:ok, status} = Tools.call_tool("foreman_queue_status", %{project_id: "p1"})
      assert status.project_id == "p1"
      assert status.running == ["p1-r1"]
      refute inspect(status) =~ "p2-"
    end

    test "no other MCP tool is a queue tool" do
      queue_tools =
        for %{name: name} <- Tools.list_tools(), name =~ "queue", do: name

      assert queue_tools == ["foreman_queue_status"]
    end
  end
end
