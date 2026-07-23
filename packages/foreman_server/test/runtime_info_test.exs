defmodule ForemanServer.RuntimeInfoTest do
  use ExUnit.Case, async: false

  alias ForemanServer.RuntimeInfo

  setup do
    original_env = System.get_env("FOREMAN_SERVER_PROJECTION_REBUILD_TIMEOUT_MS")
    original_app = Application.get_env(:foreman_server, :projection_rebuild_timeout_ms)
    original_webhook_env = System.get_env("FOREMAN_GITHUB_WEBHOOK_SECRET")
    original_webhook_app = Application.get_env(:foreman_server, :github_webhook_secret)

    on_exit(fn ->
      if is_nil(original_env) do
        System.delete_env("FOREMAN_SERVER_PROJECTION_REBUILD_TIMEOUT_MS")
      else
        System.put_env("FOREMAN_SERVER_PROJECTION_REBUILD_TIMEOUT_MS", original_env)
      end

      if is_nil(original_app) do
        Application.delete_env(:foreman_server, :projection_rebuild_timeout_ms)
      else
        Application.put_env(:foreman_server, :projection_rebuild_timeout_ms, original_app)
      end

      if is_nil(original_webhook_env) do
        System.delete_env("FOREMAN_GITHUB_WEBHOOK_SECRET")
      else
        System.put_env("FOREMAN_GITHUB_WEBHOOK_SECRET", original_webhook_env)
      end

      if is_nil(original_webhook_app) do
        Application.delete_env(:foreman_server, :github_webhook_secret)
      else
        Application.put_env(:foreman_server, :github_webhook_secret, original_webhook_app)
      end
    end)

    :ok
  end

  describe "projection_rebuild_timeout_ms/0" do
    test "returns 600_000 default when no env and no app config" do
      System.delete_env("FOREMAN_SERVER_PROJECTION_REBUILD_TIMEOUT_MS")
      Application.delete_env(:foreman_server, :projection_rebuild_timeout_ms)

      assert RuntimeInfo.projection_rebuild_timeout_ms() == 600_000
    end

    test "prefers env over app config" do
      System.put_env("FOREMAN_SERVER_PROJECTION_REBUILD_TIMEOUT_MS", "300000")
      Application.put_env(:foreman_server, :projection_rebuild_timeout_ms, 100_000)

      assert RuntimeInfo.projection_rebuild_timeout_ms() == 300_000
    end

    test "falls back to app config when env unset" do
      System.delete_env("FOREMAN_SERVER_PROJECTION_REBUILD_TIMEOUT_MS")
      Application.put_env(:foreman_server, :projection_rebuild_timeout_ms, 250_000)

      assert RuntimeInfo.projection_rebuild_timeout_ms() == 250_000
    end

    test "rejects env with trailing characters and falls back" do
      System.put_env("FOREMAN_SERVER_PROJECTION_REBUILD_TIMEOUT_MS", "600000ms")
      Application.put_env(:foreman_server, :projection_rebuild_timeout_ms, 123_456)

      assert RuntimeInfo.projection_rebuild_timeout_ms() == 123_456
    end

    test "rejects env with non-numeric chars and falls back" do
      System.put_env("FOREMAN_SERVER_PROJECTION_REBUILD_TIMEOUT_MS", "abc")
      Application.put_env(:foreman_server, :projection_rebuild_timeout_ms, 200_000)

      assert RuntimeInfo.projection_rebuild_timeout_ms() == 200_000
    end

    test "rejects non-positive env and falls back" do
      System.put_env("FOREMAN_SERVER_PROJECTION_REBUILD_TIMEOUT_MS", "0")
      Application.put_env(:foreman_server, :projection_rebuild_timeout_ms, 175_000)

      assert RuntimeInfo.projection_rebuild_timeout_ms() == 175_000
    end

    test "rejects negative env and falls back" do
      System.put_env("FOREMAN_SERVER_PROJECTION_REBUILD_TIMEOUT_MS", "-1")
      Application.put_env(:foreman_server, :projection_rebuild_timeout_ms, 200_000)

      assert RuntimeInfo.projection_rebuild_timeout_ms() == 200_000
    end

    test "falls back to default when both env and app config are invalid" do
      System.put_env("FOREMAN_SERVER_PROJECTION_REBUILD_TIMEOUT_MS", "garbage")
      Application.put_env(:foreman_server, :projection_rebuild_timeout_ms, -5)

      assert RuntimeInfo.projection_rebuild_timeout_ms() == 600_000
    end
  end

  describe "github_webhook_secret/0" do
    test "prefers runtime env over app config" do
      System.put_env("FOREMAN_GITHUB_WEBHOOK_SECRET", "env-secret")
      Application.put_env(:foreman_server, :github_webhook_secret, "app-secret")

      assert RuntimeInfo.github_webhook_secret() == "env-secret"
    end

    test "falls back to app config when env unset" do
      System.delete_env("FOREMAN_GITHUB_WEBHOOK_SECRET")
      Application.put_env(:foreman_server, :github_webhook_secret, "app-secret")

      assert RuntimeInfo.github_webhook_secret() == "app-secret"
    end

    test "falls back to app config when env is blank" do
      System.put_env("FOREMAN_GITHUB_WEBHOOK_SECRET", "")
      Application.put_env(:foreman_server, :github_webhook_secret, "app-secret")

      assert RuntimeInfo.github_webhook_secret() == "app-secret"
    end

    test "returns nil when secret is blank or unset" do
      System.delete_env("FOREMAN_GITHUB_WEBHOOK_SECRET")
      Application.put_env(:foreman_server, :github_webhook_secret, "")

      assert RuntimeInfo.github_webhook_secret() == nil
    end
  end
end
