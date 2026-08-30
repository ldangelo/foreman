defmodule ForemanServer.Workflow.RunExecutorRunWorktreeTest do
  # A run has exactly ONE worktree. Every phase executes in that same checkout
  # on that same branch, so a later phase reads its predecessors' output as
  # ordinary files rather than inheriting it through a chain of per-phase
  # branches.
  #
  # Real git repositories, the production VCS adapter, the production commit
  # path, and the production discovery gate — no mocks.
  #
  # This replaced `run_executor_phase_lineage_test.exs`, which pinned the
  # per-phase design: N worktrees per run, each cut from the previous phase's
  # branch tip, each destroyed at its phase boundary. The invariant that file
  # existed to protect is preserved below and is the interesting part of this
  # one: a phase's discovery gate must see the documents new in THAT phase and
  # not the ones it inherited.
  use ExUnit.Case, async: false

  alias ForemanServer.VcsAdapter.Default
  alias ForemanServer.Workflow.PlanContext
  alias ForemanServer.Workflow.RunExecutor

  setup do
    repo = Path.join(System.tmp_dir!(), "run-wt-#{System.unique_integer([:positive])}")
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

  describe "reuse_run_worktree/2" do
    # The one per-phase value a reused worktree carries. `commit_phase_worktree/4`
    # commits at each phase boundary, so the shared checkout's HEAD at phase N's
    # start is exactly "everything phases 1..N-1 produced" — which is the base
    # the discovery gate must diff against.
    test "refreshes base_ref to the shared checkout's current HEAD", %{repo: repo, base: base} do
      wt = Path.join(repo, ".worktrees/workspace")
      branch = "foreman/run-reuse"
      assert {:ok, _} = Default.create_worktree(repo, wt, worktree_opts(repo, base, branch))

      record = %{worktree_path: wt, branch: branch, base_ref: base}

      # Nothing committed yet: HEAD is still the run's base.
      assert {:ok, %{base_ref: ^base}} =
               RunExecutor.__reuse_run_worktree_for_test__(record, wt)

      write!(wt, "docs/PRD/PRD.md")
      commit!(wt, "prd")
      advanced = resolve!(repo, branch)
      refute advanced == base

      assert {:ok, reused} = RunExecutor.__reuse_run_worktree_for_test__(record, wt)
      assert reused.base_ref == advanced, "base_ref must advance with the shared checkout"
      assert reused.worktree_path == wt, "the path is run-scoped and must not change"
      assert reused.branch == branch, "the branch is run-scoped and must not change"

      Default.clean_worktree(wt, worktree_opts(repo, base, branch))
    end

    # AGENTS.md 5.2/5.3: continuing here would run the phase against whatever
    # directory git resolves instead, producing a plausible-looking artifact
    # from the wrong tree.
    test "a worktree that vanished mid-run is its own loud error" do
      gone = Path.join(System.tmp_dir!(), "gone-#{System.unique_integer([:positive])}")
      record = %{worktree_path: gone, branch: "foreman/run-x", base_ref: "abc"}

      assert RunExecutor.__reuse_run_worktree_for_test__(record, gone) ==
               {:error, {:run_worktree_vanished, gone}}
    end

    test "a checkout whose HEAD git cannot resolve is its own loud error" do
      not_a_repo = Path.join(System.tmp_dir!(), "no-repo-#{System.unique_integer([:positive])}")
      File.mkdir_p!(not_a_repo)
      on_exit(fn -> File.rm_rf(not_a_repo) end)

      record = %{worktree_path: not_a_repo, branch: "foreman/run-x", base_ref: "abc"}

      assert RunExecutor.__reuse_run_worktree_for_test__(record, not_a_repo) ==
               {:error, {:run_worktree_head_unresolvable, not_a_repo, :unresolvable_revision}}
    end
  end

  describe "worktree_cleanup/1" do
    test "defaults to never so the checkout survives for AutoPR" do
      assert RunExecutor.__worktree_cleanup_for_test__(%{}) == {:ok, :never}
    end

    test "honors the cleanup key the bundled manifests declare" do
      assert RunExecutor.__worktree_cleanup_for_test__(%{cleanup: "never"}) == {:ok, :never}
      assert RunExecutor.__worktree_cleanup_for_test__(%{cleanup: "always"}) == {:ok, :always}
      assert RunExecutor.__worktree_cleanup_for_test__(%{cleanup: :never}) == {:ok, :never}
      assert RunExecutor.__worktree_cleanup_for_test__(%{cleanup: :always}) == {:ok, :always}
    end

    # `on_success` was missing from this table, and its absence is not cosmetic:
    # the function once matched only "never" and sent everything else to
    # `:always`, so a manifest asking to KEEP a failed run's checkout for
    # forensics had it deleted — the exact inversion `on_success` exists to
    # prevent. A regression restoring that mapping passed the suite above.
    test "on_success is a third mode, never an alias for always" do
      assert RunExecutor.__worktree_cleanup_for_test__(%{cleanup: "on_success"}) ==
               {:ok, :on_success}

      assert RunExecutor.__worktree_cleanup_for_test__(%{cleanup: :on_success}) ==
               {:ok, :on_success}
    end

    # A misspelled declaration must not read as a working one that quietly does
    # the opposite (AGENTS.md 5.2/5.3).
    test "an unrecognized value is rejected, not defaulted" do
      assert RunExecutor.__worktree_cleanup_for_test__(%{cleanup: "allways"}) ==
               {:error, {:worktree_cleanup_invalid, "allways"}}
    end
  end

  describe "commit_phase_worktree/4" do
    test "commits what the phase produced, on a checkout with no git identity", %{
      repo: repo,
      base: base
    } do
      wt = Path.join(repo, ".worktrees/workspace")
      branch = "foreman/run-commit"
      assert {:ok, _} = Default.create_worktree(repo, wt, worktree_opts(repo, base, branch))

      # No user.email/user.name in this worktree's own config: Foreman supplies
      # its identity with `-c` overrides, so the commit cannot fail on a
      # checkout the operator never configured.
      git!(wt, ["config", "--unset-all", "user.email"])
      git!(wt, ["config", "--unset-all", "user.name"])

      write!(wt, "docs/PRD/PRD.md")

      assert RunExecutor.__commit_phase_worktree_for_test__(
               %{run_id: "run-commit"},
               %{},
               %{worktree_path: wt}
             ) == {:ok, :committed}

      assert resolve!(repo, branch) != base, "the commit must land on the run's branch"

      Default.clean_worktree(wt, worktree_opts(repo, base, branch))
    end

    # A phantom empty commit would make AutoPR propose a PR for a run that
    # produced nothing.
    test "a clean tree produces no commit", %{repo: repo, base: base} do
      wt = Path.join(repo, ".worktrees/workspace")
      branch = "foreman/run-clean"
      assert {:ok, _} = Default.create_worktree(repo, wt, worktree_opts(repo, base, branch))

      assert RunExecutor.__commit_phase_worktree_for_test__(
               %{run_id: "run-clean"},
               %{},
               %{worktree_path: wt}
             ) == {:ok, :nothing_to_commit}

      assert resolve!(repo, branch) == base, "no commit may be created for a clean tree"

      Default.clean_worktree(wt, worktree_opts(repo, base, branch))
    end

    # An untracked, never-added file is the normal shape of agent output. The
    # first implementation decided emptiness from `git commit`'s exit code,
    # where a clean tree and a real failure both exit 1.
    test "an untracked-only file counts as work", %{repo: repo, base: base} do
      wt = Path.join(repo, ".worktrees/workspace")
      branch = "foreman/run-untracked"
      assert {:ok, _} = Default.create_worktree(repo, wt, worktree_opts(repo, base, branch))

      write!(wt, "docs/TRD/TRD.md")

      assert RunExecutor.__commit_phase_worktree_for_test__(
               %{run_id: "run-untracked"},
               %{},
               %{worktree_path: wt}
             ) == {:ok, :committed}

      Default.clean_worktree(wt, worktree_opts(repo, base, branch))
    end

    # A git failure must never report as success: the phase's work would be
    # uncommitted and AutoPR would silently have nothing to propose.
    test "a directory git cannot read is an error, not a skip" do
      gone = Path.join(System.tmp_dir!(), "gone-#{System.unique_integer([:positive])}")

      assert {:error, {:phase_commit_status_failed, ^gone, _}} =
               RunExecutor.__commit_phase_worktree_for_test__(
                 %{run_id: "run-broken"},
                 %{},
                 %{worktree_path: gone}
               )
    end

    # `commit:` is INERT when the workflow declares `worktree: enabled: false`.
    # There is no checkout to commit in, so both values must reach the same
    # no-op — and neither may error. An implementation that consulted
    # `phase_commits?/1` before checking for a worktree would either raise or
    # report a deferral for a workflow that never had a worktree to defer in,
    # making a meaningless declaration look consequential.
    test "a workflow that opted out of worktrees commits nothing" do
      assert RunExecutor.__commit_phase_worktree_for_test__(%{run_id: "r"}, %{}, nil) ==
               {:ok, :no_worktree}
    end

    test "commit: false is inert with no worktree" do
      assert RunExecutor.__commit_phase_worktree_for_test__(
               %{run_id: "r"},
               %{commit: false},
               nil
             ) == {:ok, :no_worktree}
    end

    test "commit: true is inert with no worktree, identically" do
      # The PRD requires the two outcomes be indistinguishable, not merely both
      # non-failing (AC-003-2).
      assert RunExecutor.__commit_phase_worktree_for_test__(
               %{run_id: "r"},
               %{commit: true},
               nil
             ) == {:ok, :no_worktree}
    end

    # `commit: false` defers: the phase's work stays in the worktree so a later
    # phase's commit absorbs it. The observable contract is that nothing is
    # staged and HEAD does not move, while the FILES remain on disk — a
    # deferral that discarded the work, or that committed anyway, would both
    # look like success here without these two assertions.
    test "commit: false leaves the work uncommitted and on disk", %{repo: repo, base: base} do
      wt = Path.join(repo, ".worktrees/workspace")
      branch = "foreman/run-defer"
      assert {:ok, _} = Default.create_worktree(repo, wt, worktree_opts(repo, base, branch))

      write!(wt, "docs/PRD/PRD.md")

      assert RunExecutor.__commit_phase_worktree_for_test__(
               %{run_id: "run-defer"},
               %{commit: false},
               %{worktree_path: wt}
             ) == {:ok, :commit_deferred}

      assert resolve!(repo, branch) == base, "a deferred phase must not move the branch"
      assert File.regular?(Path.join(wt, "docs/PRD/PRD.md")), "the work must survive on disk"

      Default.clean_worktree(wt, worktree_opts(repo, base, branch))
    end

    # The next phase's commit must pick up the deferred work, which is the whole
    # point of batching phases into one commit.
    test "a later commit absorbs the deferred work", %{repo: repo, base: base} do
      wt = Path.join(repo, ".worktrees/workspace")
      branch = "foreman/run-absorb"
      assert {:ok, _} = Default.create_worktree(repo, wt, worktree_opts(repo, base, branch))

      write!(wt, "docs/PRD/deferred.md")

      assert {:ok, :commit_deferred} =
               RunExecutor.__commit_phase_worktree_for_test__(
                 %{run_id: "run-absorb"},
                 %{commit: false},
                 %{worktree_path: wt}
               )

      write!(wt, "docs/TRD/own.md")

      assert {:ok, :committed} =
               RunExecutor.__commit_phase_worktree_for_test__(
                 %{run_id: "run-absorb"},
                 %{commit: true},
                 %{worktree_path: wt}
               )

      tip = resolve!(repo, branch)
      assert tip != base

      {tracked, 0} = System.cmd("git", ["-C", wt, "ls-tree", "-r", "--name-only", tip])
      files = String.split(tracked, "\n", trim: true)

      assert "docs/PRD/deferred.md" in files, "the deferred phase's work must be in the commit"
      assert "docs/TRD/own.md" in files, "the committing phase's own work must be in the commit"

      Default.clean_worktree(wt, worktree_opts(repo, base, branch))
    end

    # Absent is not `false`. Seven bundled workflows declare no `commit:` at
    # all, and they must keep committing — this is the clause that preserves the
    # behavior from when the commit was unconditional.
    test "an absent commit key still commits", %{repo: repo, base: base} do
      wt = Path.join(repo, ".worktrees/workspace")
      branch = "foreman/run-absent"
      assert {:ok, _} = Default.create_worktree(repo, wt, worktree_opts(repo, base, branch))

      write!(wt, "docs/PRD/PRD.md")

      assert RunExecutor.__commit_phase_worktree_for_test__(
               %{run_id: "run-absent"},
               %{},
               %{worktree_path: wt}
             ) == {:ok, :committed}

      assert resolve!(repo, branch) != base

      Default.clean_worktree(wt, worktree_opts(repo, base, branch))
    end

    # A value that bypassed `Interpreter.validate_commit_value!/3` is a
    # programming error, not a condition to coerce: a truthiness test would read
    # the string "false" as "commit", silently doing the opposite of the
    # manifest (AGENTS.md 5.2).
    test "a non-boolean commit value raises rather than being coerced" do
      assert_raise CaseClauseError, fn ->
        RunExecutor.__commit_phase_worktree_for_test__(
          %{run_id: "r"},
          %{commit: "false"},
          %{worktree_path: "/tmp/never-read"}
        )
      end
    end
  end

  describe "one worktree for the whole run" do
    # The property the whole design exists for. Phase 2 does not get a checkout
    # of its own and does not inherit anything through a branch: it opens the
    # same directory phase 1 wrote in, and phase 1's PRD is simply there.
    test "phase 2 runs in phase 1's checkout and discovery sees only its own document",
         %{repo: repo, base: base} do
      wt = Path.join(repo, ".worktrees/workspace")
      branch = "foreman/run-single"
      prd = "docs/PRD/PRD-2026-6a25501b-durable-run-log-store.md"
      trd = "docs/TRD/TRD-2026-6a25501b-durable-run-log-store.md"

      assert {:ok, _} = Default.create_worktree(repo, wt, worktree_opts(repo, base, branch))
      record = %{worktree_path: wt, branch: branch, base_ref: base}

      # --- Phase 1 -----------------------------------------------------------
      # Provisioning phase: base_ref is the run's base.
      assert {:ok, phase1} = RunExecutor.__reuse_run_worktree_for_test__(record, wt)
      assert phase1.base_ref == base

      write!(wt, prd)
      assert PlanContext.discover_document(wt, "docs/PRD", phase1.base_ref) == {:ok, prd}

      assert RunExecutor.__commit_phase_worktree_for_test__(%{run_id: "run-single"}, %{}, record) ==
               {:ok, :committed}

      # --- Phase 2 -----------------------------------------------------------
      # Same directory. No new worktree, no new branch, nothing cleaned up.
      assert {:ok, phase2} = RunExecutor.__reuse_run_worktree_for_test__(record, wt)
      assert phase2.worktree_path == wt
      assert phase2.branch == branch

      assert File.regular?(Path.join(wt, prd)),
             "phase 2 must see phase 1's PRD as an ordinary file in the shared checkout"

      refute phase2.base_ref == base, "base_ref must advance past phase 1's commit"

      write!(wt, trd)

      # The subtlest part, and where a regression would hide: against the
      # refreshed base, `docs/TRD` captures the TRD and the inherited PRD
      # correctly does NOT read as new in phase 2.
      assert PlanContext.discover_document(wt, "docs/TRD", phase2.base_ref) == {:ok, trd}

      assert PlanContext.discover_document(wt, "docs/PRD", phase2.base_ref) ==
               {:error, {:planning_document_absent, "docs/PRD", wt}}

      # The contrast that proves base_ref has to advance: against the RUN's
      # base, phase 1's inherited PRD reads as a document phase 2 produced.
      assert PlanContext.discover_document(wt, "docs/PRD", base) == {:ok, prd}

      assert RunExecutor.__commit_phase_worktree_for_test__(%{run_id: "run-single"}, %{}, record) ==
               {:ok, :committed}

      # --- Whole run ---------------------------------------------------------
      # One branch carries the entire pipeline, which is what AutoPR proposes.
      assert File.regular?(Path.join(wt, prd))
      assert File.regular?(Path.join(wt, trd))

      tracked = git!(repo, ["ls-tree", "-r", "--name-only", branch])
      assert String.contains?(tracked, prd)
      assert String.contains?(tracked, trd)

      # And exactly one worktree was ever created for the run.
      worktrees = git!(repo, ["worktree", "list", "--porcelain"])
      assert length(Regex.scan(~r/^worktree /m, worktrees)) == 2,
             "the main checkout plus exactly one run worktree"

      Default.clean_worktree(wt, worktree_opts(repo, base, branch))
    end
  end

  # REQ-004: deferred work is ABSORBED by the next committing phase, which is
  # the whole point of the tag — several phases batch into one commit.
  #
  # Shaped like the bundled `prd` workflow, because that is the motivating case:
  # create-prd, refine-prd and create-trd produce planning documents that belong
  # together in review, and implement-trd produces code that does not. Four
  # phases, three deferring, driving the PRODUCTION commit path against a real
  # git repository.
  describe "deferral absorption across a prd-shaped run" do
    test "three deferring phases land on ONE commit, distinct from the fourth", %{
      repo: repo,
      base: base
    } do
      wt = Path.join(repo, ".worktrees/workspace")
      branch = "foreman/run-batch"
      assert {:ok, _} = Default.create_worktree(repo, wt, worktree_opts(repo, base, branch))

      state = %{run_id: "run-batch"}
      defer = %{commit: false}
      commit = %{commit: true}

      # create-prd — defers
      write!(wt, "docs/PRD/PRD-2026-aaaa-thing.md")

      assert RunExecutor.__commit_phase_worktree_for_test__(state, defer, %{worktree_path: wt}) ==
               {:ok, :commit_deferred}

      assert resolve!(repo, branch) == base, "a deferring phase must not move the branch"

      # refine-prd — defers, editing the document the previous phase left
      write!(wt, "docs/PRD/PRD-2026-aaaa-thing.md", "refined body")

      assert RunExecutor.__commit_phase_worktree_for_test__(state, defer, %{worktree_path: wt}) ==
               {:ok, :commit_deferred}

      # create-trd — defers
      write!(wt, "docs/TRD/TRD-2026-aaaa-thing.md")

      assert RunExecutor.__commit_phase_worktree_for_test__(state, defer, %{worktree_path: wt}) ==
               {:ok, :commit_deferred}

      assert resolve!(repo, branch) == base,
             "three consecutive deferrals must still leave the branch untouched"

      # implement-trd — commits, absorbing all three deferrals
      assert RunExecutor.__commit_phase_worktree_for_test__(state, commit, %{worktree_path: wt}) ==
               {:ok, :committed}

      documents_commit = resolve!(repo, branch)
      assert documents_commit != base

      # AC-004-1: the planning documents are on EXACTLY ONE commit.
      assert count_commits(repo, base, branch) == 1,
             "three deferrals plus one commit must produce one commit, not three or four"

      files = git!(repo, ["show", "--name-only", "--pretty=format:", documents_commit])
      assert String.contains?(files, "docs/PRD/PRD-2026-aaaa-thing.md")
      assert String.contains?(files, "docs/TRD/TRD-2026-aaaa-thing.md")

      # AC-004-2: a later committing phase's work is a DISTINCT commit — the
      # absorption must end, not swallow everything after it too.
      write!(wt, "lib/thing.ex", "defmodule Thing do end")

      assert RunExecutor.__commit_phase_worktree_for_test__(state, commit, %{worktree_path: wt}) ==
               {:ok, :committed}

      code_commit = resolve!(repo, branch)
      assert code_commit != documents_commit
      assert count_commits(repo, base, branch) == 2

      code_files = git!(repo, ["show", "--name-only", "--pretty=format:", code_commit])
      assert String.contains?(code_files, "lib/thing.ex")

      refute String.contains?(code_files, "docs/PRD/PRD-2026-aaaa-thing.md"),
             "the documents were already committed; they must not appear again"

      Default.clean_worktree(wt, worktree_opts(repo, base, branch))
    end

    # AC-004-3: the bundled manifest is NOT changed by this feature. Every
    # bundled workflow ships every phase committing, so shipped behavior is
    # identical to before the tag existed; deferral is opt-in per manifest.
    test "the bundled prd workflow still commits every phase" do
      path = Path.join(:code.priv_dir(:foreman_server), "defaults/workflows/prd.yaml")

      assert {:ok, workflow} = ForemanServer.Workflow.Interpreter.load!(path)

      for phase <- workflow["phases"] do
        assert Map.get(phase, "commit", true) == true,
               "bundled prd.yaml phase #{phase["name"]} must commit"
      end
    end
  end

  defp count_commits(repo, base, branch) do
    git!(repo, ["rev-list", "--count", "#{base}..#{branch}"])
    |> String.trim()
    |> String.to_integer()
  end

  defp worktree_opts(repo, base, branch) do
    [
      operation_id: "wt-run-#{System.unique_integer([:positive])}",
      repo_path: repo,
      base: base,
      branch: branch,
      project_id: "p",
      run_id: "run-single",
      phase_id: "ph"
    ]
  end

  defp resolve!(repo, ref) do
    {sha, 0} = System.cmd("git", ["-C", repo, "rev-parse", "--verify", ref], stderr_to_stdout: true)
    String.trim(sha)
  end

  defp head!(repo), do: resolve!(repo, "HEAD")

  defp write!(root, relative, body \\ "document body") do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  defp commit!(root, message) do
    git!(root, ["add", "-A"])
    git!(root, ["commit", "--no-gpg-sign", "-m", message, "--quiet"])
  end

  defp git!(root, args) do
    {output, 0} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
    output
  end
end
