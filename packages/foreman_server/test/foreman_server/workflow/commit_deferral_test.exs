defmodule ForemanServer.Workflow.CommitDeferralTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.CommitDeferral
  alias ForemanServer.Workflow.Interpreter

  # Deliberately NO `alias ForemanServer.Workflow`: `MissingRequiredPhaseError`
  # is a TOP-LEVEL `Workflow.*` module, and that alias silently redirects the
  # reference to a nonexistent `ForemanServer.Workflow.MissingRequiredPhaseError`.

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

    test "a non-map entry raises rather than inventing a non-deferring answer" do
      # A previous version of this test asserted the opposite and justified it
      # with "pending_phase/1 runs during manifest load, BEFORE a malformed
      # phase list has been rejected". That was simply wrong about the ordering:
      # `Interpreter.load!/1` calls `validate_required_fields!` (which rejects a
      # non-map phase entry at `validate_phase!`, with a message naming the
      # phase index) BEFORE `validate_commits!`. So the fallback never protected
      # any real error message — it only meant that if this function were ever
      # reached with unreadable input, it would answer "nothing deferred", which
      # is the answer that suppresses both the cleanup refusal and the
      # uncommitted-work warning. §5.2: a crash beats a lie.
      assert_raise FunctionClauseError, fn ->
        CommitDeferral.pending_phase([phase(false), "not-a-map"])
      end

      assert_raise FunctionClauseError, fn ->
        CommitDeferral.pending_phase(["not-a-map", nil, 42])
      end
    end

    test "a malformed manifest dies in the parser, before this is ever reached" do
      # The guarantee that makes raising safe, and it holds one layer earlier
      # than expected: a non-mapping phase entry is rejected by `parse_yaml!`
      # itself, naming the file and line, so it never reaches phase validation
      # let alone `validate_commits!`. If this ever regresses the operator gets
      # a FunctionClauseError instead of a located message, and THAT is the
      # failure worth catching here rather than papering over with a fallback.
      path = Path.join(System.tmp_dir!(), "commit-deferral-#{System.unique_integer([:positive])}.yaml")

      on_exit(fn -> File.rm_rf(path) end)

      File.write!(path, """
      name: malformed
      phases:
        - name: ok
          bash: "true"
        - "not-a-mapping"
      """)

      assert_raise ArgumentError, ~r/unsupported phase entry .* at line 5: "not-a-mapping"/, fn ->
        Interpreter.load!(path)
      end
    end

    test "an empty list has nothing pending" do
      assert CommitDeferral.pending_phase([]) == nil
    end

    test "a non-list raises: there is no safe answer for input it cannot read" do
      assert_raise FunctionClauseError, fn -> CommitDeferral.pending_phase(nil) end
      assert_raise FunctionClauseError, fn -> CommitDeferral.pending_phase(%{"phases" => []}) end
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

    test "a non-map raises: 'this phase commits' is not a safe default to invent" do
      assert_raise FunctionClauseError, fn -> CommitDeferral.deferred?("phase") end
      assert_raise FunctionClauseError, fn -> CommitDeferral.deferred?(nil) end
    end
  end
end
