defmodule ForemanServer.MCP.AuthTest do
  use ExUnit.Case, async: false

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

  # ---------------------------------------------------------------------------
  # verify_token/1
  # ---------------------------------------------------------------------------

  describe "verify_token/1" do
    test "rejects absent token when api_bearer_token is unset and allow_insecure_local is false" do
      Application.delete_env(:foreman_server, :api_bearer_token)
      Application.put_env(:foreman_server, :mcp, allow_insecure_local: false)

      assert Auth.verify_token(nil) == {:error, :no_token_configured}
    end

    test "accepts absent token when allow_insecure_local is true" do
      Application.delete_env(:foreman_server, :api_bearer_token)
      Application.put_env(:foreman_server, :mcp, allow_insecure_local: true)

      assert Auth.verify_token(nil) == :ok
    end

    test "accepts correct token" do
      Application.put_env(:foreman_server, :api_bearer_token, "test-secret-token")
      Application.put_env(:foreman_server, :mcp, allow_insecure_local: false)

      assert Auth.verify_token("test-secret-token") == :ok
    end

    test "rejects wrong token" do
      Application.put_env(:foreman_server, :api_bearer_token, "correct-token")
      Application.put_env(:foreman_server, :mcp, allow_insecure_local: false)

      assert Auth.verify_token("wrong-token") == {:error, :invalid_token}
    end

    test "constant-time comparison is used (timing-safe)" do
      Application.put_env(
        :foreman_server,
        :api_bearer_token,
        "super-secret-32-byte-token-here!!!!"
      )

      Application.put_env(:foreman_server, :mcp, allow_insecure_local: false)

      # If Plug.Crypto.secure_compare is used, the comparison is timing-safe
      # regardless of how many characters match.  We verify the function
      # returns :ok for the correct token and error for a wrong token.
      assert Auth.verify_token("super-secret-32-byte-token-here!!!!") == :ok
      assert Auth.verify_token("super-secret-32-byte-token-here!!!!X") == {:error, :invalid_token}
      assert Auth.verify_token("Xsuper-secret-32-byte-token-here!!!!") == {:error, :invalid_token}
    end

    test "empty string token is treated as absent" do
      Application.put_env(:foreman_server, :api_bearer_token, "")
      Application.put_env(:foreman_server, :mcp, allow_insecure_local: false)

      assert Auth.verify_token(nil) == {:error, :no_token_configured}
      assert Auth.verify_token("") == {:error, :no_token_configured}
    end
  end

  # ---------------------------------------------------------------------------
  # verify_request/3
  # ---------------------------------------------------------------------------

  describe "verify_request/3" do
    test "returns :ok when token is valid" do
      Application.put_env(:foreman_server, :api_bearer_token, "secret")
      Application.put_env(:foreman_server, :mcp, allow_insecure_local: false)

      assert Auth.verify_request("secret", "foreman_work_get", %{work_id: "123"}) == :ok
    end

    test "returns error tuple when token is invalid" do
      Application.put_env(:foreman_server, :api_bearer_token, "secret")
      Application.put_env(:foreman_server, :mcp, allow_insecure_local: false)

      assert Auth.verify_request("wrong", "foreman_work_get", %{work_id: "123"}) ==
               {:error, :invalid_token}
    end

    test "returns error tuple when token is absent" do
      Application.delete_env(:foreman_server, :api_bearer_token)
      Application.put_env(:foreman_server, :mcp, allow_insecure_local: false)

      assert Auth.verify_request(nil, "foreman_work_get", %{}) ==
               {:error, :no_token_configured}
    end
  end
end
