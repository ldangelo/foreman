defmodule ForemanServer.Events.VcsMergeRequested do
  @enforce_keys [:operation_id]
  @type t :: %__MODULE__{
    operation_id: String.t()
  }
  @derive Jason.Encoder
  defstruct [:operation_id]
end
