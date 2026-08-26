defmodule ForemanServer.Events.BeadsDbLeaseAcquired do
  @moduledoc """
  Typed event emitted when a run acquires the per-DB Beads lease.

  Carries the `db_path` keyed stream identifier, the holder `run_id`
  and `task_id`, the monotonic `acquired_at` timestamp in milliseconds,
  and a `provenance` atom (`{:direct, run_id}` for the very first
  acquirer or `{:promoted_from_waiter, enqueued_at_ms}` when the
  holder was auto-promoted from the durable waiter queue).
  """
  @enforce_keys [:db_path, :run_id, :task_id, :acquired_at_ms]
  @type t :: %__MODULE__{
          db_path: String.t(),
          run_id: String.t(),
          task_id: String.t(),
          acquired_at_ms: integer(),
          provenance: {:direct, String.t()} | {:promoted_from_waiter, integer()} | nil
        }
  @derive Jason.Encoder
  defstruct [:db_path, :run_id, :task_id, :acquired_at_ms, provenance: nil]
end
