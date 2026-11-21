defmodule ForemanServer.TestSupport.RunSlotsResetTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.RunSlots
  alias ForemanServer.CommandGateway
  alias ForemanServer.TestSupport.RunSlotsReset

  # One `run_slots:<project_id>` actor per project. A reset that crashes them makes the
  # Aggregator restart each one, and past its budget of 100 restarts in 5 s it exits `:shutdown`
  # with every actor, a moment AFTER `reset!/0` returned: the next test's `start_child` call then
  # exits `:shutdown`. So the test waits for the restarts to be over before it looks.
  test "resetting more slot actors than the restart budget leaves the Aggregator running" do
    tag = System.unique_integer([:positive])

    for i <- 1..150 do
      project_id = "reset-budget-#{tag}-#{i}"

      assert {:ok, _} =
               CommandGateway.dispatch_system(%{
                 type: "run_slots.acquire",
                 command_id: "reset-budget:#{tag}:#{i}",
                 aggregate_id: RunSlots.stream_id(project_id),
                 payload: %{run_id: "run-#{tag}-#{i}", capacity: 3, project_id: project_id}
               })
    end

    aggregator = Process.whereis(ForemanServer.Aggregator)

    RunSlotsReset.reset!()
    Process.sleep(3_000)

    assert Process.whereis(ForemanServer.Aggregator) == aggregator
  end
end
