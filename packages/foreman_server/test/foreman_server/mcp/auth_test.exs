defmodule ForemanServer.MCP.AuthTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.MCP.Auth

  setup do
    original_token = Application.get_env(:foreman_server, :api_bearer_token)
    original_mcp = Application.get_env(:foreman_server, :mcp, [])

    on_exit(fn ->
      if original_token do
        Application.put_env(:foreman_server, :api_bearer_token, original_token)
      else
        Application.delete_env(:foreman_server, :api_bearer_token)
      end

      Application.put_env(:foreman_server, :mcp, original_mcp)
    end)
  end

  describe "verify_token/1" do
    test "absent token is rejected when allow_insecure_local is false" do
      Application.delete_env(:foreman_server, :api_bearer_token)
      Application.put_env(:foreman_server, :mcp, allow_insecure_local: false)

      assert Auth.verify_token(nil) == {:error, :no_token_configured}
    end

    test "malformed token is rejected" do
      Application.put_env(:foreman_server, :api_bearer_token, "secret-token")
      Application.put_env(:foreman_server, :mcp, allow_insecure_local: false)

      assert Auth.verify_token("secret-token-extra") == {:error, :invalid_token}
    end

    test "wrong token is rejected" do
      Application.put_env(:foreman_server, :api_bearer_token, "correct-token")
      Application.put_env(:foreman_server, :mcp, allow_insecure_local: false)

      assert Auth.verify_token("wrong-token") == {:error, :invalid_token}
    end

    test "correct token is accepted" do
      Application.put_env(:foreman_server, :api_bearer_token, "test-secret-token")
      Application.put_env(:foreman_server, :mcp, allow_insecure_local: false)

      assert Auth.verify_token("test-secret-token") == :ok
    end

    test "allow_insecure_local: true permits startup without token" do
      Application.delete_env(:foreman_server, :api_bearer_token)
      Application.put_env(:foreman_server, :mcp, allow_insecure_local: true)

      assert Auth.verify_token(nil) == :ok
      assert Auth.verify_token("") == :ok
    end

    test "token is not emitted to Logger or telemetry metadata" do
      Application.put_env(:foreman_server, :api_bearer_token, "super-secret-token")
      Application.put_env(:foreman_server, :mcp, allow_insecure_local: false)

      parent = self()
      ref = make_ref()

      :telemetry.attach(
        "auth-test-#{inspect(ref)}",
        [:foreman_server, :mcp, :tool, :call],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("auth-test-#{inspect(ref)}")
      end)

      log =
        capture_log(fn ->
          assert Auth.verify_request("wrong-token", "foreman_work_get", %{work_id: "work-123"}) ==
                   {:error, :invalid_token}

          ForemanServer.Telemetry.mcp_tool_call(10, "foreman_work_get", :error)
        end)

      assert log =~ "authentication failed for tool foreman_work_get"
      refute log =~ "wrong-token"
      refute log =~ "super-secret-token"
      refute log =~ "work-123"

      assert_receive {:telemetry_event, [:foreman_server, :mcp, :tool, :call], %{duration_us: 10},
                      %{tool: "foreman_work_get", outcome: :error}}
    end
  end
end
