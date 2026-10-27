defmodule ForemanServer.Workflow.CheckoutGuardTest do
  @moduledoc """
  foreman-koas6: real git repositories, no mocks. The checkout is `repo`, the run's
  worktree a `git worktree add` of it on its own branch.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.AgentRuntime.JidoHarness.FailureCause
  alias ForemanServer.Workflow.CheckoutGuard

  setup do
    root = Path.join(System.tmp_dir!(), "checkout-guard-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "--initial-branch=main", "--quiet"])
    git!(repo, ["config", "user.email", "t@x"])
    git!(repo, ["config", "user.name", "T"])
    File.write!(Path.join(repo, "README.md"), "seed\n")
    File.write!(Path.join(repo, "tracked.txt"), "one\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--no-gpg-sign", "-m", "seed", "--quiet"])

    base = git!(repo, ["rev-parse", "HEAD"])
    worktree = Path.join(root, "wt")
    git!(repo, ["worktree", "add", "-q", worktree, "-b", "foreman/run-1", base])
    git!(worktree, ["config", "user.email", "t@x"])
    git!(worktree, ["config", "user.name", "T"])

    on_exit(fn -> File.rm_rf(root) end)

    record = %{
      project_root: repo,
      base_ref: base,
      worktree_path: worktree,
      branch: "foreman/run-1"
    }

    %{repo: repo, worktree: worktree, record: record}
  end

  test "expected?/1: only an explicit commit: true counts" do
    assert CheckoutGuard.expected?([%{name: "a", commit: true}])
    assert CheckoutGuard.expected?([%{name: "a", commit: false}, %{name: "b", commit: true}])
    refute CheckoutGuard.expected?([%{name: "a"}])
    refute CheckoutGuard.expected?([%{name: "a", commit: false}])
    refute CheckoutGuard.expected?([])
  end

  defp snapshot!(record) do
    assert {:ok, snap} = CheckoutGuard.snapshot(record)
    snap
  end

  test "an empty branch while the checkout gained files fails, naming the files", ctx do
    snap = snapshot!(ctx.record)
    File.write!(Path.join(ctx.repo, "report.md"), "the worker's output\n")
    File.mkdir_p!(Path.join(ctx.repo, "docs"))
    File.write!(Path.join(ctx.repo, "docs/plan.md"), "plan\n")

    assert {:error, %FailureCause{code: :checkout_written_instead_of_worktree, detail: detail}} =
             CheckoutGuard.verify(snap, ctx.record)

    assert detail =~ "report.md"
    assert detail =~ "docs/plan.md"
    assert detail =~ ctx.repo

    assert FailureCause.render(%FailureCause{code: :x, detail: detail}) =~
             "instead of the run's worktree"
  end

  test "a modified tracked file in the checkout counts too", ctx do
    snap = snapshot!(ctx.record)
    File.write!(Path.join(ctx.repo, "tracked.txt"), "two\n")

    assert {:error, %FailureCause{detail: detail}} = CheckoutGuard.verify(snap, ctx.record)
    assert detail =~ "tracked.txt"
  end

  test "a run that committed in its worktree passes even if the checkout gained files", ctx do
    snap = snapshot!(ctx.record)
    File.write!(Path.join(ctx.worktree, "work.txt"), "done\n")
    git!(ctx.worktree, ["add", "."])
    git!(ctx.worktree, ["commit", "--no-gpg-sign", "-m", "work", "--quiet"])

    # The operator edits the checkout while the run commits properly.
    File.write!(Path.join(ctx.repo, "operator-notes.txt"), "mine\n")
    File.write!(Path.join(ctx.repo, "tracked.txt"), "edited\n")

    assert :ok = CheckoutGuard.verify(snap, ctx.record)
  end

  test "uncommitted work in the worktree is not an empty run (commit: false)", ctx do
    snap = snapshot!(ctx.record)
    File.write!(Path.join(ctx.worktree, "deferred.txt"), "pending\n")
    File.write!(Path.join(ctx.repo, "operator-notes.txt"), "mine\n")

    assert :ok = CheckoutGuard.verify(snap, ctx.record)
  end

  test "an empty branch and an untouched checkout passes", ctx do
    assert :ok = CheckoutGuard.verify(snapshot!(ctx.record), ctx.record)
  end

  test "a checkout already dirty at the snapshot is compared against that, not against clean",
       ctx do
    File.write!(Path.join(ctx.repo, "operator-wip.txt"), "wip\n")
    File.write!(Path.join(ctx.repo, "tracked.txt"), "wip\n")
    snap = snapshot!(ctx.record)

    assert :ok = CheckoutGuard.verify(snap, ctx.record)

    File.write!(Path.join(ctx.repo, "from-worker.txt"), "x\n")

    assert {:error, %FailureCause{detail: detail}} = CheckoutGuard.verify(snap, ctx.record)
    assert detail =~ "from-worker.txt"
    refute detail =~ "operator-wip.txt"
  end

  test ".beads runtime churn in the checkout is ignored", ctx do
    snap = snapshot!(ctx.record)
    File.mkdir_p!(Path.join(ctx.repo, ".beads"))
    File.write!(Path.join(ctx.repo, ".beads/beads.db-wal"), "x")

    assert :ok = CheckoutGuard.verify(snap, ctx.record)
  end

  test "a nil snapshot (resumed run) passes", ctx do
    File.write!(Path.join(ctx.repo, "report.md"), "x\n")
    assert :ok = CheckoutGuard.verify(nil, ctx.record)
  end

  test "an unreadable checkout is a typed failure, not a pass", ctx do
    snap = snapshot!(ctx.record)
    File.rm_rf!(Path.join(ctx.repo, ".git/HEAD"))

    assert {:error, %FailureCause{code: :checkout_guard_unverifiable}} =
             CheckoutGuard.verify(snap, ctx.record)
  end

  defp git!(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, code} -> flunk("git #{Enum.join(args, " ")} failed (#{code}) in #{dir}: #{out}")
    end
  end
end
