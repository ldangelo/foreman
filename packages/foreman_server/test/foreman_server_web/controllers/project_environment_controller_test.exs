defmodule ForemanServerWeb.ProjectEnvironmentControllerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.{CommandRouter, EventStore}
  alias ForemanServer.MCP.Tools

  @endpoint ForemanServerWeb.Endpoint
  @token "project-environment-controller-token"
  @secret "http-secret-value-8675309"

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous_token = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)
    store = Application.get_env(:foreman_server, :secret_store)
    Application.put_env(:foreman_server, :secret_store, Keyword.put(store, :dir, tmp_dir))

    on_exit(fn ->
      Application.put_env(:foreman_server, :secret_store, store)

      if previous_token == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous_token)
    end)

    id = "env-http-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        payload: %{project_id: id, path: "/tmp/#{id}", config: %{}},
        aggregate_id: "project:#{id}"
      })

    {:ok, id: id}
  end

  defp call(method, path, body \\ nil) do
    conn = build_conn() |> put_req_header("authorization", "Bearer #{@token}")

    case body do
      nil ->
        dispatch(conn, @endpoint, method, path)

      body ->
        conn
        |> put_req_header("content-type", "application/json")
        |> dispatch(@endpoint, method, path, Jason.encode!(body))
    end
  end

  test "PUT then GET the environment; vars, script and network round trip", %{id: id} do
    conn =
      call(:put, "/api/projects/#{id}/environment", %{
        "vars" => %{"NPM_REGISTRY" => "https://r.example"},
        "setup_script" => "npm ci",
        "network" => %{"mode" => "allowlist", "hosts" => ["pypi.org"]}
      })

    assert %{"vars" => %{"NPM_REGISTRY" => "https://r.example"}, "setup_script" => "npm ci"} =
             json_response(conn, 200)

    assert %{
             "legacy_env" => false,
             "network" => %{"mode" => "allowlist", "hosts" => ["pypi.org"]},
             "network_enforced_on" => ["docker_jobsite"],
             "secrets" => []
           } = call(:get, "/api/projects/#{id}/environment") |> json_response(200)
  end

  test "invalid records are 422 with the typed reason; secrets in vars point at the store", %{
    id: id
  } do
    conn = call(:put, "/api/projects/#{id}/environment", %{"vars" => %{"API_TOKEN" => "x"}})
    assert %{"error" => error} = json_response(conn, 422)
    assert error =~ "secret_in_vars"
  end

  test "unknown project is 404 for every route" do
    assert call(:get, "/api/projects/ghost/environment") |> json_response(404)
    assert call(:put, "/api/projects/ghost/environment", %{"vars" => %{}}) |> json_response(404)

    assert call(:put, "/api/projects/ghost/secrets/API_TOKEN", %{"value" => "x"})
           |> json_response(404)
  end

  test "secret set/list/delete never echoes the value; logs, events and reads are clean", %{
    id: id
  } do
    log =
      capture_log([level: :debug], fn ->
        conn = call(:put, "/api/projects/#{id}/secrets/DEPLOY_PASSPHRASE", %{"value" => @secret})
        body = json_response(conn, 200)
        assert body == %{"name" => "DEPLOY_PASSPHRASE", "version" => 1}
        refute Jason.encode!(body) =~ @secret
      end)

    refute log =~ @secret

    env = call(:get, "/api/projects/#{id}/environment") |> json_response(200)

    assert [%{"name" => "DEPLOY_PASSPHRASE", "version" => 1}] =
             Enum.map(env["secrets"], &Map.take(&1, ["name", "version"]))

    refute Jason.encode!(env) =~ @secret

    {:ok, events} = EventStore.read_stream_forward("project_secret:#{id}", 0, 10)
    refute inspect(events) =~ @secret

    project = call(:get, "/api/projects/#{id}") |> json_response(200)
    refute Jason.encode!(project) =~ @secret

    assert %{"name" => "DEPLOY_PASSPHRASE"} =
             call(:delete, "/api/projects/#{id}/secrets/DEPLOY_PASSPHRASE") |> json_response(200)

    assert %{"error" => "secret_not_found"} =
             call(:delete, "/api/projects/#{id}/secrets/DEPLOY_PASSPHRASE") |> json_response(404)

    assert [] = (call(:get, "/api/projects/#{id}/environment") |> json_response(200))["secrets"]
  end

  test "invalid secret names and bodies are 422", %{id: id} do
    assert %{"error" => "invalid_secret_name"} =
             call(:put, "/api/projects/#{id}/secrets/lower", %{"value" => "x"})
             |> json_response(422)

    assert %{"error" => "invalid_secret_name"} =
             call(:put, "/api/projects/#{id}/secrets/FOREMAN_X", %{"value" => "x"})
             |> json_response(422)

    assert %{"error" => "invalid_secret_value"} =
             call(:put, "/api/projects/#{id}/secrets/OK_NAME", %{"nope" => "x"})
             |> json_response(422)
  end

  test "legacy flat env values are redacted in the environment read", %{id: id} do
    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.update",
        payload: %{project_id: id, config: %{env: %{"LEGACY_API_KEY" => "legacy-secret-value"}}},
        aggregate_id: "project:#{id}"
      })

    env = call(:get, "/api/projects/#{id}/environment") |> json_response(200)
    assert env["legacy_env"] == true
    assert env["vars"] == %{"LEGACY_API_KEY" => "[redacted]"}
    refute Jason.encode!(env) =~ "legacy-secret-value"
  end

  test "the project read keeps the record's script and network but redacts var values", %{id: id} do
    call(:put, "/api/projects/#{id}/environment", %{
      "vars" => %{"A" => "visible-looking"},
      "setup_script" => "make"
    })

    project = call(:get, "/api/projects/#{id}") |> json_response(200)

    assert %{"vars" => %{"A" => "[redacted]"}, "setup_script" => "make"} =
             project["project"]["config"]["environment"]
  end

  test "the generic command endpoint cannot write secrets", %{id: id} do
    conn =
      call(:post, "/api/commands", %{
        "type" => "project.secret.set",
        "aggregate_id" => "project_secret:#{id}",
        "payload" => %{"project_id" => id, "name" => "API_TOKEN"}
      })

    assert json_response(conn, 400)
  end

  test "MCP environment tool returns names only and never values", %{id: id} do
    call(:put, "/api/projects/#{id}/environment", %{
      "vars" => %{"REGION" => "us-east"},
      "setup_script" => "echo hi"
    })

    call(:put, "/api/projects/#{id}/secrets/DEPLOY_PASSPHRASE", %{"value" => @secret})

    assert {:ok, view} = Tools.call_tool("foreman_project_environment_get", %{project_id: id})
    assert view["vars"] == ["REGION"]
    assert view["has_setup_script"] == true
    refute Map.has_key?(view, "setup_script")
    assert [%{"name" => "DEPLOY_PASSPHRASE"}] = Enum.map(view["secrets"], &Map.take(&1, ["name"]))
    refute inspect(view) =~ @secret
    refute inspect(view) =~ "us-east"

    assert {:error, %{code: "NOT_FOUND"}} =
             Tools.call_tool("foreman_project_environment_get", %{project_id: "ghost"})
  end
end
