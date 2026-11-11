defmodule ForemanServer.Events.RunSlotRecoveryAttempted do
  @moduledoc """
  Typed event for the durable boot cleanup budget of an orphaned run-slot entry,
  on the `run_slots:global` stream (`run_slots.recovery_attempt`).

  `BootReconciliation` releases a slot holder or removes a waiter whose run is
  absent or terminal. When that dispatch fails, the failure count is recorded
  here, because such a run has no aggregate that can carry it.

    * `attempt` - the run's consecutive-failure count (one budget per run across
      both kinds); `0` after a successful dispatch.
    * `outcome` - `failed`, `exhausted` (the cleanup limit was reached) or
      `dispatched` (a cleanup succeeded after a recorded failure).
    * `kind` - `slot_release` or `waiter_remove`.
    * `reason` - free-text detail of the failure.
    * `elapsed_since_boot_ms` - monotonic time since application start.
  """
  @enforce_keys [:run_id, :attempt, :outcome, :kind, :elapsed_since_boot_ms]
  @type t :: %__MODULE__{
          run_id: String.t(),
          attempt: non_neg_integer(),
          outcome: String.t(),
          kind: String.t(),
          reason: String.t() | nil,
          elapsed_since_boot_ms: integer()
        }
  @derive Jason.Encoder
  defstruct [:run_id, :attempt, :outcome, :kind, :reason, :elapsed_since_boot_ms]
end
