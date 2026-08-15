defmodule ForemanServer.CommandRouterRunSlotsTest do
  use ExUnit.Case, async: true

  alias ForemanServer.CommandRouter

  describe "aggregate_module_for/1" do
    test "run_slots:global routes to RunSlots" do
      assert CommandRouter.aggregate_module_for("run_slots:global") ==
               ForemanServer.Aggregates.RunSlots
    end

    test "run_slots: with any suffix routes to RunSlots" do
      assert CommandRouter.aggregate_module_for("run_slots:some-id") ==
               ForemanServer.Aggregates.RunSlots
    end

    test "other stream prefixes raise FunctionClauseError" do
      assert_raise FunctionClauseError, fn ->
        CommandRouter.aggregate_module_for("unknown:foo")
      end
    end
  end
end
