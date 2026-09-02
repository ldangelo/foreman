defmodule ForemanServer.MCP.Policy do
  alias ForemanServer.Telemetry

  @write_tools [
    "foreman_task_create",
    "foreman_task_update",
    "foreman_run_cancel",
    "foreman_workflow_put",
    "foreman_workflow_delete",
    "foreman_prompt_put"
  ]

  @spec authorized?(String.t()) :: boolean()
  def authorized?(tool_name) do
    if allow_workflow_writes?() do
      true
    else
      if tool_name in @write_tools do
        Telemetry.mcp_policy_refused(tool_name, :write_not_allowed)
        false
      else
        true
      end
    end
  end

  @spec list_tools([map()]) :: [map()]
  def list_tools(tools) do
    if allow_workflow_writes?() do
      tools
    else
      Enum.reject(tools, fn %{name: name} -> name in @write_tools end)
    end
  end

  defp allow_workflow_writes? do
    Keyword.get(Application.get_env(:foreman_server, :mcp, []), :allow_workflow_writes, false)
  end
end
