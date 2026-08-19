defmodule ForemanServer.Idempotency.HeartbeatLease do
  @moduledoc """
  Heartbeat lease with expiry detection. Transitions started -> ambiguous on expiry.
  TRD-2026-4212be7e / RTE-T002 / TRD-076.
  """
  use GenServer
  require Logger
  @default_lease_ms 30_000

  defstruct [:lease_id, :key, :expires_at, :timer_ref]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts), do: {:ok, %{leases: %{}}}

  def acquire(key, lease_ms \\ @default_lease_ms), do: GenServer.call(__MODULE__, {:acquire, key, lease_ms})
  def renew(key), do: GenServer.call(__MODULE__, {:renew, key, @default_lease_ms})
  def release(key), do: GenServer.call(__MODULE__, {:release, key})
  def status(key), do: GenServer.call(__MODULE__, {:status, key})

  @impl true
  def handle_call({:acquire, key, lease_ms}, _from, state) do
    lease_id = "lease-#{System.unique_integer([:positive])}"
    timer_ref = Process.send_after(self(), {:expire, key}, lease_ms)
    lease = %__MODULE__{lease_id: lease_id, key: key, expires_at: System.monotonic_time(:millisecond) + lease_ms, timer_ref: timer_ref}
    ForemanServer.Idempotency.KeyStore.mark_started(key, %{lease_id: lease_id})
    {:reply, {:ok, lease}, put_in(state.leases[key], lease)}
  end

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

  def handle_call({:release, key}, _from, state) do
    case Map.pop(state.leases, key) do
      {nil, _} -> {:reply, :not_found, state}
      {lease, new_state} ->
        Process.cancel_timer(lease.timer_ref)
        ForemanServer.Idempotency.KeyStore.mark_completed(key, %{lease_id: lease.lease_id})
        {:reply, :ok, new_state}
    end
  end

  def handle_call({:status, key}, _from, state) do
    case Map.get(state.leases, key) do
      nil -> {:reply, :not_found, state}
      lease -> {:reply, {:ok, lease}, state}
    end
  end

  @impl true
  def handle_info({:expire, key}, state) do
    case Map.pop(state.leases, key) do
      {nil, _} -> {:noreply, state}
      {_lease, new_state} ->
        Logger.warning("Heartbeat lease expired for key=#{key}; marking ambiguous")
        ForemanServer.Idempotency.KeyStore.mark_ambiguous(key, "heartbeat_timeout")
        {:noreply, new_state}
    end
  end
end
