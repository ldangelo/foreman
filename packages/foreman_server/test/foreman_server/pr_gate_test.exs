defmodule ForemanServer.PrGateTest do
  use ExUnit.Case, async: false

  alias ForemanServer.PrGate

  setup do
    {:ok, _} = ForemanServer.Workflow.MergeGate.ensure_started()
    :ok
  end

  describe "evaluate/1 — pure status check" do
    test ":open returns :ok" do
      assert PrGate.evaluate(:open) == :ok
    end

    test ":merged returns :ok" do
      assert PrGate.evaluate(:merged) == :ok
    end

    test ":closed returns {:error, :pr_not_acceptable}" do
      assert PrGate.evaluate(:closed) == {:error, :pr_not_acceptable}
    end

    test ":conflicted returns {:error, :pr_not_acceptable}" do
      assert PrGate.evaluate(:conflicted) == {:error, :pr_not_acceptable}
    end

    test "unknown status returns {:error, :pr_not_acceptable}" do
      assert PrGate.evaluate(:weird) == {:error, :pr_not_acceptable}
      assert PrGate.evaluate(nil) == {:error, :pr_not_acceptable}
    end
  end

  describe "check/1 — non-binary" do
    test "returns {:error, :no_pr_association} for nil" do
      assert PrGate.check(nil) == {:error, :no_pr_association}
    end

    test "returns {:error, :no_pr_association} for non-string" do
      assert PrGate.check(:foo) == {:error, :no_pr_association}
      assert PrGate.check(123) == {:error, :no_pr_association}
    end
  end

  describe "check/1 — with no association registered" do
    test "returns {:error, :no_pr_association} when ProjectionStore has no association" do
      assert {:error, :no_pr_association} = PrGate.check("unknown-run-#{System.unique_integer()}")
    end
  end
end
