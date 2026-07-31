defmodule ForemanServer.SecretsProviderTest do
  use ExUnit.Case, async: false

  alias ForemanServer.SecretsProvider

  describe "init/1" do
    test "returns {:env, var} tuple unchanged" do
      assert SecretsProvider.init({:env, "FOREMAN_SERVER_SECRETS_FILE"}) ==
               {:env, "FOREMAN_SERVER_SECRETS_FILE"}
    end

    test "returns path string unchanged" do
      assert SecretsProvider.init("/etc/foreman/secrets") == "/etc/foreman/secrets"
    end
  end

  describe "load/2 — no-op paths" do
    test "nil path returns config unchanged" do
      config = [foreman_server: [foo: :bar]]
      assert SecretsProvider.load(config, nil) == config
    end

    test "empty string path returns config unchanged" do
      config = [foreman_server: [foo: :bar]]
      assert SecretsProvider.load(config, "") == config
    end

    test "missing file returns config unchanged" do
      config = [foreman_server: [foo: :bar]]
      assert SecretsProvider.load(config, "/nonexistent/path/should/not/exist") == config
    end

    test "{:env, var} with unset env var returns config unchanged" do
      config = [foreman_server: [foo: :bar]]
      env_var = "FOREMAN_SERVER_SECRETS_FILE_UNSET_TEST_#{:rand.uniform(999_999)}"

      on_exit(fn -> System.delete_env(env_var) end)

      assert SecretsProvider.load(config, {:env, env_var}) == config
    end
  end

  describe "load/2 — valid keys" do
    setup do
      # Temp file cleaned up on test exit
      tmp = Path.join(System.tmp_dir!(), "foreman_secrets_test_#{:rand.uniform(999_999)}.env")
      on_exit(fn -> File.rm(tmp) end)
      {:ok, %{tmp: tmp}}
    end

    test "DATABASE_URL is merged into foreman_server :database_url", %{tmp: tmp} do
      File.write!(tmp, "DATABASE_URL=postgresql://user:pass@host:5432/db\n")

      config = [foreman_server: []]
      result = SecretsProvider.load(config, tmp)

      assert get_in(result, [:foreman_server, :database_url]) ==
               "postgresql://user:pass@host:5432/db"
    end

    test "FOREMAN_SERVER_EVENT_STORE_ADAPTER=postgres is atom :postgres", %{tmp: tmp} do
      File.write!(tmp, "FOREMAN_SERVER_EVENT_STORE_ADAPTER=postgres\n")

      config = [foreman_server: []]
      result = SecretsProvider.load(config, tmp)

      assert get_in(result, [:foreman_server, :event_store_adapter]) == :postgres
    end

    test "FOREMAN_SERVER_EVENT_STORE_ADAPTER=term is atom :term", %{tmp: tmp} do
      File.write!(tmp, "FOREMAN_SERVER_EVENT_STORE_ADAPTER=term\n")

      config = [foreman_server: []]
      result = SecretsProvider.load(config, tmp)

      assert get_in(result, [:foreman_server, :event_store_adapter]) == :term
    end

    test "FOREMAN_SERVER_REPO_URL is merged into Repo :url", %{tmp: tmp} do
      File.write!(tmp, "FOREMAN_SERVER_REPO_URL=postgresql://user:pass@host:5432/repo\n")

      config = [foreman_server: []]
      result = SecretsProvider.load(config, tmp)

      assert get_in(result, [:foreman_server, ForemanServer.Repo, :url]) ==
               "postgresql://user:pass@host:5432/repo"
    end

    test "unknown keys are silently ignored", %{tmp: tmp} do
      File.write!(tmp, "DATABASE_URL=postgresql://localhost/db\nUNKNOWN_KEY=should_be_ignored\n")

      config = [foreman_server: []]
      result = SecretsProvider.load(config, tmp)

      assert get_in(result, [:foreman_server, :database_url]) == "postgresql://localhost/db"
      refute Keyword.has_key?(result[:foreman_server], :unknown_key)
    end

    test "comment and blank lines are ignored", %{tmp: tmp} do
      File.write!(
        tmp,
        "# this is a comment\n\nDATABASE_URL=postgresql://localhost/db\n  \n# another\n"
      )

      config = [foreman_server: []]
      result = SecretsProvider.load(config, tmp)
      assert get_in(result, [:foreman_server, :database_url]) == "postgresql://localhost/db"
    end

    test "empty value after = is ignored", %{tmp: tmp} do
      File.write!(tmp, "DATABASE_URL=\n")
      config = [foreman_server: [database_url: "original"]]
      result = SecretsProvider.load(config, tmp)
      # empty value → parse_line returns nil → line dropped, original preserved
      assert get_in(result, [:foreman_server, :database_url]) == "original"
    end

    test "merges with existing config (existing keys preserved)", %{tmp: tmp} do
      File.write!(tmp, "DATABASE_URL=postgresql://localhost/newdb\n")
      config = [foreman_server: [database_url: "postgresql://localhost/olddb", pool_size: 10]]

      result = SecretsProvider.load(config, tmp)

      assert get_in(result, [:foreman_server, :database_url]) == "postgresql://localhost/newdb"
      assert get_in(result, [:foreman_server, :pool_size]) == 10
    end
  end

  describe "load/2 — invalid adapter raises" do
    test "invalid FOREMAN_SERVER_EVENT_STORE_ADAPTER raises" do
      tmp = Path.join(System.tmp_dir!(), "foreman_invalid_adapter_#{:rand.uniform(999_999)}.env")
      on_exit(fn -> File.rm(tmp) end)
      File.write!(tmp, "FOREMAN_SERVER_EVENT_STORE_ADAPTER=redis\n")

      assert_raise RuntimeError, ~r/invalid FOREMAN_SERVER_EVENT_STORE_ADAPTER/, fn ->
        SecretsProvider.load([foreman_server: []], tmp)
      end
    end
  end

  describe "load/2 — {:env, var} with set env" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "foreman_env_test_#{:rand.uniform(999_999)}.env")
      File.write!(tmp, "DATABASE_URL=postgresql://from_env_file/db\n")
      env_var = "FOREMAN_SERVER_SECRETS_FILE_ENV_TEST_#{:rand.uniform(999_999)}"
      System.put_env(env_var, tmp)
      on_exit(fn -> File.rm(tmp) end)
      {:ok, %{env_var: env_var, tmp: tmp}}
    end

    test "resolves env var to path and merges secrets", %{env_var: env_var} do
      result = SecretsProvider.load([foreman_server: []], {:env, env_var})
      assert get_in(result, [:foreman_server, :database_url]) == "postgresql://from_env_file/db"
    end
  end
end
