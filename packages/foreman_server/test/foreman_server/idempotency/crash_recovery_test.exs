defmodule ForemanServer.Idempotency.CrashRecoveryTest do
  use ExUnit.Case, async: false
  test "completed -> skip" do
    {:ok, _pid} = ForemanServer.Idempotency.KeyStore.start_link()
    :ok = ForemanServer.Idempotency.KeyStore.mark_completed("k1")
    assert {:skip, :already_completed} = ForemanServer.Idempotency.CrashRecovery.reconcile("k1")
  end
  test "ambiguous -> retry" do
    {:ok, _pid} = ForemanServer.Idempotency.KeyStore.start_link()
    :ok = ForemanServer.Idempotency.KeyStore.mark_ambiguous("k2")
    assert {:retry, :no_side_effects} = ForemanServer.Idempotency.CrashRecovery.reconcile("k2")
  end
  test "not_found -> fresh" do
    {:ok, _pid} = ForemanServer.Idempotency.KeyStore.start_link()
    assert {:retry, :fresh} = ForemanServer.Idempotency.CrashRecovery.reconcile("unknown")
  end
end
