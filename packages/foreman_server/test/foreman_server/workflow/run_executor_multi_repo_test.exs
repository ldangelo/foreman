defmodule ForemanServer.Workflow.RunExecutorMultiRepoTest do
  @moduledoc """
  One worktree per repository per run (E12-S3): repo-set resolution and its
  run-start gate, per-repo layout/base, eager provisioning with rollback,
  resume rehydration, per-repo commit and continue-on-error cleanup.

  Real git repositories and the production worktree path (`Worktree.create/1`
  -> CommandGateway -> event store). Run worktrees live under the real
  `~/.foreman/worktrees/<project>`; each test uses a unique project id and removes
  that directory on exit.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.{MultiRepoRuns, ProjectionStore}
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Workflow.RunExecutor

  setup_all do
    template =
      Path.join(System.tmp_dir!(), "multi-repo-tpl-#{System.unique_integer([:positive])}")

    File.mkdir_p!(template)
    on_exit(fn -> File.rm_rf(template) end)
    for id <- ~w(a b c), do: seed_repo!(template, id)
    %{template: template}
  end

  setup %{template: template} do
    ProjectionStoreReset.reset!()

    root = Path.join(System.tmp_dir!(), "multi-repo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    project_id = "proj-mr-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      ProjectionStoreReset.reset!()
      File.rm_rf(root)
      File.rm_rf(Path.join(ForemanServer.Workflow.RunWorktreeLayout.base_root(), project_id))
    end)

    repos = for id <- ~w(a b c), into: %{}, do: {id, init_repo!(template, root, id)}

    register_project!(project_id, repos["a"])
    add_repo!(project_id, "b", repos["b"])
    add_repo!(project_id, "c", repos["c"])

    run_id = "run-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    seed_run!(run_id, project_id)

    %{root: root, project_id: project_id, repos: repos, run_id: run_id}
  end

  defp state(ctx, task_fields \\ %{}, extra \\ %{}) do
    Map.merge(
      %{
        task: Map.merge(%{project_id: ctx.project_id, task_id: "task-1"}, task_fields),
        run_id: ctx.run_id,
        worktree_spec: %{},
        plan_context: nil,
        artifact_base: Path.join(System.tmp_dir!(), "multi-repo-artifacts")
      },
      extra
    )
  end

  defp resolved!(ctx, task_fields) do
    MultiRepoRuns.enable!()

    assert {:ok, state} =
             ctx |> state(task_fields) |> RunExecutor.__resolve_run_repo_set_for_test__()

    state
  end

  describe "run repository set resolution" do
    test "a run naming no repository is the untouched single-repo run", ctx do
      state = state(ctx)
      assert {:ok, ^state} = RunExecutor.__resolve_run_repo_set_for_test__(state)
      refute Map.has_key?(state, :run_repos)
    end

    test "multi-repo runs are refused while the gate is closed", ctx do
      MultiRepoRuns.disable!()

      assert {:error, :multi_repo_runs_disabled} =
               ctx
               |> state(%{repo_ids: ["b"]})
               |> RunExecutor.__resolve_run_repo_set_for_test__()
    end

    test "a run primary that is not the project primary is multi-repo too (follow-up 6)", ctx do
      MultiRepoRuns.disable!()

      assert {:error, :multi_repo_runs_disabled} =
               ctx
               |> state(%{repo_id: "b"})
               |> RunExecutor.__resolve_run_repo_set_for_test__()
    end

    test "naming the project primary explicitly is still a single-repo run", ctx do
      assert {:ok, %{run_repos: %{extras: []}}} =
               ctx
               |> state(%{repo_id: "main"})
               |> RunExecutor.__resolve_run_repo_set_for_test__()
    end

    test "with the gate open the resolved set carries primary and extras in request order", ctx do
      state = resolved!(ctx, %{repo_ids: ["c", "b"]})

      assert %{primary: %{id: "main"}, extras: [%{id: "c"}, %{id: "b"}]} = state.run_repos
    end

    test "a run primary other than the project primary is selected by repo_id", ctx do
      state = resolved!(ctx, %{repo_id: "b", repo_ids: ["main"]})

      assert %{primary: %{id: "b"}, extras: [%{id: "main"}]} = state.run_repos
    end

    test "repo_ids are validated before anything is counted or provisioned", ctx do
      MultiRepoRuns.enable!()
      resolve = &RunExecutor.__resolve_run_repo_set_for_test__(state(ctx, &1))

      assert {:error, {:duplicate_repo_ids, ["b"]}} = resolve.(%{repo_ids: ["b", "b"]})
      assert {:error, {:repo_id_is_primary, "main"}} = resolve.(%{repo_ids: ["main"]})
      assert {:error, {:repo_id_is_primary, "b"}} = resolve.(%{repo_id: "b", repo_ids: ["b"]})
      assert {:error, {:unknown_repo, "zzz"}} = resolve.(%{repo_ids: ["zzz"]})
      assert {:error, {:unknown_repo, "zzz"}} = resolve.(%{repo_id: "zzz"})
      assert {:error, {:invalid_repo_ids, "b"}} = resolve.(%{repo_ids: "b"})

      # Primary-equality is reported even when the list would also exceed the cap.
      assert {:error, {:repo_id_is_primary, "main"}} =
               resolve.(%{repo_ids: ["main", "b", "c", "d", "e"]})
    end

    test "the cap counts the primary plus the extras (default 4)", ctx do
      MultiRepoRuns.enable!()
      for id <- ~w(d e), do: add_repo!(ctx.project_id, id, ctx.repos["a"] <> "-#{id}")
      resolve = &RunExecutor.__resolve_run_repo_set_for_test__(state(ctx, &1))

      # primary + 3 extras = 4: allowed.
      assert {:ok, _} = resolve.(%{repo_ids: ~w(b c d)})
      # primary + 4 extras = 5: refused, although only 4 extras were named.
      assert {:error, {:max_repos_exceeded, 4}} = resolve.(%{repo_ids: ~w(b c d e)})
    end

    test "the cap honours the project's max_repos_per_run", ctx do
      MultiRepoRuns.enable!()
      settings = struct(ForemanServer.ProjectSettings, max_repos_per_run: 2)

      assert {:error, {:max_repos_exceeded, 2}} =
               ctx
               |> state(%{repo_ids: ["b", "c"]}, %{project_settings: settings})
               |> RunExecutor.__resolve_run_repo_set_for_test__()
    end
  end

  describe "repo_root/2" do
    test "nil is the primary and a registered id is that repository's checkout", ctx do
      state = state(ctx)

      assert RunExecutor.repo_root(state, nil) == {:ok, ctx.repos["a"]}
      assert RunExecutor.repo_root(state, "main") == {:ok, ctx.repos["a"]}
      assert RunExecutor.repo_root(state, "b") == {:ok, ctx.repos["b"]}
    end

    test "an id that is not a repository of the run's project is refused", ctx do
      assert RunExecutor.repo_root(state(ctx), "zzz") == {:error, {:unknown_repo, "zzz"}}
      assert RunExecutor.repo_root(state(ctx), 7) == {:error, {:unknown_repo, 7}}
    end

    test "a run whose primary is repository b answers b for nil", ctx do
      state = resolved!(ctx, %{repo_id: "b"})

      assert RunExecutor.repo_root(state, nil) == {:ok, ctx.repos["b"]}
    end
  end

  describe "eager provisioning" do
    test "creates the primary and every extra repo, each on the run branch", ctx do
      state = resolved!(ctx, %{repo_ids: ["b", "c"]})

      assert {:ok, primary} = RunExecutor.__create_run_worktree_for_test__(state, 1)

      run_dir =
        ForemanServer.Workflow.RunWorktreeLayout.run_root(ctx.project_id, "task-1", ctx.run_id)

      assert primary.worktree_path == Path.join(run_dir, "workspace")
      assert primary.operation_id == "wt-" <> ctx.run_id
      assert primary.branch == "foreman/task-1/#{ctx.run_id}"

      by_repo =
        ctx.run_id
        |> ProjectionStore.worktrees_for_run()
        |> Map.new(&{&1.repo_id, &1})

      assert %{nil => main, "b" => b, "c" => c} = by_repo
      assert main.primary? and not b.primary? and not c.primary?
      assert b.worktree_path == Path.join([run_dir, "repos", "b"])
      assert c.worktree_path == Path.join([run_dir, "repos", "c"])
      assert b.operation_id == "wt-#{ctx.run_id}-b"
      assert b.repo_path == ctx.repos["b"]

      for {id, wt} <- [{"a", main}, {"b", b}, {"c", c}] do
        assert git!(wt.worktree_path, ["rev-parse", "--abbrev-ref", "HEAD"]) == primary.branch
        assert primary.branch in branches(ctx.repos[id])
      end
    end

    test "the primary's WorktreeCreated carries no repo_id; a secondary's does", ctx do
      state = resolved!(ctx, %{repo_ids: ["b"]})
      assert {:ok, _primary} = RunExecutor.__create_run_worktree_for_test__(state, 1)

      assert {:ok, [primary_event]} =
               ForemanServer.EventStore.read_stream_forward("vcs:wt-" <> ctx.run_id)

      assert {:ok, [secondary_event]} =
               ForemanServer.EventStore.read_stream_forward("vcs:wt-#{ctx.run_id}-b")

      refute Map.has_key?(event_data(primary_event), "repo_id")
      assert event_data(secondary_event)["repo_id"] == "b"
    end

    test "a single-repo run provisions exactly the primary", ctx do
      assert {:ok, _primary} = RunExecutor.__create_run_worktree_for_test__(state(ctx), 1)

      assert [%{repo_id: nil, primary?: true}] = ProjectionStore.worktrees_for_run(ctx.run_id)
    end

    test "each repo's base follows S3 §5: default_branch tip, else the checked-out branch", ctx do
      git!(ctx.repos["b"], ["branch", "develop"])
      File.write!(Path.join(ctx.repos["b"], "later.txt"), "x")
      git!(ctx.repos["b"], ["add", "."])
      git!(ctx.repos["b"], ["commit", "--no-gpg-sign", "-q", "-m", "later"])
      develop_tip = git!(ctx.repos["b"], ["rev-parse", "develop"])
      remove_repo!(ctx.project_id, "b")
      add_repo!(ctx.project_id, "b", ctx.repos["b"], %{default_branch: "develop"})

      state = resolved!(ctx, %{repo_ids: ["b", "c"]})
      assert {:ok, _} = RunExecutor.__create_run_worktree_for_test__(state, 1)

      by_repo = ctx.run_id |> ProjectionStore.worktrees_for_run() |> Map.new(&{&1.repo_id, &1})
      assert by_repo["b"].base_ref == develop_tip
      assert by_repo["c"].base_ref == git!(ctx.repos["c"], ["rev-parse", "HEAD"])

      # Persisted per repo, non-primary only; the aggregate's primary base is untouched.
      assert %{repo_base_branches: %{"b" => "develop", "c" => "main"}} =
               ProjectionStore.run(ctx.run_id)

      refute Map.get(ProjectionStore.run(ctx.run_id), :base_branch)
    end

    test "a failure at repo N rolls back the primary and repos 1..N-1 and fails typed", ctx do
      state = resolved!(ctx, %{repo_ids: ["b", "c"]})
      # `c` is registered but is not a git work tree.
      File.rm_rf!(Path.join(ctx.repos["c"], ".git"))

      assert {:error, {:multi_repo_worktree_failed, "c", {:not_a_git_repo, _}}} =
               RunExecutor.__create_run_worktree_for_test__(state, 1)

      branch = "foreman/task-1/#{ctx.run_id}"

      run_dir =
        ForemanServer.Workflow.RunWorktreeLayout.run_root(ctx.project_id, "task-1", ctx.run_id)

      refute File.exists?(Path.join(run_dir, "workspace"))
      refute File.exists?(Path.join([run_dir, "repos", "b"]))
      refute branch in branches(ctx.repos["a"])
      refute branch in branches(ctx.repos["b"])

      assert ctx.run_id
             |> ProjectionStore.worktrees_for_run()
             |> Enum.map(& &1.status)
             |> Enum.uniq() == ["cleaned"]
    end

    test "a failure at the first extra rolls back the primary", ctx do
      state = resolved!(ctx, %{repo_ids: ["b"]})
      File.rm_rf!(Path.join(ctx.repos["b"], ".git"))

      assert {:error, {:multi_repo_worktree_failed, "b", _}} =
               RunExecutor.__create_run_worktree_for_test__(state, 1)

      refute "foreman/task-1/#{ctx.run_id}" in branches(ctx.repos["a"])
      assert [%{status: "cleaned"}] = ProjectionStore.worktrees_for_run(ctx.run_id)
    end
  end

  describe "state.run_worktrees, resume and phase commit" do
    setup ctx do
      state = resolved!(ctx, %{repo_ids: ["b", "c"]})
      assert {:ok, primary} = RunExecutor.__create_run_worktree_for_test__(state, 1)

      loaded =
        state
        |> Map.put(:run_worktree, primary)
        |> RunExecutor.__load_run_worktrees_for_test__()

      %{state: state, primary: primary, loaded: loaded}
    end

    test "run_worktrees maps every repo, with run_worktree as the primary alias", ctx do
      assert %{"main" => primary, "b" => b, "c" => c} = ctx.loaded.run_worktrees
      assert primary == ctx.loaded.run_worktree
      assert b.repo_id == "b" and c.repo_id == "c"
      assert b.worktree_path =~ "/repos/b"
    end

    test "resume rehydrates the primary and every non-cleaned extra repo", ctx do
      fresh = state(ctx, %{repo_ids: ["b", "c"]}, %{resuming?: true})
      assert {:ok, resumed} = RunExecutor.__rehydrate_resume_context_for_test__(fresh)

      assert resumed.run_worktree.worktree_path == ctx.primary.worktree_path
      assert Map.keys(resumed.run_worktrees) |> Enum.sort() == ["b", "c", "main"]

      assert resumed.run_worktrees["b"].worktree_path ==
               ctx.loaded.run_worktrees["b"].worktree_path
    end

    test "a cleaned extra repo is not rehydrated", ctx do
      assert :ok =
               ForemanServer.Workflow.Worktree.clean(%{
                 operation_id: "wt-#{ctx.run_id}-c",
                 project_id: ctx.project_id,
                 run_id: ctx.run_id,
                 phase_id: ForemanServer.Identity.phase_id(ctx.run_id, 1),
                 repo_path: ctx.repos["c"]
               })

      fresh = state(ctx, %{repo_ids: ["b", "c"]}, %{resuming?: true})
      assert {:ok, resumed} = RunExecutor.__rehydrate_resume_context_for_test__(fresh)
      assert Map.keys(resumed.run_worktrees) |> Enum.sort() == ["b", "main"]
    end

    test "an edit only in b is committed in b at the phase end", ctx do
      b = ctx.loaded.run_worktrees["b"].worktree_path
      File.write!(Path.join(b, "only-in-b.txt"), "edit")

      assert :ok = RunExecutor.__commit_secondary_worktrees_for_test__(ctx.loaded, %{}, 1)

      assert git!(b, ["status", "--porcelain"]) == ""
      assert git!(b, ["log", "-1", "--format=%s"]) == "Foreman run #{ctx.run_id} phase 1"
      assert git!(ctx.primary.worktree_path, ["log", "-1", "--format=%s"]) == "seed"

      assert git!(ctx.loaded.run_worktrees["c"].worktree_path, ["log", "-1", "--format=%s"]) ==
               "seed"
    end

    test "the pause path commits every repo, not just the primary", ctx do
      b = ctx.loaded.run_worktrees["b"].worktree_path
      File.write!(Path.join(b, "paused.txt"), "partial")
      File.write!(Path.join(ctx.primary.worktree_path, "paused-a.txt"), "partial")

      assert {:ok, :committed} =
               RunExecutor.__commit_phase_worktree_for_test__(ctx.loaded, %{}, ctx.primary)

      assert git!(b, ["status", "--porcelain"]) == ""
      assert git!(ctx.primary.worktree_path, ["status", "--porcelain"]) == ""
    end

    test "a failing commit in one repo fails the phase but the others are still committed", ctx do
      b = ctx.loaded.run_worktrees["b"].worktree_path
      c = ctx.loaded.run_worktrees["c"].worktree_path
      File.write!(Path.join(c, "c.txt"), "edit")
      File.rm_rf!(Path.join(b, ".git"))

      assert {:error, {:phase_commit_status_failed, ^b, _}} =
               RunExecutor.__commit_secondary_worktrees_for_test__(ctx.loaded, %{}, 1)

      assert git!(c, ["status", "--porcelain"]) == ""
    end

    test "commit: false defers the secondary repos too", ctx do
      b = ctx.loaded.run_worktrees["b"].worktree_path
      File.write!(Path.join(b, "deferred.txt"), "edit")

      assert :ok =
               RunExecutor.__commit_secondary_worktrees_for_test__(
                 ctx.loaded,
                 %{commit: false},
                 1
               )

      assert git!(b, ["status", "--porcelain"]) =~ "deferred.txt"
    end

    test "terminal cleanup reclaims every repo and continues past a failing one", ctx do
      loaded = put_in(ctx.loaded, [:run_worktree, :cleanup], :always)

      loaded =
        update_in(loaded.run_worktrees, fn worktrees ->
          Map.new(worktrees, fn {id, record} -> {id, %{record | cleanup: :always}} end)
        end)

      # The primary cannot be removed (dirty), the secondaries can.
      File.write!(Path.join(ctx.primary.worktree_path, "dirty.txt"), "uncommitted")

      assert {:error, {:worktree_cleanup_failed, [{nil, _reason}]}} =
               RunExecutor.__cleanup_run_worktree_for_test__(loaded, :success)

      refute File.exists?(loaded.run_worktrees["b"].worktree_path)
      refute File.exists?(loaded.run_worktrees["c"].worktree_path)
      assert File.exists?(ctx.primary.worktree_path)
    end

    test "never-cleanup keeps every worktree", ctx do
      assert :ok = RunExecutor.__cleanup_run_worktree_for_test__(ctx.loaded, :success)

      assert File.exists?(ctx.loaded.run_worktrees["b"].worktree_path)
    end

    test "a vanished extra worktree is a hard failure at the next phase", ctx do
      File.rm_rf!(ctx.loaded.run_worktrees["b"].worktree_path)

      assert {:error, {:run_worktree_vanished, _}} =
               RunExecutor.__ensure_run_worktree_for_test__(ctx.loaded, 2)
    end
  end

  # -- helpers -----------------------------------------------------------

  # Seeding a repo is ~6 git processes and identical for every test, so it is done once per id
  # in `setup_all` and each test gets a copy.
  defp init_repo!(template, root, id) do
    File.cp_r!(Path.join(template, "repo-#{id}"), Path.join(root, "repo-#{id}"))
    Path.join(root, "repo-#{id}")
  end

  defp seed_repo!(root, id) do
    repo = Path.join(root, "repo-#{id}")
    File.mkdir_p!(repo)
    git!(repo, ["init", "--initial-branch=main", "--quiet"])
    git!(repo, ["config", "user.email", "t@x"])
    git!(repo, ["config", "user.name", "T"])
    File.write!(Path.join(repo, "README.md"), "seed")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--no-gpg-sign", "-m", "seed", "--quiet"])
    repo
  end

  defp register_project!(project_id, path) do
    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectRegistered", payload: %{project_id: project_id, path: path}}
      ])
  end

  defp add_repo!(project_id, repo_id, path, extra \\ %{}) do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRepositoryAdded",
          payload:
            Map.merge(
              %{
                project_id: project_id,
                repo_id: repo_id,
                path: path,
                default_branch: nil,
                vcs: %{adapter: "git"},
                task_provider: nil,
                added_by: "operator:test",
                at: "2026-01-01T00:00:00Z"
              },
              extra
            )
        }
      ])
  end

  defp remove_repo!(project_id, repo_id) do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRepositoryRemoved",
          payload: %{
            project_id: project_id,
            repo_id: repo_id,
            removed_by: "operator:test",
            at: "2026-01-01T00:00:00Z"
          }
        }
      ])
  end

  # `run.record_base_branch` requires the Run aggregate to exist in the event
  # store, so seed a real RunStarted (mirrors run_executor_pr_base_branch_test).
  defp seed_run!(run_id, project_id) do
    payload = %{run_id: run_id, project_id: project_id}

    :ok =
      ForemanServer.EventStore.append_to_stream("run:#{run_id}", 0, [
        %EventStore.EventData{event_type: "RunStarted", data: payload, metadata: %{}}
      ])

    :ok = ProjectionStore.apply_events([%{event_type: "RunStarted", payload: payload}])
  end

  defp event_data(%{data: data}) when is_struct(data),
    do: data |> Jason.encode!() |> Jason.decode!()

  defp event_data(%{data: data}), do: data |> Jason.encode!() |> Jason.decode!()

  defp branches(repo) do
    repo |> git!(["branch", "--format=%(refname:short)"]) |> String.split("\n", trim: true)
  end

  defp git!(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, code} -> flunk("git #{Enum.join(args, " ")} failed (#{code}) in #{dir}: #{out}")
    end
  end
end
