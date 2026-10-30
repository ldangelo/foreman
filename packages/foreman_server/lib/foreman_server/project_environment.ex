defmodule ForemanServer.ProjectEnvironment do
  @moduledoc """
  The ONE producer of a project's agent environment and redaction list.

  Every consumer — the workflow door (`RunExecutor.prepare_agent_launch`), the
  `Overwatch` fallback and the jobsite door — goes through `resolve/1`:

    * `env`: project vars (record `vars`, else legacy `config.env`, else legacy
      flat `config.environment`) overlaid by secret-store values. `FOREMAN_*` is
      Foreman's own namespace: the write path rejects such names, and a stored one
      (legacy config) makes `resolve/2` return
      `{:error, {:reserved_project_env_keys, sorted_keys}}` so the phase or jobsite
      fails LOUDLY rather than launching with a plausible but unverified value.
    * `secrets`: secret-store values ++ `WorkerEnvironment.extract_secrets/1`
      over `env`, de-duplicated, never empty strings. This list feeds log
      redaction (`WorkerLogPolicy`).

  `secrets/1` is that list on its own: the one every text persisted or derived about a project
  is redacted with (the standing context, project memory, the coordinator conversation, its
  recorded actions and turn failures, question and approval summaries, thread transcripts and
  PR-fix prompts; the persist paths that must not raise resolve it through
  `ForemanServer.Coordinator.Redact.secrets/1`). A name pattern never decides alone: a value
  stored as `DB_URL` is a secret too, unless it is shorter than `min_stored_secret_chars/0`
  (a 1-character value would corrupt the text).

  `environment/1,2` returns the full normalised record (adds `setup_script` and
  `network`). Resolution never raises: an unknown project yields an empty env;
  an unavailable secret store is logged (project id + error code only) and the
  run proceeds without the store's secrets (spike E4-SP1: fail open for reads).
  """

  require Logger

  alias ForemanServer.Aggregates.Project.Environment
  alias ForemanServer.{ProjectionStore, SecretStore, WorkerEnvironment}

  @min_stored_secret_chars 8

  @type resolved :: %{
          env: %{optional(String.t()) => String.t()},
          secrets: [String.t()]
        }
  @type resolve_error :: {:reserved_project_env_keys, [String.t()]}

  @doc """
  Resolve the agent env and redaction list. `opts[:project]` supplies an
  explicit project snapshot (used by tests and `WorkerEnvironment.build/2`).
  """
  @spec resolve(String.t(), keyword()) :: {:ok, resolved()} | {:error, resolve_error()}
  def resolve(project_id, opts \\ []) when is_binary(project_id) and is_list(opts) do
    with {:ok, env, stored, named} <- resolve_parts(project_id, opts) do
      {:ok, %{env: env, secrets: dedupe(stored ++ named)}}
    end
  end

  defp resolve_parts(project_id, opts) do
    %{"vars" => vars} = environment(project_id, opts)

    case reserved_keys(vars) do
      [] ->
        secret_pairs = secret_pairs(project_id)
        env = Map.merge(vars, secret_pairs)
        {:ok, env, Map.values(secret_pairs), WorkerEnvironment.extract_secrets(env)}

      keys ->
        {:error, {:reserved_project_env_keys, keys}}
    end
  end

  # The one choke point every redaction list passes through (`resolve/2`, `fetch_secrets/1`,
  # hence `secrets/1`). Redactors replace the values in list order, so a value that is a
  # substring of another must come after it: replaced first, it would leave the longer value's
  # remainder in the text. Longest first (stable for equal sizes) makes that order irrelevant.
  defp dedupe(values) do
    values |> Enum.reject(&(&1 == "")) |> Enum.uniq() |> Enum.sort_by(&(-byte_size(&1)))
  end

  @doc """
  The project's redaction list for persisted TEXT: `resolve/2`'s `secrets`, values only (never
  a name), minus secret-store values shorter than `min_stored_secret_chars/0` whose NAME does
  not look secret. Redaction is verbatim substring replacement, so a stored value like `"1"`
  or `"ok"` would rewrite those characters across every memory topic, coordinator message and
  standing context, corrupting knowledge without hiding anything. A value whose name looks
  secret (`API_TOKEN=ab`) is still listed at any length, as are longer stored values; log
  redaction (`resolve/2`) is unchanged. Raises `ArgumentError` for an environment `resolve/2`
  refuses, as `WorkerEnvironment.build/2` does: a text is never persisted under a partial
  list. An unavailable secret store degrades as in `resolve/2` (logged, without the store's
  values). `fetch_secrets/1` is the same list as a typed result, for a persist path that must
  not raise.
  """
  @spec secrets(String.t()) :: [String.t()]
  def secrets(project_id) when is_binary(project_id) do
    case fetch_secrets(project_id) do
      {:ok, secrets} ->
        secrets

      {:error, reason} ->
        raise ArgumentError,
              "project #{inspect(project_id)} environment is invalid: #{inspect(reason)}"
    end
  end

  @doc """
  `secrets/1` without the raise: `{:ok, list}`, or `{:error, reason}` for an environment
  `resolve/2` refuses (the one case `secrets/1` raises on). The caller decides what an
  unusable list means; `ForemanServer.Coordinator.Redact.secrets/1` degrades to the built-in
  patterns and logs.
  """
  @spec fetch_secrets(String.t()) :: {:ok, [String.t()]} | {:error, resolve_error()}
  def fetch_secrets(project_id) when is_binary(project_id) do
    with {:ok, _env, stored, named} <- resolve_parts(project_id, []) do
      {:ok,
       dedupe(Enum.filter(stored, &(String.length(&1) >= @min_stored_secret_chars)) ++ named)}
    end
  end

  @doc """
  Shortest secret-store value (characters) used to redact persisted text when its name does
  not look secret. Eight is the floor of a plausible credential (shorter ones are flags,
  ports, digits, short words) and keeps incidental collisions with prose rare.
  """
  @spec min_stored_secret_chars() :: pos_integer()
  def min_stored_secret_chars, do: @min_stored_secret_chars

  @doc "Sorted `FOREMAN_*` names present in `vars` (reserved for Foreman's own env)."
  @spec reserved_keys(%{optional(String.t()) => term()}) :: [String.t()]
  def reserved_keys(vars) when is_map(vars) do
    vars |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "FOREMAN_")) |> Enum.sort()
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
      "vars" => record |> fetch(:vars, %{}) |> stringify(),
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

    %{Environment.default() | "vars" => vars}
  end

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
