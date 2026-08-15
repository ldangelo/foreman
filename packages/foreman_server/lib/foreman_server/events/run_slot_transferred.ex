defmodule ForemanServer.Events.RunSlotTransferred do
  @moduledoc """
  Typed event emitted when a run releases a global run slot and
  the FIFO head waiter is atomically promoted into it.

  Carries the `released_run_id`, the `acquired_run_id` of the promoted
  waiter, and a monotonic `acquired_at_ms` timestamp for the new holder.
  The `capacity` field carries the effective capacity at time of transfer
  (may be nil when emitted from apply_event).
  """
  @enforce_keys [:released_run_id, :acquired_run_id, :acquired_at_ms]
  @type t :: %__MODULE__{
          released_run_id: String.t(),
          acquired_run_id: String.t(),
          capacity: non_neg_integer() | nil,
          acquired_at_ms: integer()
        }
  @derive Jason.Encoder
  defstruct [:released_run_id, :acquired_run_id, :capacity, :acquired_at_ms]
end
