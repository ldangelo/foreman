defmodule ForemanServer.Idempotency.KeyStore do
  @moduledoc """
  Durable idempotency key records with status {started, completed, ambiguous}.

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
    existing_meta =
      case :ets.lookup(@table, key) do
        [{^key, _status, existing}] -> existing
        [] -> %{}
      end

    merged = Map.merge(existing_meta, meta)

    changeset =
      IdempotencyKey.upsert_changeset(%IdempotencyKey{key: key}, %{
        key: key,
        status: status,
        metadata: merged
      })

    case repo.insert(changeset, conflict_target: :key, on_conflict: [set: [status: status, metadata: merged]]) do
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

  # Durable path: status lookup
  @impl true
  def handle_call({:status, key}, _from, %{repo: repo} = state)
      when repo != nil do
    result =
      case :ets.lookup(@table, key) do
        [{^key, status, _meta}] -> {:ok, status}
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

  # Durable path: list by status
  @impl true
  def handle_call({:list_by_status, status}, _from, %{repo: repo} = state)
      when repo != nil do
    keys =
      repo.all(
        from(k in IdempotencyKey, where: k.status == ^status, select: k.key)
      )

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

  defp repo_from_config do
    Application.get_env(:foreman_server, JidoCheckpointStore, [])[:repo]
  end
end
