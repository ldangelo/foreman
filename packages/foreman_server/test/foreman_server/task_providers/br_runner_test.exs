defmodule ForemanServer.TaskProviders.BrRunnerTest do
  use ExUnit.Case, async: true

  alias ForemanServer.TaskProviders.BrRunner

  test "declares cmd/3 as the only callback" do
    callbacks = BrRunner.behaviour_info(:callbacks)

    assert callbacks == [cmd: 3]
  end

  test "cmd/3 arity is 3" do
    callbacks = BrRunner.behaviour_info(:callbacks)

    assert {:cmd, 3} in callbacks
    assert length(callbacks) == 1
  end

  test "behaviour module loads cleanly" do
    assert Code.ensure_loaded?(BrRunner) == true
  end
end
