defmodule ForemanServer.Events.ToolCallRequested do
  @moduledoc """
  An agent needs permission to use a tool (`tool_call:<run_id>:<tool_call_id>`).

  `input_summary` is redacted and bounded (<= 500 chars) by
  `ForemanServer.Aggregates.ToolCall`; the raw tool input is never stored.
  `delivery` names how a later decision reaches the agent: `"live"` (answered
  through the provider session), `"inflight"` (a blocked claude permission prompt is
  answered: that one call) or `"resume_with_override"` (the run resumes with a
  next-phase `approval_mode` override that covers the whole phase), see
  `ForemanServer.Approvals.Capability`.
  `project_id` is nil when the producer did not know it; the projection then
  resolves it from the run.
  """
  @enforce_keys [:run_id, :tool_call_id, :tool_name, :requested_at]
  @type t :: %__MODULE__{
          run_id: String.t(),
          tool_call_id: String.t(),
          tool_name: String.t(),
          input_summary: String.t() | nil,
          project_id: String.t() | nil,
          provider: String.t() | nil,
          requested_by: String.t() | nil,
          delivery: String.t() | nil,
          requested_at: String.t()
        }
  @derive Jason.Encoder
  defstruct [
    :run_id,
    :tool_call_id,
    :tool_name,
    :input_summary,
    :project_id,
    :provider,
    :requested_by,
    :delivery,
    :requested_at
  ]
end
