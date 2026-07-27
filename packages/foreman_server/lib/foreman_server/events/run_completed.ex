defmodule ForemanServer.Events.RunCompleted do
  @enforce_keys [:run_id]
  @type t :: %__MODULE__{
    run_id: String.t(),
    sequence: integer() | nil
  }
  @derive Jason.Encoder
  defstruct [:run_id, :sequence]
end
