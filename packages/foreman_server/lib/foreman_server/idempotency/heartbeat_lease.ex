defmodule ForemanServer.Idempotency.HeartbeatLease do
  @moduledoc """
  Heartbeat lease with expiry detection.

  Manages TTL-based leases keyed by idempotency key. When a heartbeat
  lease expires, the associated idempotency key transitions from
  `started` → `ambiguous`.

  The `(worker_id, run_id)` → `key` mapping is maintained so that
  `ForemanServer.Overwatch.Tracker` (which knows only `worker_id` and
  `run_id`) can call `on_worker_unresponsive/2` on liveness timeout and
  trigger the ambiguity transition without knowing the idempotency key.

  TRD-2026-4212be7e / RTE-T002 / TRD-076.
  Extends the TRD-014 heartbeat protocol.
  """
  use GenServer
  require Logger

  @default_lease_ms 30_000

  defstruct [:lease_id, :key, :expires_at, :timer_ref]

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Start the HeartbeatLease server if not already running, otherwise return {:ok, pid}."
  def ensure_started(opts \\ []) do
    case GenServer.start_link(__MODULE__, opts, name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc """
  Acquire a heartbeat lease for `key`. Marks the key as `started` in
  `KeyStore` with `task_id` and `run_id` in metadata so crash recovery can
  look up side effects without parsing the composite key string.
  Returns `{:ok, lease}` or `{:error, reason}`.
  """
  @spec acquire(key :: String.t(), lease_ms :: non_neg_integer(), task_id :: String.t(), run_id :: String.t()) ::
          {:ok, %__MODULE__{}} | {:error, term()}
  def acquire(key, lease_ms \\ @default_lease_ms, task_id \\ "", run_id \\ "")
      when is_binary(key) and is_integer(lease_ms) and lease_ms >= 0 and is_binary(task_id) and is_binary(run_id),
      do: GenServer.call(__MODULE__, {:acquire, key, lease_ms, task_id, run_id})

  @doc """
  Renew an existing heartbeat lease, resetting its TTL.
  Idempotent: if no lease exists for `key`, returns `:not_found`.
  """
  @spec renew(key :: String.t(), lease_ms :: non_neg_integer()) ::
          {:ok, %__MODULE__{}} | :not_found
  def renew(key, lease_ms \\ @default_lease_ms),
    do: GenServer.call(__MODULE__, {:renew, key, lease_ms})

  @doc """
  Release a heartbeat lease, marking the key as `completed` in `KeyStore`.
  Idempotent: if no lease exists for `key`, returns `:not_found`.
  """
  @spec release(key :: String.t()) :: :ok | :not_found
  def release(key), do: GenServer.call(__MODULE__, {:release, key})

  @doc """
  Return the current lease for `key`, or `:not_found`.
  """
  @spec status(key :: String.t()) :: {:ok, %__MODULE__{}} | :not_found
  def status(key), do: GenServer.call(__MODULE__, {:status, key})

  @doc """
  Return the idempotency key registered for `(worker_id, run_id)`,
  or `:not_found` when no lease is registered for that worker.
  Used by `ForemanServer.Overwatch.Tracker` to renew the lease on
  heartbeat without needing to pass the key through the Tracker call path.
  """
  @spec key_for(worker_id :: String.t(), run_id :: String.t()) ::
          {:ok, String.t()} | :not_found
  def key_for(worker_id, run_id),
    do: GenServer.call(__MODULE__, {:key_for, worker_id, run_id})

  @doc """
  Register a `(worker_id, run_id)` → `key` mapping so that
  `on_worker_unresponsive/2` can look up the key without receiving it
  as an argument from the Tracker.

  The Tracker is the sole producer of `WorkerUnresponsive` and cannot
  be modified to accept an additional `key` argument at that call site.
  Instead, when a run starts the executor calls `acquire/2` (which
  records the key) and then `register_worker/3` to wire the worker
  tuple into the lease registry. On liveness timeout the Tracker calls
  `on_worker_unresponsive/2` which uses the registry to find the key
  and marks it ambiguous.
  """
  @spec register_worker(worker_id :: String.t(), run_id :: String.t(), key :: String.t()) :: :ok
  def register_worker(worker_id, run_id, key),
    do: GenServer.cast(__MODULE__, {:register_worker, worker_id, run_id, key})

  @doc """
  Called by `ForemanServer.Overwatch.Tracker` when a worker's liveness
  timer fires. Looks up the idempotency key for `(worker_id, run_id)` and
  marks it `ambiguous` in `KeyStore`.

  Safe to call even when no lease is registered — returns `:not_found`
  without side effects.
  """
  @spec on_worker_unresponsive(worker_id :: String.t(), run_id :: String.t()) ::
          :ok | :not_found
  def on_worker_unresponsive(worker_id, run_id),
    do: GenServer.call(__MODULE__, {:on_worker_unresponsive, worker_id, run_id})
  @impl true
  def init(_opts), do: {:ok, %{leases: %{}, workers: %{}}}
  @impl true
  def handle_call({:acquire, key, lease_ms, task_id, run_id}, _from, state) do
    lease_id = "lease-#{System.unique_integer([:positive])}"
    timer_ref = Process.send_after(self(), {:expire, key}, lease_ms)
    lease = %__MODULE__{lease_id: lease_id, key: key, expires_at: System.monotonic_time(:millisecond) + lease_ms, timer_ref: timer_ref}

    metadata = %{
      lease_id: lease_id,
      task_id: task_id,
      run_id: run_id
    }

    ForemanServer.Idempotency.KeyStore.mark_started(key, metadata)
    {:reply, {:ok, lease}, put_in(state.leases[key], lease)}
  end

  @impl true
  def handle_call({:renew, key, lease_ms}, _from, state) do
    case Map.get(state.leases, key) do
      nil -> {:reply, :not_found, state}
      lease ->
        Process.cancel_timer(lease.timer_ref)
        new_ref = Process.send_after(self(), {:expire, key}, lease_ms)
        updated = %{lease | timer_ref: new_ref, expires_at: System.monotonic_time(:millisecond) + lease_ms}
        {:reply, {:ok, updated}, put_in(state.leases[key], updated)}
    end
  end

  @impl true
  def handle_call({:release, key}, _from, state) do
    # Also remove any worker mapping for this key so the Tracker cannot
    # spuriously trigger ambiguity after a clean completion.
    worker_key = worker_key_for_key(state.workers, key)
    :ok = ForemanServer.Idempotency.KeyStore.mark_completed(key)
    state = remove_worker_mapping(state, worker_key)
    state = remove_lease(state, key)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:status, key}, _from, state) do
    case Map.get(state.leases, key) do
      nil -> {:reply, :not_found, state}
      lease -> {:reply, {:ok, lease}, state}
    end
  end

  @impl true
  def handle_call({:key_for, worker_id, run_id}, _from, state) do
    case Map.get(state.workers, {worker_id, run_id}) do
      nil -> {:reply, :not_found, state}
      key -> {:reply, {:ok, key}, state}
    end
  end

  @impl true
  def handle_call({:on_worker_unresponsive, worker_id, run_id}, _from, state) do
    case Map.get(state.workers, {worker_id, run_id}) do
      nil ->
        {:reply, :not_found, state}

      key ->
        # Remove the worker mapping so repeated calls are no-ops.
        state = remove_worker_mapping(state, {worker_id, run_id})

        # Also cancel the lease timer so the expiry handle_info cannot
        # also fire and double-mark.
        state =
          case Map.get(state.leases, key) do
            nil -> state
            lease ->
              Process.cancel_timer(lease.timer_ref)
              remove_lease(state, key)
          end

        Logger.warning(
          "HeartbeatLease: worker_unresponsive for {#{worker_id}, #{run_id}}; " <>
            "marking key=#{inspect(key)} ambiguous"
        )

        ForemanServer.Idempotency.KeyStore.mark_ambiguous(key, "heartbeat_timeout")
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:register_worker, worker_id, run_id, key}, state) do
    # Remove any stale mapping for this worker pair before inserting.
    state = remove_worker_mapping(state, {worker_id, run_id})
    {:noreply, put_in(state.workers[{worker_id, run_id}], key)}
  end

  @impl true
  def handle_info({:expire, key}, state) do
    case Map.pop(state.leases, key) do
      {nil, _} ->
        {:noreply, state}

      {lease, new_leases} ->
        # Cancel the timer the lease registered (best-effort: it may have
        # already fired concurrently).
        Process.cancel_timer(lease.timer_ref)
        state = %{state | leases: new_leases}
        worker_k = worker_key_for_key(state.workers, key)
        state = remove_worker_mapping(state, worker_k)

        Logger.warning("HeartbeatLease: lease expired for key=#{key}; marking ambiguous")
        ForemanServer.Idempotency.KeyStore.mark_ambiguous(key, "heartbeat_timeout")
        {:noreply, state}
    end
  end

  # ------------------------------------------------------------------
  # Internal helpers
  # ------------------------------------------------------------------

  defp remove_lease(state, key) do
    case Map.pop(state.leases, key) do
      {nil, _} -> state
      {lease, new_leases} ->
        Process.cancel_timer(lease.timer_ref)
        %{state | leases: new_leases}
    end
  end

  defp remove_worker_mapping(state, {_w, _r} = wk), do: %{state | workers: Map.delete(state.workers, wk)}
  defp remove_worker_mapping(state, nil), do: state

  # Invert the workers map to find the worker key for a given idempotency key.
  # O(n) but called only on release/expire paths which are infrequent.
  defp worker_key_for_key(workers, key) do
    Enum.find_value(workers, nil, fn {wk, k} -> if k == key, do: wk end)
  end
end
