defmodule ForemanServer.Events.RunCompleted do
  @moduledoc "Typed event emitted when a run has completed successfully."
  @enforce_keys [:run_id]
  @type t :: %__MODULE__{
          run_id: String.t(),
          sequence: non_neg_integer() | nil,
          status: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [:run_id, :sequence, :status]
end