defmodule ForemanServer.ConfigProviders.Secrets do
  @moduledoc """
  Minimal `Config.Provider` stub for production secret loading.

  Secrets via `System.fetch_env!/1` in dev/test; via Config.Provider secrets
  manager (Vault, AWS SM) in prod.
  """

  @behaviour Config.Provider

  @type mapping :: [app: atom(), key: atom() | module(), config_key: atom(), env: String.t()]
  @type state :: [source: String.t(), mappings: [mapping()]]

  @impl true
  @spec init(keyword()) :: state()
  def init(opts) do
    source = Keyword.get(opts, :source, "env")
    mappings = Keyword.get(opts, :mappings, [])
    [source: source, mappings: mappings]
  end

  @impl true
  @spec load(keyword(), state()) :: keyword()
  def load(config, opts) do
    overrides =
      opts
      |> Keyword.get(:mappings, [])
      |> Enum.reduce([], fn mapping, acc ->
        Config.Reader.merge(acc, mapping_override(mapping, opts))
      end)

    Config.Reader.merge(config, overrides)
  end

  defp mapping_override(mapping, opts) do
    app = Keyword.fetch!(mapping, :app)
    key = Keyword.fetch!(mapping, :key)
    config_key = Keyword.fetch!(mapping, :config_key)
    env_name = Keyword.fetch!(mapping, :env)

    value = read_secret(env_name, Keyword.get(opts, :source, "env"))

    [{app, [{key, [{config_key, value}]}]}]
  end

  defp read_secret(env_name, source) when source in ["vault", "aws_sm", "aws_secrets_manager"] do
    # Production stub: a real adapter would fetch from the configured secret
    # manager here before falling back to a release-provided environment value.
    System.fetch_env!(env_name)
  end

  defp read_secret(env_name, _source) do
    System.fetch_env!(env_name)
  end
end
