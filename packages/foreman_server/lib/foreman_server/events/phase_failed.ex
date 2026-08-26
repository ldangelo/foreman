defmodule ForemanServer.Events.PhaseFailed do
  @moduledoc "Typed event emitted when a workflow phase fails."
  @enforce_keys [:run_id, :phase_id, :index, :reason]
  @type t :: %__MODULE__{
          run_id: String.t(),
          phase_id: String.t(),
          sequence: non_neg_integer() | nil,
          index: pos_integer(),
          reason: String.t()
        }
  @derive Jason.Encoder
  defstruct [:run_id, :phase_id, :sequence, :index, :reason]
end
