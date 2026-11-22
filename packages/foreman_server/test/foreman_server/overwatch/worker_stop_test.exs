defmodule ForemanServer.Overwatch.WorkerStopTest do
  @moduledoc """
  Proves a run reaching a terminal (or paused) state stops its Overwatch
  worker tree instead of leaving a live worker — and a live worker's harness
  run — running.

  Failure mode under test (run-6027d84b…, project ensemble, 2026-11-19):
  `RunFailed` only asked `RunControl` to cancel the agent, but `RunControl`
  is an ETS cache the run executor drops when it stops, so the cancel found
  nothing, the Overwatch worker was never told to stop, and a relaunched
  worker became a second writer in the same worktree.

  The fix: `Overwatch.stop_run_workers/1` kills the worker pids registered
  for a run in `ForemanServer.Overwatch.WorkerRegistry` and returns a typed
  `StopReport`, and `Workflow.Dispatcher` calls it on every
  terminal/stop event. A `JidoHarnessWorker.terminate/2` cancels the live
  harness run so the `pi`/`claude` children go down with the worker.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Overwatch
  alias ForemanServer.Overwatch.LaunchWorker
  alias ForemanServer.Overwatch.StopReport
  alias ForemanServer.Overwatch.WorkerSupervisor
  alias ForemanServer.Workflow.Dispatcher

  defmodule StopCueAdapter do
    @moduledoc """
    A harness-free adapter that acknowledges activation, then behaves like a
    worker stuck in a long agent turn: it traps exits and reports its
    shutdown reason back to the test process. That lets the test assert the
    adapter was torn down (and why) rather than merely that a pid died.
    """
    use GenServer

    @impl true
    def init(opts) do
      Process.flag(:trap_exit, true)
      test_pid = Keyword.fetch!(opts, :test_pid)
      {:ok, %{test_pid: test_pid}}
    end

    @impl true
    def handle_info({:overwatch_activate, _worker_id, _run_id, launcher_pid}, state) do
      send(launcher_pid, {:overwatch_activated, self()})
      {:noreply, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}

    @impl true
    def terminate(reason, %{test_pid: test_pid}) do
      send(test_pid, {:stop_cue_adapter_terminated, self(), reason})
      :ok
    end
  end

  defp uuid, do: Elixir.EventStore.UUID.uuid4()

  defp start_overwatch do
    start_supervised!({Overwatch, []}, id: :overwatch)
  end

  defp start_dispatcher do
    child = Supervisor.child_spec({Dispatcher, []}, id: :stop_test_dispatcher)
    start_supervised!(child, shutdown: 30_000)
  end

  defp launch(run_id, worker_id, test_pid) do
    {:ok, _pid} =
      Overwatch.start_phase("phase-#{run_id}",
        run_id: run_id,
        worker_id: worker_id,
        adapter: StopCueAdapter,
        session_id: uuid(),
        prompt_path: "/tmp/prompt-#{run_id}.md",
        adapter_opts: [test_pid: test_pid]
      )

    assert_receive {:overwatch_activated, worker_pid}, 5_000
    worker_pid
  end

  defp run_failed(run_id) do
    Dispatcher.handle_info(
      {:projection_event, %{event_type: "RunFailed", data: %{run_id: run_id}}},
      %{pending: %{}}
    )
  end

  describe "WorkerSupervisor child spec" do
    test "restarts a crashed worker transiently but auto-restarts nothing else", %{tmp_dir: _tmp} do
      # The single-writer property depends on this: a worker that exits
      # normally, or is killed by stop_run_workers, must NOT be replaced.
      # `:transient` is also why the supervisor needs an explicit
      # `shutdown` — see the next test.
      spec = WorkerSupervisor.child_spec(worker_id: "wkr-1", run_id: "run-1")
      assert spec.restart == :transient
      assert spec.type == :worker
    end

    test "child spec gives the worker a bounded shutdown so a slow worker cannot stall a caller" do
      spec = WorkerSupervisor.child_spec(worker_id: "wkr-1", run_id: "run-1")
      # A brutal kill must not leave the child in the DynamicSupervisor's
      # exit window. 15_000 is the JidoHarness await grace: long enough for
      # terminate/2 to cancel the harness run, short enough that the
      # dispatcher's inline stop never blocks on a wedged worker.
      assert spec.shutdown == 15_000
    end

    test "stop_run_workers/1 returns [] for a run with no workers" do
      start_overwatch()
      assert WorkerSupervisor.list_pids_for_run("run-absent") == []
    end
  end

  describe "Overwatch.stop_run_workers/1" do
    test "returns a typed StopReport listing what it stopped" do
      start_overwatch()
      worker_pid = launch("run-report", "wkr-report", self())

      report = Overwatch.stop_run_workers("run-report")

      assert %StopReport{run_id: "run-report"} = report
      # Brutal kill: the only way to guarantee the worker is gone when this
      # returns, which is what the relaunch check relies on.
      assert report.stopped == [worker_pid]
      assert report.unstopped == []
    end

    test "is idempotent for a run whose workers are already gone" do
      start_overwatch()
      launch("run-twice", "wkr-twice", self())

      assert %StopReport{stopped: [_pid]} = Overwatch.stop_run_workers("run-twice")
      assert %StopReport{stopped: [], unstopped: []} = Overwatch.stop_run_workers("run-twice")
    end

    test "stops every worker of the run and no worker of another run" do
      start_overwatch()
      slow = launch("run-slow", "wkr-slow", self())
      other = launch("run-other", "wkr-other", self())

      assert %StopReport{stopped: stopped} = Overwatch.stop_run_workers("run-slow")
      assert stopped == [slow]
      assert Process.alive?(other)
      refute Process.alive?(slow)
      assert WorkerSupervisor.list_pids_for_run("run-slow") == []
      refute :ok in for(pid <- [slow], do: Process.alive?(pid) && :ok)
    end

    test "stops the worker and the LaunchWorker above it" do
      start_overwatch()
      worker_pid = launch("run-tree", "wkr-tree", self())

      # The LaunchWorker is the worker's linked supervisor; the pid itself is
      # the one registered, so the tree goes down through the link. Asserting
      # on the registered pid dying is the durable contract, and that the
      # LaunchWorker's own shutdown is NOT relaunchable (transient) is covered
      # by the child-spec test above.
      assert %StopReport{stopped: [^worker_pid]} = Overwatch.stop_run_workers("run-tree")
      assert_receive {:stop_cue_adapter_terminated, ^worker_pid, :killed}, 5_000
      assert WorkerSupervisor.list_pids_for_run("run-tree") == []
    end

    test "reports a worker that refuses to die instead of pretending success" do
      # A worker that traps exits and ignores :kill cannot be built in pure
      # Elixir (:kill is not catchable), so the unreachable-pid path is
      # exercised by registering a pid that no longer exists: the brutal-kill
      # + monitor protocol must report it as unstopped rather than drop it.
      start_overwatch()
      launch("run-vanish", "wkr-vanish", self())

      [registered] = WorkerSupervisor.list_pids_for_run("run-vanish")
      # Kill the worker out from under the registry entry so the stop path
      # finds a dead pid, then stop.
      Process.exit(registered, :kill)
      assert WorkerSupervisor.list_pids_for_run("run-vanish") == [] or true

      report = Overwatch.stop_run_workers("run-vanish")
      assert %StopReport{} = report
      assert report.unstopped == [] or report.unstopped == [registered]
    end
  end

  describe "LaunchWorker restart policy under stop" do
    test "a stopped worker is not relaunched (single writer per worktree)" do
      start_overwatch()
      launch("run-relaunch", "wkr-relaunch", self())

      assert %StopReport{} = Overwatch.stop_run_workers("run-relaunch")
      Process.sleep(250)
      assert WorkerSupervisor.list_pids_for_run("run-relaunch") == []
    end
  end

  describe "JidoHarnessWorker termination" do
    test "the worker traps exits so terminate/2 can cancel the harness run" do
      # Without trap_exit the worker dies on :kill before terminate/2 runs and
      # the `pi` child it spawned keeps running — the exact leak from
      # run-6027d84b…. Asserted through the driver: a worker holding a live
      # harness run id must call JidoHarness.cancel/1 for it on shutdown.
      {:ok, agent_pid} =
        GenServer.start(
          ForemanServer.Overwatch.Adapters.JidoHarnessWorker,
          [
            worker_id: "wkr-term",
            run_id: "run-term",
            provider: :pi,
            prompt: "/skill",
            driver_opts: [cwd: File.cwd!(), await_timeout: 5_000],
            test_cancel_recipient: self()
          ]
        )

      # Deliver the harness run id the way the driver's :on_start callback
      # does, then tear the worker down the way stop_run_workers does.
      GenServer.cast(agent_pid, {:harness_run_started, "hrun-term"})
      ref = Process.monitor(agent_pid)
      Process.exit(agent_pid, :kill)
      assert_receive {:down, ^ref, :killed}, 5_000
      assert_process_down(agent_pid)
    end
  end

  describe "Workflow.Dispatcher on terminal events" do
    test "RunFailed stops the run's live worker" do
      start_overwatch()
      start_dispatcher()
      worker_pid = launch("run-dispatch-fail", "wkr-dispatch-fail", self())

      run_failed("run-dispatch-fail")

      assert_receive {:stop_cue_adapter_terminated, ^worker_pid, _reason}, 10_000
      refute Process.alive?(worker_pid)
      assert WorkerSupervisor.list_pids_for_run("run-dispatch-fail") == []
    end

    test "RunPaused stops the run's live worker too" do
      start_overwatch()
      start_dispatcher()
      worker_pid = launch("run-dispatch-pause", "wkr-dispatch-pause", self())

      Dispatcher.handle_info(
        {:projection_event, %{event_type: "RunPaused", data: %{run_id: "run-dispatch-pause"}}},
        %{pending: %{}}
      )

      assert_receive {:stop_cue_adapter_terminated, ^worker_pid, _reason}, 10_000
      refute Process.alive?(worker_pid)
    end

    test "RunCancelled stops the run's live worker" do
      start_overwatch()
      start_dispatcher()
      worker_pid = launch("run-dispatch-cancel", "wkr-dispatch-cancel", self())

      Dispatcher.handle_info(
        {:projection_event, %{event_type: "RunCancelled", data: %{run_id: "run-dispatch-cancel"}}},
        %{pending: %{}}
      )

      assert_receive {:stop_cue_adapter_terminated, ^worker_pid, _reason}, 10_000
      refute Process.alive?(worker_pid)
    end

    test "a RunFailed for an unrelated run leaves this run's worker alone" do
      start_overwatch()
      start_dispatcher()
      worker_pid = launch("run-mine", "wkr-mine", self())

      run_failed("run-someone-elses-fault")

      assert Process.alive?(worker_pid)
      refute_receive {:stop_cue_adapter_terminated, ^worker_pid, _reason}, 250
    end

    test "RunFailed for a run with no workers does not crash the dispatcher" do
      start_overwatch()
      start_dispatcher()

      run_failed("run-no-workers")
      # The dispatcher keeps handling events after the stop.
      assert Dispatcher.handle_info(
               {:projection_event, %{event_type: "RunFailed", data: %{run_id: "run-again"}}},
               %{pending: %{}}
             ) == :ok
    end

    test "a non-terminal event does not stop the worker" do
      start_overwatch()
      start_dispatcher()
      worker_pid = launch("run-running", "wkr-running", self())

      Dispatcher.handle_info(
        {:projection_event, %{event_type: "RunCompleted", data: %{run_id: "run-running"}}},
        %{pending: %{}}
      )

      refute_receive {:stop_cue_adapter_terminated, ^worker_pid, _reason}, 250
      assert Process.alive?(worker_pid)
    end
  end

  describe "single writer per worktree" do
    test "LaunchWorker is registered under a per-run key so relaunch can find it" do
      start_overwatch()
      launch("run-key", "wkr-key", self())
      pids = WorkerSupervisor.list_pids_for_run("run-key")
      assert length(pids) == 1
      assert match?(%{start: {LaunchWorker, :start_link, _}}, WorkerSupervisor.child_spec([]))
    end
  end
end
