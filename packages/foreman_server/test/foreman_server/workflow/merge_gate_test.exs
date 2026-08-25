defmodule ForemanServer.Workflow.MergeGateTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Workflow.MergeGate

  setup do
    case GenServer.whereis(MergeGate) do
      nil -> {:ok, _pid} = MergeGate.start_link()
      _pid -> :ok
    end

    MergeGate.clear()
    :ok
  end

  test "request then approve" do
    assert {:ok, :pending} = MergeGate.request_approval("https://github.com/foo/bar/pull/1", "ensemble")
    assert {:ok, :approved} = MergeGate.approve("https://github.com/foo/bar/pull/1", "alice", "github:alice")
  end

  test "approve unknown PR returns error" do
    assert {:error, :not_found} = MergeGate.approve("unknown", "alice", "github:alice")
  end
end
