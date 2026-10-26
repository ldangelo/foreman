defmodule ForemanServer.Events.BeadsDbLeaseAcquired do
  @moduledoc """
  Typed event emitted when a run acquires the per-DB Beads lease.

  Carries the `db_path` keyed stream identifier, the holder `run_id`
  and `task_id`, the monotonic `acquired_at` timestamp in milliseconds,
  and a `provenance` tag: `{:direct, run_id}` for the very first
  acquirer, `{:promoted_from_waiter, enqueued_at_ms}` when the
  holder was auto-promoted from the durable waiter queue, or
  `{:reclaimed_stale_holder, stale_run_id}` when the acquirer took the
  lease over from a holder whose server incarnation no longer exists.

  `incarnation` is the `ForemanServer.Incarnation` id of the server
  that holds the lease for the duration of one call
  (`BeadsDbLease.with_lease/4`); `nil` for a hold that belongs to a run
  and outlives restarts (`RunAdmission`).
  """
  @enforce_keys [:db_path, :run_id, :task_id, :acquired_at_ms]
  @type t :: %__MODULE__{
          db_path: String.t(),
          run_id: String.t(),
          task_id: String.t(),
          acquired_at_ms: integer(),
          incarnation: String.t() | nil,
          provenance:
            {:direct, String.t()}
            | {:promoted_from_waiter, integer()}
            | {:reclaimed_stale_holder, String.t()}
            | nil
        }
  @derive Jason.Encoder
  defstruct [:db_path, :run_id, :task_id, :acquired_at_ms, incarnation: nil, provenance: nil]
end
