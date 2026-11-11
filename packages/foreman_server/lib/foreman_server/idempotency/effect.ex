defmodule ForemanServer.Idempotency.Effect do
  @moduledoc """
  Keyed external effects: record intent, run the effect, record the outcome.

  `run/4` writes a `started` key (`effect:<class>:<run_id>:<identity>`) before
  the effect runs and `completed` or `failed` after it. A process that dies
  mid-effect leaves the key `started`; boot reconciliation marks it `ambiguous`
  and the class's reconciler decides whether the effect happened (never a blind
  retry). If the intent cannot be recorded, the effect does not run.

  ## Metadata shape

  One shape with string keys, converted here once so the ETS path and the
  durable path agree. Always: `run_id`, `effect_class`. Per class:

    * `branch_push`: `head_branch`, `cwd` (+ `pre_push_remote_sha`,
      `pushed_local_sha`, written by the caller)
    * `pr_create`: `head_branch`, `base_branch`, `cwd`
    * `task_provider`: `project_id`, `op`, `issue_id`
    * any other class: only the two universal fields are required.

  `cwd` is the directory the reconcilers run `git`/`gh` in; a push or PR create
  without one records no intent.

  The key is marked with `KeyStore.mark_started/2` directly;
  `HeartbeatLease.acquire/4` arms a live-worker expiry timer and is not used.
  """

  alias ForemanServer.Aggregate
  alias ForemanServer.EventStore
  alias ForemanServer.Idempotency.KeyStore

  require Logger

  @type class :: atom() | String.t()
  @type intent_error ::
          :invalid_class
          | :invalid_key
          | {:missing_metadata, String.t()}
          | :cwd_missing
          | term()

  @max_events 99_999_999

  @required %{
    "branch_push" => ["head_branch", "cwd"],
    "pr_create" => ["head_branch", "base_branch", "cwd"],
    "task_provider" => ["project_id", "op", "issue_id"]
  }

  @doc """
  Derive the stable key `effect:<class>:<run_id>:<identity>`: the same effect
  attempted again after a crash finds the same key.
  """
  @spec key(class(), String.t(), String.t()) :: String.t()
  def key(class, run_id, identity), do: "effect:#{class}:#{run_id}:#{identity}"

  @doc """
  Run `fun` as the keyed effect `class`/`key` with metadata `meta`.

  Returns `fun`'s own result unchanged. Returns
  `{:error, {:intent_not_recorded, reason}}` without calling `fun` when the
  metadata is incomplete or the `started` key cannot be written, and
  `{:error, {:effect_unresolved, key}}` (also without calling `fun`, key and
  metadata untouched) when recovery left the key unresolved and the run has not
  been reset since. The key is
  marked `failed` when `fun` returns `:error`/`{:error, _}` or raises/throws/exits
  (the exception is re-raised), otherwise `completed`.
  """
  @spec run(class(), String.t(), (-> result), map()) ::
          result
          | {:error, {:intent_not_recorded, intent_error()} | {:effect_unresolved, String.t()}}
        when result: term()
  def run(class, key, fun, meta) when is_function(fun, 0) and is_map(meta) do
    with {:ok, class_name} <- class_name(class),
         :ok <- check_key(key, class_name),
         {:ok, typed} <- typed_meta(class_name, meta),
         {:ok, typed} <- check_unresolved(key, typed),
         :ok <- record_intent(key, typed) do
      execute(key, fun)
    else
      {:unresolved, key} -> {:error, {:effect_unresolved, key}}
      {:error, reason} -> {:error, {:intent_not_recorded, reason}}
    end
  end

  defp class_name(class) when is_atom(class) and class not in [nil, true, false],
    do: {:ok, Atom.to_string(class)}

  defp class_name(class) when is_binary(class) and class != "", do: {:ok, class}
  defp class_name(_class), do: {:error, :invalid_class}

  defp check_key(key, class_name) when is_binary(key) do
    if KeyStore.effect_key?(key) and String.starts_with?(key, "effect:#{class_name}:"),
      do: :ok,
      else: {:error, :invalid_key}
  end

  defp check_key(_key, _class_name), do: {:error, :invalid_key}

  defp typed_meta(class_name, meta) do
    typed =
      meta
      |> Map.new(fn {k, v} -> {to_string(k), normalize(v)} end)
      |> Map.put("effect_class", class_name)

    required = ["run_id" | Map.get(@required, class_name, [])]

    case Enum.find(required, &(not present?(Map.get(typed, &1)))) do
      nil -> {:ok, typed}
      "cwd" -> {:error, :cwd_missing}
      field -> {:error, {:missing_metadata, field}}
    end
  end

  # A key recovery could not resolve (`KeyStore.mark_unresolved/3`: a reconciler
  # blocked the run, or the run was terminal and could not be blocked) is never
  # repeated: the earlier attempt may have happened, and re-marking the key
  # `started` would also overwrite the SHAs its reconciler needs. The only exit
  # is an operator `run.reset`, which appends `RunReset` to the run's stream
  # after the version the marker recorded. Any other event (a terminal run still
  # takes PR events) leaves the refusal in place. A stream that cannot be read
  # refuses too: not repeating is the safe side. A lifted key is re-marked
  # `started` with the marker cleared.
  defp check_unresolved(key, typed) do
    case KeyStore.get(key) do
      {:ok, %{status: :ambiguous, metadata: metadata}} when is_map(metadata) ->
        case KeyStore.unresolved_version(metadata) do
          {:ok, version} -> lift_if_reset(key, typed, version)
          :none -> {:ok, typed}
        end

      _no_marker_to_honour ->
        {:ok, typed}
    end
  catch
    :exit, reason -> {:error, {:key_store_unavailable, reason}}
  end

  defp lift_if_reset(key, typed, version) do
    case reset_after?(typed["run_id"], version) do
      true ->
        {:ok, Map.put(typed, "unresolved_at_run_version", nil)}

      false ->
        {:unresolved, key}

      {:error, reason} ->
        Logger.error(
          "Effect: unresolved key #{inspect(key)}: run stream unreadable (#{inspect(reason)}); not repeating",
          key: key
        )

        {:unresolved, key}
    end
  end

  defp reset_after?(run_id, version) do
    case EventStore.read_stream_forward("run:#{run_id}", version + 1, @max_events) do
      {:ok, events} -> Enum.any?(events, &(Aggregate.event_type(&1) == "RunReset"))
      {:error, :stream_not_found} -> false
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  rescue
    err -> {:error, err}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp normalize(v) when is_atom(v) and v not in [nil, true, false], do: Atom.to_string(v)
  defp normalize(v), do: v

  defp present?(v) when is_binary(v), do: v != ""
  defp present?(nil), do: false
  defp present?(_v), do: true

  defp record_intent(key, typed) do
    case KeyStore.mark_started(key, typed) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  catch
    :exit, reason -> {:error, {:key_store_unavailable, reason}}
  end

  defp execute(key, fun) do
    result = fun.()

    case result do
      :error -> settle(key, :failed, ":error")
      {:error, reason} -> settle(key, :failed, inspect(reason))
      _ok -> settle(key, :completed, nil)
    end

    result
  rescue
    err ->
      settle(key, :failed, Exception.message(err))
      reraise err, __STACKTRACE__
  catch
    kind, reason ->
      settle(key, :failed, inspect({kind, reason}))
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # The effect already ran, so a failure to record its outcome is logged, never
  # allowed to change the effect's result; the key stays `started` and boot
  # reconciliation treats it as ambiguous.
  defp settle(key, status, reason) do
    outcome =
      try do
        case status do
          :completed -> KeyStore.mark_completed(key)
          :failed -> KeyStore.mark_failed(key, reason)
        end
      catch
        :exit, exit_reason -> {:error, exit_reason}
      end

    if outcome != :ok do
      Logger.error(
        "Effect: could not record #{status} for #{inspect(key)}: #{inspect(outcome)}",
        key: key
      )
    end

    :ok
  end
end
