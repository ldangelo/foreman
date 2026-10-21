defmodule ForemanServer.ProjectEnvironment do
  @moduledoc """
  The ONE producer of a project's agent environment and redaction list.

  Every consumer — the workflow door (`RunExecutor.prepare_agent_launch`), the
  `Overwatch` fallback and the jobsite door — goes through `resolve/1`:

    * `env`: project vars (record `vars`, else legacy `config.env`, else legacy
      flat `config.environment`) overlaid by secret-store values. `FOREMAN_*`
      names are dropped here (the write path already rejects them) so Foreman's
      own namespace can never be shadowed.
    * `secrets`: secret-store values ++ `WorkerEnvironment.extract_secrets/1`
      over `env`, de-duplicated, never empty strings. This list feeds log
      redaction (`WorkerLogPolicy`).

  `environment/1,2` returns the full normalised record (adds `setup_script` and
  `network`). Resolution never raises: an unknown project yields an empty env;
  an unavailable secret store is logged (project id + error code only) and the
  run proceeds without the store's secrets (spike E4-SP1: fail open for reads).
  """

  require Logger

  alias ForemanServer.Aggregates.Project.Environment
  alias ForemanServer.{ProjectionStore, SecretStore, WorkerEnvironment}

  @type resolved :: %{
          env: %{optional(String.t()) => String.t()},
          secrets: [String.t()]
        }

  @doc """
  Resolve the agent env and redaction list. `opts[:project]` supplies an
  explicit project snapshot (used by tests and `WorkerEnvironment.build/2`).
  """
  @spec resolve(String.t(), keyword()) :: resolved()
  def resolve(project_id, opts \\ []) when is_binary(project_id) and is_list(opts) do
    %{"vars" => vars} = environment(project_id, opts)
    secret_pairs = secret_pairs(project_id)
    env = Map.merge(vars, secret_pairs)

    secrets =
      (Map.values(secret_pairs) ++ WorkerEnvironment.extract_secrets(env))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    %{env: env, secrets: secrets}
  end

  @doc """
  The normalised environment record for a project: the stored record, or the
  record equivalent of legacy flat env (`vars` only; no script, default network).
  """
  @spec environment(String.t(), keyword()) :: Environment.t()
  def environment(project_id, opts \\ []) when is_binary(project_id) and is_list(opts) do
    project_id
    |> project_snapshot(opts)
    |> project_config()
    |> from_config()
  end

  @doc "Environment record encoded in a project `config` map (no store access)."
  @spec from_config(term()) :: Environment.t()
  def from_config(config) do
    case fetch(config, :environment, nil) do
      record when is_map(record) ->
        if Environment.record?(record), do: from_record(record), else: legacy(config)

      _ ->
        legacy(config)
    end
  end

  @doc "True when the config holds the record form (vs. none or legacy flat env)."
  @spec record_form?(term()) :: boolean()
  def record_form?(config), do: Environment.record?(fetch(config, :environment, nil))

  @doc "Legacy flat env vars (`config.env`, else flat `config.environment`), stringified."
  @spec legacy_vars(term()) :: %{optional(String.t()) => String.t()}
  def legacy_vars(config), do: config |> legacy() |> Map.fetch!("vars")

  defp from_record(record) do
    network = fetch(record, :network, nil)
    script = fetch(record, :setup_script, nil)

    %{
      "vars" => record |> fetch(:vars, %{}) |> stringify() |> drop_reserved(),
      "setup_script" => if(is_binary(script) and String.trim(script) != "", do: script),
      "network" => %{
        "mode" => network |> fetch(:mode, "default") |> to_string(),
        "hosts" => network |> fetch(:hosts, []) |> List.wrap() |> Enum.map(&to_string/1)
      }
    }
  end

  defp legacy(config) do
    vars =
      config
      |> fetch(:env, fetch(config, :environment, %{}))
      |> stringify()
      |> drop_reserved()

    %{Environment.default() | "vars" => vars}
  end

  defp drop_reserved(vars),
    do: Map.reject(vars, fn {k, _v} -> String.starts_with?(k, "FOREMAN_") end)

  defp secret_pairs(project_id) do
    case SecretStore.pairs(project_id) do
      {:ok, pairs} ->
        Map.reject(pairs, fn {name, value} ->
          not is_binary(value) or value == "" or String.starts_with?(name, "FOREMAN_")
        end)

      {:error, error} ->
        Logger.warning(
          "ProjectEnvironment: secret store unavailable for project #{inspect(project_id)} " <>
            "(#{error.code}); launching without stored secrets"
        )

        %{}
    end
  end

  defp project_snapshot(project_id, opts) do
    case Keyword.fetch(opts, :project) do
      {:ok, project} -> project
      :error -> ProjectionStore.project(project_id) || application_project(project_id)
    end
  end

  defp project_config(nil), do: %{}
  defp project_config(project), do: fetch(project, :config, %{})

  defp application_project(project_id) do
    scoped_config = Application.get_env(:foreman_server, WorkerEnvironment, [])
    fallback_config = Application.get_env(:foreman_server, :worker_environment, %{})

    scoped_projects = fetch(scoped_config, :projects, %{})
    fallback_projects = fetch(fallback_config, :projects, fallback_config)

    %{config: fetch(scoped_projects, project_id, fetch(fallback_projects, project_id, %{}))}
  end

  defp stringify(env) when is_map(env), do: stringify_pairs(Map.to_list(env), %{})
  defp stringify(env) when is_list(env), do: stringify_pairs(env, %{})
  defp stringify(_env), do: %{}

  defp stringify_pairs([], acc), do: acc
  defp stringify_pairs([{_key, nil} | rest], acc), do: stringify_pairs(rest, acc)

  defp stringify_pairs([{key, value} | rest], acc),
    do: stringify_pairs(rest, Map.put(acc, to_string(key), to_string(value)))

  defp stringify_pairs([_other | rest], acc), do: stringify_pairs(rest, acc)

  defp fetch(data, key, default) when is_list(data) and is_atom(key) do
    case List.keyfind(data, key, 0) || List.keyfind(data, Atom.to_string(key), 0) do
      {_, value} -> if(is_nil(value), do: default, else: value)
      nil -> default
    end
  end

  defp fetch(%{} = data, key, default) when is_atom(key) do
    case Map.get(data, key, Map.get(data, Atom.to_string(key))) do
      nil -> default
      value -> value
    end
  end

  defp fetch(%{} = data, key, default) when is_binary(key),
    do: Map.get(data, key, default)

  defp fetch(_data, _key, default), do: default
end
