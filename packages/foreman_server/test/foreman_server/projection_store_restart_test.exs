defmodule ForemanServer.ProjectionStoreRestartTest do
  # foreman-m75e9: the supervisor restarts a crashed named ProjectionStore with fresh state. Every
  # boot-time subscriber (Dispatcher, watchers, ...) subscribed once and is still alive, so the
  # restarted store must still deliver to it, and must rebuild its projection from the event log.
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandRouter, ProjectionStore}
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup do
    ProjectionStoreReset.reset!(keep_subscribers: true)
    on_exit(fn -> ProjectionStoreReset.reset!(keep_subscribers: true) end)
    :ok
  end

  # The application supervisor gives up (and takes the app down) after more than 3 restarts
  # in 5s. A kill costs more than one restart (dependents of the store/ledger restart too), so
  # allow one kill per window: before each, wait - deterministically - for the previous to age out.
  @restart_window_ms 5_000
  @max_kills_in_window 1

  defp await_restart_budget! do
    now = System.monotonic_time(:millisecond)

    recent =
      for t <- :persistent_term.get({__MODULE__, :kills}, []),
          now - t < @restart_window_ms + 250,
          do: t

    if length(recent) >= @max_kills_in_window do
      oldest = Enum.min(recent)
      Process.sleep(max(oldest + @restart_window_ms + 250 - now, 0))
      await_restart_budget!()
    else
      :persistent_term.put({__MODULE__, :kills}, [now | recent])
    end
  end

  defp crash_store! do
    await_restart_budget!()
    old = Process.whereis(ProjectionStore)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}

    # The supervisor restarts it; a call returns only once the new process is serving.
    new = wait_for_new_store(old, 100)
    _ = ProjectionStore.list_tasks()
    new
  end

  defp wait_for_new_store(old, 0),
    do: flunk("ProjectionStore was not restarted (old #{inspect(old)})")

  defp wait_for_new_store(old, tries) do
    case Process.whereis(ProjectionStore) do
      pid when is_pid(pid) and pid != old ->
        pid

      _ ->
        Process.sleep(20)
        wait_for_new_store(old, tries - 1)
    end
  end

  defp register_project do
    id = "m75e9-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             CommandRouter.dispatch(%{
               type: "project.register",
               payload: %{project_id: id, path: "/tmp/#{id}", config: %{}},
               aggregate_id: "project:#{id}"
             })

    id
  end

  test "the live Dispatcher still receives projection events after the store is crashed" do
    dispatcher = Process.whereis(ForemanServer.Workflow.Dispatcher)
    assert is_pid(dispatcher)
    ProjectionStoreReset.assert_subscribed!(ForemanServer.Workflow.Dispatcher)

    crash_store!()

    ProjectionStoreReset.assert_subscribed!(ForemanServer.Workflow.Dispatcher)

    :erlang.trace(dispatcher, true, [:receive])
    register_project()

    assert_receive {:trace, ^dispatcher, :receive, {:projection_event, _event}}, 5_000
  after
    :erlang.trace(Process.whereis(ForemanServer.Workflow.Dispatcher), false, [:all])
  end

  test "a live-only subscriber keeps receiving; a replaying subscriber gets the log again" do
    parent = self()
    :ok = ProjectionStore.subscribe(replay_existing: false)

    replayer =
      spawn_link(fn ->
        :ok = ProjectionStore.subscribe(replay_existing: true)
        send(parent, :replayer_ready)
        replay_loop(parent)
      end)

    assert_receive :replayer_ready
    flush_forwarded()

    id = register_project()
    assert :ok = await_event_mentioning(id, 5_000)

    crash_store!()

    # Live-only: no replay of what was committed before the crash, but the next event reaches
    # it. Both checks look only at events naming THIS test's projects: the store is a
    # process-wide stream, and another test's leaked executor can emit events at any moment.
    assert :timeout = await_event_mentioning(id, 200)
    id2 = register_project()
    assert :ok = await_event_mentioning(id2, 5_000)

    # Replaying: the whole committed log, both projects, came through the restart.
    assert_forwarded_mentioning(id)
    assert_forwarded_mentioning(id2)

    # The restarted store rebuilt its projection from the event log.
    assert %{} = ProjectionStore.project(id)
    assert %{} = ProjectionStore.project(id2)

    send(replayer, :stop)
  end

  test "a subscriber that died while the store was down is not adopted" do
    pid = spawn(fn -> ProjectionStore.subscribe(replay_existing: false) end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    crash_store!()
    refute ProjectionStoreReset.subscribed?(pid)
  end

  defp crash_ledger! do
    await_restart_budget!()
    old = Process.whereis(ProjectionStore.SubscriberLedger)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}
    old
  end

  # Bounded wait (no fixed sleep) until `fun` returns true.
  defp await_until(fun, tries \\ 250) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached in time")
      true -> Process.sleep(20) && await_until(fun, tries - 1)
    end
  end

  defp await_ledger_resynced(old_ledger, pid) do
    await_until(fn ->
      new = Process.whereis(ProjectionStore.SubscriberLedger)

      is_pid(new) and new != old_ledger and
        Enum.any?(ProjectionStore.SubscriberLedger.list(), &(&1.pid == pid))
    end)
  end

  test "a subscriber survives the ledger being killed and then the store crashing" do
    :ok = ProjectionStore.subscribe(replay_existing: false)
    ProjectionStoreReset.assert_subscribed!(ForemanServer.Workflow.Dispatcher)

    old = crash_ledger!()
    # The store re-puts its live subscribers into the fresh ledger.
    await_ledger_resynced(old, self())

    assert Enum.any?(
             ProjectionStore.SubscriberLedger.list(),
             &(&1.pid == Process.whereis(ForemanServer.Workflow.Dispatcher))
           )

    crash_store!()

    id = register_project()
    assert :ok = await_event_mentioning(id, 5_000)
  end

  test "a replaying subscriber keeps its replay flag through a ledger kill and a store crash" do
    parent = self()

    replayer =
      spawn_link(fn ->
        :ok = ProjectionStore.subscribe(replay_existing: true)
        send(parent, :replayer_ready)
        replay_loop(parent)
      end)

    assert_receive :replayer_ready
    flush_forwarded()

    id = register_project()
    assert_forwarded_mentioning(id)

    old = crash_ledger!()

    await_until(fn ->
      new = Process.whereis(ProjectionStore.SubscriberLedger)

      is_pid(new) and new != old and
        Enum.any?(
          ProjectionStore.SubscriberLedger.list(),
          &(&1.pid == replayer and &1.replay_existing)
        )
    end)

    # Drop everything delivered so far: only a replay can bring `id` back after the crash.
    flush_forwarded()
    crash_store!()

    id2 = register_project()
    assert_forwarded_mentioning(id)
    assert_forwarded_mentioning(id2)

    send(replayer, :stop)
  end

  test "a subscribe made while the ledger is down reaches the ledger after it restarts" do
    old = crash_ledger!()
    # The ledger may already be back; either way the subscriber must end up recorded.
    :ok = ProjectionStore.subscribe(replay_existing: false)
    await_ledger_resynced(old, self())

    crash_store!()
    id = register_project()
    assert :ok = await_event_mentioning(id, 5_000)
  end

  # Consumes `{:projection_event, _}` messages until one mentions `id` (`:ok`) or `timeout_ms`
  # elapse (`:timeout`). Events naming other projects are somebody else's and are skipped.
  defp await_event_mentioning(id, timeout_ms) do
    await_event_mentioning_until(id, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp await_event_mentioning_until(id, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:projection_event, event} ->
        if inspect(event) =~ id,
          do: :ok,
          else: await_event_mentioning_until(id, deadline)
    after
      remaining -> :timeout
    end
  end

  defp assert_forwarded_mentioning(id) do
    receive do
      {:forwarded, {:projection_event, event}} ->
        if inspect(event) =~ id, do: :ok, else: assert_forwarded_mentioning(id)
    after
      5_000 -> flunk("replaying subscriber never got an event mentioning #{id}")
    end
  end

  defp replay_loop(parent) do
    receive do
      :stop ->
        :ok

      msg ->
        send(parent, {:forwarded, msg})
        replay_loop(parent)
    end
  end

  defp flush_forwarded do
    receive do
      {:forwarded, _} -> flush_forwarded()
    after
      200 -> :ok
    end
  end
end
