defmodule ForemanServer.Workflow.MultiRepoPrRetryTest do
  @moduledoc """
  E12-S6 partial completion: when one repository's PR cannot be created the run
  still completes, the failure is recorded per repository (`RunRepoPrFailed`),
  that repository's worktree is kept, the dashboard derives `completed_with_errors`
  (no new run status), and the operator's `run.pr.retry` opens the missing PR and
  then reclaims the worktree. Real scratch git repositories, a fake `gh` on PATH.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandGateway, MultiRepoRuns, ProjectionStore}
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Workflow.RunExecutor
  alias ForemanServerWeb.OperatorDashboard

  setup context do
    cleanup = Map.get(context, :cleanup, "always")
    ProjectionStoreReset.reset!()
    MultiRepoRuns.enable!()

    root = Path.join(System.tmp_dir!(), "multi-repo-retry-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    project_id = "proj-retry-#{System.unique_integer([:positive])}"

    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    gh_dir = Path.join(root, "gh")
    File.mkdir_p!(gh_dir)
    File.write!(Path.join(bin, "gh"), fake_gh(gh_dir))
    File.chmod!(Path.join(bin, "gh"), 0o755)

    previous_path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> previous_path)

    on_exit(fn ->
      System.put_env("PATH", previous_path)
      ProjectionStoreReset.reset!()
      File.rm_rf(root)
      File.rm_rf(Path.join(ForemanServer.Workflow.RunWorktreeLayout.base_root(), project_id))
    end)

    repos = for id <- ~w(a b), into: %{}, do: {id, init_repo!(root, id)}
    register_project!(project_id, repos["a"])
    add_repo!(project_id, "b", repos["b"])

    run_id = "run-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    seed_run!(run_id, project_id, ["b"], cleanup)

    state = %{
      task: %{project_id: project_id, task_id: "task-1"},
      run_id: run_id,
      # Both worktrees would be reclaimed after a successful finalisation.
      worktree_spec: %{cleanup: cleanup},
      plan_context: nil,
      artifact_base: Path.join(root, "artifacts"),
      phase_specs: [],
      current_phase: nil,
      repo_ids: ["b"]
    }

    {:ok, state} = RunExecutor.__resolve_run_repo_set_for_test__(state)
    {:ok, primary} = RunExecutor.__create_run_worktree_for_test__(state, 1)

    state =
      state
      |> Map.put(:run_worktree, primary)
      |> Map.put(:last_worktree, primary)
      |> RunExecutor.__load_run_worktrees_for_test__()
      |> RunExecutor.__remember_run_base_branch_for_test__()

    ctx = %{
      root: root,
      gh_dir: gh_dir,
      project_id: project_id,
      repos: repos,
      run_id: run_id,
      state: state,
      wt_a: primary.worktree_path,
      wt_b: state.run_worktrees["b"].worktree_path
    }

    touch!(ctx, "a")
    touch!(ctx, "b")
    %{ctx: ctx}
  end

  # b's origin is unreachable: its push (and so its PR) fails; a's is untouched.
  defp break_origin!(ctx),
    do: git!(ctx.repos["b"], ["remote", "set-url", "origin", "/nonexistent/origin.git"])

  defp repair_origin!(ctx),
    do: git!(ctx.repos["b"], ["remote", "set-url", "origin", Path.join(ctx.root, "origin-b.git")])

  defp finalize(ctx), do: RunExecutor.__finalize_repo_prs_and_cleanup_for_test__(ctx.state)

  defp complete_run!(run_id) do
    payload = %{run_id: run_id, completed_at: "2026-01-01T00:00:00Z"}
    :ok = ProjectionStore.apply_events([%{event_type: "RunCompleted", payload: payload}])
  end

  defp retry(ctx, repo_id) do
    CommandGateway.dispatch_operator(%{
      command_id: "retry-#{System.unique_integer([:positive])}",
      type: "run.pr.retry",
      aggregate_id: "run:#{ctx.run_id}",
      payload: %{run_id: ctx.run_id, repo_id: repo_id}
    })
  end

  defp repo(ctx, repo_id),
    do: Enum.find(ProjectionStore.run_repositories(ctx.run_id), &(&1.repo_id == repo_id))

  defp run_events(ctx, type) do
    {:ok, events} = ForemanServer.EventStore.read_stream_forward("run:#{ctx.run_id}", 0, 1_000)

    events
    |> Enum.filter(&(&1.event_type == type))
    |> Enum.map(fn e -> e.data |> Jason.encode!() |> Jason.decode!() end)
  end

  defp creates(ctx, name) do
    ctx |> gh_calls() |> Enum.count(&(&1 =~ ~r/^pr create .*#{name}$/))
  end

  describe "a repository whose PR cannot be created" do
    test "is recorded, others are unaffected, and its worktree is kept", %{ctx: ctx} do
      break_origin!(ctx)

      assert [{"main", {:ok, a_url}}, {"b", {:error, _}}] = finalize(ctx)

      # a: PR + gate, and (cleanup: always) its worktree is reclaimed.
      assert %{pr_association: %{pr_url: ^a_url}, pr_state: :open, pr_failure: nil} =
               repo(ctx, "main")

      refute File.dir?(ctx.wt_a)

      # b: failure on record, no association, worktree preserved for the retry.
      assert [%{"repo_id" => "b", "reason" => reason, "at" => at}] =
               run_events(ctx, "RunRepoPrFailed")

      assert is_binary(reason) and is_integer(at)

      assert %{pr_association: nil, pr_state: :create_failed, pr_failure: %{reason: ^reason}} =
               repo(ctx, "b")

      assert File.dir?(ctx.wt_b)

      assert ProjectionStore.pr_associations_for_run(ctx.run_id) |> Enum.map(& &1.repo_id) == [
               "main"
             ]
    end

    test "the run completes: status unchanged, completed_with_errors derived", %{ctx: ctx} do
      break_origin!(ctx)
      finalize(ctx)

      {:ok, before_complete} = OperatorDashboard.run_detail(ctx.run_id)

      refute before_complete.run.completed_with_errors,
             "only a completed run can be 'with errors'"

      complete_run!(ctx.run_id)

      assert {:ok, %{run: run}} = OperatorDashboard.run_detail(ctx.run_id)
      assert run.status == "completed"
      assert run.completed_with_errors

      assert {:ok, rows} = OperatorDashboard.list_runs(%{project_id: ctx.project_id})
      assert Enum.find(rows, &(&1.run_id == ctx.run_id)).completed_with_errors
    end

    test "a run whose PRs all opened is not completed_with_errors", %{ctx: ctx} do
      assert [{"main", {:ok, _}}, {"b", {:ok, _}}] = finalize(ctx)
      complete_run!(ctx.run_id)

      assert {:ok, %{run: run}} = OperatorDashboard.run_detail(ctx.run_id)
      refute run.completed_with_errors
      assert run_events(ctx, "RunRepoPrFailed") == []
    end
  end

  describe "run.pr.retry" do
    setup %{ctx: ctx} do
      break_origin!(ctx)
      finalize(ctx)
      complete_run!(ctx.run_id)
      %{ctx: ctx}
    end

    test "opens the missing PR from the preserved worktree, then reclaims it", %{ctx: ctx} do
      repair_origin!(ctx)
      assert File.dir?(ctx.wt_b)

      assert {:ok, _} = retry(ctx, "b")

      assert %{pr_association: %{pr_url: url}, pr_state: :open, gate: :pending, pr_failure: nil} =
               repo(ctx, "b")

      assert url =~ "repo-b/pull/"
      refute File.dir?(ctx.wt_b), "the worktree is reclaimed once its PR exists"

      assert [%{"pr_url" => ^url}] =
               Enum.filter(run_events(ctx, "PrReady"), &(&1["repo_id"] == "b"))

      assert {:ok, %{run: run}} = OperatorDashboard.run_detail(ctx.run_id)
      refute run.completed_with_errors
    end

    @tag cleanup: "never"
    test "a workflow declaring cleanup: never keeps the worktree after a successful retry", %{
      ctx: ctx
    } do
      repair_origin!(ctx)
      assert {:ok, _} = retry(ctx, "b")
      assert %{pr_association: %{}, pr_state: :open} = repo(ctx, "b")
      assert File.dir?(ctx.wt_b), "cleanup: never is a declaration, retry does not override it"
    end

    test "is idempotent: a second retry opens no second PR and signals nothing new", %{ctx: ctx} do
      repair_origin!(ctx)
      assert {:ok, _} = retry(ctx, "b")
      assert creates(ctx, "repo-b") == 1

      assert {:ok, _} = retry(ctx, "b")
      assert creates(ctx, "repo-b") == 1
      assert [_one] = Enum.filter(run_events(ctx, "PrReady"), &(&1["repo_id"] == "b"))

      assert [_one] =
               ProjectionStore.pr_associations_for_run(ctx.run_id)
               |> Enum.filter(&(&1.repo_id == "b"))
    end

    test "a retry that fails again keeps the worktree and the create_failed state", %{ctx: ctx} do
      assert {:error, _} = retry(ctx, "b")

      assert File.dir?(ctx.wt_b)
      assert %{pr_state: :create_failed, pr_association: nil} = repo(ctx, "b")
      assert [_ | _] = run_events(ctx, "RunRepoPrFailed")
    end

    test "an unknown repository is a typed error and records no failure", %{ctx: ctx} do
      failures = length(run_events(ctx, "RunRepoPrFailed"))

      assert {:error, {:unknown_repo, "zzz"}} = retry(ctx, "zzz")
      assert length(run_events(ctx, "RunRepoPrFailed")) == failures
    end

    test "a missing repo_id is refused before any work", %{ctx: ctx} do
      assert {:error, {:missing_or_invalid, :repo_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "retry-norepo-#{System.unique_integer([:positive])}",
                 type: "run.pr.retry",
                 aggregate_id: "run:#{ctx.run_id}",
                 payload: %{run_id: ctx.run_id}
               })
    end
  end

  # -- helpers (the scratch-repo fixture of RunExecutorMultiRepoPrTest) ----------

  defp touch!(ctx, which) do
    wt = if which == "a", do: ctx.wt_a, else: ctx.wt_b
    File.write!(Path.join(wt, "work-#{which}.txt"), "work")
    git!(wt, ["add", "."])
    git!(wt, ["commit", "--no-gpg-sign", "-q", "-m", "work #{which}"])
  end

  defp gh_calls(ctx) do
    case File.read(Path.join(ctx.gh_dir, "calls.log")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      _ -> []
    end
  end

  # `pr create` is logged with the cwd's repository name so tests can count per repo.
  defp fake_gh(dir) do
    """
    #!/bin/sh
    DIR="#{dir}"
    echo "$1 $2 cwd=$(basename "$(pwd)")" >> "$DIR/calls.log"
    case "$1 $2" in
      "pr create")
        n=$(( $(cat "$DIR/count" 2>/dev/null || echo 0) + 1 ))
        echo $n > "$DIR/count"
        echo "https://github.com/o/$(basename "$(pwd)")/pull/$n"
        ;;
      "pr view") echo "initial body" ;;
      "pr edit") exit 0 ;;
      *) exit 1 ;;
    esac
    """
  end

  defp init_repo!(root, id) do
    origin = Path.join(root, "origin-#{id}.git")
    repo = Path.join(root, "repo-#{id}")
    File.mkdir_p!(origin)
    git!(origin, ["init", "--bare", "--quiet", "--initial-branch=main"])
    File.mkdir_p!(repo)
    git!(repo, ["init", "--initial-branch=main", "--quiet"])
    git!(repo, ["config", "user.email", "t@x"])
    git!(repo, ["config", "user.name", "T"])
    File.write!(Path.join(repo, "README.md"), "seed")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--no-gpg-sign", "-m", "seed", "--quiet"])
    git!(repo, ["remote", "add", "origin", origin])
    repo
  end

  defp register_project!(project_id, path) do
    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectRegistered", payload: %{project_id: project_id, path: path}}
      ])
  end

  defp add_repo!(project_id, repo_id, path) do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRepositoryAdded",
          payload: %{
            project_id: project_id,
            repo_id: repo_id,
            path: path,
            default_branch: nil,
            vcs: %{adapter: "git"},
            task_provider: nil,
            added_by: "operator:test",
            at: "2026-01-01T00:00:00Z"
          }
        }
      ])
  end

  defp seed_run!(run_id, project_id, repo_ids, cleanup) do
    payload = %{
      run_id: run_id,
      project_id: project_id,
      task_id: "task-1",
      repo_ids: repo_ids,
      # The workflow's `worktree.cleanup` policy: what `run.pr.retry` reclaims by.
      workflow_snapshot: %{"worktree" => %{"cleanup" => cleanup}}
    }

    :ok =
      ForemanServer.EventStore.append_to_stream("run:#{run_id}", 0, [
        %EventStore.EventData{event_type: "RunStarted", data: payload, metadata: %{}}
      ])

    :ok = ProjectionStore.apply_events([%{event_type: "RunStarted", payload: payload}])
  end

  defp git!(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, code} -> flunk("git #{Enum.join(args, " ")} failed (#{code}) in #{dir}: #{out}")
    end
  end
end
