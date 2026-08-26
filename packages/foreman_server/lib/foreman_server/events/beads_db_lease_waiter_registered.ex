defmodule ForemanServer.Events.BeadsDbLeaseWaiterRegistered do
  @moduledoc """
  Typed event emitted when a run registers as a durable waiter for a
  per-DB Beads lease it could not acquire.

  The waiter list is held in the lease aggregate stream so a
  Dispatcher restart does not lose the queued run; lease release
  promotes the head waiter to holder and emits `BeadsDbLeaseAcquired`
  with `provenance: {:promoted_from_waiter, enqueued_at_ms}`.
  """
  @enforce_keys [:db_path, :run_id, :task_id, :enqueued_at_ms]
  @type t :: %__MODULE__{
          db_path: String.t(),
          run_id: String.t(),
          task_id: String.t(),
          enqueued_at_ms: integer()
        }
  @derive Jason.Encoder
  defstruct [:db_path, :run_id, :task_id, :enqueued_at_ms]
end
