defmodule ForemanServer.Http.RouterTest do
  use ExUnit.Case
  import Plug.Conn
  import Plug.Test

  alias ForemanServer.ProjectionStore

  @opts ForemanServer.Http.Router.init([])

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "foreman-http-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    Application.put_env(:foreman_server, :auth_token, "secret")
    assert :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      Application.delete_env(:foreman_server, :auth_token)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    :ok
  end

  test "rejects missing bearer token before side effects" do
    conn =
      :post
      |> conn("/api/v1/commands", Jason.encode!(valid_command()))
      |> put_req_header("content-type", "application/json")
      |> ForemanServer.Http.Router.call(@opts)

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "UNAUTHORIZED"
    assert ForemanServer.EventStore.all() == []
  end

  test "accepts authorized JSON command and returns event/projection envelope" do
    conn =
      :post
      |> conn("/api/v1/commands", Jason.encode!(valid_command()))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert conn.status == 202
    body = Jason.decode!(conn.resp_body)
    assert body["ok"] == true
    assert [_event_id] = body["events"]
    assert body["projection_version"] == 1
    assert body["correlation_id"] == "corr-http"
  end

  test "authorized top-level external trigger command creates and dedupes integration task" do
    command = top_level_external_trigger_command()

    conn =
      :post
      |> conn("/api/v1/commands", Jason.encode!(command))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert conn.status == 202
    body = Jason.decode!(conn.resp_body)
    assert body["ok"] == true
    assert [_event_id] = body["events"]

    task_id =
      ProjectionStore.snapshot().integration_dedupe["github:fortium/foreman:evt-http-top"].task_id

    assert ProjectionStore.snapshot().tasks[task_id].external_link ==
             "https://github.com/fortium/foreman/issues/22"

    conn =
      :post
      |> conn("/api/v1/commands", Jason.encode!(command))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert conn.status == 202

    assert ProjectionStore.snapshot().integration_dedupe["github:fortium/foreman:evt-http-top"].task_id ==
             task_id
  end

  test "authorized external trigger command creates and dedupes integration task" do
    command = external_trigger_command("cmd-ext-http-1")

    conn =
      :post
      |> conn("/api/v1/commands", Jason.encode!(command))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert conn.status == 202
    body = Jason.decode!(conn.resp_body)
    assert body["ok"] == true
    assert [_event_id] = body["events"]

    task_id =
      ProjectionStore.snapshot().integration_dedupe["github:fortium/foreman:evt-http"].task_id

    assert ProjectionStore.snapshot().tasks[task_id].external_link ==
             "https://github.com/fortium/foreman/issues/20"

    conn =
      :post
      |> conn("/api/v1/commands", Jason.encode!(external_trigger_command("cmd-ext-http-2")))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert conn.status == 202

    assert ProjectionStore.snapshot().integration_dedupe["github:fortium/foreman:evt-http"].task_id ==
             task_id
  end

  test "external trigger command validates input through HTTP boundary" do
    conn =
      :post
      |> conn(
        "/api/v1/commands",
        Jason.encode!(%{
          "command_id" => "cmd-ext-bad",
          "command_type" => "ExternalTriggerCommand",
          "payload" => %{
            "source" => "github",
            "repo" => "fortium/foreman",
            "event_id" => "evt-bad",
            "external_id" => "21",
            "project_id" => "foreman",
            "event_type" => "opened"
          }
        })
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["message"] == "missing or invalid external_link"
  end

  test "invalid JSON command returns validation error" do
    conn =
      :post
      |> conn("/api/v1/commands", Jason.encode!(%{"command_id" => "cmd-bad"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["ok"] == false
    assert body["error"]["code"] == "VALIDATION_FAILED"
  end

  defp valid_command do
    %{
      "command_id" => "cmd-http",
      "command_type" => "task.create",
      "schema_version" => 1,
      "payload" => %{"task_id" => "task-http"},
      "metadata" => %{"correlation_id" => "corr-http", "idempotency_key" => "cmd-http"}
    }
  end

  defp top_level_external_trigger_command do
    %{
      "command_type" => "ExternalTriggerCommand",
      "source" => "github",
      "repo" => "fortium/foreman",
      "event_id" => "evt-http-top",
      "external_id" => "22",
      "project_id" => "foreman",
      "event_type" => "opened",
      "url" => "https://github.com/fortium/foreman/issues/22"
    }
  end

  defp external_trigger_command(command_id) do
    %{
      "command_id" => command_id,
      "command_type" => "ExternalTriggerCommand",
      "payload" => %{
        "source" => "github",
        "repo" => "fortium/foreman",
        "event_id" => "evt-http",
        "external_id" => "20",
        "project_id" => "foreman",
        "event_type" => "opened",
        "url" => "https://github.com/fortium/foreman/issues/20"
      },
      "metadata" => %{"correlation_id" => "corr-ext-http"}
    }
  end
end
