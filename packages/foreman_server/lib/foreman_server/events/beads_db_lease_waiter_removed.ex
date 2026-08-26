defmodule ForemanServer.Events.BeadsDbLeaseWaiterRemoved do
  @moduledoc """
  Typed event emitted when a queued waiter is removed from a
  per-DB Beads lease before it has been promoted to holder.

  The Dispatcher (or Run aggregate terminalization) emits this
  when a queued run transitions to terminal — preventing a
  promotion-to-already-terminal race that would strand the lease.
  """
  @enforce_keys [:db_path, :run_id, :removed_at_ms, :reason]
  @type t :: %__MODULE__{
          db_path: String.t(),
          run_id: String.t(),
          removed_at_ms: integer(),
          reason: atom()
        }
  @derive Jason.Encoder
  defstruct [:db_path, :run_id, :removed_at_ms, :reason]
end
