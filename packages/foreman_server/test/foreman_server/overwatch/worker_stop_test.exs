defmodule ForemanServer.Overwatch.WorkerStopTest do
  @moduledoc """
  A run that stops (failed, cancelled, flagged stuck, deleted, paused) must not leave a live
  worker behind, and a run must never have two workers writing into its worktree.

  The failure this pins: `Workflow.Dispatcher` only asked `RunControl` to cancel the run's agent,
  but `RunControl` is an ETS cache the run executor wipes when it stops, right after it
  dispatches `run.fail`. By the time `RunFailed` landed there was nothing to cancel, the run's
  Overwatch worker was never told to stop, and its `pi` kept writing into the worktree of a
  failed run, where a relaunched worker would have been a second writer.

  The authority on a run's workers is the Overwatch registry, so a stopped run's workers are
  stopped through it (`WorkerSupervisor.stop_run_workers/1`), after the wind-down window a
  cancelled agent's worker needs to finish by itself. Most tests drive `Overwatch`,
  `LaunchWorker` and the dispatcher for real around a fake adapter; the capstones drive the real
  `JidoHarnessWorker` and a real `pi` adapter run (`fake_agent.sh` under erlexec), and the live,
  subscribed dispatcher fed by the projection.

  The projection is updated BEFORE subscribers hear of an event, so the dispatcher finds a failed
  run terminal and a paused run paused. A direct `Dispatcher.handle_info/2` call skips that, so
  these tests state what the projection holds (`project_run/2`); a real `LaunchWorker` makes the
  projection create a running stub for its run, so the store could not answer for them.
  """

  use ExUnit.Case, async: false

  # A worker that will not stop and a refused launch log at :error on purpose.
  @moduletag :capture_log

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter
  alias ForemanServer.Overwatch
  alias ForemanServer.Overwatch.{StopReport, WorkerSupervisor}
  alias ForemanServer.ProjectionStore
  alias ForemanServer.RunControl
  alias ForemanServer.TestSupport.{Eventually, MeckScope, StrayAgent}
  alias ForemanServer.Workflow.Dispatcher
  alias Jido.Harness.Run

  # Only an upper bound on how long a failing test waits before it reports.
  @await_ms 15_000

  # The wind-down the dispatcher gives a stopped run's workers in the tests that wait for the
  # stop to happen.
  @short_wind_down_ms 50

  # The fake pi agent sleeps for minutes and ignores SIGINT (so a stop has to wait out the
  # harness's escalation to SIGTERM), and starts a tool process of its own (`stray.pid`).
  @long_agent_env %{
    "FAKE_AGENT_STRAY_SECS" => "300",
    "FAKE_AGENT_SLEEP_ON_RUN" => "1",
    "FAKE_AGENT_SLEEP_SECS" => "300",
    "FAKE_AGENT_IGNORE_INT" => "1"
  }

  defmodule StopCueAdapter do
    @moduledoc """
    A harness-free adapter. It acknowledges activation and then sits there, reporting to its
    `:result_recipient` when it is activated and when (and why) it terminates, and exits with the
    reason a test sends it.

    It does NOT trap exits, like the worker it stands in for before this fix: a link exit signal
    kills it without running `terminate/2`. So `terminate/2` runs only when the launcher stops
    the worker itself (`GenServer.stop/3`), which is the property the tests need to see.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :result_recipient)}}

    @impl true
    def handle_info({:overwatch_activate, _worker_id, _run_id, launcher_pid}, state) do
      send(launcher_pid, {:overwatch_activated, self()})
      send(state.test_pid, {:stop_cue_adapter_activated, self()})
      {:noreply, state}
    end

    def handle_info({:exit_with, reason}, state), do: {:stop, reason, state}
    def handle_info(_msg, state), do: {:noreply, state}

    @impl true
    def terminate(reason, state) do
      send(state.test_pid, {:stop_cue_adapter_terminated, self(), reason})
    end
  end

  setup_all do
    # `:meck.new(ProjectionStore, [:passthrough])` copies a 5.5k-line module: once per module.
    MeckScope.new_once!(ProjectionStore)
  end

  setup do
    MeckScope.restore_on_exit!(ProjectionStore)
    start_supervised!({Overwatch, []}, id: :overwatch)
    :ok
  end

  defp uuid, do: Elixir.EventStore.UUID.uuid4()

  defp launch_opts(run_id, owner) do
    [
      run_id: run_id,
      worker_id: "wkr-#{System.unique_integer([:positive])}",
      adapter: StopCueAdapter,
      session_id: uuid(),
      prompt_path: "/tmp/prompt-#{run_id}.md",
      result_recipient: owner
    ]
  end

  # A worker started the way a phase starts one, and waited for until it is activated.
  defp launch(run_id) do
    assert {:ok, %{launch_pid: launch_pid}} =
             Overwatch.start_phase("phase", launch_opts(run_id, self()))

    assert_receive {:stop_cue_adapter_activated, adapter_pid}, @await_ms
    %{launch_pid: launch_pid, adapter_pid: adapter_pid}
  end

  # A second worker for a run that already has one: only the supervisor lets that happen
  # (`start_phase/2` refuses it), as a crash relaunch or a stray from before this fix would.
  defp launch_beside(run_id) do
    opts = launch_opts(run_id, self()) ++ [adapter_name: "stop_cue"]
    assert {:ok, launch_pid} = WorkerSupervisor.start_worker(opts)
    assert_receive {:stop_cue_adapter_activated, adapter_pid}, @await_ms
    %{launch_pid: launch_pid, adapter_pid: adapter_pid}
  end

  # The registry can still list a worker that has just died until it has handled that exit, so
  # "who is there" is asked of the live ones.
  defp live_workers(run_id),
    do: run_id |> WorkerSupervisor.list_pids_for_run() |> Enum.filter(&Process.alive?/1)

  defp supervisor_children do
    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(WorkerSupervisor), do: pid
  end

  # A registered worker that is not a child of `WorkerSupervisor`: nothing can stop it through
  # the supervisor.
  defp register_unowned_worker(run_id) do
    {:ok, holder} = Agent.start_link(fn -> :ok end)

    {:ok, _registry} =
      Agent.get(holder, fn :ok ->
        Registry.register(ForemanServer.Overwatch.WorkerRegistry, "#{run_id}:unowned", nil)
      end)

    holder
  end

  describe "WorkerSupervisor.stop_run_workers/1" do
    test "stops the run's worker through its launcher, and nothing of another run" do
      run_id = uuid()
      %{launch_pid: launcher, adapter_pid: adapter} = launch(run_id)
      %{launch_pid: other_launcher, adapter_pid: other_adapter} = launch(uuid())

      assert %StopReport{run_id: ^run_id, stopped: [^launcher], unstopped: []} =
               WorkerSupervisor.stop_run_workers(run_id)

      # The launcher stopped the worker itself: the worker ran its own `terminate/2`, which is
      # how a real worker cancels the agent it owns. A link exit alone never reaches it. And it
      # did so before the stop returned: a caller that goes on to start a worker finds the old
      # one gone, not still dying.
      assert_receive {:stop_cue_adapter_terminated, ^adapter, :shutdown}, @await_ms
      refute Process.alive?(adapter)
      refute Process.alive?(launcher)
      assert live_workers(run_id) == []

      # And it stays stopped: the child spec went with it, so nothing relaunches the worker.
      refute launcher in supervisor_children()

      assert Process.alive?(other_launcher)
      assert Process.alive?(other_adapter)
    end

    test "stops every worker of the run" do
      run_id = uuid()
      %{launch_pid: first, adapter_pid: first_adapter} = launch(run_id)
      %{launch_pid: second, adapter_pid: second_adapter} = launch_beside(run_id)

      assert %StopReport{stopped: stopped, unstopped: []} =
               WorkerSupervisor.stop_run_workers(run_id)

      assert Enum.sort(stopped) == Enum.sort([first, second])
      assert_receive {:stop_cue_adapter_terminated, ^first_adapter, :shutdown}, @await_ms
      assert_receive {:stop_cue_adapter_terminated, ^second_adapter, :shutdown}, @await_ms
      assert live_workers(run_id) == []
    end

    test "has nothing to report for a run without workers, or once they are gone" do
      run_id = uuid()

      assert %StopReport{run_id: ^run_id, stopped: [], unstopped: []} =
               WorkerSupervisor.stop_run_workers(run_id)

      launch(run_id)

      assert %StopReport{stopped: [_launcher], unstopped: []} =
               WorkerSupervisor.stop_run_workers(run_id)

      assert %StopReport{stopped: [], unstopped: []} = WorkerSupervisor.stop_run_workers(run_id)
    end

    test "reports a worker it could not stop instead of calling the run clean" do
      run_id = uuid()
      unowned = register_unowned_worker(run_id)

      log =
        capture_log(fn ->
          assert %StopReport{run_id: ^run_id, stopped: [], unstopped: [^unowned]} =
                   WorkerSupervisor.stop_run_workers(run_id)
        end)

      assert log =~ "keeps 1 live worker(s)"
      assert Process.alive?(unowned)
    end
  end

  describe "WorkerSupervisor.await_run_workers_exit/2" do
    test "returns at once for a run without workers" do
      assert :ok = WorkerSupervisor.await_run_workers_exit(uuid(), 0)
    end

    test "gives up, stopping nothing, while a worker of the run is alive" do
      run_id = uuid()
      %{launch_pid: launcher, adapter_pid: adapter} = launch(run_id)

      assert {:error, :timeout} = WorkerSupervisor.await_run_workers_exit(run_id, 100)

      assert Process.alive?(launcher)
      refute_received {:stop_cue_adapter_terminated, ^adapter, _reason}
    end

    test "returns as soon as the worker has exited by itself" do
      run_id = uuid()
      %{adapter_pid: adapter} = launch(run_id)

      {:ok, _task} =
        Task.start(fn ->
          Process.sleep(100)
          send(adapter, {:exit_with, :normal})
        end)

      assert :ok = WorkerSupervisor.await_run_workers_exit(run_id, @await_ms)
      assert live_workers(run_id) == []
    end
  end

  describe "Overwatch.start_phase/2 keeps one writer per run" do
    test "refuses a second worker while one of the run is alive, and starts nothing" do
      run_id = uuid()
      %{launch_pid: first} = launch(run_id)

      assert {:error, {:worker_already_running, ^run_id}} =
               Overwatch.start_phase("phase", launch_opts(run_id, self()))

      refute_received {:stop_cue_adapter_activated, _adapter}
      assert live_workers(run_id) == [first]
    end

    test "starts a worker for another run beside it" do
      %{launch_pid: first} = launch(uuid())
      %{launch_pid: second} = launch(uuid())

      assert Process.alive?(first)
      assert Process.alive?(second)
    end

    test "starts a worker once the run's previous one has been stopped" do
      run_id = uuid()
      %{launch_pid: first} = launch(run_id)

      assert %StopReport{stopped: [^first], unstopped: []} =
               WorkerSupervisor.stop_run_workers(run_id)

      %{launch_pid: second} = launch(run_id)
      assert live_workers(run_id) == [second]
    end

    test "waits for a worker that is on its way out instead of refusing the launch" do
      run_id = uuid()
      %{adapter_pid: adapter} = launch(run_id)
      test_pid = self()

      starting =
        Task.async(fn -> Overwatch.start_phase("phase", launch_opts(run_id, test_pid)) end)

      # The first worker is still alive when the launch begins (it is checked first), and gone
      # shortly after: the launch has to ride that out, not refuse.
      Process.sleep(200)
      send(adapter, {:exit_with, :normal})

      assert {:ok, %{launch_pid: second}} = Task.await(starting, @await_ms)
      assert live_workers(run_id) == [second]
    end
  end

  describe "Workflow.Dispatcher: a run that stopped leaves no live worker" do
    for {event_type, keys, status} <- [
          {"RunFailed", :atoms, "failed"},
          {"RunCancelled", :strings, "cancelled"},
          {"RunFlaggedStuck", :atoms, "stuck"},
          {"RunDeleted", :strings, "deleted"}
        ] do
      test "#{event_type} stops the run's live worker, and the worker with it" do
        run_id = uuid()
        %{adapter_pid: adapter} = launch(run_id)
        project_run(run_id, unquote(status))

        dispatch(unquote(event_type), run_id, keys: unquote(keys))

        assert_receive {:stop_cue_adapter_terminated, ^adapter, :shutdown}, @await_ms
        Eventually.await(fn -> live_workers(run_id) == [] end)
      end
    end

    test "stops the worker of a run the projection no longer has" do
      # `run.reset` drops the run from the projection until it starts again.
      run_id = uuid()
      %{adapter_pid: adapter} = launch(run_id)
      project_no_run(run_id)

      dispatch("RunDeleted", run_id)

      assert_receive {:stop_cue_adapter_terminated, ^adapter, :shutdown}, @await_ms
    end

    test "RunPaused stops the live worker of a run that is still paused" do
      run_id = uuid()
      %{adapter_pid: adapter} = launch(run_id)
      project_run(run_id, "paused")

      dispatch("RunPaused", run_id)

      assert_receive {:stop_cue_adapter_terminated, ^adapter, :shutdown}, @await_ms
    end

    test "RunPaused of a run that has resumed since is history and leaves the worker alone" do
      run_id = uuid()
      %{adapter_pid: adapter} = launch(run_id)
      project_run(run_id, "in_progress")

      dispatch("RunPaused", run_id)

      refute_receive {:stop_cue_adapter_terminated, ^adapter, _reason}, 500
    end

    test "gives the worker its wind-down first: the stop comes after it, not with the event" do
      run_id = uuid()
      %{adapter_pid: adapter} = launch(run_id)
      project_run(run_id, "failed")

      dispatch("RunFailed", run_id, wind_down_ms: 1_000)

      # A cancelled agent's worker records its last events and delivers its result in this
      # window; stopping it at once would race that and lose them.
      refute_receive {:stop_cue_adapter_terminated, ^adapter, _reason}, 300
      assert_receive {:stop_cue_adapter_terminated, ^adapter, :shutdown}, @await_ms
    end

    test "leaves a worker that finishes by itself during the wind-down to finish" do
      run_id = uuid()
      %{adapter_pid: adapter} = launch(run_id)
      project_run(run_id, "cancelled")

      dispatch("RunCancelled", run_id, wind_down_ms: 60_000)
      send(adapter, {:exit_with, :normal})

      assert_receive {:stop_cue_adapter_terminated, ^adapter, :normal}, @await_ms
      refute_receive {:stop_cue_adapter_terminated, ^adapter, :shutdown}, 200
    end

    test "leaves the worker alone when the run was resumed during the wind-down" do
      run_id = uuid()
      %{adapter_pid: adapter} = launch(run_id)
      project_run(run_id, "paused")

      dispatch("RunPaused", run_id, wind_down_ms: 300)
      # Resumed while the worker wound down: the worker is the resumed run's own now.
      project_run(run_id, "in_progress")

      refute_receive {:stop_cue_adapter_terminated, ^adapter, _reason}, 800
    end

    test "does not stop the worker of a run that was reset and started again" do
      # A replayed historical `RunFailed` (a restarted dispatcher re-reads the whole log) is not a
      # command for the run that has been revived since.
      run_id = uuid()
      %{adapter_pid: adapter} = launch(run_id)
      project_run(run_id, "in_progress")

      dispatch("RunFailed", run_id)

      refute_receive {:stop_cue_adapter_terminated, ^adapter, _reason}, 500
    end

    test "leaves the workers of other runs alone" do
      run_id = uuid()
      %{adapter_pid: other} = launch(uuid())
      project_run(run_id, "failed")

      dispatch("RunFailed", run_id)

      refute_receive {:stop_cue_adapter_terminated, ^other, _reason}, 400
    end

    for {event_type, status} <- [{"RunCompleted", "completed"}, {"RunBlocked", "blocked"}] do
      test "#{event_type} does not stop the worker: the executor is finishing on its own" do
        run_id = uuid()
        %{adapter_pid: adapter} = launch(run_id)
        project_run(run_id, unquote(status))

        dispatch(unquote(event_type), run_id)

        refute_receive {:stop_cue_adapter_terminated, ^adapter, _reason}, 400
      end
    end
  end

  describe "the live Dispatcher, fed by the projection" do
    # The singleton `Dispatcher` the application runs is subscribed to `ProjectionStore`, which
    # applies an event BEFORE it tells its subscribers: these go through that real path (nothing
    # is mocked), and prove the stop is reachable from the event, not only from `handle_info/2`.
    setup do
      original = :sys.get_state(Dispatcher).worker_wind_down_ms
      set_wind_down(@short_wind_down_ms)
      on_exit(fn -> set_wind_down(original) end)
    end

    test "RunFailed in the projection stops the run's live worker" do
      run_id = uuid()
      %{adapter_pid: adapter} = launch(run_id)

      :ok =
        ProjectionStore.apply_events([
          %{event_type: "RunFailed", data: %{run_id: run_id, reason: "phase failed"}}
        ])

      assert_receive {:stop_cue_adapter_terminated, ^adapter, :shutdown}, @await_ms
    end

    test "RunPaused in the projection stops the live worker of the paused run" do
      run_id = uuid()
      %{adapter_pid: adapter} = launch(run_id)

      :ok =
        ProjectionStore.apply_events([
          %{event_type: "RunPaused", data: %{run_id: run_id, reason: "operator_pause"}}
        ])

      assert_receive {:stop_cue_adapter_terminated, ^adapter, :shutdown}, @await_ms
    end
  end

  describe "a failed run's real pi agent (the reported failure)" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      StrayAgent.tight_grace!(1_000)
      run_id = uuid()

      assert {:ok, %{launch_pid: launcher}} =
               Overwatch.start_phase("phase",
                 run_id: run_id,
                 worker_id: "wkr-pi-#{System.unique_integer([:positive])}",
                 adapter: JidoHarnessAdapter,
                 session_id: uuid(),
                 prompt_path: Path.join(dir, "prompt.md"),
                 provider: :pi,
                 prompt: "go",
                 result_recipient: self(),
                 driver_opts: [
                   cwd: dir,
                   env: @long_agent_env,
                   idle_timeout_ms: 120_000,
                   runtime_timeout_ms: :infinity,
                   provider_options: %{cli_path: StrayAgent.fake_agent()}
                 ]
               )

      StrayAgent.await!("the agent's harness run", fn ->
        match?({:ok, _harness_run_id}, RunControl.agent_run_id(run_id))
      end)

      {:ok, harness_run_id} = RunControl.agent_run_id(run_id)
      agent = StrayAgent.await_agent_os_pid!(harness_run_id)
      stray = StrayAgent.stray_pid!(dir)

      on_exit(fn ->
        RunControl.clear(run_id)
        Run.cancel(harness_run_id)
        StrayAgent.kill!(agent)
        StrayAgent.kill!(stray)
      end)

      assert StrayAgent.alive?(agent)
      %{run_id: run_id, launcher: launcher, agent: agent}
    end

    test "RunFailed after the executor wiped RunControl stops the worker and the pi under it",
         ctx do
      # What the executor does when it stops, right after it dispatches `run.fail`: with
      # `RunControl` wiped, `cancel_agent/1` finds nothing, and nothing else told the agent.
      RunControl.clear(ctx.run_id)
      assert {:error, :no_agent} = RunControl.cancel_agent(ctx.run_id)
      project_run(ctx.run_id, "failed")

      dispatch("RunFailed", ctx.run_id)

      StrayAgent.await!(
        "the stopped run's pi to exit",
        fn -> not StrayAgent.alive?(ctx.agent) end,
        400
      )

      # The pi dies inside the worker's own `terminate/2`; the worker, its launcher and the
      # registry entry follow once that returns.
      Eventually.await(fn -> not Process.alive?(ctx.launcher) end, timeout: @await_ms)
      Eventually.await(fn -> live_workers(ctx.run_id) == [] end)
    end

    test "RunCancelled while the executor is live lets the worker wind down by itself", ctx do
      # `RunControl` is intact, so the dispatcher's own cancel reaches the agent and the worker
      # finishes what it does (delivers its result) inside the wind-down; nothing is left for the
      # stop to do, and the worker was never cut off.
      project_run(ctx.run_id, "cancelled")

      dispatch("RunCancelled", ctx.run_id, wind_down_ms: 60_000)

      assert_receive {:worker_result, _result}, @await_ms

      Eventually.await(fn -> live_workers(ctx.run_id) == [] end,
        timeout: @await_ms
      )
    end
  end

  # The dispatcher's reaction to a projection event of `event_type` for `run_id`, as the
  # projection subscriber receives it. `:keys` picks the atom- or string-keyed envelope (the
  # dispatcher accepts both); `:wind_down_ms` is what its state carries (`init/1`).
  defp dispatch(event_type, run_id, opts \\ []) do
    wind_down_ms = Keyword.get(opts, :wind_down_ms, @short_wind_down_ms)
    envelope = envelope(event_type, run_id, Keyword.get(opts, :keys, :atoms))

    assert {:noreply, _state} =
             Dispatcher.handle_info({:projection_event, envelope}, %{
               worker_wind_down_ms: wind_down_ms
             })
  end

  defp envelope(event_type, run_id, :atoms),
    do: %{event_type: event_type, data: %{run_id: run_id}}

  defp envelope(event_type, run_id, :strings),
    do: %{"event_type" => event_type, "data" => %{run_id: run_id}}

  # What the projection holds for `run_id` when the dispatcher hears of an event about it. Every
  # other run is answered by the real store.
  defp project_run(run_id, status) do
    run = %{run_id: run_id, status: status, terminal?: status not in ["paused", "in_progress"]}
    expect_run(run_id, run)
  end

  defp project_no_run(run_id), do: expect_run(run_id, nil)

  defp expect_run(run_id, run) do
    :meck.expect(ProjectionStore, :run, fn
      ^run_id -> run
      other -> :meck.passthrough([other])
    end)
  end

  defp set_wind_down(ms) do
    :sys.replace_state(Dispatcher, &Map.put(&1, :worker_wind_down_ms, ms))
    :ok
  end
end
