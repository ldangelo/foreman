defmodule ForemanServer.Overview.MergeResolverTest do
  use ExUnit.Case, async: false

  alias ForemanServer.EventStore
  alias ForemanServer.Overview.MergeResolver
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Threads

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok = ProjectionStore.subscribe(replay_existing: false)

    project = "merge-p-#{System.unique_integer([:positive])}"

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload: %{
            project_id: project,
            path: "/tmp/" <> project,
            task_provider: %{type: "beads"}
          }
        }
      ])

    {:ok, project: project}
  end

  defp uid, do: System.unique_integer([:positive])

  defp start_run(project, extra \\ []) do
    run_id = "mr-#{uid()}"

    :ok =
      ProjectionStore.apply_events(
        [
          %{
            event_type: "RunStarted",
            payload: %{run_id: run_id, task_id: "t-" <> run_id, project_id: project}
          },
          %{event_type: "RunCompleted", payload: %{run_id: run_id, project_id: project}},
          %{
            event_type: "PrReady",
            payload: %{run_id: run_id, pr_url: "https://g/p/#{uid()}", head_sha: "sha-" <> run_id}
          }
        ] ++ extra
      )

    run_id
  end

  defp event(type, payload), do: %{event_type: type, payload: payload}

  defp start_resolver(opts \\ []) do
    pid = start_supervised!({MergeResolver, Keyword.put_new(opts, :name, :merge_resolver_test)})
    # handle_continue(:catch_up) has finished once any call returns.
    _ = :sys.get_state(pid)
    pid
  end

  defp stream(thread_id) do
    case EventStore.read_stream_forward("thread:" <> thread_id, 0, 99_999) do
      {:ok, recorded} -> Enum.map(recorded, & &1.event_type)
      {:error, :stream_not_found} -> []
    end
  end

  # The projection is shared and broadcasts every test's events: wait for THIS thread's.
  defp await_resolved(thread_id) do
    assert_receive {:projection_event,
                    %{event_type: "ThreadResolved", data: %{thread_id: ^thread_id}}},
                   5_000
  end

  test "merging a PR resolves its thread with reason pr_merged; a later merged PrUpdated adds nothing",
       %{project: p} do
    start_resolver()
    run_id = start_run(p)
    thread_id = "run:" <> run_id

    :ok = ProjectionStore.apply_events([event("PrMerged", %{run_id: run_id})])
    await_resolved(thread_id)

    assert %{resolved: true, reason: "pr_merged", resolved_by: "system"} =
             ProjectionStore.thread_flags(thread_id)

    # the thread is already resolved, so the follow-up merge signal dispatches nothing
    :ok =
      ProjectionStore.apply_events([
        event("PrUpdated", %{run_id: run_id, pr_status: "merged", head_sha: "sha-" <> run_id})
      ])

    _ = :sys.get_state(:merge_resolver_test)
    assert stream(thread_id) == ["ThreadResolved"]
  end

  test "a PrUpdated that is not a merge resolves nothing; a later merge of another run does",
       %{project: p} do
    start_resolver()
    open_run = start_run(p)
    closed_run = start_run(p)
    merged_run = start_run(p)

    :ok =
      ProjectionStore.apply_events([
        event("PrUpdated", %{run_id: open_run, pr_status: "open"}),
        event("PrUpdated", %{run_id: closed_run, pr_status: "closed"}),
        event("PrUpdated", %{run_id: merged_run, pr_status: "merged", head_sha: "m"})
      ])

    await_resolved("run:" <> merged_run)
    assert stream("run:" <> open_run) == []
    assert stream("run:" <> closed_run) == []
    assert {:ok, %{resolved: false}} = Threads.get("run:" <> closed_run)
  end

  test "catch-up resolves a merge that happened while the resolver was down", %{project: p} do
    run_id = start_run(p)
    :ok = ProjectionStore.apply_events([event("PrMerged", %{run_id: run_id})])
    assert stream("run:" <> run_id) == []

    start_resolver()
    await_resolved("run:" <> run_id)
    assert stream("run:" <> run_id) == ["ThreadResolved"]
  end

  test "catch-up never re-resolves a thread the operator reopened after the merge", %{project: p} do
    reopened = start_run(p)
    fresh = start_run(p)

    :ok =
      ProjectionStore.apply_events([
        event("PrMerged", %{run_id: reopened}),
        event("ThreadResolved", %{
          thread_id: "run:" <> reopened,
          project_id: p,
          reason: "pr_merged",
          resolved_by: "system",
          source: "system",
          at: "2026-10-20T00:00:00Z"
        }),
        event("ThreadReopened", %{
          thread_id: "run:" <> reopened,
          project_id: p,
          at: "2026-10-21T00:00:00Z"
        }),
        event("PrMerged", %{run_id: fresh})
      ])

    assert {:ok, %{resolved: false}} = Threads.get("run:" <> reopened)

    start_resolver()
    await_resolved("run:" <> fresh)

    assert {:ok, %{resolved: false}} = Threads.get("run:" <> reopened)
    assert stream("run:" <> reopened) == []
  end

  test "live path: a thread reopened after the merge is not resolved again by a later merged PrUpdated",
       %{project: p} do
    run_id = start_run(p)
    thread_id = "run:" <> run_id
    reopened_at = "2026-10-21T00:00:00Z"
    {:ok, reopened_dt, _offset} = DateTime.from_iso8601(reopened_at)
    reopened_ms = DateTime.to_unix(reopened_dt, :millisecond)

    :ok =
      ProjectionStore.apply_events([
        event("PrMerged", %{run_id: run_id}),
        event("ThreadResolved", %{
          thread_id: thread_id,
          project_id: p,
          reason: "operator",
          resolved_by: "op",
          source: "operator",
          at: "2026-10-20T00:00:00Z"
        }),
        event("ThreadReopened", %{thread_id: thread_id, project_id: p, at: reopened_at})
      ])

    assert {:ok, %{resolved: false}} = Threads.get(thread_id)
    start_resolver()

    # A poll that observed the merge BEFORE the reopen: the folded state is
    # merged, but the operator's reopen is newer, so the thread stays open.
    :ok =
      ProjectionStore.apply_events([
        event("PrUpdated", %{
          run_id: run_id,
          pr_status: "merged",
          head_sha: "stale",
          observed_at: reopened_ms - 1_000
        })
      ])

    _ = :sys.get_state(:merge_resolver_test)
    assert {:ok, %{resolved: false}} = Threads.get(thread_id)
    assert stream(thread_id) == []

    # Positive control: a merge observed after the reopen does resolve it.
    :ok =
      ProjectionStore.apply_events([
        event("PrUpdated", %{
          run_id: run_id,
          pr_status: "merged",
          head_sha: "fresh",
          observed_at: reopened_ms + 1_000
        })
      ])

    await_resolved(thread_id)
    assert stream(thread_id) == ["ThreadResolved"]
  end

  # A thread older than the newest `Threads.max_limit/0` threads must still be found.
  defp start_old_run_behind_a_full_window(project) do
    Process.put(:projection_store_now_ms, fn -> 1_000 end)
    old_run = start_run(project)

    Process.put(:projection_store_now_ms, fn -> 2_000 end)

    :ok =
      ProjectionStore.apply_events(
        for _ <- 1..Threads.max_limit() do
          id = "fill-#{uid()}"
          event("RunStarted", %{run_id: id, task_id: "t-" <> id, project_id: project})
        end
      )

    Process.put(:projection_store_now_ms, fn -> 1_500 end)
    old_run
  end

  test "live path: a merge of a thread outside the newest-window still resolves it", %{project: p} do
    start_resolver()
    run_id = start_old_run_behind_a_full_window(p)
    thread_id = "run:" <> run_id

    assert length(Threads.list(p, limit: Threads.max_limit())) == Threads.max_limit()
    refute thread_id in Enum.map(Threads.list(p, limit: Threads.max_limit()), & &1.id)

    :ok = ProjectionStore.apply_events([event("PrMerged", %{run_id: run_id})])
    Process.delete(:projection_store_now_ms)

    await_resolved(thread_id)
    assert stream(thread_id) == ["ThreadResolved"]
  end

  test "catch-up resolves a merged thread outside the newest-window", %{project: p} do
    run_id = start_old_run_behind_a_full_window(p)
    thread_id = "run:" <> run_id
    :ok = ProjectionStore.apply_events([event("PrMerged", %{run_id: run_id})])
    Process.delete(:projection_store_now_ms)

    refute thread_id in Enum.map(Threads.list(p, limit: Threads.max_limit()), & &1.id)

    start_resolver()
    await_resolved(thread_id)
    assert stream(thread_id) == ["ThreadResolved"]
  end

  test "an already-resolved thread is not resolved again", %{project: p} do
    run_id = start_run(p)

    :ok =
      ProjectionStore.apply_events([
        event("ThreadResolved", %{
          thread_id: "run:" <> run_id,
          project_id: p,
          reason: "operator",
          resolved_by: "op",
          source: "operator",
          at: "2026-10-20T00:00:00Z"
        }),
        event("PrMerged", %{run_id: run_id})
      ])

    start_resolver()
    assert stream("run:" <> run_id) == []
  end

  test "the resolver can only resolve: it never references the merge gate commands" do
    source = File.read!(Path.join(File.cwd!(), "lib/foreman_server/overview/merge_resolver.ex"))
    code = source |> String.split("\"\"\"") |> List.last()

    refute code =~ "merge_approve"
    refute code =~ "run.pr.merge"
    refute code =~ "run.pr.approve"
  end

  # foreman-w0tnj: a run that opened a PR in two repositories (a = the primary, b = `repo_id: "b"`)
  # resolves its thread only when no PR of either repository is still live.
  describe "a run with PRs in several repositories" do
    defp open_b_pr(run_id) do
      url = "https://g/b/#{uid()}"

      :ok =
        ProjectionStore.apply_events([
          event("PrReady", %{run_id: run_id, repo_id: "b", pr_url: url, head_sha: "sha-b"})
        ])

      url
    end

    defp merged_b(run_id, url) do
      event("PrMerged", %{run_id: run_id, repo_id: "b", pr_url: url})
    end

    test "merging the primary's PR leaves the thread open while b's PR is open; b's merge resolves it once",
         %{project: p} do
      start_resolver()
      run_id = start_run(p)
      thread_id = "run:" <> run_id
      b_url = open_b_pr(run_id)

      :ok = ProjectionStore.apply_events([event("PrMerged", %{run_id: run_id})])
      _ = :sys.get_state(:merge_resolver_test)

      assert {:ok, %{resolved: false}} = Threads.get(thread_id)
      assert stream(thread_id) == []

      :ok = ProjectionStore.apply_events([merged_b(run_id, b_url)])
      await_resolved(thread_id)

      assert %{resolved: true, reason: "pr_merged", resolved_by: "system"} =
               ProjectionStore.thread_flags(thread_id)

      assert stream(thread_id) == ["ThreadResolved"]
    end

    test "b merging first changes nothing until the primary's PR merges too", %{project: p} do
      start_resolver()
      run_id = start_run(p)
      thread_id = "run:" <> run_id
      b_url = open_b_pr(run_id)

      :ok = ProjectionStore.apply_events([merged_b(run_id, b_url)])
      _ = :sys.get_state(:merge_resolver_test)
      assert stream(thread_id) == []

      :ok = ProjectionStore.apply_events([event("PrMerged", %{run_id: run_id})])
      await_resolved(thread_id)
      assert stream(thread_id) == ["ThreadResolved"]
    end

    test "the primary merged and b closed unmerged resolves; both closed resolves nothing",
         %{project: p} do
      start_resolver()
      merged_and_closed = start_run(p)
      b_closed = open_b_pr(merged_and_closed)
      both_closed = start_run(p)
      b_closed_too = open_b_pr(both_closed)

      :ok =
        ProjectionStore.apply_events([
          event("PrUpdated", %{
            run_id: both_closed,
            repo_id: "b",
            pr_url: b_closed_too,
            pr_status: "closed"
          }),
          event("PrUpdated", %{run_id: both_closed, pr_status: "closed"}),
          event("PrUpdated", %{
            run_id: merged_and_closed,
            repo_id: "b",
            pr_url: b_closed,
            pr_status: "closed"
          }),
          event("PrMerged", %{run_id: merged_and_closed})
        ])

      await_resolved("run:" <> merged_and_closed)
      assert stream("run:" <> both_closed) == []
    end

    test "catch-up leaves a thread open while b's PR is open and resolves it once both merged",
         %{project: p} do
      half = start_run(p)
      half_b = open_b_pr(half)
      whole = start_run(p)
      whole_b = open_b_pr(whole)

      :ok =
        ProjectionStore.apply_events([
          event("PrMerged", %{run_id: half}),
          event("PrMerged", %{run_id: whole}),
          merged_b(whole, whole_b)
        ])

      start_resolver()
      await_resolved("run:" <> whole)

      assert stream("run:" <> half) == []
      assert {:ok, %{resolved: false}} = Threads.get("run:" <> half)

      # positive control for the sweep above: the live path takes over once b merges.
      :ok = ProjectionStore.apply_events([merged_b(half, half_b)])
      await_resolved("run:" <> half)
      assert stream("run:" <> half) == ["ThreadResolved"]
    end
  end
end
