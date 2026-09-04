defmodule ForemanServer.Workflow.BootReconciliationAmbiguousKeysTest do
  @moduledoc """
  Tests for `BootReconciliation`'s ambiguous-key reconciliation (TRD-077).

  Covers:
    - `do_reconcile_ambiguous_keys/1` emits telemetry with accurate skipped/retried
      counts derived from actual `CrashRecovery.reconcile/2` outcomes
    - `reconcile_ambiguous_keys/1` defers when CommandRouter is not ready
    - `scan_ambiguous_keys/0` public cast API is wired to `handle_cast`

  The full boot-scan path (`handle_continue(:reconcile, ...)`) requires the
  EventStore/CommandRouter/BootReconciliation supervision tree and is
  verified in CI where the full app boots.

  TRD-2026-4212be7e / RTE-T003 / TRD-077.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Idempotency.{CrashRecovery, KeyStore}
  alias ForemanServer.Workflow.BootReconciliation

  @ambiguous_event [:foreman_server, :workflow, :boot_reconciliation, :ambiguous_reconciled]

  setup do
    Application.put_env(:foreman_server, ForemanServer.Agents.JidoCheckpointStore, [])
    Application.ensure_all_started(:telemetry)

    case KeyStore.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    if :ets.info(:foreman_idempotency_keys) != :undefined do
      :ets.delete_all_objects(:foreman_idempotency_keys)
    end

    {handler_id, ref} =
      ForemanServer.TelemetryTest.Handler.attach_event_handlers(self(), [@ambiguous_event])

    on_exit(fn ->
      :telemetry.detach(handler_id)

      if :ets.info(:foreman_idempotency_keys) != :undefined do
        :ets.delete_all_objects(:foreman_idempotency_keys)
      end
    end)

    {:ok, telemetry_ref: ref}
  end

  describe "do_reconcile_ambiguous_keys/1" do
    test "empty ambiguous key list → telemetry fires with zero counts" do
      BootReconciliation.do_reconcile_ambiguous_keys()

      assert_receive {@ambiguous_event, _, measurements, _},
                     5_000,
                     "scan must emit ambiguous_reconciled telemetry"

      assert measurements == %{skipped: 0, retried: 0}
    end

    test "ambiguous key with no side effects → retried = 1 (key remediated, not skipped)" do
      # No run_id: has_no_side_effects?/1 safely returns true → no ProjectionStore hit.
      # CrashRecovery.reconcile returns {:retry, :no_side_effects} for :ambiguous status.
      :ets.insert(:foreman_idempotency_keys, {"ambig-no-effects", :ambiguous, %{}})

      BootReconciliation.do_reconcile_ambiguous_keys()

      assert_receive {@ambiguous_event, _, %{skipped: 0, retried: retried}, _}, 5_000
      assert retried == 1
    end

    test "ambiguous key with side effects → retried = 1, key remediated to :completed" do
      # side_effects_check always returns false → "has side effects" → mark_completed
      # then {:retry, :side_effects_present}.
      :ets.insert(
        :foreman_idempotency_keys,
        {"ambig-has-effects", :ambiguous, %{run_id: "run-x"}}
      )

      side_effects_check = fn _key -> false end
      BootReconciliation.do_reconcile_ambiguous_keys(side_effects_check)

      assert_receive {@ambiguous_event, _, %{skipped: 0, retried: retried}, _}, 5_000
      assert retried == 1, "ambiguous key with side effects must be retried after remediation"

      # Verify the key was remediated to :completed.
      assert KeyStore.status("ambig-has-effects") == {:ok, :completed}
    end

    test "mixed ambiguous keys → counts sum correctly" do
      # 2 no-effects + 1 has-effects
      :ets.insert(:foreman_idempotency_keys, {"ambig-mix-1", :ambiguous, %{}})
      :ets.insert(:foreman_idempotency_keys, {"ambig-mix-2", :ambiguous, %{}})
      :ets.insert(:foreman_idempotency_keys, {"ambig-mix-3", :ambiguous, %{run_id: "run-z"}})

      side_effects_check = fn _key -> false end
      BootReconciliation.do_reconcile_ambiguous_keys(side_effects_check)

      assert_receive {@ambiguous_event, _, %{skipped: 0, retried: retried}, _}, 5_000
      assert retried == 3, "all 3 ambiguous keys must be retried (2 no-effects + 1 has-effects)"
    end
  end

  describe "reconcile_ambiguous_keys/1 (deferral when CommandRouter absent)" do
    test "defers when command_router_ready? returns false" do
      # CommandRouter is a real supervised singleton that the full app
      # boots unconditionally, so scan_branch/0 only returns
      # :schedule_not_ready while the router is genuinely absent. Stop it
      # under its own supervisor (mirrors boot_reconciliation_test.exs's
      # "run_terminated/2 defers dispatch when CommandRouter is not
      # registered") and restart it before the test ends so later tests
      # in this run still see a live router.
      app_sup = Process.whereis(ForemanServer.Application)
      assert is_pid(app_sup)

      :ok = Supervisor.terminate_child(app_sup, ForemanServer.CommandRouter)
      assert is_nil(Process.whereis(ForemanServer.CommandRouter))

      on_exit(fn ->
        case Process.whereis(ForemanServer.CommandRouter) do
          nil -> Supervisor.restart_child(app_sup, ForemanServer.CommandRouter)
          _pid -> :ok
        end
      end)

      state = %{
        reconciled?: false,
        scanned?: false,
        vcs_scan_pid: nil,
        vcs_scan_ref: nil,
        ambiguous_reconciled?: false
      }

      result_state = BootReconciliation.reconcile_ambiguous_keys(state)

      assert result_state.ambiguous_reconciled? == false,
             "ambiguous_reconciled? must remain false when scan is deferred"

      refute_receive {@ambiguous_event, _, _, _},
                     100,
                     "no telemetry synchronously when scan is deferred"

      {:ok, _} = Supervisor.restart_child(app_sup, ForemanServer.CommandRouter)
    end
  end

  describe "scan_ambiguous_keys/0 (GenServer cast API)" do
    test "cast returns :ok without error when GenServer is not running" do
      # Without the full app boot, BootReconciliation GenServer is absent.
      # The cast is silently dropped (same behaviour as production with a dead process).
      assert :ok = BootReconciliation.scan_ambiguous_keys()

      refute_receive {@ambiguous_event, _, _, _},
                     200,
                     "no telemetry when GenServer is not running"
    end
  end
end
