defmodule ForemanServer.Workflow.RunExecutorMultiRepoPrTest do
  @moduledoc """
  One PR per touched repository (E12-S5): per-repo finalisation, association,
  `run.pr.ready` and cross-links, against real scratch git repositories with
  bare origins and a fake `gh` on PATH. The run-start gate is opened per test.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.{Identity, MultiRepoRuns, PrAssociate, ProjectionStore}
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Workflow.{RepoPr, RepoPrContext, RunExecutor}

  setup do
    ProjectionStoreReset.reset!()
    MultiRepoRuns.enable!()

    root = Path.join(System.tmp_dir!(), "multi-repo-pr-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    project_id = "proj-pr-#{System.unique_integer([:positive])}"

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
    seed_run!(run_id, project_id, ["b"])

    state = %{
      task: %{project_id: project_id, task_id: "task-1"},
      run_id: run_id,
      worktree_spec: %{},
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

    %{
      root: root,
      gh_dir: gh_dir,
      project_id: project_id,
      repos: repos,
      run_id: run_id,
      state: state,
      wt_a: primary.worktree_path,
      wt_b: state.run_worktrees["b"].worktree_path
    }
  end

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

  defp event_types(stream) do
    case ForemanServer.EventStore.read_stream_forward(stream) do
      {:ok, events} -> Enum.map(events, & &1.event_type)
      _ -> []
    end
  end

  describe "finalisation" do
    test "both repos touched: a PR each, primary first, one association each", ctx do
      touch!(ctx, "a")
      touch!(ctx, "b")

      assert [
               {"main", {:ok, "https://github.com/o/repo-a/pull/1"}},
               {"b", {:ok, "https://github.com/o/repo-b/pull/2"}}
             ] = RunExecutor.__finalize_repo_prs_for_test__(ctx.state)

      assert [%{repo_id: "main", pr_url: a_url}, %{repo_id: "b", pr_url: b_url}] =
               ProjectionStore.pr_associations_for_run(ctx.run_id)

      assert a_url =~ "repo-a/pull/1" and b_url =~ "repo-b/pull/2"

      # The primary stream and event are the single-repo shape; the secondary
      # has its own stream and carries repo_id.
      assert event_types("pr_association:#{ctx.run_id}") == ["PrAssociated"]
      assert event_types("pr_association:#{ctx.run_id}:b") == ["PrAssociated"]

      {:ok, [primary]} =
        ForemanServer.EventStore.read_stream_forward("pr_association:#{ctx.run_id}")

      {:ok, [secondary]} =
        ForemanServer.EventStore.read_stream_forward("pr_association:#{ctx.run_id}:b")

      refute Map.has_key?(decode(primary), "repo_id")
      assert decode(secondary)["repo_id"] == "b"

      # A sibling never overwrites the run's pr_url.
      assert ProjectionStore.run(ctx.run_id).pr_url == a_url
      assert ProjectionStore.run(ctx.run_id).pr_urls == %{"main" => a_url, "b" => b_url}
      assert {:ok, %{pr_url: ^a_url}} = ProjectionStore.pr_association(ctx.run_id)

      assert [%{pr_association: %{pr_url: ^a_url}}, %{pr_association: %{pr_url: ^b_url}}] =
               ProjectionStore.run_repositories(ctx.run_id)

      # b's PrReady never replaces the primary's PR state.
      assert %{pr_url: ^a_url} =
               ProjectionStore.pr_states_for_project(ctx.project_id)[ctx.run_id]

      # run.pr.ready per repo, with the per-repo command ids and repo_id only on b.
      {:ok, run_events} = ForemanServer.EventStore.read_stream_forward("run:#{ctx.run_id}")
      ready = for e <- run_events, e.event_type == "PrReady", do: decode(e)
      assert [%{"pr_url" => ^a_url} = ready_a, %{"pr_url" => ^b_url} = ready_b] = ready
      refute Map.has_key?(ready_a, "repo_id")
      assert ready_b["repo_id"] == "b"
    end

    test "an untouched repo opens no PR and records no association", ctx do
      touch!(ctx, "a")

      assert [{"main", {:ok, _}}, {"b", :noop}] =
               RunExecutor.__finalize_repo_prs_for_test__(ctx.state)

      assert [%{repo_id: "main"}] = ProjectionStore.pr_associations_for_run(ctx.run_id)
      refute Enum.any?(gh_calls(ctx), &String.contains?(&1, "repo-b"))
      assert event_types("pr_association:#{ctx.run_id}:b") == []
      # Cross-linking needs two PRs.
      refute Enum.any?(gh_calls(ctx), &String.starts_with?(&1, "pr edit"))
    end

    test "b's push failing leaves a's PR intact and returns the typed error for b", ctx do
      touch!(ctx, "a")
      touch!(ctx, "b")
      git!(ctx.repos["b"], ["remote", "set-url", "origin", "/nonexistent/origin.git"])

      assert [{"main", {:ok, a_url}}, {"b", {:error, {:git_push_failed, _, _}}}] =
               RunExecutor.__finalize_repo_prs_for_test__(ctx.state)

      assert [%{repo_id: "main", pr_url: ^a_url}] =
               ProjectionStore.pr_associations_for_run(ctx.run_id)

      assert event_types("pr_association:#{ctx.run_id}:b") == []
      refute Enum.any?(gh_calls(ctx), &String.starts_with?(&1, "pr edit"))
    end

    test "a failing primary does not stop b", ctx do
      touch!(ctx, "a")
      touch!(ctx, "b")
      git!(ctx.repos["a"], ["remote", "set-url", "origin", "/nonexistent/origin.git"])

      assert [{"main", {:error, _}}, {"b", {:ok, _}}] =
               RunExecutor.__finalize_repo_prs_for_test__(ctx.state)

      assert [%{repo_id: "b"}] = ProjectionStore.pr_associations_for_run(ctx.run_id)
    end

    test "re-finalising is idempotent: no second PR, association or PrReady", ctx do
      touch!(ctx, "a")
      touch!(ctx, "b")

      first = RunExecutor.__finalize_repo_prs_for_test__(ctx.state)
      creates = Enum.count(gh_calls(ctx), &String.starts_with?(&1, "pr create"))
      assert creates == 2

      assert RunExecutor.__finalize_repo_prs_for_test__(ctx.state) == first
      assert Enum.count(gh_calls(ctx), &String.starts_with?(&1, "pr create")) == 2
      assert event_types("pr_association:#{ctx.run_id}:b") == ["PrAssociated"]

      {:ok, run_events} = ForemanServer.EventStore.read_stream_forward("run:#{ctx.run_id}")
      assert Enum.count(run_events, &(&1.event_type == "PrReady")) == 2
    end
  end

  describe "cross-links" do
    test "each PR body names the run and its sibling, once", ctx do
      touch!(ctx, "a")
      touch!(ctx, "b")
      RunExecutor.__finalize_repo_prs_for_test__(ctx.state)
      RunExecutor.__finalize_repo_prs_for_test__(ctx.state)

      body_a = read_body(ctx, "https://github.com/o/repo-a/pull/1")
      body_b = read_body(ctx, "https://github.com/o/repo-b/pull/2")

      assert body_a =~ "Part of multi-repo run #{ctx.run_id}"
      assert body_a =~ "o/repo-b#2"
      assert body_b =~ "o/repo-a#1"
      assert length(String.split(body_a, "Part of multi-repo run")) == 2
      assert Enum.count(gh_calls(ctx), &String.starts_with?(&1, "pr edit")) == 2
    end

    test "a failing gh edit is not fatal", ctx do
      touch!(ctx, "a")
      touch!(ctx, "b")
      File.write!(Path.join(ctx.gh_dir, "fail-edit"), "")

      assert [{"main", {:ok, _}}, {"b", {:ok, _}}] =
               RunExecutor.__finalize_repo_prs_for_test__(ctx.state)
    end
  end

  describe "RepoPrContext and RepoPr.open/2" do
    test "build/2 is derived from projections: root, branch and base per repo", ctx do
      assert {:ok, %{repo_id: "b", primary?: false, auto_pr: auto}} =
               RepoPrContext.build(ctx.run_id, "b")

      assert auto.cwd == ctx.repos["b"]
      assert auto.head_branch == "foreman/task-1/#{ctx.run_id}"
      assert auto.base_branch == "main"

      assert {:ok, %{primary?: true, auto_pr: %{cwd: cwd}}} =
               RepoPrContext.build(ctx.run_id, "main")

      assert cwd == ctx.repos["a"]

      assert {:error, {:unknown_repo, "zzz"}} = RepoPrContext.build(ctx.run_id, "zzz")
      assert {:error, :run_not_found} = RepoPrContext.build("run-none", "b")
    end

    test "open/2 on an untouched repo is :noop and on a touched one pushes from its root", ctx do
      assert RepoPr.open(ctx.run_id, "b") == :noop
      touch!(ctx, "b")
      assert {:ok, "https://github.com/o/repo-b/pull/1"} = RepoPr.open(ctx.run_id, "b")
      assert "foreman/task-1/#{ctx.run_id}" in branches(ctx.repos["b"])
      assert Enum.any?(gh_calls(ctx), &String.ends_with?(&1, "/repo-b"))
    end
  end

  describe "stack_pr at run start" do
    test "stack_pr with more than one repo is refused; single-repo is untouched", ctx do
      stacked = [%{stack_pr: true}]

      assert {:error, :stack_pr_unsupported_multi_repo} =
               %{ctx.state | phase_specs: stacked}
               |> Map.delete(:run_repos)
               |> RunExecutor.__resolve_run_repo_set_for_test__()

      other_run = "run-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      seed_run!(other_run, ctx.project_id, [])

      single =
        ctx.state
        |> Map.merge(%{run_id: other_run, phase_specs: stacked})
        |> Map.delete(:run_repos)

      assert {:ok, _} = RunExecutor.__resolve_run_repo_set_for_test__(single)
    end
  end

  describe "merge gate isolation" do
    alias ForemanServer.Aggregates.Run

    test "a non-primary PrReady leaves the primary's merge gate alone" do
      gate = fn state, payload, repo_id ->
        state
        |> then(&Run.apply_event(&1, %{event_type: "PrReady", payload: payload}))
        |> Run.merge_gate(repo_id)
      end

      approved = %{Run.initial_state() | merge_gates: %{nil => :approved}}
      assert gate.(approved, %{run_id: "r"}, nil) == :pending
      assert gate.(approved, %{run_id: "r", repo_id: "b"}, nil) == :approved
      assert gate.(approved, %{run_id: "r", repo_id: "b"}, "b") == :pending
    end
  end

  describe "identities" do
    test "command ids: primary unchanged, secondary carries the repo id" do
      assert Identity.run_pr_ready_command_id("r1", nil) == "workflow:r1:pr_ready"
      assert Identity.run_pr_ready_command_id("r1", "b") == "workflow:r1:b:pr_ready"
    end

    test "PrAssociate.store/3 for a non-primary uses the repo stream", ctx do
      assert {:ok, _} = PrAssociate.store(ctx.run_id, "https://github.com/o/r/pull/9", "b")
      assert event_types("pr_association:#{ctx.run_id}:b") == ["PrAssociated"]
      assert event_types("pr_association:#{ctx.run_id}") == []
      assert {:error, :not_found} = ProjectionStore.pr_association(ctx.run_id)
      assert [%{repo_id: "b"}] = ProjectionStore.pr_associations_for_run(ctx.run_id)
      refute Map.get(ProjectionStore.run(ctx.run_id), :pr_url)
    end
  end

  # -- helpers ----------------------------------------------------------------

  # Behaves like gh for the three verbs the PR path uses. Repo name comes from
  # the working directory (`repo-a`/`repo-b`); PR numbers are global. Every call
  # is logged with its cwd.
  defp fake_gh(dir) do
    """
    #!/bin/sh
    DIR="#{dir}"
    echo "$1 $2 cwd=$(pwd)" >> "$DIR/calls.log"
    case "$1 $2" in
      "pr create")
        n=$(( $(cat "$DIR/count" 2>/dev/null || echo 0) + 1 ))
        echo $n > "$DIR/count"
        url="https://github.com/o/$(basename "$(pwd)")/pull/$n"
        echo "initial body" > "$DIR/body-$(echo "$url" | tr '/:' '__')"
        echo "$url"
        ;;
      "pr view")
        cat "$DIR/body-$(echo "$3" | tr '/:' '__')"
        ;;
      "pr edit")
        if [ -e "$DIR/fail-edit" ]; then echo "boom" >&2; exit 1; fi
        printf '%s' "$5" > "$DIR/body-$(echo "$3" | tr '/:' '__')"
        ;;
      *) exit 1 ;;
    esac
    """
  end

  defp read_body(ctx, url),
    do: File.read!(Path.join(ctx.gh_dir, "body-" <> String.replace(url, ["/", ":"], "_")))

  defp decode(event) do
    event.data |> Jason.encode!() |> Jason.decode!()
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

  defp seed_run!(run_id, project_id, repo_ids) do
    payload = %{
      run_id: run_id,
      project_id: project_id,
      task_id: "task-1",
      repo_ids: repo_ids
    }

    :ok =
      ForemanServer.EventStore.append_to_stream("run:#{run_id}", 0, [
        %EventStore.EventData{event_type: "RunStarted", data: payload, metadata: %{}}
      ])

    :ok = ProjectionStore.apply_events([%{event_type: "RunStarted", payload: payload}])
  end

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
