defmodule ForemanServer.Workflow.CommitCleanupValidationTest do
  @moduledoc """
  REQ-008: a manifest is refused when — and only when — it declares deferred
  work that no phase commits AND a cleanup mode that DELETES the worktree
  holding it. That combination cannot be honoured by anything at runtime: the
  changes are destroyed, there is no branch, and `AutoPR` has nothing to
  propose.

  The interesting property is the "only when". This check replaced an
  UNCONDITIONAL raise on any never-committed deferral, which conflated two
  different manifests: the impossible one below, and the legitimate
  `cleanup: never` workflow that stages changes in a retained worktree for
  human review. Refusing both made "defer for review" inexpressible, so the
  matrix here asserts the four cleanup modes crossed with absorbed and
  never-absorbed deferrals, and pins refusal to exactly the two unsatisfiable
  cells.
  """
  use ExUnit.Case, async: true

  # `Workflow.MissingRequiredPhaseError` is TOP-LEVEL, not
  # `ForemanServer.Workflow.*` — aliasing the latter makes every `assert_raise`
  # here silently name a module that does not exist, and the assertion then
  # fails as "no exception raised" against code that raised correctly.
  alias ForemanServer.Workflow.Interpreter

  defp manifest!(cleanup, phases) do
    worktree =
      case cleanup do
        nil -> ""
        mode -> "worktree:\n  cleanup: #{mode}\n"
      end

    body =
      Enum.map_join(phases, fn {name, commit} ->
        tag = if commit == :absent, do: "", else: "    commit: #{commit}\n"
        "  - name: #{name}\n    command: \"/skill:#{name}\"\n#{tag}"
      end)

    dir = Path.join(System.tmp_dir!(), "commit-cleanup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "workflow.yaml")
    File.write!(path, "name: w\ndescription: d\n#{worktree}phases:\n#{body}")
    on_exit(fn -> File.rm_rf(dir) end)
    path
  end

  # Never absorbed: the last phase defers, so its work is uncommitted forever.
  @never_absorbed [{"draft", false}]

  # Absorbed: a committing phase follows the deferral, which is the batching the
  # tag exists to provide.
  @absorbed [{"draft", false}, {"final", true}]

  describe "unsatisfiable: deferred work in a worktree that gets deleted" do
    test "cleanup: always with a never-absorbed deferral is refused" do
      # AC-008-1.
      path = manifest!("always", @never_absorbed)

      assert_raise Workflow.MissingRequiredPhaseError, fn -> Interpreter.load!(path) end
    end

    test "cleanup: on_success with a never-absorbed deferral is refused" do
      # AC-008-4. `on_success` is a genuinely distinct third mode, not a synonym
      # for `always` — but it still deletes the worktree on the success path,
      # which is precisely the path a deferring run takes when nothing fails.
      path = manifest!("on_success", @never_absorbed)

      assert_raise Workflow.MissingRequiredPhaseError, fn -> Interpreter.load!(path) end
    end

    test "the refusal names the deferring phase AND the cleanup mode" do
      # Both halves of the contradiction, because either alone is insufficient
      # to act on: the operator has to know which phase to move the commit to,
      # and which declaration made it fatal. The message also states the two
      # ways out, since both are legitimate fixes.
      path = manifest!("always", [{"a", true}, {"draft", false}])

      error = assert_raise Workflow.MissingRequiredPhaseError, fn -> Interpreter.load!(path) end

      assert error.message =~ "phase 1"
      assert error.message =~ "commit: false"
      assert error.message =~ "always"
      assert error.message =~ "destroyed"
      assert error.message =~ "cleanup: never"
    end
  end

  describe "satisfiable: the same deferral where the work survives" do
    test "cleanup: never with a never-absorbed deferral loads" do
      # AC-008-3, and the case the old unconditional raise wrongly refused. The
      # work stays in the retained worktree where an operator can inspect or
      # commit it; REQ-006's run-terminal warning makes the absent PR
      # attributable instead.
      assert {:ok, _} = Interpreter.load!(manifest!("never", @never_absorbed))
    end

    test "an absent worktree block with a never-absorbed deferral loads" do
      # Absent `cleanup:` defaults to `never`, matching
      # `RunExecutor.worktree_cleanup/1`. If validation read absent as `always`
      # it would refuse nearly every deferring manifest, since most declare no
      # `worktree:` block at all.
      assert {:ok, _} = Interpreter.load!(manifest!(nil, @never_absorbed))
    end
  end

  describe "absorbed deferrals load under every cleanup mode" do
    # AC-008-2. Absorption is the normal path, so no cleanup mode may refuse it:
    # the work becomes a commit on the run's branch before cleanup runs, and the
    # branch survives worktree removal.
    for mode <- [nil, "never", "always", "on_success"] do
      test "cleanup: #{inspect(mode)} with an absorbed deferral loads" do
        assert {:ok, _} = Interpreter.load!(manifest!(unquote(mode), @absorbed))
      end
    end

    for mode <- [nil, "never", "always", "on_success"] do
      test "cleanup: #{inspect(mode)} with no deferral at all loads" do
        assert {:ok, _} =
                 Interpreter.load!(manifest!(unquote(mode), [{"a", true}, {"b", :absent}]))
      end
    end
  end

  describe "worktree disabled" do
    test "cleanup: always with a never-absorbed deferral loads when enabled: false" do
      # REQ-003: with no worktree there is nothing to clean and `commit:` is
      # inert, so the contradiction does not exist. Refusing here would reject a
      # manifest whose declaration has no consequence — the mirror of the bug
      # this check was written to fix.
      dir = Path.join(System.tmp_dir!(), "commit-cleanup-off-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "workflow.yaml")

      File.write!(path, """
      name: w
      description: d
      worktree:
        enabled: false
        cleanup: always
      phases:
        - name: draft
          command: "/skill:draft"
          commit: false
      """)

      on_exit(fn -> File.rm_rf(dir) end)

      assert {:ok, _} = Interpreter.load!(path)
    end
  end

  describe "bundled manifests" do
    test "every bundled workflow loads, so no shipped manifest hits either rule" do
      bundled =
        Path.wildcard(Path.join(:code.priv_dir(:foreman_server), "defaults/workflows/*.yaml"))

      assert length(bundled) == 11

      for source <- bundled do
        assert {:ok, _} = Interpreter.load!(source),
               "bundled #{Path.basename(source)} must still load"
      end
    end
  end
end
