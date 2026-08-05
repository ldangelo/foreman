defmodule ForemanServer.ConfigTest do
  use ExUnit.Case, async: true

  @config_path Path.join([__DIR__, "..", "..", "config"])

  defp read_env!(env) do
    Config.Reader.read!(
      Path.join(@config_path, "config.exs"),
      env: env
    )
  end

  defp foreman_env(opts), do: Keyword.get(opts, :foreman_server) || []

  describe "test env (TRD-023)" do
    test "EventStore url targets the test database" do
      opts = read_env!(:test)
      es_cfg = Keyword.get(foreman_env(opts), ForemanServer.EventStore)
      assert is_list(es_cfg)

      url = Keyword.fetch!(es_cfg, :url)
      assert is_binary(url)
      assert url =~ "foreman_test" or url =~ "memory"
    end

    test "Repo url targets the test database" do
      opts = read_env!(:test)
      repo = Keyword.get(foreman_env(opts), ForemanServer.Repo)
      assert is_list(repo)

      url = Keyword.fetch!(repo, :url)
      assert url =~ "foreman_test" or url =~ "memory"
    end

    test "worker_launcher_enabled is disabled in test" do
      opts = read_env!(:test)
      assert Keyword.get(foreman_env(opts), :worker_launcher_enabled) == false
    end

    test "logster capture_log is disabled in test" do
      opts = read_env!(:test)
      logster = Keyword.get(opts, :logster) || []
      assert Keyword.get(logster, :capture_log) == false
    end

    test "Phoenix.Diagnostics is disabled in test" do
      opts = read_env!(:test)
      phoenix = Keyword.get(opts, :phoenix) || []
      diag = Keyword.get(phoenix, Phoenix.Diagnostics) || []
      assert Keyword.get(diag, :enabled) == false
    end

    test "EventStore serializer is TermOrJsonSerializer" do
      opts = read_env!(:test)
      es_cfg = Keyword.get(foreman_env(opts), ForemanServer.EventStore)
      assert Keyword.get(es_cfg, :serializer) == ForemanServer.TermOrJsonSerializer
    end
  end

  describe "dev env (TRD-022)" do
    test "EventStore reads DATABASE_URL with localhost default" do
      opts = read_env!(:dev)
      es_cfg = Keyword.get(foreman_env(opts), ForemanServer.EventStore)
      url = Keyword.fetch!(es_cfg, :url)
      assert url =~ "localhost"

      assert Keyword.get(es_cfg, :log) == :debug,
             "Dev EventStore should have verbose logging per TRD-022"
    end

    test "Repo reads DATABASE_URL with localhost default" do
      opts = read_env!(:dev)
      repo = Keyword.get(foreman_env(opts), ForemanServer.Repo)
      assert is_list(repo)
      url = Keyword.fetch!(repo, :url)
      assert url =~ "localhost"
    end

    test "Overwatch is enabled in dev" do
      opts = read_env!(:dev)
      overwatch = Keyword.get(foreman_env(opts), ForemanServer.Overwatch)
      assert Keyword.get(overwatch, :enabled) == true
    end

    test "WorkerLauncher is enabled in dev" do
      opts = read_env!(:dev)
      launcher = Keyword.get(foreman_env(opts), ForemanServer.WorkerLauncher)
      assert Keyword.get(launcher, :enabled) == true
    end
  end
end
