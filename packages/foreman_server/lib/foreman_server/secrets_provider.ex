defmodule ForemanServer.SecretsProvider do
  @moduledoc """
  #{__MODULE__} merges secrets from a `.env`-style file into the application
  config tree at release boot, on top of app and environment config.

  Only a fixed allowlist of keys is accepted — no arbitrary file writes or
  shell expansion.

  ## Provider wiring (mix.exs)

      releases: [
        foreman_server: [
          config_providers: [
            {#{inspect(__MODULE__)}, {:env, "FOREMAN_SERVER_SECRETS_FILE"}}
          ]
        ]
      ]

  The provider resolves `FOREMAN_SERVER_SECRETS_FILE` at runtime (release boot).
  If the env var is unset or empty, the provider is a no-op.

  ## Secrets file format

      DATABASE_URL=postgresql://user:pass@host:5432/foreman
      FOREMAN_SERVER_EVENT_STORE_ADAPTER=postgres
      FOREMAN_SERVER_REPO_URL=postgresql://user:pass@host:5432/foreman

  Each line `KEY=VALUE` is parsed as-is (no shell expansion, no here-docs).
  Lines starting with `#` or empty lines are ignored.
  """

  @behaviour Config.Provider

  # Allowlist: secrets file key → {app, key_atom}
  @mappings %{
    "DATABASE_URL" => {:foreman_server, :database_url},
    "FOREMAN_SERVER_EVENT_STORE_ADAPTER" => {:foreman_server, :event_store_adapter},
    "FOREMAN_SERVER_REPO_URL" => {:foreman_server, ForemanServer.Repo, :url}
  }

  @impl true
  def init({:env, var}) when is_binary(var), do: {:env, var}
  def init(path) when is_binary(path), do: path

  @impl true
  def load(config, {:env, var}) do
    load(config, System.get_env(var))
  end

  def load(config, nil), do: config
  def load(config, ""), do: config

  def load(config, path) do
    secrets = read_secrets(path)
    merge_secrets(config, secrets)
  end

  defp read_secrets(path) do
    if File.regular?(path) do
      path
      |> File.stream!()
      |> Stream.filter(&(&1 != "\n" and not String.starts_with?(&1, "#")))
      |> Stream.map(&String.trim/1)
      |> Stream.filter(&(&1 != ""))
      |> Enum.map(&parse_line/1)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  defp parse_line(line) do
    case :binary.split(line, "=") do
      [_key, ""] -> nil
      [key, value] -> {key, value}
      _ -> nil
    end
  end

  defp merge_secrets(config, secrets) do
    Enum.reduce(secrets, config, fn {key, value}, acc ->
      case Map.fetch(@mappings, key) do
        {:ok, {app, app_key}} ->
          fragment = [{app, [{app_key, transform_value(app_key, value)}]}]
          Config.Reader.merge(acc, fragment)

        {:ok, {app, repo, repo_key}} ->
          # Build a properly-structured config fragment for the Repo 2-tuple
          fragment = [{app, [{repo, [{repo_key, value}]}]}]
          Config.Reader.merge(acc, fragment)

        :error ->
          acc
      end
    end)
  end

  # Validate and convert known string keys to atoms where needed.
  # Invalid values for unknown keys pass through as-is (they have no spec).
  defp transform_value(:event_store_adapter, value) do
    case value do
      "postgres" -> :postgres
      "term" -> :term
      _ -> raise "invalid FOREMAN_SERVER_EVENT_STORE_ADAPTER: #{value}"
    end
  end

  defp transform_value(_key, value), do: value
end
