defmodule ForemanServer.Events.ToolCallApproved do
  @enforce_keys [:tool_call_id]
  @type t :: %__MODULE__{
    tool_call_id: String.t()
  }
  @derive Jason.Encoder
  defstruct [:tool_call_id]
end
