defmodule ForemanServer.Workflow.StepSequencerTest do
  use ExUnit.Case, async: true
  alias ForemanServer.Workflow.StepSequencer

  describe "sequence/2" do
    test "failed initial status halts sequence" do
      assert {:halted, :failed, :a} = StepSequencer.sequence([:a, :b, :c], :failed)
    end

    test "blocked initial status halts sequence" do
      assert {:halted, :blocked, :a} = StepSequencer.sequence([:a, :b], :blocked)
    end

    test "completed status proceeds through all steps" do
      assert {:ok, :completed} = StepSequencer.sequence([:a, :b], :completed)
    end

    test "pending status proceeds through all steps" do
      assert {:ok, :completed} = StepSequencer.sequence([:a, :b, :c], :pending)
    end

    test "in_progress status proceeds through all steps" do
      assert {:ok, :completed} = StepSequencer.sequence([:a, :b], :in_progress)
    end

    test "empty steps list returns initial status" do
      assert {:ok, :pending} = StepSequencer.sequence([], :pending)
    end
  end

  describe "propagate_terminal/2" do
    test "failed halts with :failed reason" do
      assert {:halt, :failed} = StepSequencer.propagate_terminal(:failed, :next_step)
    end

    test "blocked halts with :blocked reason" do
      assert {:halt, :blocked} = StepSequencer.propagate_terminal(:blocked, :next_step)
    end

    test "completed continues with :cont" do
      assert {:cont, nil} = StepSequencer.propagate_terminal(:completed, :next_step)
    end

    test "in_progress continues with :cont" do
      assert {:cont, nil} = StepSequencer.propagate_terminal(:in_progress, :next_step)
    end

    test "pending continues with :cont" do
      assert {:cont, nil} = StepSequencer.propagate_terminal(:pending, :next_step)
    end
  end
end
