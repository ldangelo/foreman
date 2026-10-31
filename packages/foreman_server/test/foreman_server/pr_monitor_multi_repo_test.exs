defmodule ForemanServer.PrMonitorMultiRepoTest do
  @moduledoc """
  E12-S7: a PR is addressed as `{run_id, repo_id}`. A run that opened a PR in two
  repositories (a = the primary, b) is polled and webhook-updated per PR; a state
  change of b's PR never touches a's PR, watch record or gate, and a fix for b's PR
  runs only against b's repository and worktree.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.PrAssociate
  alias ForemanServer.PrMonitor
  alias ForemanServer.PrFix
  alias ForemanServer.PrUpdate
  alias ForemanServer.PrWatcher.Observer
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.PrFixSupport
  alias ForemanServer.TestSupport.PrWatchSupport, as: Support
  alias ForemanServer.Webhooks.Github

  setup do
    on_exit(fn -> :persistent_term.erase({PrMonitor, :fetch_fun}) end)

    token = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    project_id = "project-s7-#{token}"
    repo_a = PrFixSupport.git_repo!("s7a")
    repo_b = PrFixSupport.git_repo!("s7b")

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload: %{project_id: project_id, path: repo_a, thread_model: "sonnet"}
        },
        %{
          event_type: "ProjectRepositoryAdded",
          payload: %{
            project_id: project_id,
            repo_id: "b",
            path: repo_b,
            default_branch: nil,
            vcs: %{adapter: "git"},
            task_provider: nil,
            added_by: "operator:test",
            at: "2026-01-01T00:00:00Z"
          }
        }
      ])

    run = start_two_repo_run!(project_id)
    a_url = "https://github.com/acme/a-#{token}/pull/1"
    b_url = "https://github.com/acme/b-#{token}/pull/2"
    {:ok, _} = PrAssociate.store(run.run_id, a_url)
    {:ok, _} = PrAssociate.store(run.run_id, b_url, "b")

    {:ok, Map.merge(run, %{a_url: a_url, b_url: b_url, repo_a: repo_a, repo_b: repo_b})}
  end

  # `Support.start_run!/1` has no `repo_ids`; the run must touch b for its
  # `run_repositories/1` entry to exist.
  defp start_two_repo_run!(project_id) do
    run = Support.start_run!(project_id: project_id)

    started = %{
      run_id: run.run_id,
      project_id: project_id,
      task_id: run.task_id,
      workflow_snapshot: %{},
      repo_ids: ["b"]
    }

    :ok = ProjectionStore.apply_events([%{event_type: "RunStarted", payload: started}])
    Support.complete_run!(run.run_id, project_id)
    run
  end

  defp stub(results) do
    PrMonitor.set_fetch_fun(fn url ->
      case Map.fetch(results, url) do
        {:ok, result} -> {:ok, result}
        :error -> {:error, :not_this_test}
      end
    end)
  end

  defp pr_updated(run_id) do
    for e <- Support.run_events(run_id), e.event_type == "PrUpdated", do: e.data
  end

  defp field(data, key), do: Map.get(data, key) || Map.get(data, Atom.to_string(key))

  defp record(run_id, url),
    do: run_id |> ProjectionStore.pr_watch() |> Enum.find(&(&1.pr_url == url))

  describe "enumeration" do
    test "run_ids_for_pr_url answers {run_id, repo_id} per association", ctx do
      run_id = ctx.run_id
      assert [{^run_id, "main"}] = ProjectionStore.run_ids_for_pr_url(ctx.a_url)
      assert [{^run_id, "b"}] = ProjectionStore.run_ids_for_pr_url(ctx.b_url)
      assert [] = ProjectionStore.run_ids_for_pr_url(ctx.a_url <> "9")
    end

    test "watched_prs lists the unobserved PR of each repository, b carrying its repo_id", ctx do
      mine = Enum.filter(ProjectionStore.watched_prs(), &(&1.run_id == ctx.run_id))
      assert [%{repo_id: nil}, %{repo_id: "b"}] = Enum.sort_by(mine, & &1.pr_url)
      assert Enum.map(Enum.sort_by(mine, & &1.pr_url), & &1.pr_url) == [ctx.a_url, ctx.b_url]
    end
  end

  describe "PrUpdate payload" do
    test "repo_id only for a non-primary repository", ctx do
      pr = Support.status()
      assert {:ok, %{payload: primary}} = PrUpdate.command(ctx.run_id, ctx.a_url, pr, "main")
      refute Map.has_key?(primary, :repo_id)
      assert {:ok, %{payload: legacy}} = PrUpdate.command(ctx.run_id, ctx.a_url, pr)
      refute Map.has_key?(legacy, :repo_id)

      assert {:ok, %{payload: other, command_id: id_b}} =
               PrUpdate.command(ctx.run_id, ctx.b_url, pr, "b")

      assert other.repo_id == "b"
      assert {:ok, %{command_id: id_a}} = PrUpdate.command(ctx.run_id, ctx.a_url, pr)
      assert id_a != id_b
    end
  end

  describe "PrMonitor polls every PR of the run" do
    setup do
      start_supervised!(PrMonitor)
      :ok
    end

    test "b merged updates b only; a stays open; a repeat poll appends nothing", ctx do
      stub(%{
        ctx.a_url => Support.status(status: :open, head_sha: "same"),
        ctx.b_url => Support.status(status: :merged, head_sha: "same")
      })

      PrMonitor.poll_now()

      updates = pr_updated(ctx.run_id)
      assert length(updates) == 2
      a = Enum.find(updates, &(field(&1, :pr_url) == ctx.a_url))
      b = Enum.find(updates, &(field(&1, :pr_url) == ctx.b_url))
      assert field(a, :pr_status) == :open or field(a, :pr_status) == "open"
      refute Map.has_key?(a, :repo_id) or Map.has_key?(a, "repo_id")
      assert field(b, :repo_id) == "b"
      assert to_string(field(b, :pr_status)) == "merged"

      assert %{watching: true, status: "open", repo_id: nil} = record(ctx.run_id, ctx.a_url)
      assert %{watching: false, status: "merged", repo_id: "b"} = record(ctx.run_id, ctx.b_url)

      assert [%{repo_id: "main", pr_state: :open}, %{repo_id: "b", pr_state: :merged}] =
               ProjectionStore.run_repositories(ctx.run_id)

      PrMonitor.poll_now()
      assert length(pr_updated(ctx.run_id)) == 2
    end
  end

  describe "webhook" do
    defp merged_payload(url) do
      %{
        "action" => "closed",
        "pull_request" => %{
          "html_url" => url,
          "merged" => true,
          "head" => %{"sha" => "same", "ref" => "foreman/x"},
          "base" => %{"ref" => "main"}
        }
      }
    end

    test "a merged PR of b updates b's record only", ctx do
      assert :ok = Github.process(merged_payload(ctx.b_url))

      assert [update] = pr_updated(ctx.run_id)
      assert field(update, :pr_url) == ctx.b_url
      assert field(update, :repo_id) == "b"
      assert nil == record(ctx.run_id, ctx.a_url)
      assert %{status: "merged", repo_id: "b"} = record(ctx.run_id, ctx.b_url)

      assert [%{repo_id: "main", pr_state: a_state}, %{repo_id: "b", pr_state: :merged}] =
               ProjectionStore.run_repositories(ctx.run_id)

      assert a_state != :merged
    end

    test "a's PR url yields a command without repo_id; unknown url yields none", ctx do
      assert {:ok, [%{payload: payload}]} = Github.build_commands(merged_payload(ctx.a_url))
      refute Map.has_key?(payload, :repo_id)
      assert :ignored = Github.build_commands(merged_payload(ctx.a_url <> "9"))
    end
  end

  describe "fix thread confinement" do
    test "a fix for b's PR attaches b's repository and b's worktree only", ctx do
      head = "foreman/#{ctx.run_id}/b-pr"
      status = Support.status(head_branch: head, checks_state: :failing)
      stub = fn _ -> {:ok, status} end
      assert {:ok, _} = Observer.observe(ctx.b_url, fetch_fun: stub, auto_fix: false)

      b_path = Path.join(System.tmp_dir!(), "s7-wt-b-#{ctx.run_id}")
      a_path = Path.join(System.tmp_dir!(), "s7-wt-a-#{ctx.run_id}")

      worktree = fn op, path, repo_path, repo_id ->
        payload =
          %{
            operation_id: op,
            project_id: ctx.project_id,
            run_id: ctx.run_id,
            phase_id: "implement",
            repo_path: repo_path,
            worktree_path: path,
            branch: "foreman/#{ctx.run_id}/run",
            base_ref: "main",
            cleanup: "remove"
          }
          |> then(&if repo_id, do: Map.put(&1, :repo_id, repo_id), else: &1)

        %{event_type: "WorktreeCreated", payload: payload}
      end

      # The primary's operation id sorts LAST: a run-wide "last worktree" fallback
      # would pick a's path for b's PR.
      :ok =
        ProjectionStore.apply_events([
          worktree.("wt-#{ctx.run_id}-b", b_path, ctx.repo_b, "b"),
          worktree.("wt-#{ctx.run_id}-z", a_path, ctx.repo_a, nil)
        ])

      assert {:ok, plan} = PrFix.plan("ci", ctx.run_id, ctx.b_url, fetch_fun: stub)
      assert plan.jobsite_opts[:repo_path] == ctx.repo_b
      assert plan.jobsite_opts[:path] == b_path
    end

    test "a fix for a's PR still uses the primary repository and worktree", ctx do
      head = "foreman/#{ctx.run_id}/a-pr"
      status = Support.status(head_branch: head, checks_state: :failing)
      stub = fn _ -> {:ok, status} end
      assert {:ok, _} = Observer.observe(ctx.a_url, fetch_fun: stub, auto_fix: false)

      a_path = Path.join(System.tmp_dir!(), "s7-wt-a-#{ctx.run_id}")

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "WorktreeCreated",
            payload: %{
              operation_id: "wt-#{ctx.run_id}-a",
              project_id: ctx.project_id,
              run_id: ctx.run_id,
              phase_id: "implement",
              repo_path: ctx.repo_a,
              worktree_path: a_path,
              branch: "foreman/#{ctx.run_id}/run",
              base_ref: "main",
              cleanup: "remove"
            }
          },
          %{
            event_type: "WorktreeCreated",
            payload: %{
              operation_id: "wt-#{ctx.run_id}-z",
              project_id: ctx.project_id,
              run_id: ctx.run_id,
              phase_id: "implement",
              repo_id: "b",
              repo_path: ctx.repo_b,
              worktree_path: "/nonexistent/b",
              branch: "foreman/#{ctx.run_id}/run",
              base_ref: "main",
              cleanup: "remove"
            }
          }
        ])

      assert {:ok, plan} = PrFix.plan("ci", ctx.run_id, ctx.a_url, fetch_fun: stub)
      assert plan.jobsite_opts[:repo_path] == ctx.repo_a
      assert plan.jobsite_opts[:path] == a_path
    end

    # The run's agent ran in the PRIMARY's worktree, so every persisted provider session is bound
    # to that cwd (pi refuses to resume from another directory): a non-primary fix must not resume it.
    test "a fix for b's PR never resumes the primary-bound session; a's PR does", ctx do
      session = fn kind, url ->
        head = "foreman/#{ctx.run_id}/#{kind}-pr"
        status = Support.status(head_branch: head, checks_state: :failing)
        stub = fn _ -> {:ok, status} end
        assert {:ok, _} = Observer.observe(url, fetch_fun: stub, auto_fix: false)
        stub
      end

      stub_b = session.("b", ctx.b_url)
      stub_a = session.("a", ctx.a_url)

      wt = fn op, path, repo_path, repo_id ->
        payload =
          %{
            operation_id: op,
            project_id: ctx.project_id,
            run_id: ctx.run_id,
            phase_id: "implement",
            repo_path: repo_path,
            worktree_path: path,
            branch: "foreman/#{ctx.run_id}/run",
            base_ref: "main",
            cleanup: "remove"
          }
          |> then(&if repo_id, do: Map.put(&1, :repo_id, repo_id), else: &1)

        %{event_type: "WorktreeCreated", payload: payload}
      end

      :ok =
        ProjectionStore.apply_events([
          wt.(
            "wt-#{ctx.run_id}-b",
            Path.join(System.tmp_dir!(), "s7-rs-b-#{ctx.run_id}"),
            ctx.repo_b,
            "b"
          ),
          wt.(
            "wt-#{ctx.run_id}-a",
            Path.join(System.tmp_dir!(), "s7-rs-a-#{ctx.run_id}"),
            ctx.repo_a,
            nil
          )
        ])

      :ok = PrFixSupport.session_bound!(ctx, "pi", "m", "sess-primary")

      assert {:ok, plan_a} = PrFix.plan("ci", ctx.run_id, ctx.a_url, fetch_fun: stub_a)
      assert plan_a.resumed_session
      assert plan_a.jobsite_opts[:resume_session] == "sess-primary"

      assert {:ok, plan_b} = PrFix.plan("ci", ctx.run_id, ctx.b_url, fetch_fun: stub_b)
      refute plan_b.resumed_session
      refute Keyword.has_key?(plan_b.jobsite_opts, :resume_session)
      assert plan_b.jobsite_opts[:agent].provider == :pi
    end
  end
end
