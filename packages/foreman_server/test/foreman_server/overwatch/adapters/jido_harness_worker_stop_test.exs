defmodule ForemanServer.Overwatch.Adapters.JidoHarnessWorkerStopTest do
  @moduledoc """
  A `JidoHarnessWorker` that stops while its agent runs takes the agent with it.

  The harness run is a process of its own, linked to nothing in the worker. When the worker died
  (a stop through `LaunchWorker`, a crashed agent task, a launcher that died) the run, and the
  `pi` under it, went on writing into the worktree, and the supervisor's relaunch started a
  second agent beside it.

  A REAL harness run: the pi adapter launching `fake_agent.sh` under erlexec, as production
  launches pi (`StrayAgent`). The agent ignores SIGINT, so a stop that works has to wait out the
  harness's escalation to SIGTERM (shortened to a second here), which is also why every check of
  "the agent is gone" comes after the worker's own exit and needs no waiting of its own.
  """

  use ExUnit.Case, async: false

  # An agent task that crashes on purpose, and the worker stops that follow, are reported.
  @moduletag :capture_log
  @moduletag :tmp_dir

  alias ForemanServer.AgentRuntime.JidoHarness.Driver
  alias ForemanServer.Overwatch.Adapters.JidoHarnessWorker
  alias ForemanServer.Overwatch.Tracker
  alias ForemanServer.RunControl
  alias ForemanServer.TestSupport.{MeckScope, StrayAgent}
  alias Jido.Harness.Run

  # Only an upper bound on how long a failing test waits before it reports.
  @await_ms 30_000

  # The agent sleeps for minutes, ignores SIGINT, and starts a tool process of its own (the
  # `stray.pid` that says it is up and has set its signal handling).
  @long_agent_env %{
    "FAKE_AGENT_STRAY_SECS" => "300",
    "FAKE_AGENT_SLEEP_ON_RUN" => "1",
    "FAKE_AGENT_SLEEP_SECS" => "300",
    "FAKE_AGENT_IGNORE_INT" => "1"
  }

  setup_all do
    MeckScope.new_once!(Driver)
  end

  setup %{tmp_dir: dir} do
    MeckScope.restore_on_exit!(Driver)
    StrayAgent.tight_grace!(1_000)
    # The worker heartbeats and writes its events through the Tracker.
    start_supervised!({Tracker, []}, id: :tracker)

    run_id = Elixir.EventStore.UUID.uuid4()
    worker_id = Elixir.EventStore.UUID.uuid4()
    on_exit(fn -> RunControl.clear(run_id) end)

    {:ok, dir: dir, run_id: run_id, worker_id: worker_id}
  end

  defp worker_opts(%{dir: dir, run_id: run_id, worker_id: worker_id}, env) do
    [
      worker_id: worker_id,
      run_id: run_id,
      provider: :pi,
      prompt: "go",
      result_recipient: self(),
      driver_opts: [
        cwd: dir,
        env: env,
        idle_timeout_ms: 120_000,
        runtime_timeout_ms: :infinity,
        provider_options: %{cli_path: StrayAgent.fake_agent()}
      ]
    ]
  end

  # Activates `worker` the way `LaunchWorker` does, so it starts its agent.
  defp activate(worker, %{run_id: run_id, worker_id: worker_id}) do
    send(worker, {:overwatch_activate, worker_id, run_id, self()})
    assert_receive {:overwatch_activated, ^worker}, @await_ms
    worker
  end

  defp start_worker(ctx, env) do
    worker =
      start_supervised!(%{
        id: {JidoHarnessWorker, ctx.worker_id},
        start: {JidoHarnessWorker, :start_link, [worker_opts(ctx, env)]},
        restart: :temporary
      })

    activate(worker, ctx)
  end

  # Waits for the long-running agent to be up, and makes sure it is gone when the test ends
  # whatever happens: the `pi` of a failing test must not leak.
  defp await_agent(%{dir: dir, run_id: run_id}) do
    StrayAgent.await!("the agent's harness run", fn ->
      match?({:ok, _harness_run_id}, RunControl.agent_run_id(run_id))
    end)

    {:ok, harness_run_id} = RunControl.agent_run_id(run_id)
    agent = StrayAgent.await_agent_os_pid!(harness_run_id)
    stray = StrayAgent.stray_pid!(dir)

    on_exit(fn ->
      Run.cancel(harness_run_id)
      StrayAgent.kill!(agent)
      StrayAgent.kill!(stray)
    end)

    assert StrayAgent.alive?(agent)
    %{harness_run_id: harness_run_id, agent: agent}
  end

  # The process `Task.async` started for the agent: linked to the worker, and the only linked
  # process the worker is the parent of.
  defp agent_task_of(worker) do
    {:links, links} = Process.info(worker, :links)

    [task] =
      for pid <- links, is_pid(pid), Process.info(pid, :parent) == {:parent, worker}, do: pid

    task
  end

  test "a worker that is stopped cancels its harness run and the agent is gone", ctx do
    worker = start_worker(ctx, @long_agent_env)
    %{harness_run_id: harness_run_id, agent: agent} = await_agent(ctx)

    assert :ok = GenServer.stop(worker, :shutdown, @await_ms)

    refute StrayAgent.alive?(agent)
    assert {:ok, %{status: :cancelled}} = Run.await(harness_run_id, 1_000)
  end

  test "a crashed agent task takes the worker down with its own reason, and the agent with it",
       ctx do
    worker = start_worker(ctx, @long_agent_env)
    %{agent: agent} = await_agent(ctx)
    ref = Process.monitor(worker)

    # The task is linked and the worker traps exits: the crash reaches the worker as a message.
    # It must still end the worker, with the task's reason, which is what `LaunchWorker` turns
    # into its relaunch decision.
    Process.exit(agent_task_of(worker), :boom)

    assert_receive {:DOWN, ^ref, :process, ^worker, :boom}, @await_ms
    refute StrayAgent.alive?(agent)
  end

  test "a worker whose launcher died stops its agent too", ctx do
    test_pid = self()

    # Stands in for `LaunchWorker`: the process that starts the worker, and so is its parent.
    launcher =
      spawn(fn ->
        {:ok, worker} = JidoHarnessWorker.start_link(worker_opts(ctx, @long_agent_env))
        send(test_pid, {:worker_started, worker})
        Process.sleep(:infinity)
      end)

    assert_receive {:worker_started, worker}, @await_ms
    activate(worker, ctx)
    %{agent: agent} = await_agent(ctx)
    ref = Process.monitor(worker)

    Process.exit(launcher, :kill)

    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, @await_ms
    refute StrayAgent.alive?(agent)
  end

  test "a worker whose agent finished delivers its result and cancels nothing when it exits",
       ctx do
    worker = start_worker(ctx, %{})
    ref = Process.monitor(worker)

    assert_receive {:worker_result, {:ok, "did some work"}}, @await_ms
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, @await_ms

    refute :meck.called(Driver, :stop, :_)
  end
end
