defmodule ForemanServer.Approvals.DTO do
  @moduledoc """
  String-keyed, whitelisted view of a projected tool-call approval, shared by the
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

  @type t :: %{String.t() => term()}

  @doc "DTO for one projected tool call."
  @spec to_map(ProjectionStore.tool_call()) :: t()
  def to_map(call) do
    pending? = call.status == "requested"

    %{
      "tool_call_id" => call.tool_call_id,
      "run_id" => call.run_id,
      "project_id" => call.project_id,
      "tool_name" => call.tool_name,
      "input_summary" => call.input_summary,
      "status" => call.status,
      "requested_at" => call.requested_at,
      "decided_at" => call.decided_at,
      "decided_by" => call.decided_by,
      "reason" => call.reason,
      "approval_delivery" => call.delivery,
      "actions" => if(pending?, do: ["tool.approve", "tool.deny"], else: []),
      "command_hints" => if(pending?, do: hints(call), else: %{})
    }
  end

  @doc "DTO list."
  @spec list([ProjectionStore.tool_call()]) :: [t()]
  def list(calls), do: Enum.map(calls, &to_map/1)

  defp hints(call) do
    payload = %{"run_id" => call.run_id, "tool_call_id" => call.tool_call_id}

    for type <- ["tool.approve", "tool.deny"], into: %{} do
      {type, %{"type" => type, "payload" => payload}}
    end
  end
end
