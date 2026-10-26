defmodule ForemanServer.Workflow.RunExecutorSourceBranchTest do
  # `adopt --continue --from-source-branch`: a task that names a `source_branch`
  # (`TaskCreated.source_branch`) gets a run cut from the tip of that LOCAL branch of the project's
  # repository instead of the checkout's HEAD, records that branch as the run's PR base, and refuses
  # with a typed reason when the branch is absent, when the workflow has no worktree to cut, or when an
  # ImplementationContext already pins the base. Ordinary tasks are untouched.
  #
  # Real git repositories and the production worktree path, no mocks.
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Workflow.{RunExecutor, RunWorktreeLayout}

  setup do
    ProjectionStoreReset.reset!()

    root = Path.join(System.tmp_dir!(), "source-branch-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    project_id = "proj-sb-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      ProjectionStoreReset.reset!()
      File.rm_rf(root)
      File.rm_rf(Path.join(RunWorktreeLayout.base_root(), project_id))
    end)

    # main: seed -> main-only; feat/source: seed -> source. HEAD is on main, so the checkout's HEAD
    # and the source branch are different commits with different files.
    git!(repo, ["init", "--initial-branch=main", "--quiet"])
    git!(repo, ["config", "user.email", "t@x"])
    git!(repo, ["config", "user.name", "T"])
    commit!(repo, "seed.txt", "seed")
    git!(repo, ["checkout", "-b", "feat/source", "--quiet"])
    commit!(repo, "source.txt", "source")
    git!(repo, ["checkout", "main", "--quiet"])
    commit!(repo, "main-only.txt", "main only")

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectRegistered", payload: %{project_id: project_id, path: repo}}
      ])

    run_id = "run-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    seed_run!(run_id, project_id)

    %{repo: repo, project_id: project_id, run_id: run_id}
  end

  defp state(ctx, task_fields \\ %{}, extra \\ %{}) do
    Map.merge(
      %{
        task: Map.merge(%{project_id: ctx.project_id, task_id: "task-sb"}, task_fields),
        run_id: ctx.run_id,
        worktree_spec: %{},
        plan_context: nil,
        completed: [],
        phase_specs: [],
        artifact_base: Path.join(System.tmp_dir!(), "source-branch-artifacts")
      },
      extra
    )
  end

  describe "the run's worktree" do
    test "a task with a source_branch is cut from that branch, not from the checkout's HEAD",
         ctx do
      assert {:ok, record} =
               ctx
               |> state(%{source_branch: "feat/source"})
               |> RunExecutor.__create_run_worktree_for_test__(1)

      source_tip = git!(ctx.repo, ["rev-parse", "feat/source"])
      main_tip = git!(ctx.repo, ["rev-parse", "main"])
      refute source_tip == main_tip

      assert record.base_ref == source_tip
      assert File.exists?(Path.join(record.worktree_path, "source.txt"))
      refute File.exists?(Path.join(record.worktree_path, "main-only.txt"))

      # The run's own branch descends from the source branch's tip.
      assert {_, 0} =
               System.cmd(
                 "git",
                 ["-C", ctx.repo, "merge-base", "--is-ancestor", source_tip, record.branch],
                 stderr_to_stdout: true
               )
    end

    test "an ordinary task is still cut from the checkout's HEAD (the control)", ctx do
      assert {:ok, record} =
               ctx |> state() |> RunExecutor.__create_run_worktree_for_test__(1)

      assert record.base_ref == git!(ctx.repo, ["rev-parse", "main"])
      assert File.exists?(Path.join(record.worktree_path, "main-only.txt"))
      refute File.exists?(Path.join(record.worktree_path, "source.txt"))
    end

    test "a branch that is not there is a typed failure, never HEAD, and nothing is created",
         ctx do
      state = state(ctx, %{source_branch: "feat/gone"})
      path = RunWorktreeLayout.path(ctx.project_id, "task-sb", ctx.run_id, :primary)

      assert {:error, {:source_branch_not_found, "feat/gone", repo}} =
               RunExecutor.__create_run_worktree_for_test__(state, 1)

      assert repo == ctx.repo
      refute File.exists?(path)
    end

    test "only a LOCAL branch counts: a tag of that name is not the branch", ctx do
      git!(ctx.repo, ["tag", "v1", "feat/source"])

      assert {:error, {:source_branch_not_found, "v1", _repo}} =
               ctx
               |> state(%{source_branch: "v1"})
               |> RunExecutor.__create_run_worktree_for_test__(1)
    end

    test "it is refused beside an ImplementationContext, whose frozen revision is the base",
         ctx do
      plan_context = %{
        "source_revision" => git!(ctx.repo, ["rev-parse", "main"]),
        "project_root" => ctx.repo,
        "implementation_key" => "key"
      }

      assert {:error, {:source_branch_conflicts_with_implementation_context, "feat/source"}} =
               ctx
               |> state(%{source_branch: "feat/source"}, %{plan_context: plan_context})
               |> RunExecutor.__create_run_worktree_for_test__(1)
    end
  end

  describe "a workflow without a worktree" do
    test "cannot be cut from a branch: the phase is refused, naming it", ctx do
      state = state(ctx, %{source_branch: "feat/source"}, %{worktree_spec: %{enabled: false}})

      assert {:error, {:source_branch_needs_worktree, "feat/source"}} =
               RunExecutor.__maybe_create_worktree_for_test__(state, 1)
    end

    test "still runs in the project checkout when the task names no branch", ctx do
      state = state(ctx, %{}, %{worktree_spec: %{enabled: false}})
      assert {:ok, nil} = RunExecutor.__maybe_create_worktree_for_test__(state, 1)
    end
  end

  describe "the run's PR base branch" do
    test "is the source branch, whatever branch the checkout is on", ctx do
      git!(ctx.repo, ["checkout", "-b", "operator/side-quest", "--quiet"])

      from_source =
        ctx
        |> state(%{source_branch: "feat/source"}, %{plan_context: %{"project_root" => ctx.repo}})
        |> RunExecutor.__remember_run_base_branch_for_test__()

      assert RunExecutor.__run_base_branch_for_test__(from_source) == {:ok, "feat/source"}

      # The control: no source branch, so the checkout's branch, as always.
      ordinary =
        ctx
        |> state(%{}, %{plan_context: %{"project_root" => ctx.repo}})
        |> Map.put(:run_id, "run-sb-ordinary")
        |> RunExecutor.__remember_run_base_branch_for_test__()

      assert RunExecutor.__run_base_branch_for_test__(ordinary) == {:ok, "operator/side-quest"}
    end

    test "is persisted, so a resumed executor reads it back", ctx do
      state =
        ctx
        |> state(%{source_branch: "feat/source"}, %{plan_context: %{"project_root" => ctx.repo}})

      _first_attempt = RunExecutor.__remember_run_base_branch_for_test__(state)
      assert %{base_branch: "feat/source"} = ProjectionStore.run(ctx.run_id)

      # A fresh executor on a task that lost the field still recovers the persisted base.
      resumed =
        ctx
        |> state(%{}, %{plan_context: %{"project_root" => ctx.repo}})
        |> RunExecutor.__remember_run_base_branch_for_test__()

      assert RunExecutor.__run_base_branch_for_test__(resumed) == {:ok, "feat/source"}
    end
  end

  # -- helpers -----------------------------------------------------------

  defp seed_run!(run_id, project_id) do
    payload = %{run_id: run_id, project_id: project_id}

    :ok =
      ForemanServer.EventStore.append_to_stream("run:#{run_id}", 0, [
        %EventStore.EventData{event_type: "RunStarted", data: payload, metadata: %{}}
      ])

    :ok = ProjectionStore.apply_events([%{event_type: "RunStarted", payload: payload}])
  end

  defp commit!(repo, file, content) do
    File.write!(Path.join(repo, file), content)
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--no-gpg-sign", "-m", content, "--quiet"])
  end

  defp git!(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, code} -> flunk("git #{Enum.join(args, " ")} failed (#{code}) in #{dir}: #{out}")
    end
  end
end
