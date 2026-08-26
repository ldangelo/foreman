defmodule ForemanServer.Idempotency.CrashRecoveryCharacterizationTest do
  use ExUnit.Case, async: false
  @moduletag :characterization

  alias ForemanServer.Idempotency.{CrashRecovery, KeyStore}
  alias ForemanServer.TestSupport.KeyStoreReset

  # ---------------------------------------------------------------------------
  # Core reconciliation contracts — no duplicate side effects
  # ---------------------------------------------------------------------------

  describe "no duplicate side effects" do
    setup do
      {:ok, _} = KeyStore.ensure_started()
      KeyStoreReset.reset!()
      :ok
    end

    test "completed key is skipped on recovery" do
      :ok = KeyStore.mark_completed("k1")

      counter = :counters.new(1, [])

      assert {:skip, :already_completed} =
               CrashRecovery.reconcile("k1", fn _ ->
                 :counters.add(counter, 1, 1)
                 true
               end)

      # Side-effect fn was NOT called because key was already completed.
      assert :counters.get(counter, 1) == 0
    end

    test "ambiguous with side effects detected and key marked completed before returning" do
      :ok = KeyStore.mark_ambiguous("k3_sidefx")

      # reconcile/2 calls the side_effects_check; if it returns false
      # (side effects present), the key is marked completed BEFORE returning.
      # A second reconcile call must skip — proving no duplicate side effects.
      assert {:retry, :side_effects_present} =
               CrashRecovery.reconcile("k3_sidefx", fn _ -> false end)

      # Now completed — recovery would skip.
      counter = :counters.new(1, [])

      assert {:skip, :already_completed} =
               CrashRecovery.reconcile("k3_sidefx", fn _ ->
                 :counters.add(counter, 1, 1)
                 true
               end)

      assert :counters.get(counter, 1) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # State resumption contracts
  # ---------------------------------------------------------------------------

  describe "correct state resumption" do
    setup do
      {:ok, _} = KeyStore.ensure_started()
      KeyStoreReset.reset!()
      :ok
    end

    test "fresh key retried on first crash recovery" do
      assert {:retry, :fresh} = CrashRecovery.reconcile("k_fresh")
    end

    test "ambiguous with no side effects retries safely" do
      :ok = KeyStore.mark_ambiguous("k_ambiguous_clean")

      assert {:retry, :no_side_effects} =
               CrashRecovery.reconcile("k_ambiguous_clean", fn _ -> true end)
    end

    test "unknown key with bad type is not retried" do
      # reconcile/2 guards on is_binary(key) — non-binary returns unknown_state.
      assert {:retry, :unknown_state} = CrashRecovery.reconcile(:not_a_string)
    end
  end
end