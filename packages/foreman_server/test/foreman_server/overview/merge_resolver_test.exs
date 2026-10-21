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

  defp await_resolved(thread_id) do
    assert_receive {:projection_event, %{event_type: "ThreadResolved", data: data}}, 5_000

    case field(data, :thread_id) do
      ^thread_id -> :ok
      _other -> await_resolved(thread_id)
    end
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  test "merging a PR resolves its thread exactly once, with reason pr_merged", %{project: p} do
    start_resolver()
    run_id = start_run(p)
    thread_id = "run:" <> run_id

    :ok = ProjectionStore.apply_events([event("PrMerged", %{run_id: run_id})])
    await_resolved(thread_id)

    assert %{resolved: true, reason: "pr_merged", resolved_by: "system"} =
             ProjectionStore.thread_flags(thread_id)

    # a duplicate merge signal is deduplicated by command_id
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
end
