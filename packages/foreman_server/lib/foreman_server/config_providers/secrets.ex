defmodule ForemanServer.ConfigProviders.Secrets do
  @moduledoc """
  Release `Config.Provider` that sources secrets from the 1Password CLI
  or a release-local `.env` file before the application starts.
  Configured in `config/prod.exs` as `:prod_secret_provider`.

  Source resolution (controlled by `FOREMAN_SERVER_SECRET_SOURCE`,
  default `"auto"`):

    * `:auto`        — 1Password CLI if available, else release-local `.env`.
    * `:op` / `:"1password"` — 1Password CLI only.
    * `:env_file`    — release-local `.env` only.

  ## TRD policy note (TRD-024)

  The slice TRD ("Quality Requirements → Security") states:

    > Secrets in prod: `Vault`, `AWS Secrets Manager`, or equivalent.
    > Env vars only in dev/test.

  Today this provider implements only the dev/test path (env vars via
  release-local `.env` or the `op` CLI). It is currently wired into
  `config/prod.exs` as the prod provider.

  Centralized-secrets-manager integration (Vault, AWS Secrets Manager,
  or equivalent) is not implemented; this provider has no `:vault` /
  `:aws_sm` source today.


  """

  @behaviour Config.Provider

  @type mapping :: [
          app: atom(),
          key: atom() | module(),
          config_key: atom(),
          env: String.t(),
          secret_key: atom(),
          required: boolean(),
          op_ref: String.t() | nil
        ]

  @impl true
  @spec init(keyword()) :: {:ok, keyword()}
  def init(opts) do
    provider_opts =
      :foreman_server
      |> Application.get_env(:prod_secret_provider, [])
      |> Keyword.merge(opts)

    mappings = provider_opts |> Keyword.get(:mappings, []) |> Enum.map(&normalize_mapping/1)
    source = Keyword.get(provider_opts, :source, "auto")

    state =
      [mappings: mappings, source: source]
      |> put_if_present(:env_file, Keyword.get(provider_opts, :env_file))

    {:ok, state}
  end

  @impl true
  @spec load(keyword(), {:ok, keyword()} | keyword()) :: keyword()
  def load(config, {:ok, state}), do: load(config, state)

  def load(config, state) do
    mappings = Keyword.fetch!(state, :mappings)
    env_file = Keyword.get(state, :env_file, default_env_file())
    source = resolve_source(Keyword.get(state, :source, "auto"), mappings)

    secrets =
      mappings
      |> Enum.map(fn mapping ->
        {Keyword.fetch!(mapping, :secret_key), read_value(mapping, source, env_file)}
      end)
      |> Map.new()

    overrides =
      Enum.reduce(mappings, [], fn mapping, acc ->
        secret_key = Keyword.fetch!(mapping, :secret_key)

        case Map.fetch(secrets, secret_key) do
          {:ok, value} when is_binary(value) ->
            Config.Reader.merge(acc, mapping_override(mapping, value))

          _ ->
            acc
        end
      end)

    Config.Reader.merge(config, overrides)
  end

  defp normalize_mapping(mapping) do
    env_name = Keyword.fetch!(mapping, :env)

    mapping
    |> Keyword.put_new(:secret_key, env_name |> String.downcase() |> String.to_atom())
    |> Keyword.put_new(:required, true)
    |> Keyword.put_new(:op_ref, System.get_env("#{env_name}_OP_REF"))
  end

  defp resolve_source(source, mappings) when source in [:auto, "auto"] do
    if op_available?() and Enum.any?(mappings, &Keyword.get(&1, :op_ref)) do
      :op
    else
      :env_file
    end
  end

  defp resolve_source(source, _mappings)
       when source in [:op, "op", :one_password, "one_password"] do
    if op_available?() do
      :op
    else
      raise ArgumentError, "1Password CLI requested but `op` is not available on PATH"
    end
  end

  defp resolve_source(source, _mappings)
       when source in [:env, "env", :env_file, "env_file", :dotenv, "dotenv"] do
    :env_file
  end

  defp read_value(mapping, :op, env_file) do
    case read_from_op(mapping) do
      {:ok, value} -> value
      :error -> read_from_env_file(mapping, env_file)
    end
  end

  defp read_value(mapping, :env_file, env_file), do: read_from_env_file(mapping, env_file)

  defp read_from_op(mapping) do
    with op_ref when is_binary(op_ref) <- Keyword.get(mapping, :op_ref),
         op_ref when op_ref != "" <- String.trim(op_ref),
         {value, 0} <- System.cmd("op", ["read", op_ref], stderr_to_stdout: true) do
      {:ok, String.trim(value)}
    else
      _ -> :error
    end
  end

  defp read_from_env_file(mapping, env_file) do
    env_name = Keyword.fetch!(mapping, :env)
    required? = Keyword.fetch!(mapping, :required)

    value =
      env_file
      |> parse_env_file()
      |> Map.get(env_name)
      |> case do
        nil -> System.get_env(env_name)
        env_value -> env_value
      end

    cond do
      is_binary(value) and value != "" -> value
      required? -> raise ArgumentError, missing_secret_message(env_name, env_file)
      true -> nil
    end
  end

  defp parse_env_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.reduce(%{}, fn line, acc ->
          case parse_env_line(line) do
            {key, value} -> Map.put(acc, key, value)
            nil -> acc
          end
        end)

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read env file", path: path
    end
  end

  defp parse_env_line(line) do
    line = String.trim(line)

    cond do
      line == "" or String.starts_with?(line, "#") ->
        nil

      true ->
        case String.split(line, "=", parts: 2) do
          [key, value] ->
            key = key |> String.trim() |> String.trim_leading("export ")
            value = value |> String.trim() |> strip_quotes()
            {key, value}

          _ ->
            nil
        end
    end
  end

  defp strip_quotes(value) do
    if String.length(value) >= 2 do
      case {String.first(value), String.last(value)} do
        {quote, quote} when quote in ["\"", "'"] ->
          String.slice(value, 1, String.length(value) - 2)

        _ ->
          value
      end
    else
      value
    end
  end

  defp put_if_present(keyword, _key, nil), do: keyword
  defp put_if_present(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp mapping_override(mapping, value) do
    app = Keyword.fetch!(mapping, :app)
    key = Keyword.fetch!(mapping, :key)
    config_key = Keyword.fetch!(mapping, :config_key)

    cond do
      Keyword.get(mapping, :nested) ->
        [{app, [{key, [{Keyword.fetch!(mapping, :nested), [{config_key, value}]}]}]}]

      config_key == nil ->
        # Plain value: config :app, :key, "value"
        [{app, [{key, value}]}]

      true ->
        [{app, [{key, [{config_key, value}]}]}]
    end
  end

  defp missing_secret_message(env_name, env_file) do
    "Missing required secret: #{env_name} (checked env file: #{env_file})"
  end

  defp default_env_file do
    release_root = System.get_env("RELEASE_ROOT") || File.cwd!()
    Path.join(release_root, ".env")
  end

  defp op_available?, do: System.find_executable("op") != nil
end
