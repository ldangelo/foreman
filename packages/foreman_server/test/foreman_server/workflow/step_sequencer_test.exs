defmodule ForemanServer.Workflow.StepSequencerTest do
  use ExUnit.Case, async: true
  test "failed status halts sequence" do
    assert {:halted, :failed, _} = ForemanServer.Workflow.StepSequencer.sequence([:a, :b, :c], :failed)
  end
  test "blocked status halts sequence" do
    assert {:halted, :blocked, _} = ForemanServer.Workflow.StepSequencer.sequence([:a, :b], :blocked)
  end
  test "completed status proceeds" do
    assert {:ok, :completed} = ForemanServer.Workflow.StepSequencer.sequence([:a, :b], :completed)
  end
end
