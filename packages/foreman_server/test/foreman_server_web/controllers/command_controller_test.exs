defmodule ForemanServerWeb.CommandControllerTest do
  use ExUnit.Case, async: false

  use Phoenix.ConnTest

  @moduletag :controller

  @endpoint ForemanServerWeb.Endpoint

  alias ForemanServer.CommandGateway

  defmodule WrongExpectedVersionGateway do
    def dispatch_operator(_command), do: {:error, {:wrong_expected_version, 7}}
  end

  setup do
    previous = Application.get_env(:foreman_server, :command_gateway_module)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:foreman_server, :command_gateway_module)
      else
        Application.put_env(:foreman_server, :command_gateway_module, previous)
      end
    end)

    :ok
  end

  defp unique_id(prefix), do: "#{prefix}-#{Elixir.EventStore.UUID.uuid4()}"

  defp project_payload do
    %{
      type: "project.register",
      payload: %{
        project_id: unique_id("proj"),
        path: "/tmp/proj"
      }
    }
  end

  defp task_payload do
    %{
      type: "task.create",
      payload: %{
        task_id: unique_id("task"),
        project_id: unique_id("proj"),
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

  test "POST /api/commands task.create rejects non-string task_id without aggregate_id" do
    body = %{
      type: "task.create",
      payload: %{
        task_id: 123,
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

  test "POST /api/commands accepts project.update and returns the project_id envelope" do
    project_id = unique_id("proj")

    register_conn =
      build_conn()
      |> post("/api/commands", %{
        type: "project.register",
        payload: %{project_id: project_id, path: "/tmp/#{project_id}"}
      })

    assert json_response(register_conn, 201)["status"] == "accepted"

    update_conn =
      build_conn()
      |> post("/api/commands", %{
        type: "project.update",
        payload: %{project_id: project_id, path: "/tmp/#{project_id}/updated"}
      })

    assert %{"status" => "accepted", "result" => %{"project_id" => ^project_id}} =
             json_response(update_conn, 201)
  end

  test "POST /api/commands returns 409 version_conflict when gateway reports wrong expected version" do
    Application.put_env(
      :foreman_server,
      :command_gateway_module,
      WrongExpectedVersionGateway
    )

    conn =
      build_conn()
      |> post("/api/commands", %{
        type: "project.update",
        payload: %{project_id: "proj-conflict", path: "/tmp/proj-conflict"}
      })

    assert %{"code" => "version_conflict", "current_version" => 7} =
             json_response(conn, 409)
  end

  test "POST /api/commands returns 409 project_has_active_runs when project.archive is rejected by active runs" do
    project_id = unique_id("proj")
    run_id = unique_id("run")

    register_conn =
      build_conn()
      |> post("/api/commands", %{
        type: "project.register",
        payload: %{project_id: project_id, path: "/tmp/#{project_id}"}
      })

    assert json_response(register_conn, 201)["status"] == "accepted"

    assert {:ok, _} =
             CommandGateway.dispatch_system(%{
               command_id: "reserve:#{project_id}:#{run_id}",
               aggregate_id: "project:#{project_id}",
               type: "project.reserve_run",
               payload: %{
                 project_id: project_id,
                 run_id: run_id,
                 command_id: "run-start:#{project_id}:#{run_id}",
                 sequence: 1,
                 run_start_payload: %{
                   project_id: project_id,
                   run_id: run_id,
                   task_id: unique_id("task"),
                   workflow_snapshot: %{}
                 }
               }
             })

    archive_conn =
      build_conn()
      |> post("/api/commands", %{
        type: "project.archive",
        payload: %{project_id: project_id}
      })

    assert %{"code" => "project_has_active_runs", "run_ids" => [^run_id]} =
             json_response(archive_conn, 409)
  end

  test "POST /api/commands task.create omits external_id when no provider linked a bead" do
    project_id = unique_id("proj")

    project_body = %{
      type: "project.register",
      payload: %{project_id: project_id, path: "/tmp/proj"}
    }

    conn1 = build_conn() |> post("/api/commands", project_body)
    assert json_response(conn1, 201)["status"] == "accepted"

    task_body = %{
      type: "task.create",
      payload: %{
        task_id: unique_id("task"),
        project_id: project_id,
        title: "demo"
      }
    }

    conn2 = build_conn() |> post("/api/commands", task_body)
    # The test project has no :create provider configured, so the
    # Actor hook does not invoke a provider and payload.external_id
    # is nil. The response OMITS the key entirely. The CLI treats
    # absence as "no Bead linked yet".
    response = json_response(conn2, 201)
    result = response["result"]

    assert %{"status" => "accepted"} = response
    assert is_binary(result["task_id"])
    refute Map.has_key?(result, "external_id")
  end

  defmodule WithExternalIdGateway do
    def dispatch_operator(%{type: "task.create", payload: payload} = _command) do
      task_id =
        Map.get(payload, :task_id) ||
          Map.get(payload, "task_id") ||
          "task-stub"

      {:ok,
       %{
         payload: %{
           task_id: task_id,
           project_id: "proj-stub",
           external_id: "br-123"
         }
       }}
    end
  end

  test "POST /api/commands task.create result surfaces external_id when provider links a bead" do
    Application.put_env(
      :foreman_server,
      :command_gateway_module,
      WithExternalIdGateway
    )

    conn =
      build_conn()
      |> post("/api/commands", %{
        type: "task.create",
        payload: %{task_id: "task-stub", project_id: "proj-stub", title: "demo"}
      })

    assert %{
             "status" => "accepted",
             "result" => %{"task_id" => "task-stub", "external_id" => "br-123"}
           } = json_response(conn, 201)
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

  test "POST /api/commands rejects run.cancel with mismatched aggregate_id" do
    body = %{
      type: "run.cancel",
      aggregate_id: "run:wrong-id",
      payload: %{run_id: "run-real", reason: "test"}
    }

    conn = build_conn() |> post("/api/commands", body)
    assert json_response(conn, 400)["error"] == "invalid_envelope"
  end

  test "POST /api/commands accepts run.cancel envelope and reaches dispatch" do
    # No run exists for this id, so dispatch itself will fail at the
    # aggregate layer; what we verify here is that envelope validation
    # accepts the body and yields a structured non-400 response.
    body = %{
      type: "run.cancel",
      payload: %{run_id: "run-does-not-exist-yet", reason: "test"}
    }

    conn = build_conn() |> post("/api/commands", body)
    body_json = json_response(conn, 422)
    refute body_json["error"] =~ "invalid_envelope"
  end

  test "POST /api/commands accepts run.cancel with explicit matching aggregate_id" do
    run_id = "run-cancel-explicit"

    body = %{
      type: "run.cancel",
      aggregate_id: "run:#{run_id}",
      payload: %{run_id: run_id, reason: "test"}
    }

    conn = build_conn() |> post("/api/commands", body)
    body_json = json_response(conn, 422)
    refute body_json["error"] =~ "invalid_envelope"
  end
end
