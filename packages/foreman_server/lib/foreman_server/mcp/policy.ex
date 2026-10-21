defmodule ForemanServer.MCP.Policy do
  alias ForemanServer.Telemetry

  @write_tools [
    "foreman_task_create",
    "foreman_task_update",
    "foreman_task_add_comment",
    "foreman_run_cancel",
    "foreman_run_pause",
    "foreman_run_resume",
    "foreman_thread_stop",
    "foreman_thread_steer",
    "foreman_inbox_send",
    "foreman_workflow_put",
    "foreman_workflow_delete",
    "foreman_prompt_put",
    "foreman_project_settings_update",
    "foreman_project_pause",
    "foreman_project_resume",
    "foreman_project_memory_write",
    "foreman_project_memory_forget",
    "foreman_schedule_create",
    "foreman_schedule_pause",
    "foreman_schedule_resume",
    "foreman_schedule_delete",
    "foreman_project_message",
    "foreman_pr_fix",
    "foreman_pr_watch_stop"
  ]

  @doc """
  The single source of truth for which MCP tools mutate state. Both
  `authorized?/1` / `list_tools/1` (the write gate) and the MCP allowlist seed in
  `ForemanServer.Application` read this list, so a write tool can never be gated
  by one and silently allowed by the other. The merge gate is never an MCP tool.
  """
  @spec write_tools() :: [String.t()]
  def write_tools, do: @write_tools

  @doc """
  Names of every advertised tool that is not a write tool: the set the MCP
  allowlist is seeded with. Derived, never hand-maintained.
  """
  @spec read_tool_names() :: [String.t()]
  def read_tool_names do
    for %{name: name} <- ForemanServer.MCP.Tools.list_tools(), name not in @write_tools, do: name
  end

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
