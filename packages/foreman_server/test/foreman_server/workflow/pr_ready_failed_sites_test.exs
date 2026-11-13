defmodule ForemanServer.Workflow.PrReadyFailedSitesTest do
  # TRD-033: a failed ready signal is recorded at all three production signalling sites
  # (`RunExecutor.signal_pr_ready/2`, `PrCreate.signal_ready/6`, `RepoPr.signal_ready/2`), each
  # reached through its own entry point; only `gh` is scripted.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.{
    CommandGateway,
    MultiRepoRuns,
    PrCreate,
    ProjectionStore,
    RunPrMerge
  }

  alias ForemanServer.TestSupport.PrFixSupport, as: Fix
  alias ForemanServer.TestSupport.PrWatchSupport, as: Support
  alias ForemanServer.TestSupport.{PrReadyGithub, ProjectionStoreReset}
  alias ForemanServer.Workflow.{MergeGate, RunExecutor}

  defp failed_events(run_id) do
    for event <- Support.run_events(run_id), event.event_type == "PrReadyFailed" do
      event.data |> Jason.encode!() |> Jason.decode!()
    end
  end

  defp delivery_issue(run_id, pr_url) do
    run_id
    |> ProjectionStore.pr_watch()
    |> Enum.find(&(&1.pr_url == pr_url))
    |> then(&(&1 && &1.evidence.delivery_issue))
  end

  describe "RunExecutor.signal_pr_ready/2" do
    @pr_url "https://github.com/acme/repo/pull/3302"

    setup do
      MergeGate.clear()
      repo = Path.join(System.tmp_dir!(), "pr-ready-failed-#{System.unique_integer([:positive])}")
      File.mkdir_p!(repo)
      on_exit(fn -> File.rm_rf(repo) end)

      run = Support.start_run!()

      state = %{
        run_id: run.run_id,
        task: %{task_id: run.task_id, project_id: run.project_id},
        plan_context: %{"project_root" => repo},
        run_base_branch: {:ok, "main"},
        last_worktree: %{branch: "foreman/run-branch"},
        current_phase: nil,
        phase_specs: []
      }

      %{run: run, state: state}
    end

    test "a failed GitHub read is logged, recorded and never engages the gate", %{
      run: run,
      state: state
    } do
      PrReadyGithub.install!(fn _url -> {:error, 13} end)

      log =
        capture_log([level: :error], fn ->
          assert :ok = RunExecutor.__signal_pr_ready_for_test__(state, @pr_url)
        end)

      assert log =~ "head_read_failed"
      refute MergeGate.pending_for_key?("run:#{run.run_id}")
      refute "PrReady" in Support.run_event_types(run.run_id)

      assert [%{"stage" => "head_read", "reason" => "gh_failed:13", "pr_url" => @pr_url} = event] =
               failed_events(run.run_id)

      refute event["repo_id"]

      assert %{stage: "head_read", reason: "gh_failed:13"} = delivery_issue(run.run_id, @pr_url)
    end

    test "the run that already completed still takes the record, and the recovered retry clears it",
         %{run: run, state: state} do
      Support.complete_run!(run.run_id, run.project_id)
      PrReadyGithub.install!(fn _url -> {:error, 1} end)

      capture_log([level: :error], fn ->
        RunExecutor.__signal_pr_ready_for_test__(state, @pr_url)
      end)

      assert [_] = failed_events(run.run_id)
      assert %{reason: "gh_failed:1"} = delivery_issue(run.run_id, @pr_url)

      PrReadyGithub.install!(%{@pr_url => PrReadyGithub.sha("h")})
      assert :ok = RunExecutor.__signal_pr_ready_for_test__(state, @pr_url)
      assert "PrReady" in Support.run_event_types(run.run_id)
      assert delivery_issue(run.run_id, @pr_url) == nil
    end
  end

  describe "PrCreate (the operator Create PR action)" do
    @base "main"
    @head_sha "0123456789abcdef0123456789abcdef01234567"

    setup do
      pr_url = "https://github.com/acme/widgets/pull/#{System.unique_integer([:positive])}"
      {:ok, view} = Agent.start_link(fn -> PrReadyGithub.view_reply(@head_sha) end)

      PrCreate.set_command_runner(fn cmd, args, _opts ->
        case {cmd, args} do
          {"git", ["rev-list" | _]} -> {"2\n", 0}
          {"git", ["rev-parse", "--verify", "refs/heads/" <> _]} -> {@head_sha <> "\n", 0}
          {"git", ["ls-remote" | _]} -> {"", 0}
          {"git", ["push" | _]} -> {"", 0}
          {"gh", ["pr", "view" | _]} -> Agent.get(view, & &1)
          {"gh", ["pr", "list" | _]} -> {"[]\n", 0}
          {"gh", ["pr", "create" | _]} -> {pr_url <> "\n", 0}
          other -> flunk("unexpected command #{inspect(other)}")
        end
      end)

      on_exit(fn ->
        PrCreate.clear_command_runner()
        RunPrMerge.clear_command_runner()
        if Process.alive?(view), do: Agent.stop(view)
      end)

      %{view: view, pr_url: pr_url}
    end

    defp create_thread! do
      repo = Fix.git_repo!()
      project_id = "project-prf-#{System.unique_integer([:positive])}"

      :ok =
        ProjectionStore.apply_events([
          %{event_type: "ProjectRegistered", payload: %{project_id: project_id, path: repo}}
        ])

      run = Support.start_run!(project_id: project_id, complete: true)
      branch = "foreman/#{run.run_id}/implement"

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "TaskCreated",
            payload: %{
              task_id: run.task_id,
              project_id: project_id,
              title: "Add widgets",
              description: "Adds the widget screen",
              status: "open",
              task_type: "implement"
            }
          },
          %{
            event_type: "RunBaseBranchRecorded",
            payload: %{run_id: run.run_id, base_branch: @base}
          },
          %{
            event_type: "WorktreeCreated",
            payload: %{
              operation_id: "wt-#{run.run_id}-implement",
              project_id: project_id,
              run_id: run.run_id,
              phase_id: "implement",
              repo_path: repo,
              worktree_path: "/gone/#{run.run_id}",
              branch: branch,
              base_ref: @base,
              cleanup: "remove"
            }
          }
        ])

      run
    end

    defp create_command(run_id) do
      %{
        type: "run.pr.create",
        command_id: "create-#{run_id}-#{System.unique_integer([:positive])}",
        aggregate_id: "run:#{run_id}",
        payload: %{run_id: run_id}
      }
    end

    test "a failed signal keeps its {:pr_ready_signal_failed, reason} error and is also recorded",
         %{view: view, pr_url: pr_url} do
      run = create_thread!()
      Agent.update(view, fn _ -> {"GraphQL: could not resolve", 1} end)

      assert {:error,
              {:pr_ready_signal_failed,
               {:head_read_failed, {:gh_failed, 1, "GraphQL: could not resolve"}}}} =
               CommandGateway.dispatch_operator(create_command(run.run_id))

      assert [%{"stage" => "head_read", "reason" => "gh_failed:1", "pr_url" => ^pr_url}] =
               failed_events(run.run_id)

      refute inspect(failed_events(run.run_id)) =~ "could not resolve"
      refute "PrReady" in Support.run_event_types(run.run_id)
      assert %{stage: "head_read"} = delivery_issue(run.run_id, pr_url)

      # the retry resumes the open PR, signals again, and the record clears
      Agent.update(view, fn _ -> PrReadyGithub.view_reply(@head_sha) end)
      assert {:ok, _} = CommandGateway.dispatch_operator(create_command(run.run_id))
      assert "PrReady" in Support.run_event_types(run.run_id)
      assert delivery_issue(run.run_id, pr_url) == nil
    end
  end

  describe "RepoPr.finalize/2 (a secondary repository's PR)" do
    setup do
      ProjectionStoreReset.reset!()
      MultiRepoRuns.enable!()
      PrReadyGithub.install!(&PrReadyGithub.sha/1)

      root = Path.join(System.tmp_dir!(), "pr-ready-failed-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      project_id = "proj-prf-#{System.unique_integer([:positive])}"

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

      for {id, wt} <- [
            {"a", primary.worktree_path},
            {"b", state.run_worktrees["b"].worktree_path}
          ] do
        File.write!(Path.join(wt, "work-#{id}.txt"), "work")
        git!(wt, ["add", "."])
        git!(wt, ["commit", "--no-gpg-sign", "-q", "-m", "work #{id}"])
      end

      %{run_id: run_id, state: state}
    end

    test "the failure record carries the secondary's repo_id; the primary's does not; the run goes on",
         %{run_id: run_id, state: state} do
      PrReadyGithub.install!(fn url ->
        if String.contains?(url, "repo-b"), do: {:error, 1}, else: PrReadyGithub.sha(url)
      end)

      capture_log([level: :error], fn ->
        assert [{"main", {:ok, a_url}}, {"b", {:ok, b_url}}] =
                 RunExecutor.__finalize_repo_prs_for_test__(state)

        send(self(), {:urls, a_url, b_url})
      end)

      assert_received {:urls, a_url, b_url}

      assert [
               %{
                 "repo_id" => "b",
                 "pr_url" => ^b_url,
                 "stage" => "head_read",
                 "reason" => "gh_failed:1"
               }
             ] =
               failed_events(run_id)

      assert %{stage: "head_read"} = delivery_issue(run_id, b_url)
      assert delivery_issue(run_id, a_url) == nil

      # recovery: the next finalisation signals b, and its record clears
      PrReadyGithub.install!(&PrReadyGithub.sha/1)
      RunExecutor.__finalize_repo_prs_for_test__(state)
      assert delivery_issue(run_id, b_url) == nil
    end

    defp fake_gh(dir) do
      """
      #!/bin/sh
      DIR="#{dir}"
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

    defp seed_run!(run_id, project_id, repo_ids) do
      payload = %{run_id: run_id, project_id: project_id, task_id: "task-1", repo_ids: repo_ids}

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
end
