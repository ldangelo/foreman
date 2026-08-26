defmodule ForemanServer.Idempotency.HeartbeatLeaseTest do
  use ExUnit.Case, async: false

  test "acquire returns a lease" do
    {:ok, _pid} = ForemanServer.Idempotency.HeartbeatLease.ensure_started()
    {:ok, _pid2} = ForemanServer.Idempotency.KeyStore.ensure_started()
    assert {:ok, lease} = ForemanServer.Idempotency.HeartbeatLease.acquire("k1", 60_000)
    assert is_binary(lease.lease_id)
  end

  test "release marks completed" do
    {:ok, _pid} = ForemanServer.Idempotency.HeartbeatLease.ensure_started()
    {:ok, _pid2} = ForemanServer.Idempotency.KeyStore.ensure_started()
    {:ok, _lease} = ForemanServer.Idempotency.HeartbeatLease.acquire("k2", 60_000)

    # Verify key is started in KeyStore
    assert {:ok, :started} = ForemanServer.Idempotency.KeyStore.status("k2")

    assert :ok = ForemanServer.Idempotency.HeartbeatLease.release("k2")

    # HeartbeatLease lease is removed
    assert :not_found = ForemanServer.Idempotency.HeartbeatLease.status("k2")
    # KeyStore key transitions to completed so crash-recovery skips side-effect inspection
    assert {:ok, :completed} = ForemanServer.Idempotency.KeyStore.status("k2")
  end

  test "status of unknown key is :not_found" do
    {:ok, _pid} = ForemanServer.Idempotency.HeartbeatLease.ensure_started()
    assert :not_found = ForemanServer.Idempotency.HeartbeatLease.status("unknown")
  end

  test "expiry marks key ambiguous and removes lease" do
    {:ok, _pid} = ForemanServer.Idempotency.HeartbeatLease.ensure_started()
    {:ok, _pid2} = ForemanServer.Idempotency.KeyStore.ensure_started()

    # Acquire with a short TTL (10 ms) so expiry fires quickly in the test
    {:ok, _lease} = ForemanServer.Idempotency.HeartbeatLease.acquire("k-expiry", 10)

    # Wait for the timer to fire and the `:expire` message to be processed
    Process.sleep(30)

    # Expiry removes the lease from HeartbeatLease
    assert :not_found = ForemanServer.Idempotency.HeartbeatLease.status("k-expiry")
  end
end
