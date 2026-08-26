defmodule ForemanServer.Events.RunSlotReleased do
  @moduledoc """
  Typed event emitted when a run releases a global run slot
  with no waiters present to promote.
  """
  @enforce_keys [:run_id]
  @type t :: %__MODULE__{
          run_id: String.t(),
          capacity: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [:run_id, :capacity]
end
