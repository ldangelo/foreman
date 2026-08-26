defmodule ForemanServer.Idempotency.ResumptionTimeTest do
  @moduledoc """
  TRD-080 / RTE-T006 — NFR-03 Verification: crash recovery ≤30 seconds to resumption.

  Crash recovery involves multiple layers:

    1. Idempotency layer — `CrashRecovery.reconcile/1` (this file)
       Determines whether a crashed operation should skip, retry fresh, or
       retry after checking side effects. Must decide within ≤30s.

    2. EventStore replay — aggregate state rebuilt from event stream on
       GenServer restart. Tested in aggregate integration tests.

    3. ProjectionStore rebuild — projectors replay from EventStore on
       startup. Tested in projector integration tests.

    4. RunExecutor re-entry — workflow resumes from the last checkpoint.
       Tested in `crash_recovery_characterization_test.exs` (TRD-079).

  This test exercises layer 1 (the decision layer) under the NFR-03
  threshold. Layer 1 is the critical path: if `reconcile/1` times out,
  the entire recovery pipeline stalls.

  NFR-03 contract:
    - REQ-017: crash recovery safety (no duplicate side effects)
    - NFR-03: ≤30 000 ms from reconcile/1 call to decision
    - RTE-T004: 5-restart backoff (TRD-078)
    - RTE-T006: this verification (TRD-080)
  """

  use ExUnit.Case, async: false
  @moduletag :nfr

  alias ForemanServer.Idempotency.{CrashRecovery, KeyStore}

  @resumption_target_ms 30_000

  # ---------------------------------------------------------------------------
  # NFR-03: ≤30s recovery decision for each reconcile path
  # ---------------------------------------------------------------------------

  describe "NFR-03: crash recovery ≤30 seconds to resumption" do
    setup do
      {:ok, _} = KeyStore.ensure_started()
      ForemanServer.TestSupport.KeyStoreReset.reset!()
      :ok
    end

    test "ambiguous key: side-effects check decides within 30s" do
      :ok = KeyStore.mark_ambiguous("k-resume-ambiguous")

      {time_us, result} = :timer.tc(fn ->
        CrashRecovery.reconcile("k-resume-ambiguous", fn _ -> true end)
      end)

      time_ms = div(time_us, 1000)

      assert time_ms < @resumption_target_ms,
             "NFR-03 violated: ambiguous recovery took #{time_ms}ms (limit: #{@resumption_target_ms}ms)"

      assert match?({:retry, :no_side_effects}, result),
             "expected {:retry, :no_side_effects}, got #{inspect(result)}"
    end

    test "completed key: skip decision within 30s (fastest path)" do
      :ok = KeyStore.mark_completed("k-resume-completed")

      {time_us, result} = :timer.tc(fn ->
        CrashRecovery.reconcile("k-resume-completed")
      end)

      time_ms = div(time_us, 1000)

      assert time_ms < @resumption_target_ms,
             "NFR-03 violated: completed recovery took #{time_ms}ms (limit: #{@resumption_target_ms}ms)"

      assert {:skip, :already_completed} = result
    end

    test "fresh key: retry decision within 30s (no prior state)" do
      {time_us, result} = :timer.tc(fn ->
        CrashRecovery.reconcile("k-resume-fresh-#{:rand.uniform(1_000_000)}")
      end)

      time_ms = div(time_us, 1000)

      assert time_ms < @resumption_target_ms,
             "NFR-03 violated: fresh recovery took #{time_ms}ms (limit: #{@resumption_target_ms}ms)"

      assert {:retry, :fresh} = result
    end

    test "started-but-unknown key: retry within 30s" do
      :ok = KeyStore.mark_started("k-resume-started")

      {time_us, result} = :timer.tc(fn ->
        CrashRecovery.reconcile("k-resume-started")
      end)

      time_ms = div(time_us, 1000)

      assert time_ms < @resumption_target_ms,
             "NFR-03 violated: started-key recovery took #{time_ms}ms (limit: #{@resumption_target_ms}ms)"

      assert {:retry, :unknown_state} = result
    end
  end
end
