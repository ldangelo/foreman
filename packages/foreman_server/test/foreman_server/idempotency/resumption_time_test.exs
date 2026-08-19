defmodule ForemanServer.Idempotency.ResumptionTimeTest do
  use ExUnit.Case, async: false
  @moduletag :nfr
  @resumption_target_ms 30_000

  test "resumption completes within 30s NFR-03" do
    {:ok, _pid} = ForemanServer.Idempotency.KeyStore.start_link()
    :ok = ForemanServer.Idempotency.KeyStore.mark_ambiguous("k-resume")
    {time_us, result} = :timer.tc(fn ->
      ForemanServer.Idempotency.CrashRecovery.reconcile("k-resume", fn _ -> true end)
    end)
    time_ms = div(time_us, 1000)
    assert time_ms < @resumption_target_ms
    assert {:retry, _} = result
  end
end