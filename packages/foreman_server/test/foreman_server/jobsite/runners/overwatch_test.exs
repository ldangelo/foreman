defmodule ForemanServer.Jobsite.Runners.OverwatchTest do
  # The runner's outcome mapping on the script path: a deadline that elapses
  # while the launch process is still alive reports `:agent_idle_timeout`,
  # carrying the executor's original reason (`:worker_timeout`) in
  # `details.reason`. The wait itself (`wait_for_worker_result/4`, the DOWN
  # race, mailbox draining, the dead-at-deadline branch) is pinned
  # deterministically in `run_executor_test.exs`, which exercises it through
  # `Runners.Overwatch.__wait_for_worker_result_for_test__/4`.
  use ExUnit.Case, async: false

  alias ForemanServer.Jobsite.{Agent, Error, Runners}

  defmodule HangingWorkerAdapter do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_info({:overwatch_activate, _worker_id, _run_id, parent}, state) do
      send(parent, {:overwatch_activated, self()})
      # Deliberately never sends {:worker_result, _} — stays alive so the
      # runner's timeout branch must hit the `Process.alive?/1 == true` arm.
      {:noreply, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}
  end

  setup do
    previous = Application.get_env(:foreman_server, :worker_adapter)
    Application.put_env(:foreman_server, :worker_adapter, HangingWorkerAdapter)
    start_supervised!({ForemanServer.Overwatch, []}, id: :overwatch)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:foreman_server, :worker_adapter)
        adapter -> Application.put_env(:foreman_server, :worker_adapter, adapter)
      end
    end)

    :ok
  end

  test "reports :agent_idle_timeout (not :agent_failed) when the worker is still alive at the deadline" do
    run_id = "run-overwatch-timeout-#{System.unique_integer([:positive])}"
    agent = %Agent{provider: :claude, model: "test-model"}

    # The idle budget also caps worker admission (`min(activation_timeout_ms, remaining_ms)` in
    # `Runners.Overwatch.dispatch/1`). It must leave room for the hanging worker to be admitted
    # and activated on a loaded machine, or a slow admission surfaces as `:agent_start_failed`
    # and the worker-is-alive-at-the-deadline arm this test names is never reached.
    idle_timeout_ms = 1_000

    assert {:error, %Error{code: :agent_idle_timeout} = error} =
             Runners.Overwatch.run(agent, "do the thing", nil,
               run_id: run_id,
               idle_timeout_ms: idle_timeout_ms
             )

    assert error.details.timeout_ms == idle_timeout_ms
  end

  defmodule HeartbeatingWorkerAdapter do
    # Heartbeats under the id the overwatch GENERATES (it arrives in the activate message), the
    # way `JidoHarnessWorker` does, and delivers its result only when the test says so.
    use GenServer

    alias ForemanServer.Overwatch.WorkerProtocol

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, %{opts: opts, worker: nil}}

    @impl true
    def handle_info({:overwatch_activate, worker_id, run_id, parent}, state) do
      Process.register(self(), :"lease_test_worker_#{run_id}")
      send(parent, {:overwatch_activated, self()})
      send(self(), :beat)
      {:noreply, %{state | worker: {worker_id, run_id}}}
    end

    def handle_info(:beat, %{worker: {worker_id, run_id}} = state) do
      _ = WorkerProtocol.emit(:heartbeat, %{worker_id: worker_id, run_id: run_id})
      Process.send_after(self(), :beat, 20)
      {:noreply, state}
    end

    def handle_info(:finish, state) do
      send(Keyword.fetch!(state.opts, :result_recipient), {:worker_result, {:ok, "done"}})
      {:noreply, state}
    end

    def handle_info(:fail, state) do
      send(Keyword.fetch!(state.opts, :result_recipient), {:worker_result, {:error, :boom}})
      {:noreply, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}
  end

  test "a heartbeating worker keeps its phase's idempotency key started past the lease TTL" do
    Application.put_env(:foreman_server, :worker_adapter, HeartbeatingWorkerAdapter)

    run_id = "run-overwatch-lease-#{System.unique_integer([:positive])}"
    key = "lease-test-#{run_id}-1"
    lease_ms = 1_000

    launch = %{
      run_id: run_id,
      phase: "jobsite:#{run_id}",
      phase_index: 1,
      deadline_ms: System.system_time(:millisecond) + 60_000,
      timeout_ms: 60_000,
      activation_timeout_ms: 5_000,
      lease: %{key: key, budget_ms: lease_ms, task_id: "task-lease-test"},
      driver_opts: fn _remaining_ms -> [] end,
      launch_opts: [provider: :claude, prompt: "x", prompt_path: "/dev/null"]
    }

    runner =
      Task.async(fn ->
        Runners.Overwatch.run(%Agent{provider: :claude, model: "m"}, "x", nil, launch: launch)
      end)

    # Two full lease TTLs of heartbeats later the lease must still be live. Unrenewed it expires
    # after `lease_ms` and the key is `ambiguous` while the worker is alive.
    Process.sleep(lease_ms * 2)
    assert {:ok, :started} = ForemanServer.Idempotency.KeyStore.status(key)

    worker = Process.whereis(:"lease_test_worker_#{run_id}")
    assert is_pid(worker)
    send(worker, :finish)

    assert {:ok, %ForemanServer.Jobsite.IterationResult{status: :completed}} =
             Task.await(runner, 10_000)

    assert {:ok, :completed} = ForemanServer.Idempotency.KeyStore.status(key)
  end

  defp start_leased_run do
    Application.put_env(:foreman_server, :worker_adapter, HeartbeatingWorkerAdapter)

    run_id = "run-overwatch-lease-#{System.unique_integer([:positive])}"
    key = "lease-test-#{run_id}-1"

    launch = %{
      run_id: run_id,
      phase: "jobsite:#{run_id}",
      phase_index: 1,
      deadline_ms: System.system_time(:millisecond) + 60_000,
      timeout_ms: 60_000,
      activation_timeout_ms: 5_000,
      lease: %{key: key, budget_ms: 30_000, task_id: "task-lease-test"},
      driver_opts: fn _remaining_ms -> [] end,
      launch_opts: [provider: :claude, prompt: "x", prompt_path: "/dev/null"]
    }

    runner =
      Task.async(fn ->
        Runners.Overwatch.run(%Agent{provider: :claude, model: "m"}, "x", nil, launch: launch)
      end)

    worker = await_worker(run_id)
    {key, runner, worker}
  end

  defp await_worker(run_id, attempts \\ 200) do
    case Process.whereis(:"lease_test_worker_#{run_id}") do
      nil when attempts > 0 ->
        Process.sleep(10)
        await_worker(run_id, attempts - 1)

      nil ->
        flunk("worker for #{run_id} never activated")

      pid ->
        pid
    end
  end

  test "a failed dispatch leaves its idempotency key failed, not completed" do
    {key, runner, worker} = start_leased_run()
    assert {:ok, :started} = ForemanServer.Idempotency.KeyStore.status(key)

    send(worker, :fail)

    assert {:error, %Error{code: :agent_failed}} = Task.await(runner, 10_000)
    assert {:ok, :failed} = ForemanServer.Idempotency.KeyStore.status(key)
    assert :not_found = ForemanServer.Idempotency.HeartbeatLease.status(key)
  end

  test "a worker that dies without a result leaves its key ambiguous: the outcome is unknown" do
    {key, runner, worker} = start_leased_run()

    Process.exit(worker, :kill)

    assert {:error, %Error{details: %{reason: :worker_died_no_result}}} =
             Task.await(runner, 10_000)

    assert {:ok, %{status: :ambiguous, metadata: %{reason: "worker_died_no_result"}}} =
             ForemanServer.Idempotency.KeyStore.get(key)
  end

  test "a successful dispatch overwrites an ambiguous left by lease expiry" do
    {key, runner, worker} = start_leased_run()

    # Lease expiry marks the key ambiguous while the worker is still running.
    :ok = ForemanServer.Idempotency.KeyStore.mark_ambiguous(key, "heartbeat_timeout")
    assert {:ok, :ambiguous} = ForemanServer.Idempotency.KeyStore.status(key)

    send(worker, :finish)

    assert {:ok, %ForemanServer.Jobsite.IterationResult{status: :completed}} =
             Task.await(runner, 10_000)

    assert {:ok, :completed} = ForemanServer.Idempotency.KeyStore.status(key)
  end

  test "a dispatch that raises leaves its key failed and the exception still propagates" do
    run_id = "run-overwatch-raise-#{System.unique_integer([:positive])}"
    key = "lease-test-#{run_id}-1"

    launch = %{
      run_id: run_id,
      phase: "jobsite:#{run_id}",
      phase_index: 1,
      deadline_ms: System.system_time(:millisecond) + 60_000,
      timeout_ms: 60_000,
      activation_timeout_ms: 5_000,
      lease: %{key: key, budget_ms: 30_000, task_id: "task-lease-test"},
      driver_opts: fn _remaining_ms -> raise "driver exploded" end,
      launch_opts: [provider: :claude, prompt: "x", prompt_path: "/dev/null"]
    }

    assert_raise RuntimeError, "driver exploded", fn ->
      Runners.Overwatch.run(%Agent{provider: :claude, model: "m"}, "x", nil, launch: launch)
    end

    assert {:ok, %{status: :failed, metadata: %{reason: reason}}} =
             ForemanServer.Idempotency.KeyStore.get(key)

    assert reason =~ "driver exploded"
    assert :not_found = ForemanServer.Idempotency.HeartbeatLease.status(key)
  end
end
