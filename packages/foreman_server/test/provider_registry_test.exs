defmodule ForemanServer.ProviderRegistryTest do
  use ExUnit.Case
  import Plug.Conn
  import Plug.Test

  alias ForemanServer.ProviderRegistry

  @opts ForemanServer.Http.Router.init([])

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-provider-registry-test-#{System.unique_integer([:positive])}"
      )

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

  test "workflow provider selection resolves through adapter registry" do
    assert {:ok, adapter} =
             ProviderRegistry.resolve(%{provider: "pi_sdk", tool_names: ["read", "edit"]})

    assert adapter.id == "pi_sdk"
    assert adapter.production_ready == true
    assert adapter.worker_protocol == "worker_http_v1"
  end

  test "non-production adapters fail before worker execution with Pi SDK v1 message" do
    conn =
      post_start(%{"run_id" => "run-provider", "worker_id" => "worker-1", "adapter" => "mock"})

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "VALIDATION_FAILED"
    assert body["error"]["message"] =~ "Pi SDK is the only required production adapter for v1"
    assert ForemanServer.EventStore.all() == []
  end

  test "unsupported tools fail before execution with actionable validation" do
    conn =
      post_start(%{
        "run_id" => "run-tools",
        "worker_id" => "worker-1",
        "adapter" => "pi_sdk",
        "tool_names" => ["read", "unsafe_shell"]
      })

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["details"] == %{"unsupported_tools" => ["unsafe_shell"]}
    assert body["error"]["message"] =~ "Use Pi-compatible tools"
    assert ForemanServer.EventStore.all() == []
  end

  defp post_start(payload) do
    :post
    |> conn("/worker/v1/phases/developer/start", Jason.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer secret")
    |> ForemanServer.Http.Router.call(@opts)
  end
end
