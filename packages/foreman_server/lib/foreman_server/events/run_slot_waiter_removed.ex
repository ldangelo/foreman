defmodule ForemanServer.Events.RunSlotWaiterRemoved do
  @moduledoc """
  Typed event emitted when a waiter is removed from the global
  run-slot queue (e.g. the queued run transitioned to a terminal
  state before being promoted).
  """
  @enforce_keys [:run_id]
  @type t :: %__MODULE__{
          run_id: String.t()
        }
  @derive Jason.Encoder
  defstruct [:run_id]
end
