defmodule ForemanServer.Approvals.DTO do
  @moduledoc """
  Whitelisted struct view of a projected tool-call approval, shared by the
  HTTP controller and the `foreman_approvals_list` MCP tool so both return the
  same fields.

  `actions` lists the operator commands that can still be issued
  (`tool.approve`, `tool.deny`) and only while the call is `requested`;
  `command_hints` carries the payload skeleton for each so a UI can POST it to
  `/api/commands` unchanged. The merge gate is not an action of a tool call.
  `approval_delivery` says how a decision reaches the agent: `live` or
  `resume_with_override` (see `ForemanServer.Approvals.Capability`).
  """

  alias ForemanServer.ProjectionStore

  @enforce_keys [
    :tool_call_id,
    :run_id,
    :tool_name,
    :status,
    :requested_at,
    :actions,
    :command_hints
  ]
  @type t :: %__MODULE__{
          tool_call_id: String.t(),
          run_id: String.t(),
          project_id: String.t() | nil,
          tool_name: String.t(),
          input_summary: String.t() | nil,
          status: String.t(),
          requested_at: String.t(),
          decided_at: String.t() | nil,
          decided_by: String.t() | nil,
          reason: String.t() | nil,
          approval_delivery: String.t() | nil,
          actions: [String.t()],
          command_hints: %{String.t() => map()}
        }
  # The struct field names ARE the wire names (`Jason.Encoder` emits them as-is).
  @derive Jason.Encoder
  defstruct [
    :tool_call_id,
    :run_id,
    :project_id,
    :tool_name,
    :input_summary,
    :status,
    :requested_at,
    :decided_at,
    :decided_by,
    :reason,
    :approval_delivery,
    :actions,
    :command_hints
  ]

  @doc "DTO for one projected tool call."
  @spec build(ProjectionStore.tool_call()) :: t()
  def build(call) do
    pending? = call.status == "requested"

    %__MODULE__{
      tool_call_id: call.tool_call_id,
      run_id: call.run_id,
      project_id: call.project_id,
      tool_name: call.tool_name,
      input_summary: call.input_summary,
      status: call.status,
      requested_at: call.requested_at,
      decided_at: call.decided_at,
      decided_by: call.decided_by,
      reason: call.reason,
      approval_delivery: call.delivery,
      actions: if(pending?, do: ["tool.approve", "tool.deny"], else: []),
      command_hints: if(pending?, do: hints(call), else: %{})
    }
  end

  @doc "DTO list."
  @spec list([ProjectionStore.tool_call()]) :: [t()]
  def list(calls), do: Enum.map(calls, &build/1)

  defp hints(call) do
    payload = %{"run_id" => call.run_id, "tool_call_id" => call.tool_call_id}

    for type <- ["tool.approve", "tool.deny"], into: %{} do
      {type, %{"type" => type, "payload" => payload}}
    end
  end
end
