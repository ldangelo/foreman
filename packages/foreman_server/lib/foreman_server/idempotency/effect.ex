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
    * `pr_comment`: `pr_url`, `head_sha`, `digest` (no `cwd`: the comment is written by URL)
    * `task_provider`: `project_id`, `op`, `issue_id`
    * any other class: only the two universal fields are required.

  `cwd` is the directory the reconcilers run `git`/`gh` in; a push or PR create
  without one records no intent.

  ## Which keys are refused

  An effect runs again only when its key is decided: not found, `completed` or
  `failed` (a settled effect may run again), `ambiguous` with the decision `not_done`
  that the boot sweep recorded once the class's reconciler found the effect did not
  happen (`KeyStore.mark_decided/2`), or of a class whose reconciler declares
  `repeatable?/1` true (`Reconciler.repeatable?/2`: repeating it is harmless, so it is
  never undecided). Any other `started` or `ambiguous` key is undecided: an earlier
  attempt may have happened, or still be running, and nobody has said which, so
  `run/4` and `preflight/3` return `{:error, {:effect_undecided, key}}`, without
  calling `fun` and without touching the key, and ask the boot sweep to run again
  (`BootReconciliation.scan_ambiguous_keys/0`, once per refusal; best effort, so a
  sweep that is not running leaves the refusal as it is, and the sweep coalesces the
  requests), because a decision can only come from it. That scan is an on-demand one: a
  reconciler that cannot tell (`unknown`, such as a `gh` call that timed out) leaves the key
  undecided and the run running, and the next refusal or the boot sweep asks again; only the
  boot sweep marks such a key unresolved. A key recovery could not
  resolve is refused as `effect_unresolved` until an operator `run.reset`.

  ## The writer stamp

  The `started` key records its writer: the server incarnation (`Incarnation.id/0`) and the
  pid of the process that called `run/4`, as a string (`writer_incarnation`, `writer_pid`:
  JSON-safe, so it survives the repo-backed path). The effect runs in that same process, so
  the writer is alive exactly while the effect can still be running. `writer_state/1` is the
  one reading of the stamp: the boot sweep orphans a stamped `started` key only when its
  writer is `:dead`, whatever executor its run has now, and never when it is `:alive`; the
  doctor prints it. A key without a stamp (written before the stamp existed) is `:none` and
  keeps the run-liveness rule. A settle clears the stamp (`KeyStore.recovery_fields_cleared/0`).
  A writer that hangs forever keeps its key undecided, and a local pid recycled within one
  incarnation (a full wrap of the pid space in one boot) would read `alive`: both are
  accepted, since not repeating is the safe side.

  The key is marked with `KeyStore.mark_started/2` directly;
  `HeartbeatLease.acquire/4` arms a live-worker expiry timer and is not used.
  """

  alias ForemanServer.Aggregate
  alias ForemanServer.EventStore
  alias ForemanServer.Incarnation
  alias ForemanServer.Idempotency.KeyStore
  alias ForemanServer.Idempotency.Reconciler
  alias ForemanServer.Workflow.BootReconciliation

  require Logger

  @type class :: atom() | String.t()
  @type intent_error ::
          :invalid_class
          | :invalid_key
          | {:missing_metadata, String.t()}
          | :cwd_missing
          | term()

  @type refusal ::
          {:error, {:intent_not_recorded, intent_error()}}
          | {:error, {:effect_unresolved, String.t()}}
          | {:error, {:effect_undecided, String.t()}}
          | {:error, {:effect_marker_malformed, String.t()}}
          | {:error, {:effect_check_failed, term()}}

  @max_events 99_999_999

  @required %{
    "branch_push" => ["head_branch", "cwd"],
    "pr_create" => ["head_branch", "base_branch", "cwd"],
    "pr_comment" => ["pr_url", "head_sha", "digest"],
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
  metadata is incomplete or the `started` key cannot be written;
  `{:error, {:effect_undecided, key}}` (also without calling `fun`, key and
  metadata untouched) when the key is `started`, or `ambiguous` with no decision,
  and its class is not repeatable (see "Which keys are refused");
  `{:error, {:effect_unresolved, key}}` (likewise) when recovery left the key
  unresolved and the run has not been reset since;
  `{:error, {:effect_marker_malformed, key}}` when the key's
  unresolved marker is present but not a version (no reset clears it: an operator
  must repair the stored key); and `{:error, {:effect_check_failed, reason}}` when that
  could not be established (an unreadable run stream, a stored record that cannot
  be read): not repeating is the safe side. The key is marked `failed` when
  `fun` returns `:error`/`{:error, _}` or raises/throws/exits (the exception is
  re-raised), otherwise `completed`.
  """
  @spec run(class(), String.t(), (-> result), map()) :: result | refusal()
        when result: term()
  def run(class, key, fun, meta) when is_function(fun, 0) and is_map(meta) do
    with {:ok, class_name} <- class_name(class),
         :ok <- check_key(key, class_name),
         {:ok, typed} <- typed_meta(class_name, meta),
         {:ok, mode} <- check_unresolved(class_name, key, typed["run_id"]),
         :ok <- record_intent(key, typed, mode) do
      execute(key, fun)
    else
      {:error, reason} -> {:error, {:intent_not_recorded, reason}}
      refusal -> refusal_error(refusal)
    end
  end

  @doc """
  The refusal check `run/4` makes, without writing anything: `:ok` when an
  effect of `class` under `key` may be attempted for `meta["run_id"]`, otherwise
  the same refusal `run/4` would return. Callers that run a cheaper effect
  before the keyed one (the push before the PR create) call this on the later
  key first, so a refusal stops the earlier effect too.
  """
  @spec preflight(class(), String.t(), map()) :: :ok | refusal()
  def preflight(class, key, meta) when is_map(meta) do
    with {:ok, class_name} <- class_name(class),
         :ok <- check_key(key, class_name),
         run_id = meta |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.get("run_id"),
         true <- present?(run_id) || {:error, {:missing_metadata, "run_id"}},
         {:ok, _mode} <- check_unresolved(class_name, key, run_id) do
      :ok
    else
      {:error, reason} -> {:error, {:intent_not_recorded, reason}}
      refusal -> refusal_error(refusal)
    end
  end

  defp refusal_error({:unresolved, key}), do: {:error, {:effect_unresolved, key}}

  # An undecided key waits for a decision that only the boot sweep writes, and the sweep runs
  # at boot: ask it to run now. The cast cannot fail the refusal (a `BootReconciliation` that
  # is not running drops it).
  defp refusal_error({:undecided, key}) do
    BootReconciliation.scan_ambiguous_keys()
    {:error, {:effect_undecided, key}}
  end

  defp refusal_error({:malformed, key}), do: {:error, {:effect_marker_malformed, key}}
  defp refusal_error({:check_failed, reason}), do: {:error, {:effect_check_failed, reason}}

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

  # A key is attempted again only when it is decided. `{:ok, mode}` says how it is
  # re-marked: `:clear` (not found, `completed` or `failed`: a settled effect may run
  # again; or a key of a repeatable class, `Reconciler.repeatable?/2`: repeating it is
  # harmless, so it is never undecided), `{:decided, decision}` (`ambiguous` with the
  # decision the boot sweep wrote once its reconciler found the effect did not happen)
  # or `{:lifted, version}` (a reset followed the key's unresolved marker). Any other
  # `started` or `ambiguous` key is undecided: the earlier attempt may have happened,
  # or still be running, and nobody has said which, so it is not repeated and the key
  # stays as it is.
  #
  # A key recovery could not resolve (`KeyStore.mark_unresolved/3`: a reconciler
  # blocked the run, or the run was terminal and could not be blocked) is never
  # repeated: the earlier attempt may have happened, and re-marking the key
  # `started` would also overwrite the SHAs its reconciler needs. The only exit
  # is an operator `run.reset`, which appends `RunReset` to the run's stream
  # after the version the marker recorded. Any other event (a terminal run still
  # takes PR events) leaves the refusal in place. A marker that is malformed, a
  # record that cannot be read and a stream that cannot be read all refuse: not
  # repeating is the safe side.
  defp check_unresolved(class_name, key, run_id) do
    case KeyStore.get(key) do
      :not_found ->
        {:ok, :clear}

      {:ok, %{status: :ambiguous, metadata: metadata}} when is_map(metadata) ->
        case KeyStore.unresolved_version(metadata) do
          :none -> check_decided(class_name, key, :ambiguous, metadata)
          {:ok, version} -> lift_if_reset(key, run_id, version)
          {:error, :malformed} -> {:malformed, key}
        end

      {:ok, %{status: :started, metadata: metadata}} when is_map(metadata) ->
        check_decided(class_name, key, :started, metadata)

      {:ok, %{status: undecided, metadata: other}} when undecided in [:started, :ambiguous] ->
        {:check_failed, {:metadata_not_a_map, other}}

      {:ok, %{status: settled}} when settled in [:completed, :failed] ->
        {:ok, :clear}

      # A status the store never writes: not a settled effect, so not repeatable. Refuse and
      # leave the key as it is (re-marking it `started` would overwrite it).
      {:ok, %{status: status}} ->
        {:check_failed, {:unexpected_status, status}}

      other ->
        {:check_failed, {:unreadable_key, other}}
    end
  catch
    :exit, reason -> {:error, {:key_store_unavailable, reason}}
  end

  # A `started` key, or an `ambiguous` one with no marker. Metadata is handed to the
  # reconciler string-keyed, as `Reconciler` documents.
  defp check_decided(class_name, key, status, metadata) do
    stored = Map.new(metadata, fn {k, v} -> {to_string(k), v} end)

    cond do
      Reconciler.repeatable?(class_name, stored) ->
        {:ok, :clear}

      status == :ambiguous and KeyStore.decision(stored) == :not_done ->
        {:ok, {:decided, :not_done}}

      true ->
        {:undecided, key}
    end
  end

  defp lift_if_reset(key, run_id, version) do
    case reset_after?(run_id, version) do
      true ->
        {:ok, {:lifted, version}}

      false ->
        {:unresolved, key}

      {:error, reason} ->
        Logger.error(
          "Effect: unresolved key #{inspect(key)}: run stream unreadable (#{inspect(reason)}); not repeating",
          key: key
        )

        {:check_failed, reason}
    end
  end

  defp reset_after?(run_id, version) do
    case read_run_stream(run_id, version + 1) do
      {:ok, events} -> Enum.any?(events, &(Aggregate.event_type(&1) == "RunReset"))
      {:error, :stream_not_found} -> false
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  end

  # The run stream's events from `from`. The reader is `EventStore` unless the
  # `:run_stream_reader` setting (a 2-arity function, `(stream_id, from)`) says
  # otherwise: the seam tests use to make the stream unreadable for this check only.
  defp read_run_stream(run_id, from) do
    case Application.get_env(:foreman_server, __MODULE__, [])[:run_stream_reader] do
      reader when is_function(reader, 2) ->
        reader.("run:#{run_id}", from)

      nil ->
        EventStore.read_stream_forward("run:#{run_id}", from, @max_events)
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

  @doc """
  The writer stamp for a `started` key written by the calling process: the incarnation id and
  the pid as a string.
  """
  @spec writer_stamp() :: %{String.t() => String.t()}
  def writer_stamp do
    %{
      "writer_incarnation" => Incarnation.id(),
      "writer_pid" => self() |> :erlang.pid_to_list() |> List.to_string()
    }
  end

  @doc """
  Whether the writer of a key (its string-keyed metadata) is `:alive`, `:dead` or `:none`
  (no stamp: a key written before the stamp existed, or an agent-phase key).

  `:dead` when the stamp names another incarnation (no process of an earlier boot exists), a
  pid that is not alive, or a pid that cannot be read back (garbage, or a pid of another node:
  neither can be a writer of this boot). Never raises.
  """
  @spec writer_state(term()) :: :alive | :dead | :none
  def writer_state(%{"writer_incarnation" => incarnation, "writer_pid" => pid_text})
      when is_binary(incarnation) and is_binary(pid_text) do
    if incarnation == Incarnation.id() do
      case local_pid(pid_text) do
        {:ok, pid} -> if Process.alive?(pid), do: :alive, else: :dead
        :error -> :dead
      end
    else
      :dead
    end
  end

  def writer_state(%{writer_incarnation: _} = metadata),
    do: metadata |> Map.new(fn {k, v} -> {to_string(k), v} end) |> writer_state()

  def writer_state(_metadata), do: :none

  # `list_to_pid/1` raises `badarg` for text that is not a pid, and for a pid text with a node
  # index this VM does not know (`"<5.1.0>"` on a VM that is not connected to that node;
  # observed on OTP 28); on a distributed VM that knows the index it returns a remote pid, which
  # `Process.alive?/1` would raise on, hence the `node/1` check. `String.to_charlist/1` raises
  # `UnicodeConversionError` on invalid UTF-8. None of them may escape: an unreadable stamp is a
  # writer that cannot be alive.
  defp local_pid(text) do
    if String.valid?(text) do
      pid = text |> String.to_charlist() |> :erlang.list_to_pid()
      if node(pid) == node(), do: {:ok, pid}, else: :error
    else
      :error
    end
  rescue
    _error -> :error
  end

  # Every re-mark clears what recovery wrote (the decision and the unresolved marker): the
  # store merges new metadata over the stored, so either left on the key by an earlier
  # crash would survive the re-mark and make the next crash look decided or unresolved
  # when the sweep has not yet looked at it.
  defp record_intent(key, typed, :clear) do
    key
    |> KeyStore.mark_started(stamped(typed))
    |> intent_result()
  catch
    :exit, reason -> {:error, {:key_store_unavailable, reason}}
  end

  # A lifted key is re-marked `started` with its marker cleared, atomically in the
  # store: the write succeeds only while the key still carries the marker version this
  # caller observed, so of two callers that both saw the reset only one runs the effect,
  # and a marker rewritten after the check is not lifted on the earlier decision.
  defp record_intent(key, typed, {:lifted, observed_version}) do
    cleared = stamped(typed)

    case KeyStore.lift_unresolved(key, observed_version, cleared) do
      :lifted -> :ok
      :not_unresolved -> {:unresolved, key}
      other -> intent_result(other)
    end
  catch
    :exit, reason -> {:error, {:key_store_unavailable, reason}}
  end

  # A decided key is re-marked `started` with its decision cleared, atomically in the
  # store: the write succeeds only while the key still carries the decision this caller
  # read, so of two callers that both read it only one runs the effect; the other finds
  # the key `started` and is refused as undecided.
  defp record_intent(key, typed, {:decided, observed}) do
    cleared = stamped(typed)

    case KeyStore.consume_decision(key, observed, cleared) do
      :consumed -> :ok
      :not_decided -> {:undecided, key}
      other -> intent_result(other)
    end
  catch
    :exit, reason -> {:error, {:key_store_unavailable, reason}}
  end

  # The metadata of a `started` write: everything recovery or an earlier writer left is
  # cleared, then this process stamps itself as the writer.
  defp stamped(typed),
    do: typed |> Map.merge(KeyStore.recovery_fields_cleared()) |> Map.merge(writer_stamp())

  defp intent_result(:ok), do: :ok
  defp intent_result({:error, reason}), do: {:error, reason}
  defp intent_result(other), do: {:error, other}

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
  # reconciliation treats it as ambiguous. A scan that ran while the effect was in flight
  # may have marked the key and written a marker or decision: the outcome supersedes them
  # (the PRD says a settled key carries neither).
  defp settle(key, status, reason) do
    outcome =
      try do
        case status do
          :completed -> KeyStore.mark_completed(key, KeyStore.recovery_fields_cleared())
          :failed -> KeyStore.mark_failed(key, reason, KeyStore.recovery_fields_cleared())
        end
      catch
        :exit, exit_reason -> {:error, exit_reason}
      end

    # `:status_changed`: the key settled meanwhile (a recorded outcome is never rewritten).
    if outcome != :ok do
      Logger.error(
        "Effect: could not record #{status} for #{inspect(key)}: #{inspect(outcome)}",
        key: key
      )
    end

    :ok
  end
end
