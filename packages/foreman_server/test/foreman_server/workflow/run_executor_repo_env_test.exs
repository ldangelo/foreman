defmodule ForemanServer.Workflow.RunExecutorRepoEnvTest do
  @moduledoc """
  The multi-repo env/prompt/VFS/add_dirs contract (E12-S4): `FOREMAN_PRIMARY_REPO`,
  `FOREMAN_REPOS`, `FOREMAN_REPO_<ID>_WORKTREE`, the one-shot VFS bind of every
  worktree root, `add_dirs` for non-primary worktrees and the `repositories` /
  `repositories_count` prompt assigns.

  Real git repositories and the production worktree path, like
  `RunExecutorMultiRepoTest`.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Agents.VfsIsolation
  alias ForemanServer.{MultiRepoRuns, ProjectEnvironment, ProjectionStore}
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Workflow.RunExecutor

  setup do
    ProjectionStoreReset.reset!()

    case Process.whereis(VfsIsolation) do
      nil -> start_supervised!(VfsIsolation)
      _pid -> :ok
    end

    root = Path.join(System.tmp_dir!(), "repo-env-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    project_id = "proj-env-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      ProjectionStoreReset.reset!()
      File.rm_rf(root)
      File.rm_rf(Path.join(ForemanServer.Workflow.RunWorktreeLayout.base_root(), project_id))
    end)

    repos = for id <- ~w(a b web-app), into: %{}, do: {id, init_repo!(root, id)}
    register_project!(project_id, repos["a"])
    add_repo!(project_id, "b", repos["b"])
    add_repo!(project_id, "web-app", repos["web-app"])

    run_id = "run-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    seed_run!(run_id, project_id)

    %{project_id: project_id, repos: repos, run_id: run_id}
  end

  # A multi-repo run (primary "main" + b + web-app), worktrees provisioned and
  # the registry rehydrated from the projection.
  defp multi_state(ctx) do
    MultiRepoRuns.enable!()
    {:ok, state} = ctx |> base_state(%{repo_ids: ["b", "web-app"]}) |> resolve()
    {:ok, primary} = RunExecutor.__create_run_worktree_for_test__(state, 1)

    state
    |> Map.put(:run_worktree, primary)
    |> Map.put(:run_base_branch, {:ok, "main"})
    |> RunExecutor.__load_run_worktrees_for_test__()
  end

  defp single_state(ctx) do
    {:ok, state} = ctx |> base_state(%{}) |> resolve()
    {:ok, primary} = RunExecutor.__create_run_worktree_for_test__(state, 1)

    state
    |> Map.put(:run_worktree, primary)
    |> Map.put(:run_base_branch, {:ok, "main"})
    |> RunExecutor.__load_run_worktrees_for_test__()
  end

  defp base_state(ctx, task_fields) do
    %{
      task: Map.merge(%{project_id: ctx.project_id, task_id: "task-1"}, task_fields),
      run_id: ctx.run_id,
      worktree_spec: %{},
      plan_context: nil,
      completed: [],
      phase_specs: [],
      artifact_base: Path.join(System.tmp_dir!(), "repo-env-artifacts")
    }
  end

  defp resolve(state), do: RunExecutor.__resolve_run_repo_set_for_test__(state)

  defp env(state, model \\ nil),
    do: RunExecutor.__foreman_env_for_test__(state, state.run_worktree, "/tmp/artifact.md", model)

  describe "FOREMAN_PRIMARY_REPO / FOREMAN_REPOS / FOREMAN_REPO_<ID>_WORKTREE" do
    test "a single-repo run emits the same vars with one entry", ctx do
      state = single_state(ctx)
      env = env(state)

      assert env["FOREMAN_PRIMARY_REPO"] == "main"
      assert env["FOREMAN_REPO_MAIN_WORKTREE"] == state.run_worktree.worktree_path
      assert env["FOREMAN_WORKTREE_PATH"] == state.run_worktree.worktree_path

      assert %{"main" => entry} = Jason.decode!(env["FOREMAN_REPOS"])

      assert entry == %{
               "path" => state.run_worktree.worktree_path,
               "branch" => state.run_worktree.branch,
               "base_ref" => state.run_worktree.base_ref,
               "base_branch" => "main",
               "primary" => true
             }

      refute Enum.any?(Map.keys(env), &String.starts_with?(&1, "FOREMAN_REPO_B"))
    end

    test "a multi-repo run lists every repo; FOREMAN_REPOS is compact with sorted keys", ctx do
      state = multi_state(ctx)
      env = env(state)
      repos = Jason.decode!(env["FOREMAN_REPOS"])

      assert Map.keys(repos) |> Enum.sort() == ["b", "main", "web-app"]
      assert env["FOREMAN_PRIMARY_REPO"] == "main"
      assert repos["main"]["primary"] == true
      assert repos["b"]["primary"] == false

      # base_branch of a non-primary comes from the run projection.
      assert repos["b"]["base_branch"] == "main"
      assert repos["web-app"]["base_branch"] == "main"

      raw = env["FOREMAN_REPOS"]
      refute raw =~ ~r/\s/

      assert raw =~
               ~r/^\{"b":\{"base_branch":"main","base_ref":"[0-9a-f]+","branch":"[^"]+","path":"[^"]+","primary":false\},"main":\{.*\},"web-app":\{.*\}\}$/

      assert env["FOREMAN_REPO_MAIN_WORKTREE"] == state.run_worktrees["main"].worktree_path
      assert env["FOREMAN_REPO_B_WORKTREE"] == state.run_worktrees["b"].worktree_path
      assert env["FOREMAN_REPO_WEB_APP_WORKTREE"] == state.run_worktrees["web-app"].worktree_path
      assert repos["web-app"]["path"] == env["FOREMAN_REPO_WEB_APP_WORKTREE"]

      # The primary-describing vars keep their meaning.
      assert env["FOREMAN_WORKTREE_PATH"] == state.run_worktree.worktree_path
    end

    test "the model-carrying clause emits the same repo vars", ctx do
      state = multi_state(ctx)
      env = env(state, "MiniMax")

      assert env["FOREMAN_MODEL"] == "MiniMax"
      assert env["FOREMAN_PRIMARY_REPO"] == "main"
      assert Map.has_key?(env, "FOREMAN_REPO_WEB_APP_WORKTREE")
    end

    test "a phase without a worktree emits none of them", ctx do
      env = RunExecutor.__foreman_env_for_test__(base_state(ctx, %{}), nil, "/tmp/a.md", nil)

      refute Map.has_key?(env, "FOREMAN_PRIMARY_REPO")
      refute Map.has_key?(env, "FOREMAN_REPOS")
    end

    test "FOREMAN_REPOS is recomputed from the projection each phase (stale registry)", ctx do
      state = multi_state(ctx)
      stale = %{state | run_worktrees: Map.take(state.run_worktrees, ["main"])}

      assert stale |> env() |> Map.fetch!("FOREMAN_REPOS") |> Jason.decode!() |> map_size() == 3
    end

    test "project config.env can never carry these names", _ctx do
      assert ProjectEnvironment.reserved_keys(%{
               "FOREMAN_REPOS" => "x",
               "FOREMAN_PRIMARY_REPO" => "y",
               "FOREMAN_REPO_B_WORKTREE" => "z",
               "OK" => "1"
             }) == ["FOREMAN_PRIMARY_REPO", "FOREMAN_REPOS", "FOREMAN_REPO_B_WORKTREE"]
    end
  end

  describe "VFS isolation" do
    setup do
      # Run worktrees live under ~/.foreman/worktrees, outside the test allowlist.
      previous = Application.get_env(:foreman_server, :jido_vfs)

      Application.put_env(
        :foreman_server,
        :jido_vfs,
        Keyword.put(previous, :enforce_allowlist, false)
      )

      on_exit(fn -> Application.put_env(:foreman_server, :jido_vfs, previous) end)
    end

    test "all roots are bound once per phase; rebinding does not drop any", ctx do
      state = multi_state(ctx)
      _ = env(state)
      _ = env(state)

      assert {:ok, roots} = VfsIsolation.lookup(ctx.run_id)

      assert roots ==
               Enum.map(
                 [
                   state.run_worktrees["main"],
                   state.run_worktrees["b"],
                   state.run_worktrees["web-app"]
                 ],
                 &VfsIsolation.canonical_path(&1.worktree_path)
               )

      assert VfsIsolation.allowed?(
               ctx.run_id,
               Path.join(state.run_worktrees["b"].worktree_path, "x")
             )

      refute VfsIsolation.allowed?(ctx.run_id, ctx.repos["b"])
    end
  end

  describe "add_dirs" do
    test "non-primary worktrees, for a provider that declares add_dirs", ctx do
      state = multi_state(ctx)
      opts = RunExecutor.__maybe_put_add_dirs_for_test__([cwd: "x"], state, :claude)

      assert opts[:add_dirs] == [
               state.run_worktrees["b"].worktree_path,
               state.run_worktrees["web-app"].worktree_path
             ]
    end

    test "omitted for a provider that does not declare it (pi)", ctx do
      multi = multi_state(ctx)
      assert RunExecutor.__maybe_put_add_dirs_for_test__([cwd: "x"], multi, :pi) == [cwd: "x"]
    end

    # The reason for the provider check, pinned against the harness itself:
    # the request path `Driver.run -> Run.start -> RequestResolver -> RunRequest`
    # carries `add_dirs` into the request for claude, and REJECTS the whole
    # request for pi.
    test "the harness request path keeps add_dirs for claude and rejects it for pi" do
      dirs = [Path.join(System.tmp_dir!(), "extra-dir")]
      attrs = %{prompt: "p", cwd: System.tmp_dir!(), add_dirs: dirs}

      assert {:ok, %Jido.Harness.RunRequest{add_dirs: ^dirs}} =
               Jido.Harness.RequestResolver.resolve(:claude, attrs)

      assert {:error, %Jido.Harness.Error{}} = Jido.Harness.RequestResolver.resolve(:pi, attrs)
    end

    test "a single-repo run is unchanged", ctx do
      assert RunExecutor.__maybe_put_add_dirs_for_test__([cwd: "x"], single_state(ctx), :claude) ==
               [cwd: "x"]
    end
  end

  describe "prompt assigns" do
    test "repositories and repositories_count for a multi-repo run", ctx do
      state = multi_state(ctx)
      assigns = RunExecutor.prompt_template_assigns(state, %{name: "implement"}, 1, %{})

      assert assigns["repositories_count"] == "3"

      assert [%{"id" => "main", "primary" => true} = main, %{"id" => "b"}, %{"id" => "web-app"}] =
               Jason.decode!(assigns["repositories"])

      assert Map.keys(main) |> Enum.sort() == ["branch", "id", "path", "primary"]
      assert main["path"] == state.run_worktrees["main"].worktree_path
    end

    test "a single-repo run has one entry; no worktree has none", ctx do
      assigns = RunExecutor.prompt_template_assigns(single_state(ctx), %{name: "x"}, 1, %{})
      assert assigns["repositories_count"] == "1"
      assert [%{"id" => "main", "primary" => true}] = Jason.decode!(assigns["repositories"])

      none = RunExecutor.prompt_template_assigns(base_state(ctx, %{}), %{name: "x"}, 1, %{})
      assert none["repositories_count"] == "0"
      assert none["repositories"] == "[]"
    end
  end

  # -- helpers -----------------------------------------------------------

  defp init_repo!(root, id) do
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

  defp seed_run!(run_id, project_id) do
    payload = %{run_id: run_id, project_id: project_id}

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
