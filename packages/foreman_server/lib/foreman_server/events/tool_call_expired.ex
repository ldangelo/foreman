defmodule ForemanServer.Events.ToolCallExpired do
  @moduledoc """
  A requested tool call was not decided before its timeout. Expired calls can no
  longer be approved; the operator re-requests by resuming or steering the run.
  """
  @enforce_keys [:run_id, :tool_call_id, :at]
  @type t :: %__MODULE__{
          run_id: String.t(),
          tool_call_id: String.t(),
          reason: String.t() | nil,
          at: String.t()
        }
  @derive Jason.Encoder
  defstruct [:run_id, :tool_call_id, :reason, :at]
end
