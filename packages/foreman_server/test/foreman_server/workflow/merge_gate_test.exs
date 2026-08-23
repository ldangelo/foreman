defmodule ForemanServer.Workflow.MergeGateTest do
  use ExUnit.Case, async: false
  test "request then approve" do
    {:ok, _} = ForemanServer.Workflow.MergeGate.ensure_started()
    assert {:ok, :pending} = ForemanServer.Workflow.MergeGate.request_approval("https://github.com/foo/bar/pull/1", "ensemble")
    assert {:ok, :approved} = ForemanServer.Workflow.MergeGate.approve("https://github.com/foo/bar/pull/1", "alice", "github:alice")
  end
  test "approve unknown PR returns error" do
    {:ok, _} = ForemanServer.Workflow.MergeGate.ensure_started()
    assert {:error, :not_found} = ForemanServer.Workflow.MergeGate.approve("unknown", "alice", "github:alice")
  end
end
