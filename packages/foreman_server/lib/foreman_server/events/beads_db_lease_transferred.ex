defmodule ForemanServer.Events.BeadsDbLeaseTransferred do
  @moduledoc """
  Typed event emitted when a holder releases a per-DB Beads lease and
  the head waiter is atomically promoted to the new holder.

  Replaces both a `BeadsDbLeaseReleased` and a follow-up
  `BeadsDbLeaseAcquired` so the Actor protocol is unchanged: the
  state transition is encoded in a single event whose `apply_event`
  swaps the holder and drops the head waiter in one step.
  """
  @enforce_keys [
    :db_path,
    :released_run_id,
    :released_at_ms,
    :reason,
    :acquired_run_id,
    :acquired_task_id,
    :acquired_at_ms,
    :enqueued_at_ms
  ]
  @type t :: %__MODULE__{
          db_path: String.t(),
          released_run_id: String.t(),
          released_at_ms: integer(),
          reason: atom(),
          acquired_run_id: String.t(),
          acquired_task_id: String.t(),
          acquired_at_ms: integer(),
          enqueued_at_ms: integer()
        }
  @derive Jason.Encoder
  defstruct [
    :db_path,
    :released_run_id,
    :released_at_ms,
    :reason,
    :acquired_run_id,
    :acquired_task_id,
    :acquired_at_ms,
    :enqueued_at_ms
  ]
end
