defmodule ForemanServerWeb.CommandControllerToolCallTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias ForemanServer.Aggregates.ToolCall
  alias ForemanServer.CommandGateway

  @moduletag :controller
  @endpoint ForemanServerWeb.Endpoint

  defp uid, do: Elixir.EventStore.UUID.uuid4()

  defp request(run_id, tool_call_id) do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "tool.request",
        command_id: "tool-request:#{uid()}",
        aggregate_id: ToolCall.stream_id(run_id, tool_call_id),
        payload: %{run_id: run_id, tool_call_id: tool_call_id, tool_name: "Write"}
      })
  end

  defp body(type, run_id, tool_call_id),
    do: %{type: type, payload: %{run_id: run_id, tool_call_id: tool_call_id}}

  test "POST /api/commands accepts tool.approve and tool.deny for requested calls" do
    run_id = "run-#{uid()}"
    request(run_id, "a")
    request(run_id, "b")

    conn = build_conn() |> post("/api/commands", body("tool.approve", run_id, "a"))
    assert %{"status" => "accepted"} = json_response(conn, 201)

    conn = build_conn() |> post("/api/commands", body("tool.deny", run_id, "b"))
    assert %{"status" => "accepted"} = json_response(conn, 201)
  end

  test "ids containing a colon resolve the escaped composite stream" do
    run_id = "run:#{uid()}"
    request(run_id, "tc:1")
    conn = build_conn() |> post("/api/commands", body("tool.approve", run_id, "tc:1"))
    assert %{"status" => "accepted"} = json_response(conn, 201)
  end

  test "an unknown call is a 422 domain error, never a 500" do
    conn = build_conn() |> post("/api/commands", body("tool.approve", "run-#{uid()}", "nope"))
    assert %{"error" => error} = json_response(conn, 422)
    assert error =~ "tool_call_not_requested"
  end

  test "a mismatched aggregate_id is rejected" do
    conn =
      build_conn()
      |> post(
        "/api/commands",
        Map.put(body("tool.approve", "r", "t"), :aggregate_id, "run:r")
      )

    assert json_response(conn, 400)["error"] == "invalid_envelope"
  end

  test "system-only tool commands are not accepted over HTTP" do
    for type <- ["tool.request", "tool.finish", "tool.expire"] do
      conn = build_conn() |> post("/api/commands", body(type, "r", "t"))
      assert json_response(conn, 400)["error"] == "invalid_envelope"
    end
  end
end
