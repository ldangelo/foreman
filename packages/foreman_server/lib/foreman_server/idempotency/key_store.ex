defmodule ForemanServer.Idempotency.KeyStore do
  @moduledoc """
  Durable idempotency key records with status {started, completed, ambiguous, failed}.

  - `started`: phase in flight (lease live).
  - `completed`: phase finished successfully.
  - `ambiguous`: outcome unknown (lease expired / worker died); crash recovery
    inspects side effects before retry.
    An effect key (`effect:<class>:...`, written by `Idempotency.Effect`) stays
    `ambiguous` until the boot sweep decides it: `mark_decided/2` records that the
    effect did not happen (it may run again) and `mark_unresolved/3` that recovery
    could not resolve it (it is never repeated).
  - `failed`: phase ended in an observed error and may have left side effects;
    its run's failure path owns it. Crash recovery does not re-inspect it.

  Uses `ForemanServer.Agents.JidoCheckpointStore.Repo` as the backing
  Postgres store when the repo is configured (production). Falls back to
  an in-process ETS table when the repo is not available (dev/test) so
  the rest of the system is not blocked on DB setup.

  The ETS fallback preserves the same API surface and return types, so
  callers (HeartbeatLease, CrashRecovery) are unaffected by the storage
  backend. On a running system with the repo configured, every record
  survives process restarts.

  ## Idempotency key format

  Dispatch keys follow `{workflow}-{taskId}-{step}`, e.g.:
  `create-prd-{taskId}-1`, `implement-{taskId}-1`, `fix-{taskId}-1`.

  TRD-2026-4212be7e / RTE-T001 / TRD-075.
  Extends the TRD-014 idempotency key contract (REQ-017, REQ-026).
  """
  use GenServer
  @table :foreman_idempotency_keys

  import Ecto.Query
  require Logger
  alias ForemanServer.Idempotency.IdempotencyKey
  alias ForemanServer.Agents.JidoCheckpointStore

  # --- public API ---

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Start the KeyStore server if not already running, otherwise return {:ok, pid}."
  def ensure_started(opts \\ []) do
    case GenServer.start_link(__MODULE__, opts, name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc """
  Mark an idempotency key as started, recording optional metadata.
  Returns `:ok` on success.
  """
  def mark_started(key, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:record, key, :started, metadata})
  end

  @doc """
  Mark an idempotency key as completed, recording an optional result.
  Returns `:ok` on success.
  """
  def mark_completed(key, result \\ %{}) do
    GenServer.call(__MODULE__, {:record, key, :completed, result})
  end

  @doc """
  Mark an idempotency key as ambiguous with a reason (default: "timeout").
  Returns `:ok` on success.
  """
  def mark_ambiguous(key, reason \\ "timeout") do
    GenServer.call(__MODULE__, {:record, key, :ambiguous, %{reason: reason}})
  end

  @doc """
  Mark an idempotency key as failed with a reason (default: "failed").
  The phase ended in an observed error and may have left side effects; the
  run's failure path owns it. Returns `:ok` on success.
  """
  def mark_failed(key, reason \\ "failed", meta \\ %{}) do
    GenServer.call(__MODULE__, {:record, key, :failed, Map.put(meta, :reason, reason)})
  end

  @doc """
  The metadata that clears what recovery wrote on a key (the unresolved marker and the
  decision). The store merges metadata over what it holds, so a settle or a re-mark that
  does not name these fields leaves a marker or decision written by a scan in between.
  """
  @spec recovery_fields_cleared() :: %{String.t() => nil}
  def recovery_fields_cleared do
    %{"unresolved_at_run_version" => nil, "unresolved_reason" => nil, "decision" => nil}
  end

  @doc """
  True exactly for effect keys (`effect:<class>:<run_id>:<identity>`, written by
  `ForemanServer.Idempotency.Effect`). Agent-phase keys are
  `"phase:<run_id>:<phase_id>"`, so the two families cannot collide. Recovery
  and the doctor partition keys with this predicate rather than the prefix.
  """
  @spec effect_key?(term()) :: boolean()
  def effect_key?("effect:" <> _), do: true
  def effect_key?(_), do: false

  @unresolved_version_field "unresolved_at_run_version"

  @doc """
  Record on an effect key that recovery could not resolve it: the key stays
  (or becomes) `ambiguous` and its metadata gains the run stream's version at
  that moment (`unresolved_at_run_version`) and the reason
  (`unresolved_reason`). `Idempotency.Effect.run/4` refuses to repeat a key that
  carries the marker until the run has been reset. String keys, merged with the
  stored metadata like every record call. Returns `:ok` or `{:error, reason}`.
  """
  @spec mark_unresolved(String.t(), non_neg_integer(), String.t()) :: :ok | {:error, term()}
  def mark_unresolved(key, run_version, reason)
      when is_integer(run_version) and run_version >= 0 do
    GenServer.call(
      __MODULE__,
      {:record, key, :ambiguous,
       %{@unresolved_version_field => run_version, "unresolved_reason" => reason}}
    )
  end

  @doc """
  The run-stream version recorded by `mark_unresolved/3` in a key's metadata
  (string key), `:none` when the key carries no marker (absent or nil), and
  `{:error, :malformed}` when a marker is present but is not a non-negative
  integer: the caller must treat that as unresolved, never as no marker.
  """
  @spec unresolved_version(term()) :: {:ok, non_neg_integer()} | :none | {:error, :malformed}
  def unresolved_version(metadata) when is_map(metadata) do
    case Map.get(metadata, @unresolved_version_field) do
      nil -> :none
      version when is_integer(version) and version >= 0 -> {:ok, version}
      _other -> {:error, :malformed}
    end
  end

  def unresolved_version(_metadata), do: :none

  @doc """
  Atomically move an unresolved key to `started` (an operator `run.reset` has
  lifted the refusal): only when the key is `ambiguous` and its marker is still
  `observed_version`, the version the caller read before deciding the reset
  lifts it. So of two concurrent callers that both saw the reset only one wins,
  and a marker rewritten after the check is not lifted on the earlier decision.
  `meta` is merged like any record call; it must clear the marker fields. A
  malformed marker is never lifted (`unresolved_version/1` is an error): it is
  operator-repair only.

  Returns `:lifted`, `:not_unresolved` (the key no longer carries that marker) or
  `{:error, reason}`.
  """
  @spec lift_unresolved(String.t(), non_neg_integer(), map()) ::
          :lifted | :not_unresolved | {:error, term()}
  def lift_unresolved(key, observed_version, meta)
      when is_integer(observed_version) and is_map(meta) do
    GenServer.call(__MODULE__, {:lift_unresolved, key, observed_version, meta})
  end

  @decision_field "decision"

  @typedoc "What the boot sweep records on an `ambiguous` effect key once its reconciler has spoken."
  @type decision :: :not_done

  @doc """
  Record on an `ambiguous` effect key the decision that its effect did not happen
  (`:not_done`): the metadata gains `"decision" => "not_done"` and
  `Idempotency.Effect.run/4` may attempt the effect again (an `ambiguous` key with no
  decision is refused as undecided). A compare-and-set inside the store: only a key that
  is `ambiguous` and carries no unresolved marker (`mark_unresolved/3`) takes it, so a
  key its effect settled in the meantime is not decided on a stale read, and neither is
  a key recovery marked unresolved. Deciding a decided key again is `:ok`.

  Returns `:ok`, `:not_decidable` (no such key, or it is not an `ambiguous` key without a
  marker) or `{:error, reason}` (the write failed; the key is as it was).
  """
  @spec mark_decided(String.t(), decision()) :: :ok | :not_decidable | {:error, term()}
  def mark_decided(key, :not_done = decision) do
    GenServer.call(__MODULE__, {:mark_decided, key, decision})
  end

  @doc """
  The decision recorded in a key's metadata (string key): `:not_done` once
  `mark_decided/2` wrote it, `:none` when the key carries none (absent or nil: re-marking
  a key `started` clears it) and for any other value, which decides nothing.
  """
  @spec decision(term()) :: decision() | :none
  def decision(metadata) when is_map(metadata) do
    case Map.get(metadata, @decision_field) do
      "not_done" -> :not_done
      _undecided -> :none
    end
  end

  def decision(_metadata), do: :none

  @doc """
  Atomically move a decided key to `started` and clear its decision: only when the key
  is `ambiguous`, carries no unresolved marker and still carries `observed`, the decision
  the caller read before deciding to run the effect. So of two concurrent callers that
  both read the decision only one wins; the other finds the key `started`. `meta` is
  merged like any record call; it must clear the decision (`"decision" => nil`), because
  the merge cannot delete a field.

  Returns `:consumed`, `:not_decided` (the key no longer carries that decision) or
  `{:error, reason}`.
  """
  @spec consume_decision(String.t(), decision(), map()) ::
          :consumed | :not_decided | {:error, term()}
  def consume_decision(key, :not_done = observed, meta) when is_map(meta) do
    GenServer.call(__MODULE__, {:consume_decision, key, observed, meta})
  end

  @doc """
  Return the current status of an idempotency key.
  Returns `{:ok, status}` when found, `:not_found` otherwise.
  """
  def status(key) do
    GenServer.call(__MODULE__, {:status, key})
  end

  @doc """
  Return the full record (status + metadata) for an idempotency key.
  Returns `{:ok, record}` when found, `:not_found` otherwise.
  """
  def get(key) do
    GenServer.call(__MODULE__, {:get, key})
  end

  @doc """
  List all keys with a given status.
  Returns `[key, ...]` or `[]`.
  """
  def list_by_status(status) do
    GenServer.call(__MODULE__, {:list_by_status, status})
  end

  @typedoc "A stored key record as `list_records_checked/1` returns it."
  @type stored_record :: %{key: String.t(), status: atom(), metadata: map()}

  @doc """
  List the full records (key, status, metadata) with a given status, reporting
  a failed read instead of hiding it.

  Returns `{:ok, [record]}` or `{:error, reason}`. With a repo configured it
  queries the stored rows under a rescue and NEVER falls back to ETS (a
  fallback would show an outage as an empty list); a repo that is down, or a
  `KeyStore` that is not running, is `{:error, reason}`. Without a repo it
  scans the ETS table. Metadata keys are strings when read from the repo
  (JSON round trip) and as written when read from ETS. `list_by_status/1`
  keeps its ETS fallback: boot reconciliation reads it and is not changed here.
  """
  @spec list_records_checked(atom()) :: {:ok, [stored_record()]} | {:error, term()}
  def list_records_checked(status) do
    GenServer.call(__MODULE__, {:list_records_checked, status})
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc """
  The store's durability: `:durable` only when a repo is configured AND answers
  (probed by a one-row read of the same table);
  `{:not_durable, :no_repo}` for the ETS-only fallback (keys do not survive a
  restart); `{:not_durable, {:unreachable, reason}}` for a repo that is
  configured but does not answer (or a `KeyStore` that is not running).
  """
  @spec durability() :: :durable | {:not_durable, :no_repo | {:unreachable, term()}}
  def durability do
    GenServer.call(__MODULE__, :durability)
  catch
    :exit, reason -> {:not_durable, {:unreachable, {:exit, reason}}}
  end

  @doc "True only when `durability/0` is `:durable`."
  @spec durable?() :: boolean()
  def durable?, do: durability() == :durable

  # `config :foreman_server, :jido_ecto, enabled: true` is read at `application.ex`
  # (`maybe_jido_checkpoint_repo_child/0`). Do not name `FOREMAN_JIDO_ECTO_ENABLED`:
  # only a comment in `config/prod.exs` mentions it and no code reads it.
  @production_switches "`config :foreman_server, :jido_ecto, enabled: true` and " <>
                         "JIDO_CHECKPOINT_DATABASE_URL"

  @doc """
  The one-line statement of the store's durability, used by the boot log and the
  doctor. `nil` when the store is durable.
  """
  @spec durability_note() :: String.t() | nil
  def durability_note, do: note_for(durability())

  defp note_for(:durable), do: nil

  defp note_for({:not_durable, :no_repo}) do
    "idempotency store is not durable: no repo is configured (ETS fallback), so effect keys " <>
      "do not survive a restart and crash recovery cannot reconcile effects; set " <>
      @production_switches
  end

  defp note_for({:not_durable, {:unreachable, reason}}) do
    "idempotency store is configured but unreachable (#{inspect(reason, limit: 5)}): " <>
      "keys written now do not survive a restart and crash recovery cannot reconcile " <>
      "effects; check " <> @production_switches
  end

  @doc """
  Whether `config :foreman_server, :require_durable_store_for_gating` is on
  (true in `config.exs`, false in `dev.exs` and `test.exs`). Anything but a boolean
  raises: the guard must never read a mistyped switch as "off".
  """
  @spec durable_store_required?() :: boolean()
  def durable_store_required? do
    case Application.get_env(:foreman_server, :require_durable_store_for_gating, true) do
      flag when is_boolean(flag) ->
        flag

      other ->
        raise ArgumentError,
              "config :foreman_server, :require_durable_store_for_gating must be a boolean, " <>
                "got: #{inspect(other)}"
    end
  end

  @doc """
  The Phase 1 gating precondition (P-3): `:ok` when the store is durable or when
  `:require_durable_store_for_gating` is false; otherwise
  `{:error, {:store_not_durable, note}}` with the `durability_note/0` text, so a gated
  project is never set up or approved while keys would not survive a restart (the
  note names the switches to turn on, whether the repo is missing or unreachable).
  """
  @spec require_durable() :: :ok | {:error, {:store_not_durable, String.t()}}
  def require_durable do
    if durable_store_required?() do
      case durability() do
        :durable -> :ok
        not_durable -> {:error, {:store_not_durable, note_for(not_durable)}}
      end
    else
      :ok
    end
  end

  @doc """
  Boot report: when the store is not durable, logs an error and emits
  `[:foreman_server, :idempotency, :key_store, :not_durable]` (measurements
  `%{count: 1}`, metadata `%{reason: :no_repo | :unreachable}`). Called once from
  `ForemanServer.Application.start/2` after the supervision tree is up, so a
  configured repo has started.
  """
  @spec report_boot_durability() :: :durable | {:not_durable, :no_repo | {:unreachable, term()}}
  def report_boot_durability do
    case durability() do
      :durable ->
        :durable

      {:not_durable, detail} = result ->
        reason = if detail == :no_repo, do: :no_repo, else: :unreachable
        Logger.error(durability_note())

        :telemetry.execute(
          [:foreman_server, :idempotency, :key_store, :not_durable],
          %{count: 1},
          %{reason: reason}
        )

        result
    end
  end

  # --- genserver callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{repo: repo_from_config()}}
  end

  # Durable path: repo configured — merges new metadata into existing so that
  # later transitions (e.g. started→ambiguous via HeartbeatLease) do not wipe
  # fields stored earlier (run_id, task_id).
  @impl true
  def handle_call({:record, key, status, meta}, _from, %{repo: repo} = state)
      when repo != nil do
    merged =
      case :ets.lookup(@table, key) do
        [{^key, _status, existing}] -> Map.merge(existing, meta)
        [] -> merge_stored(repo, key, meta)
      end

    changeset =
      IdempotencyKey.upsert_changeset(%IdempotencyKey{key: key}, %{
        key: key,
        status: status,
        metadata: merged
      })

    case repo.insert(changeset,
           conflict_target: :key,
           on_conflict: [set: [status: status, metadata: merged]]
         ) do
      {:ok, _} ->
        :ets.insert(@table, {key, status, merged})
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  rescue
    err ->
      {:reply, {:error, err}, state}
  end

  # Fallback path: no repo configured — ETS only — same merge semantics.
  @impl true
  def handle_call({:record, key, status, meta}, _from, %{repo: nil} = state) do
    existing_meta =
      case :ets.lookup(@table, key) do
        [{^key, _status, existing}] -> existing
        [] -> %{}
      end

    merged = Map.merge(existing_meta, meta)
    :ets.insert(@table, {key, status, merged})
    {:reply, :ok, state}
  end

  # Compare-and-set for `lift_unresolved/2`: runs inside the server, so the
  # marker check and the `started` write cannot interleave with another caller.
  @impl true
  def handle_call({:lift_unresolved, key, observed_version, meta}, from, state) do
    case current_record(state, key) do
      {:ok, :ambiguous, stored} when is_map(stored) ->
        if unresolved_version(stored) == {:ok, observed_version} do
          case handle_call({:record, key, :started, meta}, from, state) do
            {:reply, :ok, state} -> {:reply, :lifted, state}
            other -> other
          end
        else
          {:reply, :not_unresolved, state}
        end

      _no_marker ->
        {:reply, :not_unresolved, state}
    end
  rescue
    err -> {:reply, {:error, err}, state}
  end

  # Compare-and-set for `mark_decided/2`: runs inside the server, so the status and
  # marker check and the write cannot interleave with another caller.
  @impl true
  def handle_call({:mark_decided, key, decision}, from, state) do
    case current_record(state, key) do
      {:ok, :ambiguous, stored} when is_map(stored) ->
        if unresolved_version(stored) == :none do
          handle_call(
            {:record, key, :ambiguous, %{@decision_field => Atom.to_string(decision)}},
            from,
            state
          )
        else
          {:reply, :not_decidable, state}
        end

      _not_decidable ->
        {:reply, :not_decidable, state}
    end
  rescue
    err -> {:reply, {:error, err}, state}
  end

  # Compare-and-set for `consume_decision/3`: runs inside the server, so the decision
  # check and the `started` write cannot interleave with another caller.
  @impl true
  def handle_call({:consume_decision, key, observed, meta}, from, state) do
    case current_record(state, key) do
      {:ok, :ambiguous, stored} when is_map(stored) ->
        if decision(stored) == observed and unresolved_version(stored) == :none do
          case handle_call({:record, key, :started, meta}, from, state) do
            {:reply, :ok, state} -> {:reply, :consumed, state}
            other -> other
          end
        else
          {:reply, :not_decided, state}
        end

      _not_decided ->
        {:reply, :not_decided, state}
    end
  rescue
    err -> {:reply, {:error, err}, state}
  end

  # Durable path: status lookup
  @impl true
  def handle_call({:status, key}, _from, %{repo: repo} = state)
      when repo != nil do
    result =
      case :ets.lookup(@table, key) do
        [{^key, status, _meta}] ->
          {:ok, status}

        [] ->
          # Miss in ETS but might exist in DB — query repo
          case repo.get(IdempotencyKey, key) do
            %IdempotencyKey{status: status} ->
              {:ok, status}

            nil ->
              :not_found
          end
      end

    {:reply, result, state}
  end

  # Fallback path: ETS status lookup
  @impl true
  def handle_call({:status, key}, _from, %{repo: nil} = state) do
    result =
      case :ets.lookup(@table, key) do
        [{^key, status, _meta}] -> {:ok, status}
        [] -> :not_found
      end

    {:reply, result, state}
  end

  # Durable path: full record lookup
  @impl true
  def handle_call({:get, key}, _from, %{repo: repo} = state)
      when repo != nil do
    result =
      case :ets.lookup(@table, key) do
        [{^key, status, meta}] ->
          {:ok, %{key: key, status: status, metadata: meta}}

        [] ->
          case repo.get(IdempotencyKey, key) do
            %IdempotencyKey{} = record ->
              {:ok, %{key: record.key, status: record.status, metadata: record.metadata}}

            nil ->
              :not_found
          end
      end

    {:reply, result, state}
  end

  # Fallback path: ETS full record lookup
  @impl true
  def handle_call({:get, key}, _from, %{repo: nil} = state) do
    result =
      case :ets.lookup(@table, key) do
        [{^key, status, meta}] -> {:ok, %{key: key, status: status, metadata: meta}}
        [] -> :not_found
      end

    {:reply, result, state}
  end

  # Checked reads and the durability probe. A failed repo query is an error, never ETS.
  @impl true
  def handle_call({:list_records_checked, status}, _from, %{repo: repo} = state)
      when repo != nil do
    {:reply, query_records(repo, status), state}
  end

  def handle_call({:list_records_checked, status}, _from, %{repo: nil} = state) do
    records =
      for {key, ^status, meta} <- :ets.tab2list(@table),
          do: %{key: key, status: status, metadata: meta}

    {:reply, {:ok, records}, state}
  end

  def handle_call(:durability, _from, %{repo: nil} = state),
    do: {:reply, {:not_durable, :no_repo}, state}

  def handle_call(:durability, _from, %{repo: repo} = state) do
    case probe_repo(repo) do
      :ok -> {:reply, :durable, state}
      {:error, reason} -> {:reply, {:not_durable, {:unreachable, reason}}, state}
    end
  end

  # Durable path: list by status
  @impl true
  def handle_call({:list_by_status, status}, _from, %{repo: repo} = state)
      when repo != nil do
    keys =
      repo.all(from(k in IdempotencyKey, where: k.status == ^status, select: k.key))

    {:reply, keys, state}
  rescue
    _err ->
      # Fall back to ETS scan if the query fails
      keys =
        :ets.match_object(@table, {:_, status, :_})
        |> Enum.map(fn {key, _, _} -> key end)

      {:reply, keys, state}
  end

  # Fallback path: ETS list by status
  @impl true
  def handle_call({:list_by_status, status}, _from, %{repo: nil} = state) do
    keys =
      :ets.match_object(@table, {:_, status, :_})
      |> Enum.map(fn {key, _, _} -> key end)

    {:reply, keys, state}
  end

  # --- internal helpers ---

  # Does the repo answer? One key, never the rows: the probe runs at boot and on every doctor
  # render, so it must not load every ambiguous record with its metadata.
  defp probe_repo(repo) do
    _ = repo.all(from(k in IdempotencyKey, limit: 1, select: k.key))
    :ok
  rescue
    err -> {:error, err}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp query_records(repo, status) do
    rows = repo.all(from(k in IdempotencyKey, where: k.status == ^status))

    {:ok, Enum.map(rows, &%{key: &1.key, status: &1.status, metadata: &1.metadata || %{}})}
  rescue
    err -> {:error, err}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp current_record(%{repo: repo}, key) do
    case :ets.lookup(@table, key) do
      [{^key, status, meta}] ->
        {:ok, status, meta}

      [] when repo == nil ->
        :not_found

      [] ->
        case repo.get(IdempotencyKey, key) do
          %IdempotencyKey{status: status, metadata: meta} -> {:ok, status, meta}
          nil -> :not_found
        end
    end
  end

  # After a restart ETS has no copy of the key (`init/1` creates the table
  # empty) but the stored row does. Merge the incoming fields into the stored
  # metadata so a status change never drops a field it did not name. The stored
  # map has string keys (JSON round trip), so the incoming keys are converted
  # to strings to line up with it. No stored row: the incoming fields as given.
  defp merge_stored(repo, key, meta) do
    case repo.get(IdempotencyKey, key) do
      %IdempotencyKey{metadata: stored} when is_map(stored) ->
        Map.merge(stringify_keys(stored), stringify_keys(meta))

      _none ->
        meta
    end
  end

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp repo_from_config do
    Application.get_env(:foreman_server, JidoCheckpointStore, [])[:repo]
  end
end
