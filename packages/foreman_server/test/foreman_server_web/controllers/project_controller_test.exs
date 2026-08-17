defmodule ForemanServerWeb.ProjectControllerTest do
  use ExUnit.Case, async: false

  use Phoenix.ConnTest

  alias ForemanServer.ProjectStore

  @endpoint ForemanServerWeb.Endpoint
  @token "project-controller-test-token"
  defmodule WrongExpectedVersionGateway do
    def dispatch_operator(_command), do: {:error, {:wrong_expected_version, 7}}
  end

  setup do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)

    :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
      %{state | projects: %{}, runs: %{}, project_active_runs: %{}}
    end)

    on_exit(fn ->
      :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
        %{state | projects: %{}, runs: %{}, project_active_runs: %{}}
      end)

      if previous == nil do
        Application.delete_env(:foreman_server, :api_bearer_token)
      else
        Application.put_env(:foreman_server, :api_bearer_token, previous)
      end

      Application.delete_env(:foreman_server, :projects_list_max)
    end)

    :ok
  end

  test "GET /api/projects/:id returns 200 with the project envelope and echoes X-Request-Id" do
    project_id = unique_project_id()

    assert {:ok, _} =
             ProjectStore.save(%{
               project_id: project_id,
               path: "/tmp/#{project_id}",
               name: "Demo Project",
               task_provider: %{provider: :beads, config: %{"database_path" => "/tmp/demo.db"}}
             })

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{@token}")
      |> put_req_header("x-request-id", "req-project-show")
      |> get("/api/projects/#{project_id}")

    body = json_response(conn, 200)

    assert body["project"]["project_id"] == project_id
    assert body["project"]["path"] == "/tmp/#{project_id}"
    assert body["project"]["name"] == "Demo Project"
    assert body["project"]["task_provider"]["provider"] == "beads"
    assert body["project"]["task_provider"]["config"]["database_path"] == "/tmp/demo.db"
    assert get_resp_header(conn, "x-request-id") == ["req-project-show"]
  end

  test "GET /api/projects/:id returns 404 with the TRD missing-project envelope" do
    project_id = unique_project_id()

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{@token}")
      |> get("/api/projects/#{project_id}")

    assert json_response(conn, 404) == %{"error" => "not_found", "reason" => ":project_not_found"}
  end

  test "GET /api/projects/:id returns 401 when the bearer token is missing" do
    conn = build_conn() |> get("/api/projects/#{unique_project_id()}")

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "GET /api/projects/:id returns 404 for malformed ids that do not match the route" do
    conn = build_conn() |> get("/api/projects/not/a/uuid")

    assert conn.status == 404
  end

  test "project.register is accepted on the actual HTTP mutation surface and returns 201" do
    project_id = unique_project_id()

    conn =
      dispatch_json_conn(:post, "/api/commands", %{
        type: "project.register",
        payload: %{project_id: project_id, path: "/tmp/#{project_id}"}
      })

    assert %{"status" => "accepted", "result" => %{"project_id" => ^project_id}} =
             json_response(conn, 201)
  end

  test "project.update is allowlisted on the actual HTTP mutation surface and currently returns 201" do
    project_id = unique_project_id()

    register_conn =
      dispatch_json_conn(:post, "/api/commands", %{
        type: "project.register",
        payload: %{project_id: project_id, path: "/tmp/#{project_id}"}
      })

    assert json_response(register_conn, 201)["status"] == "accepted"

    update_conn =
      dispatch_json_conn(:post, "/api/commands", %{
        type: "project.update",
        payload: %{project_id: project_id, path: "/tmp/#{project_id}/updated"}
      })

    assert %{"status" => "accepted", "result" => %{"project_id" => ^project_id}} =
             json_response(update_conn, 201)
  end

  test "project mutations map wrong_expected_version to the current 409 conflict envelope" do
    previous = Application.get_env(:foreman_server, :command_gateway_module)

    Application.put_env(
      :foreman_server,
      :command_gateway_module,
      WrongExpectedVersionGateway
    )

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:foreman_server, :command_gateway_module)
      else
        Application.put_env(:foreman_server, :command_gateway_module, previous)
      end
    end)

    conn =
      dispatch_json_conn(:post, "/api/commands", %{
        type: "project.update",
        payload: %{project_id: unique_project_id(), path: "/tmp/conflict"}
      })

    assert json_response(conn, 409) == %{"code" => "version_conflict", "current_version" => 7}
  end

  test "project.register surfaces aggregate validation failures as 422" do
    conn =
      dispatch_json_conn(:post, "/api/commands", %{
        type: "project.register",
        payload: %{
          project_id: unique_project_id(),
          path: "/tmp/project-invalid-provider",
          task_provider: %{provider: :beads, config: %{database_path: "relative/beads.db"}}
        }
      })

    assert json_response(conn, 422) == %{"error" => ":database_path_must_be_absolute"}
  end

  test "GET /api/projects excludes archived projects by default and returns 200 with an empty list when none match" do
    archived_id = unique_project_id()

    assert {:ok, _} =
             ProjectStore.save(%{
               project_id: archived_id,
               path: "/tmp/#{archived_id}",
               task_provider: %{provider: :beads}
             })

    assert {:ok, _} = ProjectStore.archive(archived_id)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{@token}")
      |> get("/api/projects")

    assert json_response(conn, 200) == %{
             "projects" => [],
             "meta" => %{"truncated" => false}
           }

    assert get_resp_header(conn, "x-total-count") == ["0"]
  end

  test "GET /api/projects includes archived projects when requested" do
    archived_id = unique_project_id()

    assert {:ok, _} =
             ProjectStore.save(%{
               project_id: archived_id,
               path: "/tmp/#{archived_id}",
               task_provider: %{provider: :beads}
             })

    assert {:ok, _} = ProjectStore.archive(archived_id)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{@token}")
      |> get("/api/projects?include_archived=true")

    body = json_response(conn, 200)

    assert get_resp_header(conn, "x-total-count") == ["1"]
    assert body["meta"] == %{"truncated" => false}
    assert Enum.map(body["projects"], & &1["project_id"]) == [archived_id]
    assert Enum.map(body["projects"], & &1["archived?"]) == [true]
  end

  test "GET /api/projects truncates at the configured hard cap and reports the full count" do
    Application.put_env(:foreman_server, :projects_list_max, 2)

    for suffix <- 1..3 do
      project_id = "#{unique_project_id()}-list-#{suffix}"

      assert {:ok, _} =
               ProjectStore.save(%{
                 project_id: project_id,
                 path: "/tmp/#{project_id}",
                 task_provider: %{provider: :beads}
               })
    end

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{@token}")
      |> get("/api/projects")

    body = json_response(conn, 200)

    assert length(body["projects"]) == 2
    assert body["meta"] == %{"truncated" => true}
    assert get_resp_header(conn, "x-total-count") == ["3"]
  end

  test "GET /api/projects applies the caller limit and caps it at the hard cap" do
    Application.put_env(:foreman_server, :projects_list_max, 2)

    for suffix <- 1..3 do
      project_id = "#{unique_project_id()}-limit-#{suffix}"

      assert {:ok, _} =
               ProjectStore.save(%{
                 project_id: project_id,
                 path: "/tmp/#{project_id}",
                 task_provider: %{provider: :beads}
               })
    end

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{@token}")
      |> get("/api/projects?limit=5")

    body = json_response(conn, 200)

    assert length(body["projects"]) == 2
    assert body["meta"] == %{"truncated" => true}
    assert get_resp_header(conn, "x-total-count") == ["3"]
  end

  test "GET /api/projects rejects malformed query values with 400 invalid_query" do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{@token}")
      |> get("/api/projects?include_archived=notabool")

    assert json_response(conn, 400) == %{"error" => "invalid_query", "reason" => ":invalid_query"}
  end

  test "GET /api/projects/:id emits read telemetry for success" do
    project_id = unique_project_id()

    assert {:ok, _} =
             ProjectStore.save(%{
               project_id: project_id,
               path: "/tmp/#{project_id}",
               task_provider: %{provider: :beads}
             })

    handler_id = attach_telemetry(self(), [[:foreman_server, :project, :read]])

    try do
      conn = authorized_conn() |> get("/api/projects/#{project_id}")

      assert conn.status == 200

      assert_receive {
        :telemetry_event,
        [:foreman_server, :project, :read],
        %{duration_ms: duration_ms},
        %{project_id: ^project_id, outcome: :ok}
      }

      assert is_integer(duration_ms) and duration_ms >= 0
    after
      :telemetry.detach(handler_id)
    end
  end

  test "GET /api/projects/:id emits read telemetry for not_found" do
    project_id = unique_project_id()
    handler_id = attach_telemetry(self(), [[:foreman_server, :project, :read]])

    try do
      conn = authorized_conn() |> get("/api/projects/#{project_id}")

      assert conn.status == 404

      assert_receive {
        :telemetry_event,
        [:foreman_server, :project, :read],
        %{duration_ms: duration_ms},
        %{
          project_id: ^project_id,
          outcome: :error,
          code: "not_found",
          retryable: false
        }
      }

      assert is_integer(duration_ms) and duration_ms >= 0
    after
      :telemetry.detach(handler_id)
    end
  end

  test "GET /api/projects emits list telemetry with count and outcome" do
    project_id = unique_project_id()

    assert {:ok, _} =
             ProjectStore.save(%{
               project_id: project_id,
               path: "/tmp/#{project_id}",
               task_provider: %{provider: :beads}
             })

    handler_id = attach_telemetry(self(), [[:foreman_server, :project, :list]])

    try do
      conn = authorized_conn() |> get("/api/projects")

      assert conn.status == 200

      assert_receive {
        :telemetry_event,
        [:foreman_server, :project, :list],
        %{duration_ms: duration_ms, count: 1},
        %{outcome: :ok}
      }

      assert is_integer(duration_ms) and duration_ms >= 0
    after
      :telemetry.detach(handler_id)
    end
  end

  test "GET /api/projects invalid_query emits list telemetry code and retryable" do
    handler_id = attach_telemetry(self(), [[:foreman_server, :project, :list]])

    try do
      conn = authorized_conn() |> get("/api/projects?include_archived=notabool")

      assert conn.status == 400

      assert_receive {
        :telemetry_event,
        [:foreman_server, :project, :list],
        %{duration_ms: duration_ms, count: 0},
        %{outcome: :error, code: "invalid_query", retryable: false}
      }

      assert is_integer(duration_ms) and duration_ms >= 0
    after
      :telemetry.detach(handler_id)
    end
  end

  defp authorized_conn do
    build_conn() |> put_req_header("authorization", "Bearer #{@token}")
  end

  defp dispatch_json_conn(method, path, body) do
    method
    |> Plug.Test.conn(path, Jason.encode!(body))
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{@token}")
    |> @endpoint.call(@endpoint.init([]))
  end

  defp attach_telemetry(test_pid, events) do
    handler_id = "project-controller-telemetry-#{unique_project_id()}"

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    handler_id
  end

  defp unique_project_id do
    "project-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end
end
