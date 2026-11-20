defmodule ForemanServer.Aggregates.Project.Settings do
  @moduledoc """
  The single whitelist table for project settings.

  Every key a project owner can configure is declared here with its
  validator/normaliser. `normalize/1` accepts a map with atom or string keys and
  returns `{:ok, %{atom => term | nil}}` (one key convention: atoms; a `nil`
  value means "clear this setting") or a DISTINCT error tuple per failure.

  Settings travel on the wire as typed optional fields on
  `ForemanServer.Events.ProjectUpdated` (plus `cleared_settings`) and are folded
  into the project's `config` under the same names.

  `coordinator_provider` is a closed set (`JidoHarness.providers/0`): spike S1
  found a per-project coordinator provider is needed (default `pi`, applied by
  the coordinator in E15, not here). Validation here is a name check only; the
  real provider probe belongs to E15, which is the first thing to start an agent.
  There is no `coordinator_effort_effective?` helper: spike S1's default
  coordinator provider (`pi`) declares `reasoning_effort`.

  Later epics add their key to `@validators` and nowhere else.
  """

  alias ForemanServer.AgentRuntime.JidoHarness

  @max_instructions_chars 16_000
  @max_goal_chars 2_000
  @max_model_chars 200
  @max_concurrent_runs_range 1..1000
  @daily_thread_cap_range 1..10_000
  @max_repos_per_run_range 1..1000
  @default_max_repos_per_run 4
  @pr_fix_kinds ~w(ci comments conflicts)
  @pr_fix_attempts_range 1..5
  @pr_fix_cooldown_range 0..86_400
  @max_active_threads_range 1..50
  @max_required_checks 20
  @max_check_text_chars 200
  @required_check_kinds ~w(check_run status_context)
  @required_check_entry_keys ~w(name kind workflow allow_skipped)
  # What `Jido.Harness.RunRequest` accepts for `reasoning_effort`; a wider value
  # would validate here and then fail the launch.
  @efforts ~w(low medium high)
  # Notification preference (E10): every turn, only when blocked, or off.
  @notification_preferences ~w(every_turn blocked_only off)

  @keys ~w(goal instructions thread_model thread_effort coordinator_provider coordinator_model
           coordinator_effort max_concurrent_runs daily_thread_cap pr_auto_fix
           coordinator_propose_before_start coordinator_max_active_threads
           coordinator_reuse_threads library_collect_produced repo_allowlist max_repos_per_run
           notification_preference required_checks)a

  # Config keys that existing callers send and that are not settings: the
  # registered display name, task-provider routing, the beads database path and
  # the project environment.
  @legacy_keys ~w(name task_provider database_path env environment)a

  @type key ::
          :goal
          | :instructions
          | :thread_model
          | :thread_effort
          | :coordinator_provider
          | :coordinator_model
          | :coordinator_effort
          | :max_concurrent_runs
          | :daily_thread_cap
          | :repo_allowlist
          | :max_repos_per_run
          | :library_collect_produced
          | :pr_auto_fix
          | :coordinator_propose_before_start
          | :coordinator_max_active_threads
          | :coordinator_reuse_threads
          | :notification_preference
          | :required_checks

  @type error ::
          {:goal_too_long, non_neg_integer(), pos_integer()}
          | {:goal_not_a_string, atom()}
          | {:goal_invalid_encoding}
          | {:instructions_too_long, non_neg_integer(), pos_integer()}
          | {:instructions_not_a_string, atom()}
          | {:instructions_invalid_encoding}
          | {:thread_model_invalid, term()}
          | {:thread_effort_invalid, term(), [String.t()]}
          | {:invalid_setting, :coordinator_provider, {:unknown_provider, term()}}
          | {:coordinator_model_invalid, term()}
          | {:coordinator_effort_invalid, term(), [String.t()]}
          | {:max_concurrent_runs_invalid, term(), Range.t()}
          | {:daily_thread_cap_invalid, term(), Range.t()}
          | {:invalid_repo_allowlist, term()}
          | {:max_repos_per_run_invalid, term(), Range.t()}
          | {:library_collect_produced_invalid, term()}
          | {:pr_auto_fix_invalid, term()}
          | {:pr_auto_fix_unknown_kind, term()}
          | {:pr_auto_fix_max_attempts_invalid, term(), Range.t()}
          | {:pr_auto_fix_cooldown_invalid, term(), Range.t()}
          | {:coordinator_max_active_threads_invalid, term(), Range.t()}
          | {:coordinator_propose_before_start_invalid, term()}
          | {:coordinator_reuse_threads_invalid, term()}
          | {:notification_preference_invalid, term(), [String.t()]}
          | {:required_checks_invalid, term()}
          | {:required_checks_too_many, non_neg_integer(), pos_integer()}
          | {:required_checks_name_invalid, term()}
          | {:required_checks_kind_invalid, term()}
          | {:required_checks_workflow_invalid, term()}
          | {:required_checks_allow_skipped_invalid, term()}
          | {:required_checks_unknown_key, String.t()}
          | {:required_checks_conflicting_entry, String.t(), String.t(), String.t() | nil}
          | {:unknown_setting, String.t()}

  @doc "Default `max_repos_per_run` when the project does not set one."
  @spec default_max_repos_per_run() :: pos_integer()
  def default_max_repos_per_run, do: @default_max_repos_per_run

  @doc "Maximum characters of project instructions (`String.length/1`)."
  @spec max_instructions_chars() :: pos_integer()
  def max_instructions_chars, do: @max_instructions_chars

  @doc "Maximum characters of a project goal."
  @spec max_goal_chars() :: pos_integer()
  def max_goal_chars, do: @max_goal_chars

  @doc "Efforts accepted for thread/coordinator effort settings."
  @spec efforts() :: [String.t()]
  def efforts, do: @efforts

  @doc "Values accepted for the `notification_preference` setting."
  @spec notification_preferences() :: [String.t()]
  def notification_preferences, do: @notification_preferences

  @doc "Setting keys, in declaration order."
  @spec keys() :: [key()]
  def keys, do: @keys

  @doc "Setting keys as strings (for CLI help, docs and the wire)."
  @spec string_keys() :: [String.t()]
  def string_keys, do: Enum.map(@keys, &Atom.to_string/1)

  @doc "Non-setting keys existing callers may send inside `config`."
  @spec legacy_keys() :: [atom()]
  def legacy_keys, do: @legacy_keys

  @doc """
  The setting keys a `project.update` or `project.register` payload sets or
  clears, as `%{key => :set | :clear}`. It reads the typed top-level fields,
  the open `config` map and `cleared_settings` (atom or string keys) and does
  not validate: a non-nil value is `:set` (`[]` and `false` included), a `nil`
  value or a name in `cleared_settings` is `:clear`. A key that is both set and
  cleared reports `:set` (the aggregate refuses such a payload anyway).
  """
  @spec changed_keys(map()) :: %{optional(key()) => :set | :clear}
  def changed_keys(payload) when is_map(payload) do
    config =
      case fetch(payload, :config) do
        {:ok, config} when is_map(config) -> config
        _ -> %{}
      end

    cleared =
      case fetch(payload, :cleared_settings) do
        {:ok, list} when is_list(list) ->
          for item <- list, {:ok, key} <- [to_key(item)], into: %{}, do: {key, :clear}

        _ ->
          %{}
      end

    nested = changes_in(config)
    top = changes_in(payload)

    cleared
    |> Map.merge(nested)
    |> Map.merge(top)
  end

  defp changes_in(map) do
    for key <- @keys, {:ok, value} <- [fetch(map, key)], into: %{} do
      {key, if(is_nil(value), do: :clear, else: :set)}
    end
  end

  @doc """
  Resolves a user supplied key (atom or string) to a setting key atom.
  """
  @spec to_key(atom() | String.t()) :: {:ok, key()} | :error
  def to_key(key) when is_atom(key) and key in @keys, do: {:ok, key}
  def to_key(key) when is_binary(key), do: Enum.find_value(@keys, :error, &match_key(&1, key))
  def to_key(_key), do: :error

  defp match_key(key, string) do
    if Atom.to_string(key) == string, do: {:ok, key}
  end

  @doc """
  Normalises the settings found in `raw` (atom or string keys). Keys that are
  not settings are ignored here; `check_config_keys/1` polices the open config.
  A `nil` value (or a blank goal/instructions string) means "clear".
  """
  @spec normalize(map()) :: {:ok, %{optional(key()) => term() | nil}} | {:error, error()}
  def normalize(raw) when is_map(raw) do
    Enum.reduce_while(@keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case fetch(raw, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case validate(key, value) do
            {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
            {:error, _} = error -> {:halt, error}
          end
      end
    end)
  end

  @doc """
  Rejects keys of an open `config` map that are neither settings nor on the
  legacy allowlist.
  """
  @spec check_config_keys(map()) :: :ok | {:error, {:unknown_setting, String.t()}}
  def check_config_keys(config) when is_map(config) do
    config
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
    |> Enum.find(fn key ->
      key not in string_keys() and key not in Enum.map(@legacy_keys, &Atom.to_string/1)
    end)
    |> case do
      nil -> :ok
      key -> {:error, {:unknown_setting, key}}
    end
  end

  @doc """
  Validates a `cleared_settings` list and returns the keys as atoms.
  """
  @spec normalize_cleared(term()) :: {:ok, [key()]} | {:error, error()}
  def normalize_cleared(nil), do: {:ok, []}

  def normalize_cleared(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case to_key(item) do
        {:ok, key} -> {:cont, {:ok, [key | acc]}}
        :error -> {:halt, {:error, {:unknown_setting, to_string_key(item)}}}
      end
    end)
    |> case do
      {:ok, keys} -> {:ok, keys |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  def normalize_cleared(other), do: {:error, {:unknown_setting, inspect(other)}}

  defp to_string_key(item) when is_binary(item), do: item
  defp to_string_key(item) when is_atom(item), do: Atom.to_string(item)
  defp to_string_key(item), do: inspect(item)

  defp fetch(raw, key) do
    case Map.fetch(raw, key) do
      {:ok, _} = ok -> ok
      :error -> Map.fetch(raw, Atom.to_string(key))
    end
  end

  # -- validators ------------------------------------------------------------

  defp validate(:goal, value), do: text(value, :goal, @max_goal_chars)
  defp validate(:instructions, value), do: text(value, :instructions, @max_instructions_chars)
  defp validate(:thread_model, value), do: model(value, :thread_model)
  defp validate(:coordinator_provider, nil), do: {:ok, nil}

  defp validate(:coordinator_provider, value) when is_binary(value) do
    supported = Enum.map(JidoHarness.providers(), &Atom.to_string/1)

    case String.trim(value) do
      "" -> {:ok, nil}
      provider -> if provider in supported, do: {:ok, provider}, else: unknown_provider(value)
    end
  end

  defp validate(:coordinator_provider, value), do: unknown_provider(value)
  defp validate(:coordinator_model, value), do: model(value, :coordinator_model)
  defp validate(:thread_effort, value), do: effort(value, :thread_effort)
  defp validate(:coordinator_effort, value), do: effort(value, :coordinator_effort)

  defp validate(:max_concurrent_runs, value),
    do: ranged(value, :max_concurrent_runs_invalid, @max_concurrent_runs_range)

  defp validate(:pr_auto_fix, value), do: pr_auto_fix(value)

  defp validate(:daily_thread_cap, value),
    do: ranged(value, :daily_thread_cap_invalid, @daily_thread_cap_range)

  defp validate(:max_repos_per_run, value),
    do: ranged(value, :max_repos_per_run_invalid, @max_repos_per_run_range)

  defp validate(:repo_allowlist, nil), do: {:ok, nil}

  defp validate(:repo_allowlist, entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case allowlist_entry(entry) do
        {:ok, clean} -> {:cont, {:ok, [clean | acc]}}
        :error -> {:halt, {:error, {:invalid_repo_allowlist, entry}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, acc |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp validate(:repo_allowlist, other), do: {:error, {:invalid_repo_allowlist, other}}

  defp validate(:library_collect_produced, nil), do: {:ok, nil}
  defp validate(:library_collect_produced, value) when is_boolean(value), do: {:ok, value}

  defp validate(:library_collect_produced, value),
    do: {:error, {:library_collect_produced_invalid, value}}

  defp validate(:coordinator_propose_before_start, value),
    do: boolean(value, :coordinator_propose_before_start)

  defp validate(:coordinator_reuse_threads, value), do: boolean(value, :coordinator_reuse_threads)

  defp validate(:coordinator_max_active_threads, value),
    do: ranged(value, :coordinator_max_active_threads_invalid, @max_active_threads_range)

  defp validate(:notification_preference, nil), do: {:ok, nil}

  defp validate(:notification_preference, value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> {:ok, nil}
      pref when pref in @notification_preferences -> {:ok, pref}
      _ -> {:error, {:notification_preference_invalid, value, @notification_preferences}}
    end
  end

  defp validate(:notification_preference, value),
    do: {:error, {:notification_preference_invalid, value, @notification_preferences}}

  defp validate(:required_checks, nil), do: {:ok, nil}

  defp validate(:required_checks, entries) when is_list(entries) do
    if length(entries) > @max_required_checks do
      {:error, {:required_checks_too_many, length(entries), @max_required_checks}}
    else
      with {:ok, clean} <- required_check_entries(entries),
           :ok <- required_check_conflicts(clean) do
        {:ok, clean |> Enum.uniq() |> Enum.sort_by(&required_check_sort_key/1)}
      end
    end
  end

  defp validate(:required_checks, other), do: {:error, {:required_checks_invalid, other}}

  defp boolean(nil, _name), do: {:ok, nil}
  defp boolean(value, _name) when is_boolean(value), do: {:ok, value}
  defp boolean(value, name), do: {:error, {:"#{name}_invalid", value}}

  # An absolute path prefix: no `..` segments, not the bare root. Trailing
  # slashes are dropped so prefix matching is segment-based.
  defp allowlist_entry(entry) when is_binary(entry) do
    segments = Path.split(entry)

    cond do
      Path.type(entry) != :absolute -> :error
      ".." in segments -> :error
      segments == ["/"] -> :error
      true -> {:ok, entry |> Path.expand() |> String.trim_trailing("/")}
    end
  end

  defp allowlist_entry(_entry), do: :error

  defp required_check_entries(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case required_check_entry(entry) do
        {:ok, clean} -> {:cont, {:ok, [clean | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp required_check_entry(entry) when is_map(entry) do
    entry = Map.new(entry, fn {key, value} -> {to_string_key(key), value} end)

    with :ok <- required_check_keys(entry),
         {:ok, name} <- check_text(Map.get(entry, "name"), :required_checks_name_invalid),
         {:ok, kind} <- required_check_kind(Map.get(entry, "kind")),
         {:ok, workflow} <- required_check_workflow(kind, Map.get(entry, "workflow")),
         {:ok, allow_skipped} <-
           required_check_allow_skipped(kind, Map.get(entry, "allow_skipped")) do
      {:ok,
       %{"name" => name, "kind" => kind}
       |> put_unless_nil("workflow", workflow)
       |> put_unless_nil("allow_skipped", allow_skipped)}
    end
  end

  defp required_check_entry(entry), do: {:error, {:required_checks_invalid, entry}}

  defp required_check_keys(entry) do
    case entry
         |> Map.keys()
         |> Enum.sort()
         |> Enum.find(&(&1 not in @required_check_entry_keys)) do
      nil -> :ok
      key -> {:error, {:required_checks_unknown_key, key}}
    end
  end

  defp required_check_kind(kind) when kind in @required_check_kinds, do: {:ok, kind}
  defp required_check_kind(kind), do: {:error, {:required_checks_kind_invalid, kind}}

  defp required_check_workflow(_kind, nil), do: {:ok, nil}

  defp required_check_workflow("check_run", workflow),
    do: check_text(workflow, :required_checks_workflow_invalid)

  defp required_check_workflow(_kind, workflow),
    do: {:error, {:required_checks_workflow_invalid, workflow}}

  # `false` is the default and is dropped, so one meaning has one stored form.
  defp required_check_allow_skipped(_kind, nil), do: {:ok, nil}
  defp required_check_allow_skipped("check_run", false), do: {:ok, nil}
  defp required_check_allow_skipped("check_run", true), do: {:ok, true}

  defp required_check_allow_skipped(_kind, value),
    do: {:error, {:required_checks_allow_skipped_invalid, value}}

  defp check_text(value, error) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      not String.valid?(value) -> {:error, {error, value}}
      trimmed == "" -> {:error, {error, value}}
      String.length(trimmed) > @max_check_text_chars -> {:error, {error, value}}
      String.match?(trimmed, ~r/[[:cntrl:]]/u) -> {:error, {error, value}}
      true -> {:ok, trimmed}
    end
  end

  defp check_text(value, error), do: {:error, {error, value}}

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp required_check_sort_key(entry),
    do: {entry["name"], entry["kind"], entry["workflow"] || ""}

  # One name, kind and workflow with two `allow_skipped` values is a
  # contradiction, not a duplicate.
  defp required_check_conflicts(entries) do
    entries
    |> Enum.uniq()
    |> Enum.group_by(&required_check_sort_key/1)
    |> Enum.sort()
    |> Enum.find(fn {_identity, group} -> length(group) > 1 end)
    |> case do
      nil ->
        :ok

      {_identity, [entry | _]} ->
        {:error,
         {:required_checks_conflicting_entry, entry["name"], entry["kind"], entry["workflow"]}}
    end
  end

  defp unknown_provider(value),
    do: {:error, {:invalid_setting, :coordinator_provider, {:unknown_provider, value}}}

  defp text(nil, _name, _max), do: {:ok, nil}

  defp text(value, name, max) when is_binary(value) do
    if String.valid?(value) do
      normalized =
        value
        |> String.replace("\r\n", "\n")
        |> String.replace("\r", "\n")
        |> String.trim()

      length = String.length(normalized)

      cond do
        normalized == "" -> {:ok, nil}
        length > max -> {:error, {:"#{name}_too_long", length, max}}
        true -> {:ok, normalized}
      end
    else
      {:error, {:"#{name}_invalid_encoding"}}
    end
  end

  defp text(value, name, _max), do: {:error, {:"#{name}_not_a_string", type_of(value)}}

  defp model(nil, _name), do: {:ok, nil}

  defp model(value, name) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:ok, nil}
      not String.valid?(value) -> {:error, {:"#{name}_invalid", value}}
      String.length(trimmed) > @max_model_chars -> {:error, {:"#{name}_invalid", value}}
      String.match?(trimmed, ~r/[\s[:cntrl:]]/u) -> {:error, {:"#{name}_invalid", value}}
      true -> {:ok, trimmed}
    end
  end

  defp model(value, name), do: {:error, {:"#{name}_invalid", value}}

  defp effort(nil, _name), do: {:ok, nil}

  defp effort(value, name) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> {:ok, nil}
      effort when effort in @efforts -> {:ok, effort}
      _ -> {:error, {:"#{name}_invalid", value, @efforts}}
    end
  end

  defp effort(value, name), do: {:error, {:"#{name}_invalid", value, @efforts}}

  # `pr_auto_fix` (E9-S4): which PR problems Foreman may fix by itself. `nil`, an empty
  # map, or an empty `kinds` list all mean "off" (stored as nil). The normalised value
  # is a STRING-keyed map `%{"kinds", "max_attempts", "cooldown_seconds"}` so the live
  # value and the one replayed from the JSON event log are identical.
  defp pr_auto_fix(nil), do: {:ok, nil}

  defp pr_auto_fix(value) when is_map(value) do
    kinds = pr_field_or(value, :kinds, [])

    with {:ok, kinds} <- pr_auto_fix_kinds(kinds),
         {:ok, attempts} <-
           ranged(
             pr_field_or(value, :max_attempts, 2),
             :pr_auto_fix_max_attempts_invalid,
             @pr_fix_attempts_range
           ),
         {:ok, cooldown} <-
           ranged(
             pr_field_or(value, :cooldown_seconds, 0),
             :pr_auto_fix_cooldown_invalid,
             @pr_fix_cooldown_range
           ) do
      if kinds == [],
        do: {:ok, nil},
        else:
          {:ok, %{"kinds" => kinds, "max_attempts" => attempts, "cooldown_seconds" => cooldown}}
    end
  end

  defp pr_auto_fix(value), do: {:error, {:pr_auto_fix_invalid, value}}

  defp pr_auto_fix_kinds(kinds) when is_list(kinds) do
    case Enum.find(kinds, &(to_string_safe(&1) not in @pr_fix_kinds)) do
      nil -> {:ok, kinds |> Enum.map(&to_string_safe/1) |> Enum.uniq() |> Enum.sort()}
      bad -> {:error, {:pr_auto_fix_unknown_kind, bad}}
    end
  end

  defp pr_auto_fix_kinds(other), do: {:error, {:pr_auto_fix_invalid, other}}

  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp to_string_safe(_value), do: nil

  defp pr_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  # Absent (or JSON null) takes the default; any other value, including `false`, is
  # passed on to be validated rather than silently replaced.
  defp pr_field_or(map, key, default) do
    case pr_field(map, key) do
      nil -> default
      value -> value
    end
  end

  defp ranged(nil, _error, _range), do: {:ok, nil}

  defp ranged(value, error, range) when is_integer(value) do
    if value in range, do: {:ok, value}, else: {:error, {error, value, range}}
  end

  defp ranged(value, error, range), do: {:error, {error, value, range}}

  defp type_of(value) when is_integer(value), do: :integer
  defp type_of(value) when is_float(value), do: :float
  defp type_of(value) when is_boolean(value), do: :boolean
  defp type_of(value) when is_atom(value), do: :atom
  defp type_of(value) when is_list(value), do: :list
  defp type_of(value) when is_map(value), do: :map
  defp type_of(value) when is_tuple(value), do: :tuple
  defp type_of(_value), do: :other
end
