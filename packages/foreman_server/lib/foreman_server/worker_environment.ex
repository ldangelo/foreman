defmodule ForemanServer.WorkerEnvironment do
  @moduledoc "Prepares scoped worker environment variables without leaking forbidden host secrets."

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
