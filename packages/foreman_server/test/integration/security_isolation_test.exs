defmodule ForemanServer.Integration.SecurityIsolationTest do
  use ExUnit.Case, async: false
  @moduletag :security
  @moduletag :integration

  alias ForemanServer.Agents.VfsIsolation
  alias ForemanServer.Workflow.ApproverAuthorizer
  alias ForemanServer.Workflow.MergeToolRefuser

  test "vector 1: jido_vfs denies out-of-worktree access" do
    case GenServer.whereis(VfsIsolation) do
      nil -> start_supervised!(VfsIsolation)
      _pid -> :ok
    end

    :ok = VfsIsolation.bind("agent-sec", "/tmp/wt-sec")
    refute VfsIsolation.allowed?("agent-sec", "/etc/passwd")
    assert VfsIsolation.allowed?("agent-sec", "/tmp/wt-sec/file.txt")
  end

  test "vector 2: unauthorized approver rejected" do
    assert {:error, :unauthorized_approver} = ApproverAuthorizer.authorize("github:attacker")
  end

  test "vector 3: agent denied direct merge" do
    refute MergeToolRefuser.permitted?("agent:1")
    assert MergeToolRefuser.permitted?("merge_gate")
    assert MergeToolRefuser.permitted?("human:operator")
  end
end
