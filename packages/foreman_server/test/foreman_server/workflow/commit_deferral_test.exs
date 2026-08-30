defmodule ForemanServer.Workflow.CommitDeferralTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.CommitDeferral

  defp phase(commit) when is_boolean(commit), do: %{"name" => "p", "commit" => commit}
  defp phase(:absent), do: %{"name" => "p"}

  describe "pending_phase/1" do
    test "returns nil when every deferral is followed by a committing phase" do
      assert CommitDeferral.pending_phase([phase(false), phase(true)]) == nil
      assert CommitDeferral.pending_phase([phase(false), phase(false), phase(true)]) == nil
    end

    test "an absent commit key absorbs a deferral, because absent means commit" do
      # This is the distinction the whole feature rests on: absent is NOT false.
      # If absent were ever backfilled as false, this would report pending.
      assert CommitDeferral.pending_phase([phase(false), phase(:absent)]) == nil
    end

    test "returns the index of a trailing deferral" do
      assert CommitDeferral.pending_phase([phase(true), phase(false)]) == 1
    end

    test "returns the EARLIEST index across consecutive unabsorbed deferrals" do
      # The operator needs where the uncommitted run began, not where it ended.
      # A `pending = index` fold (rather than `pending || index`) would return 2.
      assert CommitDeferral.pending_phase([phase(false), phase(false), phase(false)]) == 0
    end

    test "a committing phase clears earlier pending work, so only the later run reports" do
      phases = [phase(false), phase(true), phase(false), phase(false)]
      assert CommitDeferral.pending_phase(phases) == 2
    end

    test "a non-map entry is treated as non-deferring rather than raising" do
      # pending_phase/1 runs during manifest load, BEFORE a malformed phase list
      # has been rejected. Raising here would replace the validator's good error
      # message with a crash from inside the validator.
      assert CommitDeferral.pending_phase([phase(false), "not-a-map"]) == nil
      assert CommitDeferral.pending_phase(["not-a-map", nil, 42]) == nil
      assert CommitDeferral.pending_phase([phase(true), nil, phase(false)]) == 2
    end

    test "an empty list has nothing pending" do
      assert CommitDeferral.pending_phase([]) == nil
    end

    test "a non-list is total, not a raise" do
      assert CommitDeferral.pending_phase(nil) == nil
      assert CommitDeferral.pending_phase(%{"phases" => []}) == nil
    end
  end

  describe "deferred?/1" do
    test "only a literal boolean false defers" do
      assert CommitDeferral.deferred?(phase(false))
      refute CommitDeferral.deferred?(phase(true))
      refute CommitDeferral.deferred?(phase(:absent))
    end

    test "a non-boolean value does not defer" do
      # Interpreter refuses these at load, so this only pins that the predicate
      # itself never treats a truthy-looking string as a deferral.
      refute CommitDeferral.deferred?(%{"commit" => "false"})
      refute CommitDeferral.deferred?(%{"commit" => nil})
    end

    test "a non-map never defers" do
      refute CommitDeferral.deferred?("phase")
      refute CommitDeferral.deferred?(nil)
    end
  end
end
