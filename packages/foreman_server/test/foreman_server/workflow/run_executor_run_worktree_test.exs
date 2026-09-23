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

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.VcsAdapter.Default
  alias ForemanServer.Workflow.PlanContext
  alias ForemanServer.Workflow.RunExecutor

  setup do
    # Other test files inject fixture projects directly into ProjectionStore's
    # shared singleton state via `:sys.replace_state` (e.g.
    # implementation_context_test.exs's `state.projects["proj-1"]`) without
    # resetting it afterward. Reset defensively so tests here that assert a
    # project id is UNREGISTERED (e.g. "proj-1" -> :project_not_found) can't
    # inherit a leftover registration from an earlier file under full-suite
    # load (AGENTS.md "Elixir Test Suite Non-Determinism").
    ProjectionStoreReset.reset!()

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

  describe "worktree_task_id/1" do
    test "prefers external_id over task_id when both are present" do
      assert RunExecutor.__worktree_task_id_for_test__(
               %{external_id: "ext-1", task_id: "task-1"},
               "run-1"
             ) == "ext-1"
    end

    # CodeRabbit finding on PR #484: an empty string is truthy in Elixir, so
    # `Map.get(..., :external_id) || Map.get(..., :task_id) || ...` used to
    # short-circuit on `external_id: ""` and never try task_id at all,
    # falling straight to run_id even though a valid task_id existed. This
    # is the same truthiness class as AGENTS.md 5.4b's `dependencies: false`
    # bug.
    test "an empty external_id does not block falling through to a valid task_id" do
      assert RunExecutor.__worktree_task_id_for_test__(
               %{external_id: "", task_id: "task-1"},
               "run-1"
             ) == "task-1"
    end

    test "falls through empty external_id and task_id to work_id" do
      assert RunExecutor.__worktree_task_id_for_test__(
               %{external_id: "", task_id: "", work_id: "work-1"},
               "run-1"
             ) == "work-1"
    end

    test "falls back to run_id only when no candidate is a non-empty binary" do
      assert RunExecutor.__worktree_task_id_for_test__(
               %{external_id: "", task_id: nil, work_id: "", id: nil},
               "run-1"
             ) == "run-1"

      assert RunExecutor.__worktree_task_id_for_test__(%{}, "run-1") == "run-1"
    end

    # CodeRabbit review on PR #484: worktree_task_id/1 and provider_task_id/1
    # used to run independent atom/string lookups, so a task carrying both
    # forms of a field with different values (e.g. a decode artifact) could
    # give the worktree and the provider a different notion of the task's
    # identity for the same run. Both now share task_identity/1.
    test "worktree_task_id and provider_task_id agree on identity even with mixed keys" do
      task = %{"external_id" => "ext-1", external_id: "", task_id: "task-1"}

      assert RunExecutor.__worktree_task_id_for_test__(task, "run-1") == "ext-1"
      assert RunExecutor.__provider_task_id_for_test__(task, "run-1") == "ext-1"
    end

    # CodeRabbit review on PR #484: Enum.find/2 over the raw candidates
    # discarded a non-binary value (e.g. `external_id: 123`) the same way it
    # discarded a genuinely absent one, silently falling through to run_id
    # and provisioning a plausible-looking worktree for corrupt data instead
    # of failing loudly (AGENTS.md 5.2).
    test "a non-binary candidate is rejected instead of silently falling through" do
      assert_raise ArgumentError, ~r/task\.external_id/, fn ->
        RunExecutor.__worktree_task_id_for_test__(%{external_id: 123}, "run-1")
      end
    end

    test "provider_task_id falls back to task_id, not run_id, when no external_id exists" do
      assert RunExecutor.__provider_task_id_for_test__(%{task_id: "task-1"}, "run-1") ==
               "task-1"
    end
  end

  describe "fetch_project_id/1" do
    test "nil and empty project_id are both project_id_missing" do
      assert RunExecutor.__fetch_project_id_for_test__(%{project_id: nil}) ==
               {:error, :project_id_missing}

      assert RunExecutor.__fetch_project_id_for_test__(%{project_id: ""}) ==
               {:error, :project_id_missing}
    end

    test "a non-empty binary project_id is accepted" do
      assert RunExecutor.__fetch_project_id_for_test__(%{project_id: "proj-1"}) ==
               {:ok, "proj-1"}
    end

    # A malformed projection (e.g. `project_id: %{}`) must not reach
    # `Path.join/1` in `run_worktree_path/3`, which raises rather than
    # returning an error for a non-binary path segment.
    test "a non-binary project_id is rejected as malformed, not accepted" do
      assert RunExecutor.__fetch_project_id_for_test__(%{project_id: %{}}) ==
               {:error, {:project_id_malformed, %{}}}

      assert RunExecutor.__fetch_project_id_for_test__(%{project_id: :proj}) ==
               {:error, {:project_id_malformed, :proj}}
    end
  end

  describe "assert_safe_path_identifier/1 (via __assert_safe_path_identifier_for_test__)" do
    test "a safe slug identifier is accepted" do
      assert RunExecutor.__assert_safe_path_identifier_for_test__("my-task_123") == :ok
    end

    test "an empty identifier is rejected" do
      assert RunExecutor.__assert_safe_path_identifier_for_test__("") ==
               {:error, {:unsafe_path_identifier, "", "empty identifier"}}
    end

    test "traversal segments are rejected" do
      assert RunExecutor.__assert_safe_path_identifier_for_test__(".") ==
               {:error, {:unsafe_path_identifier, ".", "traversal segment"}}

      assert RunExecutor.__assert_safe_path_identifier_for_test__("..") ==
               {:error, {:unsafe_path_identifier, "..", "traversal segment"}}
    end

    test "path separators are rejected" do
      assert RunExecutor.__assert_safe_path_identifier_for_test__("foo/bar") ==
               {:error, {:unsafe_path_identifier, "foo/bar", "contains path separator"}}

      assert RunExecutor.__assert_safe_path_identifier_for_test__("foo\\bar") ==
               {:error, {:unsafe_path_identifier, "foo\\bar", "contains path separator"}}
    end

    test "control characters are rejected, not just the null byte" do
      assert RunExecutor.__assert_safe_path_identifier_for_test__("foo\0bar") ==
               {:error, {:unsafe_path_identifier, "foo\0bar", "contains control character"}}

      assert RunExecutor.__assert_safe_path_identifier_for_test__("foo\nbar") ==
               {:error, {:unsafe_path_identifier, "foo\nbar", "contains control character"}}

      assert RunExecutor.__assert_safe_path_identifier_for_test__("foo\tbar") ==
               {:error, {:unsafe_path_identifier, "foo\tbar", "contains control character"}}

      assert RunExecutor.__assert_safe_path_identifier_for_test__("foo\rbar") ==
               {:error, {:unsafe_path_identifier, "foo\rbar", "contains control character"}}

      assert RunExecutor.__assert_safe_path_identifier_for_test__("foo\x7Fbar") ==
               {:error, {:unsafe_path_identifier, "foo\x7Fbar", "contains control character"}}

      assert RunExecutor.__assert_safe_path_identifier_for_test__("foo\x80bar") ==
               {:error, {:unsafe_path_identifier, "foo\x80bar", "contains control character"}}
    end

    # A traversal segment embedded inside a longer identifier (e.g.
    # "../etc/passwd") is caught by the path-separator check above, not the
    # exact-match traversal check, since it necessarily contains "/".
    test "a traversal segment embedded in a longer identifier is rejected via the separator check" do
      assert RunExecutor.__assert_safe_path_identifier_for_test__("../etc/passwd") ==
               {:error, {:unsafe_path_identifier, "../etc/passwd", "contains path separator"}}
    end
  end

  # CodeRabbit flagged that create_run_worktree/2 validated project_id and
  # the task segment but not state.run_id itself. In production, run_id is
  # always Identity.run_id/2's deterministic sha256 hex output ("run-" <>
  # 32 lowercase hex chars) EXCEPT one path: ForemanServer.Aggregates.WorkRequest
  # accepts `cmd.run_id` verbatim when present, bypassing the safe derivation
  # entirely (`run_id = cmd.run_id || Identity.run_id(cmd.work_id, submission_id)`).
  # A traversal-bearing run_id from that path would otherwise reach
  # Path.join/1 in run_worktree_path/3 unvalidated.
  describe "create_run_worktree/2 validates state.run_id" do
    test "a traversal-bearing run_id is rejected before filesystem path construction" do
      state = %{
        task: %{project_id: "proj-1", task_id: "task-1"},
        run_id: "../../../outside",
        worktree_spec: %{}
      }

      assert RunExecutor.__create_run_worktree_for_test__(state, 1) ==
               {:error, {:unsafe_path_identifier, "../../../outside", "contains path separator"}}
    end

    test "a well-formed run_id is not rejected by the identifier guard" do
      state = %{
        task: %{project_id: "proj-1", task_id: "task-1"},
        run_id: "run-" <> String.duplicate("a", 32),
        worktree_spec: %{},
        plan_context: nil
      }

      # Passes the run_id guard and proceeds to resolve_run_base/2, which
      # fails on this minimal fixture for an unrelated reason (no registered
      # project on disk) — proving the guard itself let a safe run_id
      # through rather than rejecting on identifier shape.
      assert RunExecutor.__create_run_worktree_for_test__(state, 1) ==
               {:error, :project_not_found}
    end

    # CodeRabbit review on PR #484: assert_safe_path_identifier/1 accepted
    # "", and WorkRequest accepts `cmd.run_id` verbatim
    # (`cmd.run_id || Identity.run_id(...)`) — an empty string is truthy in
    # Elixir, so an empty run_id bypassed safe generation entirely, colliding
    # every such run on the same "wt-" operation id and dropping the run
    # component from the worktree path.
    test "an empty run_id is rejected before filesystem path construction" do
      state = %{
        task: %{project_id: "proj-1", task_id: "task-1"},
        run_id: "",
        worktree_spec: %{}
      }

      assert RunExecutor.__create_run_worktree_for_test__(state, 1) ==
               {:error, {:unsafe_path_identifier, "", "empty identifier"}}
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

  # An operator's `run.pause`/`run.cancel` reaches this blocked, synchronous
  # phase loop only through `RunControl.intent/1` — the dispatcher cancels the
  # in-flight agent, which unblocks `execute_agent/4` with an error, and this
  # is where that error is folded into a stop instead of a PhaseFailed. Real
  # git, no mocks: pause must leave the killed agent's partial work committed
  # on the run branch; cancel must leave the tree exactly as the agent left it.
  describe "handle_phase_body_error/6 honours RunControl.intent/1" do
    setup %{repo: repo, base: base} do
      run_id = "run-pause-#{System.unique_integer([:positive])}"
      wt = Path.join(repo, ".worktrees/workspace")
      branch = "foreman/#{run_id}"

      assert {:ok, _} = Default.create_worktree(repo, wt, worktree_opts(repo, base, branch))
      record = %{worktree_path: wt, branch: branch, base_ref: base}

      on_exit(fn -> ForemanServer.RunControl.clear(run_id) end)

      %{run_id: run_id, record: record, wt: wt, branch: branch}
    end

    test "pause commits the phase's partial work and stops without a phase failure",
         %{repo: repo, base: base, run_id: run_id, record: record, wt: wt, branch: branch} do
      write!(wt, "docs/PRD/partial.md")

      :ok = ForemanServer.RunControl.request(run_id, :pause)

      assert {:stopped, %{status: :paused}} =
               RunExecutor.__handle_phase_body_error_for_test__(
                 %{run_id: run_id, task: %{task_id: run_id}, status: :in_progress},
                 %{},
                 1,
                 record,
                 :worker_died_no_result
               )

      assert count_commits(repo, base, branch) == 1,
             "the killed phase's partial work must land on the run branch"

      tracked = git!(repo, ["ls-tree", "-r", "--name-only", branch])
      assert String.contains?(tracked, "docs/PRD/partial.md")
    end

    test "cancel stops without committing whatever the phase left behind",
         %{repo: repo, base: base, run_id: run_id, record: record, wt: wt, branch: branch} do
      write!(wt, "docs/PRD/orphaned.md")

      :ok = ForemanServer.RunControl.request(run_id, :cancel)

      assert {:stopped, %{status: :cancelled}} =
               RunExecutor.__handle_phase_body_error_for_test__(
                 %{run_id: run_id, task: %{task_id: run_id}, status: :in_progress},
                 %{},
                 1,
                 record,
                 :worker_died_no_result
               )

      assert count_commits(repo, base, branch) == 0,
             "cancel must not commit the cancelled phase's partial work"
    end
  end

  # The gap `handle_phase_body_error/6` alone cannot close: a pause/cancel
  # requested while the executor sits BETWEEN phases (no agent running, so
  # `RunControl.cancel_agent/1` has nothing to interrupt) must still stop the
  # run before the next phase starts — not silently run that phase to
  # completion while the intent sits unconsumed in the ETS table.
  describe "run_single_phase/3 honours RunControl.intent/1 before a phase starts" do
    setup do
      run_id = "run-between-#{System.unique_integer([:positive])}"
      on_exit(fn -> ForemanServer.RunControl.clear(run_id) end)
      %{run_id: run_id}
    end

    test "pause stops before the next phase creates a worktree or commits anything",
         %{repo: repo, run_id: run_id} do
      :ok = ForemanServer.RunControl.request(run_id, :pause)

      state = %{
        run_id: run_id,
        plan_context: %{"project_root" => repo},
        task: %{task_id: run_id},
        status: :in_progress
      }

      assert {:stopped, %{status: :paused}} =
               RunExecutor.__run_single_phase_for_test__(
                 state,
                 %{"command" => "/skill:never-runs"},
                 0
               )

      worktrees = git!(repo, ["worktree", "list", "--porcelain"])

      assert length(Regex.scan(~r/^worktree /m, worktrees)) == 1,
             "no run worktree should have been created for a phase that never started"
    end

    test "cancel stops before the next phase creates a worktree or commits anything",
         %{repo: repo, run_id: run_id} do
      :ok = ForemanServer.RunControl.request(run_id, :cancel)

      state = %{
        run_id: run_id,
        plan_context: %{"project_root" => repo},
        task: %{task_id: run_id},
        status: :in_progress
      }

      assert {:stopped, %{status: :cancelled}} =
               RunExecutor.__run_single_phase_for_test__(
                 state,
                 %{"command" => "/skill:never-runs"},
                 0
               )

      worktrees = git!(repo, ["worktree", "list", "--porcelain"])

      assert length(Regex.scan(~r/^worktree /m, worktrees)) == 1,
             "no run worktree should have been created for a phase that never started"
    end
  end

  # The gap `run_single_phase/3`'s check alone cannot close: when the LAST
  # phase completes, `handle_cast({:advance_to, ...})` finalizes the run
  # (`finalize_run/1`) DIRECTLY, without ever routing through
  # `start_phase_at_index/2`/`run_single_phase/3`. A pause/cancel racing that
  # last phase's completion must still stop the run before it finalizes —
  # not let `maybe_complete_task`, AutoPR, and `RunCompleted` fire anyway.
  describe "handle_cast({:advance_to, ...}) honours RunControl.intent/1 before finalizing" do
    setup do
      run_id = "run-finalize-race-#{System.unique_integer([:positive])}"
      on_exit(fn -> ForemanServer.RunControl.clear(run_id) end)
      %{run_id: run_id}
    end

    test "pause stops before the run finalizes", %{run_id: run_id} do
      :ok = ForemanServer.RunControl.request(run_id, :pause)

      state = %{run_id: run_id, task: %{task_id: run_id}, status: :in_progress}

      assert {:stop, :normal, %{status: :paused}} =
               RunExecutor.__handle_cast_advance_to_for_test__(state, 0)
    end

    test "cancel stops before the run finalizes", %{run_id: run_id} do
      :ok = ForemanServer.RunControl.request(run_id, :cancel)

      state = %{run_id: run_id, task: %{task_id: run_id}, status: :in_progress}

      assert {:stop, :normal, %{status: :cancelled}} =
               RunExecutor.__handle_cast_advance_to_for_test__(state, 0)
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
    {sha, 0} =
      System.cmd("git", ["-C", repo, "rev-parse", "--verify", ref], stderr_to_stdout: true)

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

  # `find_resumable_worktree/1` must match the `operation_id` shape the
  # production create path actually emits (`create_run_worktree/2`:
  # `operation_id = "wt-" <> state.run_id`, no phase suffix — the
  # `WorktreeCreated` moduledoc previously described a stale per-phase
  # shape from before the one-worktree-per-run refactor). Seed a
  # `WorktreeCreated` event through the real `ProjectionStore` with that
  # exact shape rather than hand-picking a string that happens to satisfy
  # the lookup, so this proves the two sides actually agree.
  describe "find_resumable_worktree/1" do
    test "finds the run's worktree entry by its real operation_id shape" do
      run_id = "run-rehydrate-#{System.unique_integer([:positive])}"

      created = %{
        event_type: "WorktreeCreated",
        payload: %{
          operation_id: "wt-" <> run_id,
          project_id: "project-rehydrate-test",
          run_id: run_id,
          phase_id: "#{run_id}-phase-1",
          repo_path: "/tmp/repo",
          worktree_path: "/tmp/repo-wt",
          branch: "foreman/#{run_id}",
          base_ref: "abc123",
          cleanup: "never"
        }
      }

      ProjectionStore.apply_events([created])

      assert %{operation_id: "wt-" <> ^run_id, worktree_path: "/tmp/repo-wt"} =
               RunExecutor.__find_resumable_worktree_for_test__(run_id)
    end

    test "returns nil when the run has no worktree entry" do
      run_id = "run-rehydrate-missing-#{System.unique_integer([:positive])}"
      assert RunExecutor.__find_resumable_worktree_for_test__(run_id) == nil
    end
  end

  # `rehydrate_resume_context/1` is `handle_kickoff_ready/1`'s first step on
  # a resuming executor (`resuming?: true`) — it is what makes
  # `ensure_run_worktree/2` take the REUSE path instead of `git worktree
  # add`ing a path that already exists on disk (which would fail outright).
  # Real git worktree, real `ProjectionStore` seeding, no mocks: this is
  # the actual on-disk state a resumed run's executor rehydrates from.
  describe "rehydrate_resume_context/1 (resume worktree reuse)" do
    test "a resuming executor rehydrates run_worktree from the persisted entry, not a fresh create",
         %{repo: repo, base: base} do
      run_id = "run-resume-rehydrate-#{System.unique_integer([:positive])}"
      wt = Path.join(repo, ".worktrees/workspace")
      branch = "foreman/#{run_id}"

      assert {:ok, _} = Default.create_worktree(repo, wt, worktree_opts(repo, base, branch))

      created = %{
        event_type: "WorktreeCreated",
        payload: %{
          operation_id: "wt-" <> run_id,
          project_id: "project-resume-test",
          run_id: run_id,
          phase_id: "#{run_id}-phase-1",
          repo_path: repo,
          worktree_path: wt,
          branch: branch,
          base_ref: base,
          cleanup: "never"
        }
      }

      ProjectionStore.apply_events([created])

      state = %{
        run_id: run_id,
        resuming?: true,
        worktree_spec: %{},
        plan_context: %{
          "source_revision" => base,
          "project_root" => repo,
          "implementation_key" => "test-key"
        }
      }

      assert {:ok, resumed_state} = RunExecutor.__rehydrate_resume_context_for_test__(state)

      assert %{
               operation_id: "wt-" <> ^run_id,
               worktree_path: ^wt,
               branch: ^branch,
               project_root: ^repo
             } = resumed_state.run_worktree

      # The rehydrated path is the SAME on-disk worktree `create_worktree/3`
      # made above, still checked out — proof this took the reuse path
      # rather than discarding the entry and re-provisioning.
      assert File.dir?(wt)

      Default.clean_worktree(wt, worktree_opts(repo, base, branch))
    end

    test "a non-resuming executor is a no-op (fresh runs never rehydrate)" do
      state = %{run_id: "run-not-resuming", resuming?: false}

      assert RunExecutor.__rehydrate_resume_context_for_test__(state) == {:ok, state}
    end
  end

  # `init/1` is the `resume_from`/`resuming?`/`completed` derivation this
  # advisory flagged as having zero test hits: a `resume_from:` opt must
  # pre-populate `completed` with every phase index before it (so
  # `handle_cast({:advance_to, ...})` never re-marks them) and set
  # `resuming?: true` (so `rehydrate_resume_context/1` and the
  # claim-skip in `handle_kickoff_ready/1` both activate). A fresh run
  # (no `resume_from:` opt) must get neither.
  describe "init/1 (resume state derivation)" do
    test "a fresh run (no resume_from opt) starts un-resumed with nothing completed" do
      assert {:ok, state} = RunExecutor.init({"run-fresh", %{task_id: "run-fresh"}, []})
      assert state.resume_from == 0
      assert state.resuming? == false
      assert state.completed == []
    end

    test "resume_from: 0 (explicitly passed) IS treated as resuming, unlike the absent-opt fresh-run default" do
      assert {:ok, state} =
               RunExecutor.init(
                 {"run-resume-zero", %{task_id: "run-resume-zero"}, resume_from: 0}
               )

      assert state.resume_from == 0
      assert state.resuming? == true
      assert state.completed == []
    end

    test "resume_from: N pre-populates completed with every index before N and marks resuming" do
      assert {:ok, state} =
               RunExecutor.init({"run-resume-two", %{task_id: "run-resume-two"}, resume_from: 2})

      assert state.resume_from == 2
      assert state.resuming? == true
      assert state.completed == [0, 1]
    end
  end

  defp git!(root, args) do
    {output, 0} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
    output
  end
end
