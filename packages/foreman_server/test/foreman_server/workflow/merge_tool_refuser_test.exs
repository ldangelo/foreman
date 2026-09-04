defmodule ForemanServer.Workflow.MergeToolRefuserTest do
  use ExUnit.Case, async: true

  test "permitted? allows merge_gate" do
    assert ForemanServer.Workflow.MergeToolRefuser.permitted?("merge_gate")
  end

  test "permitted? allows human operator" do
    assert ForemanServer.Workflow.MergeToolRefuser.permitted?("human:operator")
  end

  test "permitted? denies agent" do
    refute ForemanServer.Workflow.MergeToolRefuser.permitted?("agent:1")
  end

  test "refuse returns error tuple" do
    assert {:error, :merge_refused, _msg} =
             ForemanServer.Workflow.MergeToolRefuser.refuse("agent:1", "gh.merge", "direct_call")
  end
end
