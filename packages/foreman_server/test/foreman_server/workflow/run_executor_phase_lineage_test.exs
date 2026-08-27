defmodule ForemanServer.Workflow.RunExecutorPhaseLineageTest do
  # Phase lineage: a phase's worktree is cut from the PREVIOUS phase's
  # branch, so committed artifacts flow forward. Real git repositories, the
  # production VCS adapter, and the production discovery gate — no mocks.
  use ExUnit.Case, async: false

  alias ForemanServer.VcsAdapter.Default
  alias ForemanServer.Workflow.PlanContext
  alias ForemanServer.Workflow.RunExecutor

  setup do
    repo = Path.join(System.tmp_dir!(), "lineage-#{System.unique_integer([:positive])}")
    File.rm_rf!(repo)
    File.mkdir_p!(repo)
    git!(repo, ["init", "--initial-branch=main", "--quiet"])
    git!(repo, ["config", "user.email", "t@x"])
    git!(repo, ["config", "user.name", "T"])
    File.write!(Path.join(repo, "README.md"), "seed")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--no-gpg-sign", "-m", "seed", "--quiet"])

    on_exit(fn -> File.rm_rf(repo) end)

    %{repo: repo, base: head!(repo)}
  end

  describe "phase_lineage_base_ref/2" do
    # The first phase of a run has no predecessor, so it still cuts from the
    # current branch tip. This is the whole of the single-phase and non-plan
    # contract: `remember_worktree/2` runs AFTER provisioning, so a
    # single-phase run never has a `:last_worktree` when its only phase is
    # provisioned and resolves exactly as it did before chaining.
    test "no previous phase resolves the current branch tip", %{repo: repo, base: base} do
      assert RunExecutor.__phase_lineage_base_ref_for_test__(%{}, repo) == {:ok, base}
    end

    test "a previous phase's branch resolves to that branch's tip", %{repo: repo, base: base} do
      git!(repo, ["branch", "foreman/run-x/create-prd", base])
      state = %{last_worktree: %{branch: "foreman/run-x/create-prd"}}

      assert RunExecutor.__phase_lineage_base_ref_for_test__(state, repo) == {:ok, base}

      # The lineage tracks the predecessor's tip, not the run's base: once
      # phase 1 commits, phase 2 must be cut from the commit that carries
      # the document, not from where phase 1 started.
      advanced = commit_on_branch!(repo, "foreman/run-x/create-prd", "docs/PRD/PRD.md")
      refute advanced == base

      assert RunExecutor.__phase_lineage_base_ref_for_test__(state, repo) == {:ok, advanced}
    end

    # AGENTS.md 5.2/5.3: falling back to HEAD here would hand the phase a
    # checkout missing its input document and let the run produce a
    # plausible-looking wrong artifact — the exact failure chaining removes.
    test "a previous phase's branch git cannot resolve is its own loud error", %{repo: repo} do
      state = %{last_worktree: %{branch: "foreman/run-x/deleted"}}

      assert RunExecutor.__phase_lineage_base_ref_for_test__(state, repo) ==
               {:error,
                {:phase_lineage_branch_unresolvable, "foreman/run-x/deleted",
                 :unresolvable_revision}}
    end

    test "a repository git cannot read is not silently treated as a first phase" do
      not_a_repo = Path.join(System.tmp_dir!(), "no-repo-#{System.unique_integer([:positive])}")
      state = %{last_worktree: %{branch: "foreman/run-x/create-prd"}}

      assert RunExecutor.__phase_lineage_base_ref_for_test__(state, not_a_repo) ==
               {:error,
                {:phase_lineage_branch_unresolvable, "foreman/run-x/create-prd",
                 :unresolvable_revision}}
    end
  end

  describe "chained phase worktrees" do
    # The pipeline run-d75304aca144c15409087ed744e2a7dc failed here: phase 2
    # was cut from the base branch, so phase 1's committed PRD was not in
    # its checkout and `docs/TRD` discovery failed with
    # {:planning_document_absent, "docs/TRD", ...}.
    test "phase 2 inherits phase 1's committed document and discovery sees only its own", %{
      repo: repo,
      base: base
    } do
      phase1_branch = "foreman/run-lineage/create-prd"
      phase2_branch = "foreman/run-lineage/create-trd"
      wt1 = Path.join(repo, ".worktrees/create-prd")
      wt2 = Path.join(repo, ".worktrees/create-trd")
      prd = "docs/PRD/PRD-2026-6a25501b-durable-run-log-store.md"
      trd = "docs/TRD/TRD-2026-6a25501b-durable-run-log-store.md"

      # Phase 1: first phase of the run, cut from the branch tip.
      assert {:ok, _} = Default.create_worktree(repo, wt1, worktree_opts(repo, base, phase1_branch))
      write!(wt1, prd)
      commit!(wt1, "prd")

      # Phase cleanup: `cleanup_phase_worktree/4` -> `Worktree.clean/1`
      # reaches this exact adapter call. It reclaims the directory and
      # leaves the ref alone, which is what makes the lineage available to
      # the next phase. Branch deletion lives in `Worktree.clean_for_run/1`
      # (RunDeleted only).
      assert {:ok, %{cleaned?: true}} = Default.clean_worktree(wt1, worktree_opts(repo, base, phase1_branch))
      refute File.dir?(wt1)

      lineage = resolve!(repo, phase1_branch)
      assert lineage != base, "phase 1's commit must be on its branch"

      # Phase 2: chained onto phase 1's branch.
      assert {:ok, _} =
               Default.create_worktree(repo, wt2, worktree_opts(repo, lineage, phase2_branch))

      assert File.regular?(Path.join(wt2, prd)),
             "phase 2's checkout must contain phase 1's committed PRD"

      write!(wt2, trd)
      commit!(wt2, "trd")

      # `capture_planning_document/4` diffs `<base_ref>..HEAD`, and with
      # chaining phase 2's `base_ref` IS phase 1's tip — so the inherited
      # PRD is correctly not new in phase 2 and `docs/TRD` captures exactly
      # the TRD.
      assert PlanContext.discover_document(wt2, "docs/TRD", lineage) == {:ok, trd}

      assert PlanContext.discover_document(wt2, "docs/PRD", lineage) ==
               {:error, {:planning_document_absent, "docs/PRD", wt2}}

      # Why `base_ref` has to chain along with the checkout: against the
      # run's base, the inherited PRD reads as a document phase 2 produced.
      assert PlanContext.discover_document(wt2, "docs/PRD", base) == {:ok, prd}

      Default.clean_worktree(wt2, worktree_opts(repo, lineage, phase2_branch))
    end
  end

  defp worktree_opts(repo, base, branch) do
    [
      operation_id: "wt-lineage-#{System.unique_integer([:positive])}",
      repo_path: repo,
      base: base,
      branch: branch,
      project_id: "p",
      run_id: "run-lineage",
      phase_id: "ph"
    ]
  end

  defp commit_on_branch!(repo, branch, relative) do
    wt = Path.join(repo, ".worktrees/tmp-#{System.unique_integer([:positive])}")
    git!(repo, ["worktree", "add", "--quiet", wt, branch])
    write!(wt, relative)
    commit!(wt, "advance #{branch}")
    git!(repo, ["worktree", "remove", wt])
    resolve!(repo, branch)
  end

  defp resolve!(repo, ref) do
    {sha, 0} = System.cmd("git", ["-C", repo, "rev-parse", "--verify", ref], stderr_to_stdout: true)
    String.trim(sha)
  end

  defp head!(repo), do: resolve!(repo, "HEAD")

  defp write!(root, relative, body \\ "document body") do
    target = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, body)
  end

  defp commit!(root, message) do
    git!(root, ["add", "-A", "--", "docs"])
    git!(root, ["commit", "--no-gpg-sign", "-m", message, "--quiet"])
  end

  defp git!(root, args) do
    {_output, 0} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
    :ok
  end
end
