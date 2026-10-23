defmodule ForemanServer.Workflow.LiveSteeringTest do
  @moduledoc """
  Live mid-phase steering end to end (docs/plans/live-steering.md): operator
  `run.steer` -> Dispatcher -> `LiveSteer.deliver/2` -> a REAL `JidoHarnessWorker`
  running a REAL harness run of the claude adapter against a CLI that replays
  records captured from claude 2.1.308 (`jido_harness/test/support/fixtures`).

  No pause is requested and the message is taken inside the running session.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.{CommandGateway, CommandRouter, ProjectionStore, RunAdmission, RunControl}
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.Overwatch.Adapters.JidoHarnessWorker
  alias ForemanServer.TestSupport.RunSlotsReset
  alias ForemanServer.Workflow.LiveSteer

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:eventstore)

    ensure_started({Phoenix.PubSub, name: ForemanServer.PubSub}, ForemanServer.PubSub)
    ensure_started(ForemanServerWeb.Presence, ForemanServerWeb.Presence)
    ensure_started(ForemanServer.EventStore, ForemanServer.EventStore)
    ensure_started(ForemanServer.ProjectionStore, ForemanServer.ProjectionStore)
    ensure_started(ForemanServer.Aggregator, ForemanServer.Aggregator)
    ensure_started(ForemanServer.CommandRouter, ForemanServer.CommandRouter)
    ensure_started(ForemanServer.TaskProvider.Registry, ForemanServer.TaskProvider.Registry)

    ensure_started(
      {Registry, keys: :unique, name: ForemanServer.RunExecutorRegistry},
      ForemanServer.RunExecutorRegistry
    )

    ensure_started(
      ForemanServer.AgentRuntime.AdapterCatalog,
      ForemanServer.AgentRuntime.AdapterCatalog
    )

    ensure_started(ForemanServer.Workflow.Catalog, ForemanServer.Workflow.Catalog)
    ensure_started(ForemanServer.Workflow.RunSupervisor, ForemanServer.Workflow.RunSupervisor)
    ensure_started(ForemanServer.RunControl, ForemanServer.RunControl)
    ensure_started(ForemanServer.Overwatch.Tracker, ForemanServer.Overwatch.Tracker)
    ensure_started(ForemanServer.Workflow.Dispatcher, ForemanServer.Workflow.Dispatcher)
    :ok
  end

  setup do
    RunSlotsReset.reset!()
    ensure_dispatcher_subscribed()
    :ok = ProjectionStore.subscribe()

    fixtures = Path.join([Mix.Project.deps_paths()[:jido_harness], "test", "support", "fixtures"])
    original = Application.get_env(:jido_harness, :provider_config, %{})

    Application.put_env(
      :jido_harness,
      :provider_config,
      Map.put(original, :claude, %{cli_path: Path.join(fixtures, "fake_claude_live.py")})
    )

    System.put_env("TURN_SECONDS", "2")

    run_id = "run-live-#{Elixir.EventStore.UUID.uuid4()}"
    project_id = "project-#{run_id}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        aggregate_id: "project:#{project_id}",
        command_id: "register:#{project_id}",
        type: "project.register",
        payload: %{project_id: project_id, name: "live #{run_id}", path: System.tmp_dir!()}
      })

    {:ok, _} =
      RunAdmission.start(project_id, %{
        run_id: run_id,
        task_id: "task-#{run_id}",
        project_id: project_id,
        workflow_snapshot: %{}
      })

    on_exit(fn ->
      System.delete_env("TURN_SECONDS")
      Application.put_env(:jido_harness, :provider_config, original)
      RunControl.clear(run_id)
    end)

    {:ok, run_id: run_id}
  end

  test "a steer to a running live claude phase is delivered and consumed in-session, with no pause",
       %{run_id: run_id} do
    worker = start_worker(run_id, :claude)
    harness_run_id = await_agent(run_id)
    await_harness_event(harness_run_id, &(&1.type == :input_accepted))

    steer!(run_id, "m1", "use tabs")

    assert_event("RunSteerQueued", run_id)
    assert_event("RunSteerDelivered", run_id)
    assert_event("RunSteerConsumed", run_id)

    types = event_types(run_id)
    refute "RunPaused" in types

    assert %{data: consumed} =
             Enum.find(stream_events(run_id), &(&1.event_type == "RunSteerConsumed"))

    assert (Map.get(consumed, :delivery) || Map.get(consumed, "delivery")) == "live"
    assert ProjectionStore.pending_steering(run_id) == []

    ref = Process.monitor(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 20_000
  end

  test "a steer pending when the run ends is recorded RunSteerUndelivered, never left silent",
       %{run_id: run_id} do
    # No agent is running: the steer takes the pause path and stays pending.
    steer!(run_id, "m1", "never read", %{resume: false})
    assert_event("RunPaused", run_id)
    assert [%{message_id: "m1", delivered: false}] = ProjectionStore.pending_steering(run_id)

    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: "run.cancel",
        command_id: "cancel-#{run_id}",
        aggregate_id: "run:#{run_id}",
        payload: %{run_id: run_id}
      })

    assert_event("RunSteerUndelivered", run_id)
    assert ProjectionStore.pending_steering(run_id) == []

    assert [%{message_id: "m1", text: "never read", reason: "run_cancelled"}] =
             ProjectionStore.undelivered_steering(run_id)
  end

  test "an agent that cannot take live input is refused with a typed error, not delivered", %{
    run_id: run_id
  } do
    assert {:error, :no_agent} = LiveSteer.deliver(run_id, %{message_id: "m1", text: "x"})

    :ok = RunControl.register_agent(run_id, "run-that-never-existed")
    assert {:error, :not_found} = LiveSteer.deliver(run_id, %{message_id: "m1", text: "x"})
  end

  defp start_worker(run_id, provider) do
    worker_id = "worker-#{Elixir.EventStore.UUID.uuid4()}"

    pid =
      start_supervised!(%{
        id: {JidoHarnessWorker, worker_id},
        start:
          {JidoHarnessWorker, :start_link,
           [
             [
               worker_id: worker_id,
               run_id: run_id,
               provider: provider,
               prompt: "first",
               project_id: "project-#{run_id}",
               task_id: "task-#{run_id}",
               driver_opts:
                 LiveSteer.put_driver_opts([cwd: System.tmp_dir!(), timeout: 60_000], provider)
             ]
           ]},
        restart: :temporary
      })

    :ok =
      ForemanServer.Overwatch.Tracker.register(
        ForemanServer.Overwatch.Tracker,
        worker_id,
        run_id,
        pid
      )

    send(pid, {:overwatch_activate, worker_id, run_id, self()})
    assert_receive {:overwatch_activated, ^pid}, 5_000
    pid
  end

  # Observables that have no event to wait on: the worker registers its harness run
  # asynchronously, and the harness journals the first echo asynchronously.
  defp await_agent(run_id, attempts \\ 200) do
    case RunControl.agent_run_id(run_id) do
      {:ok, id} ->
        id

      {:error, :no_agent} when attempts > 0 ->
        Process.sleep(25)
        await_agent(run_id, attempts - 1)

      error ->
        flunk("agent never registered: #{inspect(error)}")
    end
  end

  defp await_harness_event(harness_run_id, fun, attempts \\ 200) do
    {:ok, events} = Jido.Harness.Run.replay(harness_run_id, cursor: 0, limit: 1_000)

    cond do
      Enum.any?(events, fun) ->
        :ok

      attempts > 0 ->
        Process.sleep(25)
        await_harness_event(harness_run_id, fun, attempts - 1)

      true ->
        flunk("harness event never appeared: #{inspect(Enum.map(events, & &1.type))}")
    end
  end

  defp steer!(run_id, message_id, text, extra \\ %{}) do
    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: "run.steer",
        command_id: "steer-#{run_id}-#{message_id}",
        aggregate_id: "run:#{run_id}",
        payload: Map.merge(%{run_id: run_id, message_id: message_id, text: text}, extra)
      })
  end

  defp stream_events(run_id) do
    {:ok, events} = Store.read_stream_forward("run:#{run_id}", 0, 1_000)
    events
  end

  defp event_types(run_id), do: Enum.map(stream_events(run_id), & &1.event_type)

  defp assert_event(type, run_id) do
    receive do
      {:projection_event, event} ->
        if event_matches?(event, type, run_id), do: :ok, else: assert_event(type, run_id)
    after
      5_000 -> flunk("timed out waiting for #{type} on #{run_id}")
    end
  end

  defp event_matches?(event, type, run_id) do
    ev_type = Map.get(event, :event_type) || Map.get(event, "event_type")
    data = Map.get(event, :data) || Map.get(event, "data") || Map.get(event, :payload) || %{}
    ev_run = Map.get(data, :run_id) || Map.get(data, "run_id")
    ev_type == type and ev_run == run_id
  end

  defp ensure_started(child_spec, name) do
    case Process.whereis(name) do
      nil -> start_supervised!(child_spec)
      _pid -> :ok
    end
  end

  defp ensure_dispatcher_subscribed do
    case Process.whereis(ForemanServer.Workflow.Dispatcher) do
      pid when is_pid(pid) ->
        :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
          %{state | subscribers: Map.put(state.subscribers, pid, true)}
        end)

      nil ->
        flunk("ForemanServer.Workflow.Dispatcher is not running")
    end
  end
end
