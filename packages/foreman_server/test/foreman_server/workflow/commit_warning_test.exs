defmodule ForemanServer.Workflow.CommitWarningTest do
  @moduledoc """
  REQ-006: never-committed work WARNS instead of refusing to load.

  This behavior replaced a load-time raise. The raise could not tell "the
  operator authored a workflow that stages changes for human review" from "the
  operator made a mistake", so it forbade the first outright. The warning is the
  PRD's design principle applied: refuse only what cannot be honoured (that is
  REQ-008, the cleanup case), and warn where the consequence would merely be
  INVISIBLE.

  Invisible is exact here. `AutoPR` gates on `git rev-list --count base..head`,
  which counts commits only. Deferred work is not a commit, so the run reports
  success and simply produces no PR — an operator otherwise has an absent PR
  and nothing anywhere attributing it.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ForemanServer.Workflow.{Interpreter, RunExecutor}

  defp state(specs, completed) do
    %{run_id: "run-warn", phase_specs: specs, completed: completed, run_worktree: nil}
  end

  # `refute_warned/2` rather than `assert capture_log(...) == ""`. In an async
  # case `capture_log/1` also captures lines emitted by tests running
  # concurrently in other modules, so an emptiness assertion passes or fails on
  # unrelated timing — it failed exactly once here on a line from another suite.
  # Asserting the ABSENCE OF THIS WARNING is both what the contract says and
  # immune to that bleed.
  defp warn(specs, completed) do
    capture_log(fn -> RunExecutor.__warn_uncommitted_work_for_test__(state(specs, completed)) end)
  end

  defp refute_warned(specs, completed) do
    refute warn(specs, completed) =~ "left work uncommitted"
  end

  defp temp_yaml!(body) do
    dir = Path.join(System.tmp_dir!(), "commit-warn-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "workflow.yaml")
    File.write!(path, body)
    on_exit(fn -> File.rm_rf(dir) end)
    path
  end

  describe "the manifest shape that used to be refused now loads" do
    test "a final phase declaring commit: false loads under cleanup: never" do
      # AC-006-1. This exact manifest raised at load before PR 2.
      path =
        temp_yaml!("""
        name: review-staging
        description: stages changes for human review
        worktree:
          cleanup: never
        phases:
          - name: draft
            command: "/skill:draft"
            commit: false
        """)

      assert {:ok, workflow} = Interpreter.load!(path)
      assert workflow["phases"] |> hd() |> Map.get("commit") == false
    end

    test "it also loads with no worktree block at all" do
      # Absent `cleanup:` is `never`, so the default is the permissive case.
      # Reading absent as `always` would refuse most deferring manifests.
      path =
        temp_yaml!("""
        name: review-staging
        description: d
        phases:
          - name: draft
            command: "/skill:draft"
            commit: false
        """)

      assert {:ok, _workflow} = Interpreter.load!(path)
    end
  end

  describe "run-terminal warning" do
    test "names the deferring phase when its work is never committed" do
      # AC-006-2. Naming the phase is the point: "something was left
      # uncommitted" would not tell an operator where to look.
      log = warn([%{name: "draft", commit: false}], [0])

      assert log =~ "left work uncommitted"
      assert log =~ "phase 0"
      assert log =~ "draft"
      assert log =~ "AutoPR proposes commits only"
    end

    test "names the EARLIEST phase of a consecutive uncommitted run" do
      log =
        warn(
          [
            %{name: "one", commit: false},
            %{name: "two", commit: false},
            %{name: "three", commit: false}
          ],
          [0, 1, 2]
        )

      assert log =~ "phase 0"
      assert log =~ "one"

      refute log =~ "phase 2",
             "the operator needs where the uncommitted run BEGINS, not which phase was last"
    end

    test "is silent when every deferral was absorbed" do
      # AC-006-4. A warning here would be noise on the normal batching path —
      # which is the feature's whole purpose — and would train operators to
      # ignore it.
      log = warn([%{name: "draft", commit: false}, %{name: "final", commit: true}], [0, 1])

      refute log =~ "left work uncommitted"
    end

    test "is silent for a run whose phases all commit" do
      refute_warned([%{name: "a", commit: true}, %{name: "b"}], [0, 1])
    end
  end

  describe "a run that fails before the absorbing phase" do
    test "warns even though the manifest's later phase would have committed" do
      # AC-006-3, and the case an end-of-manifest check misses entirely: the
      # committing phase that would have absorbed the work NEVER RAN. Judging
      # the manifest instead of the execution would report no problem while the
      # work sits uncommitted in the worktree.
      specs = [%{name: "draft", commit: false}, %{name: "final", commit: true}]

      log = warn(specs, [0])

      assert log =~ "left work uncommitted"
      assert log =~ "phase 0"
      assert log =~ "draft"
      assert log =~ "no " <> "later phase that ran committed it"
    end

    test "is silent for a run that failed before any phase completed" do
      # Nothing executed, so nothing was deferred. A warning would be false.
      refute_warned([%{name: "draft", commit: false}], [])
    end

    test "is silent when the failure came after the absorbing phase ran" do
      specs = [%{name: "draft", commit: false}, %{name: "final", commit: true}, %{name: "extra"}]

      refute_warned(specs, [0, 1])
    end
  end

  describe "totality" do
    test "a run carrying no phase specs does not raise" do
      refute_warned([], [])

      # A state with no :phase_specs key at all — the shape a run reaching
      # terminal before initialization would carry.
      assert capture_log(fn ->
               RunExecutor.__warn_uncommitted_work_for_test__(%{run_id: "r"})
             end) =~ ""
    end
  end
end
