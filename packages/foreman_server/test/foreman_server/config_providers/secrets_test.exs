defmodule ForemanServer.ConfigProviders.SecretsTest do
  use ExUnit.Case, async: false

  alias ForemanServer.ConfigProviders.Secrets

  test "init/1 preserves provider state and load/2 resolves secrets from a release-local env file" do
    tmp_dir = Path.join(System.tmp_dir!(), "foreman-secrets-#{System.unique_integer([:positive])}")
    env_file = Path.join(tmp_dir, ".env")

    File.mkdir_p!(tmp_dir)

    File.write!(
      env_file,
      """
      EVENTSTORE_URL=postgres://postgres:postgres@localhost:55432/foreman_eventstore_prod
      DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_prod
      DATABASE_PASSWORD=swordfish
      SECRET_KEY_BASE=super-secret-key-base
      SIGNING_SALT=salty
      """
    )

    provider_opts = [
      source: "env_file",
      env_file: env_file,
      mappings: [
        [app: :foreman_server, key: ForemanServer.EventStore, config_key: :url, env: "EVENTSTORE_URL", secret_key: :eventstore_url],
        [app: :foreman_server, key: ForemanServer.Repo, config_key: :url, env: "DATABASE_URL", secret_key: :database_url],
        [app: :foreman_server, key: ForemanServerWeb.Endpoint, config_key: :secret_key_base, env: "SECRET_KEY_BASE", secret_key: :secret_key_base],
        [app: :foreman_server, key: ForemanServerWeb.Endpoint, config_key: :signing_salt, env: "SIGNING_SALT", secret_key: :signing_salt, nested: :live_view]
      ]
    ]

    original_endpoint = Application.get_env(:foreman_server, ForemanServerWeb.Endpoint)
    endpoint_overrides = Application.get_env(:foreman_server, ForemanServerWeb.Endpoint, [])
    Application.delete_env(:foreman_server, ForemanServerWeb.Endpoint)
    on_exit(fn ->
      Application.put_env(:foreman_server, ForemanServerWeb.Endpoint, original_endpoint || endpoint_overrides)
    end)

    original = Application.get_env(:foreman_server, :prod_secret_provider)
    Application.put_env(:foreman_server, :prod_secret_provider, provider_opts)

    on_exit(fn ->
      if original == nil do
        Application.delete_env(:foreman_server, :prod_secret_provider)
      else
        Application.put_env(:foreman_server, :prod_secret_provider, original)
      end

      File.rm_rf(tmp_dir)
    end)

    state = Secrets.init([])

    assert {:ok, init_state} = state
    assert Keyword.fetch!(init_state, :env_file) == env_file
    assert Keyword.fetch!(init_state, :source) == "env_file"

    mappings = Keyword.fetch!(init_state, :mappings)
    assert Enum.map(mappings, &Keyword.fetch!(&1, :secret_key)) == [
             :eventstore_url,
             :database_url,
             :secret_key_base,
             :signing_salt
           ]

    merged = Secrets.load([foreman_server: []], state)
    foreman_config = Keyword.fetch!(merged, :foreman_server)

    assert Keyword.get(foreman_config, ForemanServer.EventStore)[:url] =~ "foreman_eventstore_prod"
    assert Keyword.get(foreman_config, ForemanServer.Repo)[:url] =~ "foreman_prod"
    endpoint_config = Keyword.get(foreman_config, ForemanServerWeb.Endpoint, [])
    assert endpoint_config[:secret_key_base] == "super-secret-key-base"
    assert get_in(endpoint_config, [:live_view, :signing_salt]) == "salty"
  end
end
