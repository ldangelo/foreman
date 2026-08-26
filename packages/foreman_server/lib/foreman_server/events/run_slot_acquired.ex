defmodule ForemanServer.Events.RunSlotAcquired do
  @moduledoc """
  Typed event emitted when a run acquires a global run slot.

  Carries the `run_id`, the slot `capacity` at time of acquisition,
  and a monotonic `acquired_at_ms` timestamp.
  """
  @enforce_keys [:run_id, :capacity, :acquired_at_ms]
  @type t :: %__MODULE__{
          run_id: String.t(),
          capacity: non_neg_integer(),
          acquired_at_ms: integer()
        }
  @derive Jason.Encoder
  defstruct [:run_id, :capacity, :acquired_at_ms]
end
