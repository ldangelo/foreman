defmodule ForemanServer.Events.RunSlotQueued do
  @moduledoc """
  Typed event emitted when a run is enqueued in the global run-slot
  waiter list because all slots are occupied.

  Carries the `run_id`, the `position` (1-indexed FIFO position), and a
  monotonic `enqueued_at_ms` timestamp.
  """
  @enforce_keys [:run_id, :position, :enqueued_at_ms]
  @type t :: %__MODULE__{
          run_id: String.t(),
          position: pos_integer(),
          enqueued_at_ms: integer()
        }
  @derive Jason.Encoder
  defstruct [:run_id, :position, :enqueued_at_ms]
end
