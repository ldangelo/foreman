defmodule ForemanServer.Http.RouterTest do
  use ExUnit.Case
  import Plug.Conn
  import Plug.Test

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
end
