defmodule ForemanServerWeb.CommandControllerThreadTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @moduletag :controller
  @endpoint ForemanServerWeb.Endpoint

  defp uid, do: Elixir.EventStore.UUID.uuid4()

  defp body(type, thread_id),
    do: %{type: type, payload: %{thread_id: thread_id, project_id: "p"}}

  test "POST /api/commands accepts thread.resolve and thread.reopen" do
    thread_id = "run:ctl-#{uid()}"

    conn = build_conn() |> post("/api/commands", body("thread.resolve", thread_id))
    assert %{"status" => "accepted"} = json_response(conn, 201)

    conn = build_conn() |> post("/api/commands", body("thread.reopen", thread_id))
    assert %{"status" => "accepted"} = json_response(conn, 201)
  end

  test "the controller derives the thread aggregate id and rejects a mismatch" do
    thread_id = "run:ctl-#{uid()}"

    conn =
      build_conn()
      |> post(
        "/api/commands",
        Map.put(body("thread.resolve", thread_id), :aggregate_id, "thread:run:other")
      )

    assert json_response(conn, 400)["error"] == "invalid_envelope"
  end

  test "reopening a never-resolved thread is a 422 carrying the typed error" do
    conn = build_conn() |> post("/api/commands", body("thread.reopen", "run:ctl-#{uid()}"))
    assert %{"error" => error} = json_response(conn, 422)
    assert error =~ "thread_not_resolved"
  end
end
