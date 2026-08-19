defmodule ForemanServer.Idempotency.HeartbeatLeaseTest do
  use ExUnit.Case, async: false

  test "acquire returns a lease" do
    {:ok, _pid} = ForemanServer.Idempotency.HeartbeatLease.start_link()
    {:ok, _pid2} = ForemanServer.Idempotency.KeyStore.start_link()
    assert {:ok, lease} = ForemanServer.Idempotency.HeartbeatLease.acquire("k1", 60_000)
    assert is_binary(lease.lease_id)
  end

  test "release marks completed" do
    {:ok, _pid} = ForemanServer.Idempotency.HeartbeatLease.start_link()
    {:ok, _pid2} = ForemanServer.Idempotency.KeyStore.start_link()
    {:ok, _lease} = ForemanServer.Idempotency.HeartbeatLease.acquire("k2", 60_000)
    assert :ok = ForemanServer.Idempotency.HeartbeatLease.release("k2")
    assert :not_found = ForemanServer.Idempotency.HeartbeatLease.status("k2")
  end

  test "status of unknown key is :not_found" do
    {:ok, _pid} = ForemanServer.Idempotency.HeartbeatLease.start_link()
    assert :not_found = ForemanServer.Idempotency.HeartbeatLease.status("unknown")
  end
end
