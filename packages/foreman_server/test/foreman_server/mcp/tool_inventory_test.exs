defmodule ForemanServer.MCP.ToolInventoryTest do
  # Pins the complete MCP tool inventory and its read/write classification.
  # Adding, removing or reclassifying a tool MUST update this file (and the docs).
  use ExUnit.Case, async: true

  alias ForemanServer.MCP.{Policy, Tools}

  @write_tools Enum.sort([
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
               ])

  @read_tools Enum.sort([
                "foreman_run_get",
                "foreman_run_status",
                "foreman_thread_list",
                "foreman_thread_get",
                "foreman_thread_find",
                "foreman_thread_transcript",
                "foreman_overview",
                "foreman_queue_status",
                "foreman_project_list",
                "foreman_project_get",
                "foreman_project_recommendations",
                "foreman_project_settings_get",
                "foreman_project_environment_get",
                "foreman_schedule_list",
                "foreman_usage_get",
                "foreman_workflow_list",
                "foreman_workflow_get",
                "foreman_workflow_validate",
                "foreman_task_list",
                "foreman_task_get",
                "foreman_prompt_get",
                "foreman_doctor",
                "foreman_run_get_logs",
                "foreman_run_get_events",
                "foreman_run_get_activity",
                "foreman_inbox_get",
                "foreman_project_memory_list",
                "foreman_project_memory_read",
                "foreman_approvals_list",
                "foreman_questions_list",
                "foreman_project_conversation",
                "foreman_pr_status",
                "foreman_project_library_list",
                "foreman_project_library_read",
                "foreman_project_repo_list"
              ])

  defp names, do: Enum.map(Tools.list_tools(), & &1.name)

  # Names advertised but in neither pinned list (and pinned names not advertised).
  def unclassified(advertised, read, write), do: advertised -- (read ++ write)

  test "every advertised tool is classified read or write, and the inventory is complete" do
    assert length(names()) == 61
    assert Enum.sort(names()) == Enum.sort(@read_tools ++ @write_tools)
    assert unclassified(names(), @read_tools, @write_tools) == []
    assert @read_tools -- @write_tools == @read_tools
  end

  test "the classification check can fail: an unlisted tool is reported" do
    assert unclassified(names() ++ ["foreman_new_tool"], @read_tools, @write_tools) ==
             ["foreman_new_tool"]
  end

  test "Policy.write_tools/0 is exactly the pinned write set, all of them advertised" do
    assert Enum.sort(Policy.write_tools()) == @write_tools
    assert Policy.write_tools() -- names() == []
  end

  test "the allowlist seed set (read_tool_names) is exactly the read tools and contains no write tool" do
    assert Enum.sort(Policy.read_tool_names()) == @read_tools
    assert Policy.read_tool_names() -- Policy.write_tools() == Policy.read_tool_names()
  end

  describe "merge gate" do
    test "no tool can merge or approve a PR" do
      for %{name: name} = tool <- Tools.list_tools() do
        refute name =~ ~r/merge|approve/i, "tool #{name} must not be a merge/approve tool"
        refute name == "merge_approve"

        schema = inspect(tool.inputSchema)
        refute schema =~ "run.pr.merge"
        refute schema =~ "merge_approve"
      end
    end

    test "calling a merge/approve tool name is METHOD_NOT_FOUND" do
      for name <- [
            "merge_approve",
            "run.pr.merge",
            "foreman_run_merge",
            "foreman_run_approve_merge",
            "foreman_pr_merge"
          ] do
        assert {:error, %{code: "METHOD_NOT_FOUND"}} = Tools.call_tool(name, %{})
      end
    end

    test "the tool-name check can fail: a merge tool would be caught" do
      assert Enum.any?(["foreman_run_merge"], &(&1 =~ ~r/merge|approve/i))
    end
  end

  describe "documentation coverage" do
    test "every MCP tool is documented in docs/user-guide.md or docs/cli-reference.md" do
      root = Path.expand("../../../../../docs", __DIR__)

      docs =
        File.read!(Path.join(root, "user-guide.md")) <>
          File.read!(Path.join(root, "cli-reference.md"))

      undocumented = Enum.reject(names(), &String.contains?(docs, &1))
      assert undocumented == [], "undocumented MCP tools: #{inspect(undocumented)}"
    end
  end
end
