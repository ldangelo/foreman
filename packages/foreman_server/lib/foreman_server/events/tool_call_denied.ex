defmodule ForemanServer.Events.ToolCallDenied do
  @moduledoc """
  A requested tool call was denied, by an operator or by the timeout policy
  (`decided_by` is then `"system"` and `reason` is `"timeout"`).
  """
  @enforce_keys [:run_id, :tool_call_id, :decided_at]
  @type t :: %__MODULE__{
          run_id: String.t(),
          tool_call_id: String.t(),
          decided_by: String.t() | nil,
          reason: String.t() | nil,
          decided_at: String.t()
        }
  @derive Jason.Encoder
  defstruct [:run_id, :tool_call_id, :decided_by, :reason, :decided_at]
end
