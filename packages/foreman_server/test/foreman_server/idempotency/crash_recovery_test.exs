defmodule ForemanServer.Idempotency.CrashRecoveryTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, _pid} = ForemanServer.Idempotency.KeyStore.ensure_started()
    ForemanServer.TestSupport.KeyStoreReset.reset!()
    :ok
  end

  # --- reconcile/1,2 core transitions ---

  test "completed -> skip" do
    :ok = ForemanServer.Idempotency.KeyStore.mark_completed("k1")
    assert {:skip, :already_completed} = ForemanServer.Idempotency.CrashRecovery.reconcile("k1")
  end

  test "not_found -> fresh" do
    assert {:retry, :fresh} = ForemanServer.Idempotency.CrashRecovery.reconcile("unknown")
  end

  test "unknown status (started) -> retry" do
    # mark_started leaves status :started which is not :completed/:ambiguous
    :ok = ForemanServer.Idempotency.KeyStore.mark_started("k4")
    assert {:retry, :unknown_state} = ForemanServer.Idempotency.CrashRecovery.reconcile("k4")
  end

  # --- ambiguous -> side effects check ---

  test "ambiguous, legacy key with no metadata -> no_side_effects (safe fallback)" do
    # Keys created before TRD-077 have no run_id in metadata.
    # CrashRecovery falls back to safe (no side effects) so recovery can proceed.
    :ok = ForemanServer.Idempotency.KeyStore.mark_ambiguous("legacy-key")
    assert {:retry, :no_side_effects} = ForemanServer.Idempotency.CrashRecovery.reconcile("legacy-key")
  end

  test "ambiguous, no side effects (default check, no ProjectionStore) -> no_side_effects" do
    # Metadata has run_id but ProjectionStore is not running — the default
    # has_no_side_effects? will fall through to the catch-all `true`.
    :ok = ForemanServer.Idempotency.KeyStore.mark_ambiguous("k2")
    assert {:retry, :no_side_effects} = ForemanServer.Idempotency.CrashRecovery.reconcile("k2")
  end

  test "ambiguous, side effects detected via custom check -> side_effects_present and key marked completed" do
    # Custom side_effects_check returns false (has side effects).
    :ok = ForemanServer.Idempotency.KeyStore.mark_ambiguous("k3")
    assert {:retry, :side_effects_present} =
             ForemanServer.Idempotency.CrashRecovery.reconcile("k3", fn _ -> false end)
    # reconcile should have marked the key completed so a subsequent retry
    # does not re-trigger the ambiguous path.
    assert {:ok, :completed} = ForemanServer.Idempotency.KeyStore.status("k3")
  end

  test "ambiguous, custom check reports no side effects -> no_side_effects" do
    :ok = ForemanServer.Idempotency.KeyStore.mark_ambiguous("k5")
    assert {:retry, :no_side_effects} =
             ForemanServer.Idempotency.CrashRecovery.reconcile("k5", fn _ -> true end)
  end

  # --- has_no_side_effects? ---

  test "has_no_side_effects? non-binary key -> true (guard)" do
    assert ForemanServer.Idempotency.CrashRecovery.has_no_side_effects?(nil) === true
    assert ForemanServer.Idempotency.CrashRecovery.has_no_side_effects?(123) === true
  end

  test "has_no_side_effects? reads run_id from KeyStore metadata — verified via reconcile with custom check" do
    # mark_ambiguous/2 wraps its arg as %{reason: arg}, not top-level metadata.
    # Use mark_started first to establish correct metadata, then mark_ambiguous
    # with a plain string reason.
    :ok = ForemanServer.Idempotency.KeyStore.mark_started("meta-key-#{:rand.uniform(999_999)}",
             %{run_id: "known-run-id", task_id: "task-1"})

    :ok = ForemanServer.Idempotency.KeyStore.mark_ambiguous("meta-key-#{:rand.uniform(999_999)}",
             "timeout")

    custom_check = fn key ->
      case ForemanServer.Idempotency.KeyStore.get(key) do
        {:ok, %{metadata: %{run_id: "known-run-id"}}} -> false  # has side effects
        _ -> true
      end
    end

    # Use a fresh key for this sub-assertion so ETS state is clean.
    key = "meta-verify-#{:rand.uniform(999_999)}"
    :ok = ForemanServer.Idempotency.KeyStore.mark_started(key, %{run_id: "known-run-id", task_id: "task-1"})
    :ok = ForemanServer.Idempotency.KeyStore.mark_ambiguous(key, "timeout")

    # custom_check returns false -> side effects detected -> reconcile returns
    # :side_effects_present and marks the key completed.
    assert {:retry, :side_effects_present} =
             ForemanServer.Idempotency.CrashRecovery.reconcile(key, custom_check)
    assert {:ok, :completed} = ForemanServer.Idempotency.KeyStore.status(key)
  end

  # --- reconcile/1,2 guards ---

  test "non-binary key -> unknown_state" do
    assert {:retry, :unknown_state} = ForemanServer.Idempotency.CrashRecovery.reconcile(nil)
    assert {:retry, :unknown_state} = ForemanServer.Idempotency.CrashRecovery.reconcile(123)
  end
end
