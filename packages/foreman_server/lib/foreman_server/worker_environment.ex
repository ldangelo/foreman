defmodule ForemanServer.WorkerEnvironment do
  @moduledoc """
  Builds immutable worker environment snapshots from the registered project config.
  """

  alias ForemanServer.ProjectionStore

  @type env_map :: %{optional(String.t()) => String.t()}

  @spec build(String.t(), keyword()) :: env_map()
  def build(project_id, opts \\ []) when is_binary(project_id) and is_list(opts) do
    project_id
    |> project_snapshot(opts)
    |> extract_env_map()
  end

  @spec build_env_map(String.t()) :: env_map()
  def build_env_map(project_id) when is_binary(project_id), do: build(project_id, [])

  @spec refresh_on_relaunch(String.t(), env_map()) :: env_map()
  def refresh_on_relaunch(project_id, _current_env) when is_binary(project_id) do
    build_env_map(project_id)
  end

  defp project_snapshot(project_id, opts) do
    case Keyword.fetch(opts, :project) do
      {:ok, project} -> project
      :error -> ProjectionStore.project(project_id) || application_project(project_id)
    end
  end

  defp application_project(project_id) do
    %{config: application_project_config(project_id)}
  end

  defp application_project_config(project_id) do
    scoped_config = Application.get_env(:foreman_server, __MODULE__, [])
    fallback_config = Application.get_env(:foreman_server, :worker_environment, %{})

    scoped_projects = fetch(scoped_config, :projects, %{})
    fallback_projects = fetch(fallback_config, :projects, fallback_config)

    fetch(scoped_projects, project_id, fetch(fallback_projects, project_id, %{}))
  end

  defp extract_env_map(nil), do: %{}

  defp extract_env_map(project) do
    project
    |> fetch(:config, %{})
    |> extract_env_config()
    |> stringify_env()
  end

  defp extract_env_config(config) when is_map(config) or is_list(config) do
    fetch(config, :env, fetch(config, :environment, %{}))
  end

  defp extract_env_config(_config), do: %{}

  defp stringify_env(env) when is_map(env), do: stringify_pairs(Map.to_list(env), %{})
  defp stringify_env(env) when is_list(env), do: stringify_pairs(env, %{})
  defp stringify_env(_env), do: %{}

  defp stringify_pairs([], acc), do: acc

  defp stringify_pairs([{_key, nil} | rest], acc), do: stringify_pairs(rest, acc)

  defp stringify_pairs([{key, value} | rest], acc) do
    stringify_pairs(rest, Map.put(acc, to_string(key), to_string(value)))
  end

  defp fetch(data, key, default) when is_list(data) and is_atom(key) do
    case List.keyfind(data, key, 0) || List.keyfind(data, Atom.to_string(key), 0) do
      {_, value} -> value
      nil -> default
    end
  end

  defp fetch(%{} = data, key, default) when is_atom(key) do
    Map.get(data, key, Map.get(data, Atom.to_string(key), default))
  end

  defp fetch(%{} = data, key, default), do: Map.get(data, key, default)
  defp fetch(_data, _key, default), do: default

  # Matches env var names that conventionally hold secrets, including namespaced forms
  # (ENCRYPTION_KEY, SIGNING_KEY, MASTER_KEY, GITHUB_TOKEN, OPENAI_API_KEY, etc.)
  # like OPENAI_API_KEY, GITHUB_TOKEN, AWS_SECRET_ACCESS_KEY.
  # Group 1 captures the value portion (e.g. "TOKEN" in "GITHUB_TOKEN").
  @secret_key_pattern ~r/(?i)(?:^|_)(?:api[_-]?key|token|password|secret|encryption_key|signing_key|master_key|private[_-]?key|bearer|credential|passphrase|client[_-]?secret|auth[_-]?token|access[_-]?token)(?:_|$)/

  @doc """
  Extract secret values from an env map for log redaction.

  Values whose keys match the known secret-name pattern are returned as a
  list.  An empty list is returned when no matching keys are present.
  """
  @spec extract_secrets(env_map()) :: [String.t()]
  def extract_secrets(env) when is_map(env) do
    env
    |> Enum.reject(fn {k, _v} -> is_atom(k) end)
    |> Enum.flat_map(fn
      {k, v} when is_binary(v) and v != "" ->
        if k =~ @secret_key_pattern, do: [v], else: []

      _ ->
        []
    end)
  end

  def extract_secrets(_), do: []

end

