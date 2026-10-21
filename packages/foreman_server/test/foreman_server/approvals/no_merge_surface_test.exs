defmodule ForemanServer.Approvals.NoMergeSurfaceTest do
  # E8 adds approve/answer surfaces; none may reach the run merge gate
  # (`merge_approve`, `run.pr.merge`), and none may be an MCP tool.
  use ExUnit.Case, async: true

  alias ForemanServer.Approvals.Dispatch
  alias ForemanServer.MCP.{Policy, Tools}

  @forbidden ["merge_approve", "run.pr.merge"]

  def offenders(types), do: Enum.filter(types, &(&1 in @forbidden))

  test "the approvals/questions system dispatch list is closed and excludes the merge gate" do
    assert offenders(Dispatch.command_types()) == []
  end

  test "the check can fail: a list with a merge command is caught" do
    assert offenders(["tool.finish", "merge_approve"]) == ["merge_approve"]
  end

  test "Dispatch refuses merge commands without reaching the gateway" do
    for type <- @forbidden do
      assert {:error, {:forbidden_command, ^type}} =
               Dispatch.system(
                 %{type: type, command_id: "x", aggregate_id: "run:r", payload: %{}},
                 NoSuchGateway
               )
    end
  end

  test "E8 MCP tools are read-only listings; none decides, answers or merges" do
    names = Enum.map(Tools.list_tools(), & &1.name)
    assert "foreman_approvals_list" in names and "foreman_questions_list" in names

    for name <- names, String.contains?(name, ["approve", "deny", "answer", "merge"]) do
      flunk("MCP tool #{name} must not exist")
    end

    for name <- ["foreman_approvals_list", "foreman_questions_list"],
        do: assert(Policy.authorized?(name))
  end

  test "operator tool/question commands cannot be aimed at a run's merge gate" do
    for type <- ["tool.approve", "tool.deny", "question.answer"] do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               ForemanServer.CommandGateway.dispatch_operator(%{
                 type: type,
                 command_id: "nm-#{type}",
                 aggregate_id: "run:r1",
                 payload: %{run_id: "r1", tool_call_id: "t", question_id: "q", text: "x"}
               })
    end
  end
end
