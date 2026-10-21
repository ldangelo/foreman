defmodule ForemanServer.Threads.SteererTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Threads.{Steerer, Thread}

  test "every provider is pause_resume per the S2 NO-GO decision" do
    for provider <- [:pi, :claude, :codex, "pi", "claude", nil] do
      assert Steerer.capability(provider) == "pause_resume"
    end
  end

  test "the Thread DTO steering value agrees with the Steerer capability" do
    thread = %Thread{
      id: "run:steerer-test",
      door: :workflow,
      project_id: "p",
      title: "t",
      status: "running"
    }

    assert thread.steering == Steerer.capability(:pi)
    assert Thread.to_dto(thread)["steering"] == Steerer.capability(:claude)
  end
end
