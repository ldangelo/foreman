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

  defp crash_store! do
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
    assert_receive {:projection_event, _}
    drain_events()

    crash_store!()

    # Live-only: no replay, but the next event reaches it.
    refute_receive {:projection_event, _}, 200
    id2 = register_project()
    assert_receive {:projection_event, _}, 5_000

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

  defp drain_events do
    receive do
      {:projection_event, _} -> drain_events()
    after
      200 -> :ok
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
