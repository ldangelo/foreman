defmodule ForemanServer.Aggregates.Project.Environment do
  @moduledoc """
  The per-project environment record and its single validator/normaliser.

  Stored under `config["environment"]` of a project as

      %{"vars" => %{NAME => value}, "setup_script" => String.t() | nil,
        "network" => %{"mode" => "default" | "none" | "allowlist", "hosts" => [String.t()]}}

  Written ONLY by the operator-allowlisted `project.environment.set` command
  (`ForemanServer.Aggregates.Project`): `setup_script` is arbitrary code run on
  the server host, so `project.update` (which E15's coordinator uses) rejects
  the `environment` key. Secrets never live here: secret-looking var names are
  rejected with `{:secret_in_vars, name}` and belong in `ForemanServer.SecretStore`.

  `normalize/1` accepts atom or string keys at the boundary and returns the
  string-keyed record; every failure is a distinct tuple:
  `{:invalid_env_name, n}`, `{:reserved_env_name, n}`, `{:secret_in_vars, n}`,
  `{:env_value_invalid, n}`, `{:env_value_too_long, n}`, `{:too_many_env_vars, count}`,
  `{:setup_script_invalid, term}`, `{:setup_script_too_long, bytes}`,
  `{:invalid_network_mode, m}`, `{:invalid_network_host, h}`,
  `{:too_many_network_hosts, count}`, `{:invalid_network, term}`,
  `{:invalid_environment, term}`, `{:unknown_environment_key, k}`.
  """

  @max_vars 100
  @max_value_bytes 8 * 1024
  @max_script_bytes 16 * 1024
  @max_hosts 100
  @modes ~w(default none allowlist)
  @record_keys ~w(vars setup_script network)
  @name_pattern ~r/\A[A-Za-z][A-Za-z0-9_]*\z/
  @host_pattern ~r/\A[a-z0-9.*-]+\z/

  # Env var names that conventionally hold secrets (ENCRYPTION_KEY, GITHUB_TOKEN,
  # OPENAI_API_KEY, AWS_SECRET_ACCESS_KEY, ...). Shared with log redaction in
  # `ForemanServer.WorkerEnvironment.extract_secrets/1`.
  @secret_key_pattern ~r/(?i)(?:^|_)(?:api[_-]?key|token|password|secret|encryption_key|signing_key|master_key|private[_-]?key|bearer|credential|passphrase|client[_-]?secret|auth[_-]?token|access[_-]?token)(?:_|$)/

  @type network :: %{String.t() => String.t() | [String.t()]}
  @type t :: %{String.t() => term()}

  @doc "Keys that identify a map as the record form (vs. legacy flat env)."
  @spec record_keys() :: [String.t()]
  def record_keys, do: @record_keys

  @doc "True when `map` has any record key (string or atom)."
  @spec record?(term()) :: boolean()
  def record?(map) when is_map(map) do
    Enum.any?(map, fn {k, _} -> to_string(k) in @record_keys end)
  end

  def record?(_), do: false

  @doc "Closed set of network modes."
  @spec network_modes() :: [String.t()]
  def network_modes, do: @modes

  @doc "True when an env var name looks like it holds a secret."
  @spec secret_name?(term()) :: boolean()
  def secret_name?(name) when is_binary(name), do: name =~ @secret_key_pattern
  def secret_name?(_), do: false

  @doc "The record every project without one effectively has."
  @spec default() :: t()
  def default,
    do: %{
      "vars" => %{},
      "setup_script" => nil,
      "network" => %{"mode" => "default", "hosts" => []}
    }

  @doc """
  Validates and normalises a raw environment record. Missing keys take their
  defaults; any key outside `vars`, `setup_script`, `network` is an error.
  """
  @spec normalize(term()) :: {:ok, t()} | {:error, term()}
  def normalize(raw) when is_map(raw) do
    raw = Map.new(raw, fn {k, v} -> {to_string(k), v} end)

    with :ok <- check_keys(raw),
         {:ok, vars} <- normalize_vars(Map.get(raw, "vars", %{})),
         {:ok, script} <- normalize_script(Map.get(raw, "setup_script")),
         {:ok, network} <- normalize_network(Map.get(raw, "network")) do
      {:ok, %{"vars" => vars, "setup_script" => script, "network" => network}}
    end
  end

  def normalize(other), do: {:error, {:invalid_environment, other}}

  defp check_keys(raw) do
    case Enum.find(Map.keys(raw), &(&1 not in @record_keys)) do
      nil -> :ok
      key -> {:error, {:unknown_environment_key, key}}
    end
  end

  defp normalize_vars(nil), do: {:ok, %{}}

  defp normalize_vars(vars) when is_map(vars) do
    if map_size(vars) > @max_vars do
      {:error, {:too_many_env_vars, map_size(vars)}}
    else
      vars
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
        name = to_string(key)

        case normalize_var(name, value) do
          {:ok, string} -> {:cont, {:ok, Map.put(acc, name, string)}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp normalize_vars(other), do: {:error, {:invalid_environment, {:vars, other}}}

  defp normalize_var(name, value) do
    cond do
      not Regex.match?(@name_pattern, name) ->
        {:error, {:invalid_env_name, name}}

      String.starts_with?(name, "FOREMAN_") ->
        {:error, {:reserved_env_name, name}}

      secret_name?(name) ->
        {:error, {:secret_in_vars, name}}

      not (is_binary(value) or is_number(value) or is_boolean(value)) ->
        {:error, {:env_value_invalid, name}}

      byte_size(to_string(value)) > @max_value_bytes ->
        {:error, {:env_value_too_long, name}}

      true ->
        {:ok, to_string(value)}
    end
  end

  defp normalize_script(nil), do: {:ok, nil}

  defp normalize_script(script) when is_binary(script) do
    cond do
      String.trim(script) == "" ->
        {:ok, nil}

      byte_size(script) > @max_script_bytes ->
        {:error, {:setup_script_too_long, byte_size(script)}}

      String.contains?(script, <<0>>) ->
        {:error, {:setup_script_invalid, :nul_byte}}

      true ->
        {:ok, script}
    end
  end

  defp normalize_script(other), do: {:error, {:setup_script_invalid, other}}

  defp normalize_network(nil), do: {:ok, %{"mode" => "default", "hosts" => []}}

  defp normalize_network(network) when is_map(network) do
    network = Map.new(network, fn {k, v} -> {to_string(k), v} end)
    mode = Map.get(network, "mode", "default")
    hosts = Map.get(network, "hosts", [])

    with :ok <- check_network_keys(network),
         {:ok, mode} <- check_mode(mode),
         {:ok, hosts} <- check_hosts(hosts) do
      {:ok, %{"mode" => mode, "hosts" => hosts}}
    end
  end

  defp normalize_network(other), do: {:error, {:invalid_network, other}}

  defp check_network_keys(network) do
    case Enum.find(Map.keys(network), &(&1 not in ["mode", "hosts"])) do
      nil -> :ok
      key -> {:error, {:invalid_network, {:unknown_key, key}}}
    end
  end

  defp check_mode(mode) when mode in @modes, do: {:ok, mode}
  defp check_mode(mode), do: {:error, {:invalid_network_mode, mode}}

  defp check_hosts(hosts) when is_list(hosts) do
    if length(hosts) > @max_hosts do
      {:error, {:too_many_network_hosts, length(hosts)}}
    else
      hosts
      |> Enum.reduce_while({:ok, []}, fn host, {:ok, acc} ->
        if is_binary(host) and Regex.match?(@host_pattern, host),
          do: {:cont, {:ok, [host | acc]}},
          else: {:halt, {:error, {:invalid_network_host, host}}}
      end)
      |> case do
        {:ok, list} -> {:ok, list |> Enum.reverse() |> Enum.uniq()}
        error -> error
      end
    end
  end

  defp check_hosts(other), do: {:error, {:invalid_network_host, other}}
end
