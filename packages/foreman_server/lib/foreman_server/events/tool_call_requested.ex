defmodule ForemanServer.Events.ToolCallRequested do
  @enforce_keys [:tool_call_id]
  @type t :: %__MODULE__{
    tool_call_id: String.t(),
    tool_name: String.t() | nil,
    input: map() | nil,
    run_id: String.t() | nil
  }
  @derive Jason.Encoder
  defstruct [:tool_call_id, :tool_name, :input, :run_id]
end
