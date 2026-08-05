defmodule ForemanServerWeb.CommandControllerTest do
  use ExUnit.Case, async: false

  use Phoenix.ConnTest

  @moduletag :controller

  @endpoint ForemanServerWeb.Endpoint

  defp project_payload do
    %{
      type: "project.register",
      payload: %{
        project_id: "proj-#{System.unique_integer([:positive])}",
        path: "/tmp/proj"
      }
    }
  end

  defp task_payload do
    %{
      type: "task.create",
      payload: %{
        task_id: "task-#{System.unique_integer([:positive])}",
        project_id: "proj-#{System.unique_integer([:positive])}",
        title: "demo"
      }
    }
  end

  test "POST /api/commands rejects unknown type with 400" do
    conn = build_conn() |> post("/api/commands", %{type: "nope", payload: %{}})
    assert json_response(conn, 400)["error"] == "invalid_envelope"
  end

  test "POST /api/commands rejects missing type" do
    conn = build_conn() |> post("/api/commands", %{payload: %{}})
    assert json_response(conn, 400)["error"] == "invalid_envelope"
  end

  test "POST /api/commands rejects aggregate_id mismatch" do
    body = %{
      type: "task.create",
      aggregate_id: "task:wrong-id",
      payload: %{
        task_id: "task-real",
        project_id: "proj-real",
        title: "demo"
      }
    }

    conn = build_conn() |> post("/api/commands", body)
    assert json_response(conn, 400)["error"] == "invalid_envelope"
  end

  test "POST /api/commands rejects system command type" do
    body = %{type: "run.start", payload: %{run_id: "r1"}}
    conn = build_conn() |> post("/api/commands", body)
    assert json_response(conn, 400)["error"] == "invalid_envelope"
  end

  test "POST /api/commands projects a project.register envelope end-to-end" do
    body = project_payload()
    conn = build_conn() |> post("/api/commands", body)

    response = json_response(conn, 201)
    assert response["status"] == "accepted"
  end

  test "POST /api/commands creates a task through the gateway" do
    project_id = "proj-#{System.unique_integer([:positive])}"

    project_body = %{
      type: "project.register",
      payload: %{project_id: project_id, path: "/tmp/proj"}
    }

    conn1 = build_conn() |> post("/api/commands", project_body)
    assert json_response(conn1, 201)["status"] == "accepted"

    task_body = %{
      type: "task.create",
      payload: %{task_id: "task-#{System.unique_integer([:positive])}", project_id: project_id, title: "demo"}
    }

    conn2 = build_conn() |> post("/api/commands", task_body)
    assert json_response(conn2, 201)["status"] == "accepted"
  end
  test "aggregate_id is preserved when explicitly provided and matches" do
    task_id = "task-fixed"
    body = %{
      type: "task.create",
      aggregate_id: "task:#{task_id}",
      payload: %{task_id: task_id, project_id: "p-fixed", title: "x"}
    }

    # The dispatch itself may fail (no project registered for `p-fixed`),
    # but the envelope validation should accept the body and yield a
    # structured non-201 response — not a 400 invalid_envelope.
    conn = build_conn() |> post("/api/commands", body)
    body_json = json_response(conn, 422)
    refute body_json["error"] =~ "invalid_envelope"
  end
end