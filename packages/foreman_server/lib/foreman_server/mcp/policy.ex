defmodule ForemanServer.MCP.Policy do
  @write_tools ["foreman_work_submit", "foreman_work_cancel"]

  @spec authorized?(String.t()) :: boolean()
  def authorized?(tool_name) do
    if allow_workflow_writes?() do
      true
    else
      tool_name not in @write_tools
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
