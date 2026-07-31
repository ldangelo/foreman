defmodule ForemanServer.WorkerEnvironment do
  @moduledoc "Prepares scoped worker environment variables without leaking forbidden host secrets."
  alias ForemanServer.ProjectStore

  @forbidden_exact MapSet.new(~w(
    AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    DATABASE_URL FOREMAN_SERVER_AUTH_TOKEN GITHUB_TOKEN GIT_ASKPASS
    NPM_TOKEN SSH_AGENT_PID SSH_AUTH_SOCK
  ))

  @forbidden_prefixes ["AWS_", "GITHUB_", "NPM_", "SSH_", "DATABASE_"]

  @spec prepare(map()) :: {:ok, map()} | {:error, term()}
  def prepare(input) when is_map(input) do
    with {:ok, project_id} <- required_binary(get(input, :project_id), :project_id),
         {:ok, run_id} <- required_binary(get(input, :run_id), :run_id),
         {:ok, env} <- string_map(get(input, :env, %{}), :env),
         {:ok, project_secrets} <-
           string_map(get(input, :project_secrets, %{}), :project_secrets),
         {:ok, run_secrets} <- string_map(get(input, :run_secrets, %{}), :run_secrets) do
      prepared =
        env
        |> strip_forbidden()
        |> Map.merge(strip_forbidden(project_secrets))
        |> Map.merge(strip_forbidden(run_secrets))
        |> Map.put("FOREMAN_PROJECT_ID", project_id)
        |> Map.put("FOREMAN_RUN_ID", run_id)

      {:ok,
       %{
         env: prepared,
         stripped: stripped_keys(env, project_secrets, run_secrets),
         scoped_secret_keys: %{
           project: scoped_keys(project_secrets),
           run: scoped_keys(run_secrets)
         }
       }}
    end
  end
  def prepare(_input), do: {:error, {:missing_or_invalid, :environment}}

  @doc """
  Builds the worker env map for a launched process by sourcing the project's
  registered config from ProjectStore and piping it through `prepare/1`.

  `overrides` are merged last so callers (e.g. task-level env) take precedence
  over project defaults without mutating stored config.

  Returns `{:ok, env_map}` on success; `{:error, reason}` if the project is
  not found or the resulting env fails validation.
  """
  @spec build_env_map(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def build_env_map(project_id, run_id, overrides \\ %{}) when is_binary(project_id) and is_binary(run_id) and is_map(overrides) do
    case ProjectStore.get(project_id) do
      nil ->
        {:error, {:not_found, :project, project_id}}

      %{config: config} when is_map(config) ->
        with {:ok, project_env} <- string_map(get(config, :env, %{}), :env),
             {:ok, project_secrets} <- string_map(get(config, :project_secrets, %{}), :project_secrets),
             {:ok, run_secrets} <- string_map(get(config, :run_secrets, %{}), :run_secrets),
             {:ok, validated_overrides} <- string_map(overrides, :overrides) do
          merged_env = Map.merge(project_env, validated_overrides)

          case prepare(%{
                 project_id: project_id,
                 run_id: run_id,
                 env: merged_env,
                 project_secrets: project_secrets,
                 run_secrets: run_secrets
               }) do
            {:ok, prepared} -> {:ok, prepared.env}
            {:error, _} = error -> error
          end
        else
          {:error, _} = error -> error
        end

      _ ->
        {:error, {:not_found, :project, project_id}}
    end
  end

  @spec forbidden_key?(String.t()) :: boolean()
  def forbidden_key?(key) when is_binary(key) do
    MapSet.member?(@forbidden_exact, key) or
      Enum.any?(@forbidden_prefixes, &String.starts_with?(key, &1))
  end

  def forbidden_key?(_key), do: true

  defp get(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp strip_forbidden(env) do
    Map.reject(env, fn {key, _value} -> forbidden_key?(key) end)
  end

  defp scoped_keys(secrets) do
    secrets
    |> strip_forbidden()
    |> Map.keys()
    |> Enum.sort()
  end

  defp stripped_keys(collections) do
    collections
    |> Enum.flat_map(fn env ->
      env
      |> Map.keys()
      |> Enum.filter(&forbidden_key?/1)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp stripped_keys(env, project_secrets, run_secrets),
    do: stripped_keys([env, project_secrets, run_secrets])

  defp string_map(nil, _key), do: {:ok, %{}}

  defp string_map(map, _key) when is_map(map) do
    valid? = Enum.all?(map, fn {key, value} -> is_binary(key) and is_binary(value) end)
    if valid?, do: {:ok, map}, else: {:error, {:missing_or_invalid, :env}}
  end

  defp string_map(_value, key), do: {:error, {:missing_or_invalid, key}}

  defp required_binary(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary(_value, key), do: {:error, {:missing_or_invalid, key}}
end
