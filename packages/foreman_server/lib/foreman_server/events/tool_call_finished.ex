defmodule ForemanServer.Events.ToolCallFinished do
  @moduledoc """
  Typed event emitted when a worker completes a tool call, and when an approved
  tool call's decision has been delivered (`tool_call:` stream, `tool.finish`):
  `tool_call_id` and `outcome` (`"delivered"` or an error marker) are set only on
  that second path, and `worker_id` is then `"approvals"`.
  """
  @enforce_keys [:worker_id, :run_id]
  @type t :: %__MODULE__{
          worker_id: String.t(),
          run_id: String.t(),
          sequence: non_neg_integer() | nil,
          tool_name: String.t() | nil,
          result: term() | nil,
          tool_call_id: String.t() | nil,
          outcome: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [:worker_id, :run_id, :sequence, :tool_name, :result, :tool_call_id, :outcome]
end
