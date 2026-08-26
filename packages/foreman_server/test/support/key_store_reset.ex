defmodule ForemanServer.TestSupport.KeyStoreReset do
  @moduledoc false
  # The `Idempotency.KeyStore` GenServer (supervised at
  # application.ex:40) owns a public, named ETS table
  # `:foreman_idempotency_keys` (see key_store.ex:93). The table is the
  # source of truth for every `CrashRecovery.reconcile/2` decision and
  # every `HeartbeatLease` transition across the Idempotency test
  # cluster. Without a per-test reset, one file's `mark_completed` /
  # `mark_started` rows leak into the next test's reconcile, and the
  # "fresh key" / "completed -> skip" assertions stop being exercised
  # against an empty slate.
  #
  # `reset!/0` wipes the ETS rows in place. The KeyStore GenServer
  # keeps running; only its in-memory rows are cleared. Production
  # code never invokes this — it's compiled under `test/support/` and
  # only available via `Mix.env() == :test`.
  @spec reset!() :: :ok
  def reset! do
    table = :foreman_idempotency_keys

    if :ets.info(table) != :undefined do
      :ets.delete_all_objects(table)
    end

    :ok
  end
end