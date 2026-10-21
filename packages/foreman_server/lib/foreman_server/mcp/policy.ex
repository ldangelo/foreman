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
    "foreman_pr_watch_stop",
    "foreman_run_request_repo",
    "foreman_task_fanout"
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
