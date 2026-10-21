defmodule ForemanServer.Threads.IdleResolverTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandGateway, EventStore, ProjectionStore}
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Threads
  alias ForemanServer.Threads.IdleResolver

  @day_ms 86_400_000

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    project = "idle-p-#{uid()}"

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload: %{project_id: project, path: "/tmp/#{project}"}
        }
      ])

    {:ok, project: project}
  end

  defp uid, do: System.unique_integer([:positive])

  # Returns the thread id; the run's activity timestamp is read back so tests
  # can drive the injected clock relative to it.
  defp run_thread(project, status_event) do
    run_id = "idle-r-#{uid()}"

    events =
      [%{event_type: "RunStarted", payload: %{run_id: run_id, project_id: project}}] ++
        status_event_for(status_event, run_id, project)

    :ok = ProjectionStore.apply_events(events)
    {:ok, thread} = Threads.get("run:" <> run_id)
    thread
  end

  defp status_event_for(:running, _run_id, _project), do: []

  defp status_event_for(:completed, run_id, project),
    do: [%{event_type: "RunCompleted", payload: %{run_id: run_id, project_id: project}}]

  defp status_event_for(:failed, run_id, project),
    do: [%{event_type: "RunFailed", payload: %{run_id: run_id, project_id: project}}]

  defp start_resolver(clock_ms) do
    start_supervised!({IdleResolver, now_fun: fn -> clock_ms end, sweep_interval_ms: :manual})
  end

  # `send/2` is asynchronous; a synchronous `:sys.get_state/1` is processed after
  # it, so on return the sweep has finished (the router applies each appended
  # event to the projection before dispatch returns).
  defp sweep(pid) do
    send(pid, :sweep)
    _ = :sys.get_state(pid)
    :ok
  end

  defp events(thread_id) do
    case EventStore.read_stream_forward("thread:" <> thread_id, 0, 99_999) do
      {:ok, recorded} -> Enum.map(recorded, & &1.event_type)
      {:error, :stream_not_found} -> []
    end
  end

  test "terminal, unresolved thread idle for 8 days is resolved with reason idle", %{project: p} do
    thread = run_thread(p, :completed)
    assert thread.status == "completed"
    pid = start_resolver(thread.updated_at + 8 * @day_ms)

    sweep(pid)

    assert events(thread.id) == ["ThreadResolved"]
    assert {:ok, %{resolved: true}} = Threads.get(thread.id)
    assert %{reason: "idle", resolved_by: nil} = ProjectionStore.thread_flags(thread.id)
  end

  test "failed threads are terminal too", %{project: p} do
    thread = run_thread(p, :failed)
    assert thread.status == "failed"
    sweep(start_resolver(thread.updated_at + 8 * @day_ms))
    assert events(thread.id) == ["ThreadResolved"]
  end

  test "the same thread at 6 days idle is untouched", %{project: p} do
    thread = run_thread(p, :completed)
    sweep(start_resolver(thread.updated_at + 6 * @day_ms))
    assert events(thread.id) == []
    assert {:ok, %{resolved: false}} = Threads.get(thread.id)
  end

  test "a running thread idle for 30 days is never resolved", %{project: p} do
    thread = run_thread(p, :running)
    refute thread.status in IdleResolver.terminal_statuses()
    sweep(start_resolver(thread.updated_at + 30 * @day_ms))
    assert events(thread.id) == []
  end

  test "a thread with a pr_url is left to the PR lifecycle", %{project: p} do
    thread = run_thread(p, :completed)

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "PrAssociated",
          payload: %{
            run_id: String.replace_prefix(thread.id, "run:", ""),
            pr_url: "https://github.com/o/r/pull/#{uid()}"
          }
        }
      ])

    assert {:ok, %{pr_url: "https://github.com/" <> _}} = Threads.get(thread.id)
    sweep(start_resolver(thread.updated_at + 30 * @day_ms))
    assert events(thread.id) == []
  end

  test "a second sweep appends no second ThreadResolved", %{project: p} do
    thread = run_thread(p, :completed)
    pid = start_resolver(thread.updated_at + 8 * @day_ms)

    sweep(pid)
    sweep(pid)

    assert events(thread.id) == ["ThreadResolved"]
  end

  test "an already resolved thread is not re-resolved even by a fresh command id", %{project: p} do
    thread = run_thread(p, :completed)

    assert {:ok, _} =
             CommandGateway.dispatch_operator(%{
               type: "thread.resolve",
               command_id: "op-#{uid()}",
               aggregate_id: "thread:" <> thread.id,
               payload: %{thread_id: thread.id, project_id: p, reason: "manual"}
             })

    sweep(start_resolver(thread.updated_at + 30 * @day_ms))

    assert events(thread.id) == ["ThreadResolved"]
    assert %{reason: "manual"} = ProjectionStore.thread_flags(thread.id)
  end

  test "a reopened thread gets another full idle period before it is re-resolved", %{project: p} do
    thread = run_thread(p, :completed)
    t0 = thread.updated_at

    # Idle-resolve, then the operator reopens it "one day ago" on the injected clock.
    sweep(start_resolver(t0 + 8 * @day_ms))
    assert events(thread.id) == ["ThreadResolved"]

    reopened_at = (t0 + 7 * @day_ms) |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

    assert {:ok, _} =
             CommandGateway.dispatch_operator(%{
               type: "thread.reopen",
               command_id: "op-#{uid()}",
               aggregate_id: "thread:" <> thread.id,
               payload: %{thread_id: thread.id, project_id: p, at: reopened_at}
             })

    # 8 days after the last activity but only 1 day after the reopen: untouched.
    sweep(start_resolver_named(:idle_a, t0 + 8 * @day_ms))
    assert events(thread.id) == ["ThreadResolved", "ThreadReopened"]

    # 8 days after the reopen: resolved again.
    sweep(start_resolver_named(:idle_b, t0 + 15 * @day_ms))
    assert events(thread.id) == ["ThreadResolved", "ThreadReopened", "ThreadResolved"]
  end

  defp start_resolver_named(name, clock_ms) do
    start_supervised!(
      {IdleResolver, name: name, now_fun: fn -> clock_ms end, sweep_interval_ms: :manual},
      id: name
    )
  end

  test "the resolver is not part of the test supervision tree" do
    assert Process.whereis(IdleResolver) == nil
  end
end
