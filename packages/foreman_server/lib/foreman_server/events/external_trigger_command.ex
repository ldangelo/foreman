defmodule ForemanServer.Events.ExternalTriggerCommand do
  @enforce_keys [:trigger_id]
  @type t :: %__MODULE__{
    trigger_id: String.t()
  }
  @derive Jason.Encoder
  defstruct [:trigger_id]
end
