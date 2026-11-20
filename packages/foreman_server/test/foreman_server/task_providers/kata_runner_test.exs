defmodule ForemanServer.TaskProviders.KataRunnerTest do
  use ExUnit.Case, async: true

  alias ForemanServer.TaskProviders.KataRunner

  test "the behaviour declares exactly one callback, cmd/3" do
    assert KataRunner.behaviour_info(:callbacks) == [cmd: 3]
    assert KataRunner.behaviour_info(:optional_callbacks) == []
  end
end
