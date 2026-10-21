defmodule ForemanServer.Events.ToolCallApproved do
  @moduledoc """
  An operator approved a requested tool call. Approving an agent tool call is
  unrelated to the run's merge gate (`merge_approve` / `run.pr.merge`).
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
