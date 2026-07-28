defmodule ForemanServer.Events.ToolCallFinished do
  @enforce_keys [:tool_call_id]
  @type t :: %__MODULE__{
    tool_call_id: String.t(),
    worker_id: String.t() | nil,
    run_id: String.t() | nil
  }
  @derive Jason.Encoder
  defstruct [:tool_call_id, :worker_id, :run_id]
end
