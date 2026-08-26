defmodule ForemanServer.Events.PhaseBlocked do
  @moduledoc "Typed event emitted when a workflow phase is blocked due to upstream failure."
  @enforce_keys [:phase_id, :run_id, :index]
  @type t :: %__MODULE__{
          sequence: non_neg_integer() | nil,
          run_id: String.t(),
          index: pos_integer(),
          reason: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [
    :phase_id,
    :sequence,
    :run_id,
    :index,
    :reason
  ]
end
