defmodule ForemanServer.Idempotency.CrashRecoveryCharacterizationTest do
  use ExUnit.Case, async: false
  @moduletag :characterization
  test "completed key is skipped on recovery" do
    {:ok, _pid} = ForemanServer.Idempotency.KeyStore.start_link()
    :ok = ForemanServer.Idempotency.KeyStore.mark_completed("k1")
    counter = :counters.new(1, [])
    assert {:skip, :already_completed} = ForemanServer.Idempotency.CrashRecovery.reconcile("k1", fn _ ->
      :counters.add(counter, 1, 1)
      true
    end)
    assert :counters.get(counter, 1) == 0
  end
  test "ambiguous with no side effects retries" do
    {:ok, _pid} = ForemanServer.Idempotency.KeyStore.start_link()
    :ok = ForemanServer.Idempotency.KeyStore.mark_ambiguous("k2")
    assert {:retry, :no_side_effects} = ForemanServer.Idempotency.CrashRecovery.reconcile("k2", fn _ -> true end)
  end
  test "ambiguous with side effects retries with warning" do
    {:ok, _pid} = ForemanServer.Idempotency.KeyStore.start_link()
    :ok = ForemanServer.Idempotency.KeyStore.mark_ambiguous("k3")
    assert {:retry, :side_effects_present} = ForemanServer.Idempotency.CrashRecovery.reconcile("k3", fn _ -> false end)
  end
end