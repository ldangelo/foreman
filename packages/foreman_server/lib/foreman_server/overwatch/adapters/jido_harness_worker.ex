defmodule ForemanServer.Overwatch.Adapters.JidoHarnessWorker do
  @moduledoc """
  Worker GenServer that runs a `Jido.Harness` agent under Overwatch supervision.
  Closes the LGC-T002/JHA-T002 gap between `RunExecutor` (which only knew
  about `AgentRuntime.execute`) and the Overwatch supervision tree (sole
  producer of `WorkerStarted` / `WorkerHeartbeat` / `WorkerExited`).

  ## Lifecycle

    1. `LaunchWorker` calls `WorkerProtocol.start_worker/3`, which dispatches
       to `JidoHarnessAdapter.start_link/1` (the adapter contract). This
       module's `start_link/1` is the entry point.
    2. `init/1` captures opts and returns immediately — no blocking work.
    3. `LaunchWorker` sends `{:overwatch_activate, worker_id, run_id, parent}`.
       This worker must reply with `{:overwatch_activated, self()}` within
       `activation_timeout_ms` (default 5_000) or `LaunchWorker` exits.
    4. After the activation ack, the worker spawns the agent in a Task and
       monitors the task pid. The task body calls `Driver.run` (handling
       sync and detached branches) and normalizes via `RunResult.normalize/1`.
    5. The task sends `{:agent_done, result}` to this pid before exiting.
    6. On `:agent_done`, this worker emits `WorkerExited` and forwards the
       normalized result to `:result_recipient` (the `RunExecutor` pid).
       Then exits `:normal` so `LaunchWorker` sees the DOWN and exits cleanly.

  ## Result normalization

  `RunResult.normalize/1` returns `{:ok, text, metadata}` (3-tuple) for
  success and `{:error, code}` for failure. `RunExecutor.execute_agent`
  pattern-matches on `{:ok, output}` (2-tuple) via
  `with {:ok, output} <- execute_agent(...)`. The Invocation layer
  (`invocation.ex:183`) unwraps the 3-tuple to 2-tuple before forwarding
  to the caller. This worker replicates that unwrap explicitly.
  """

  use GenServer

  require Logger

  alias ForemanServer.AgentRuntime.JidoHarness.{Driver, RunResult}
  alias ForemanServer.Overwatch.WorkerProtocol

  @default_heartbeat_interval_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    worker_id = Keyword.fetch!(opts, :worker_id)
    run_id = Keyword.fetch!(opts, :run_id)
    provider = Keyword.fetch!(opts, :provider)
    prompt = Keyword.fetch!(opts, :prompt)
    driver_opts = Keyword.get(opts, :driver_opts, [])
    interval = Keyword.get(opts, :heartbeat_interval_ms, @default_heartbeat_interval_ms)
    result_recipient = Keyword.get(opts, :result_recipient)

    state = %{
      worker_id: worker_id,
      run_id: run_id,
      provider: provider,
      prompt: prompt,
      driver_opts: driver_opts,
      interval: interval,
      result_recipient: result_recipient,
      activated?: false
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:overwatch_activate, _worker_id, _run_id, parent}, state) do
    # Activation handshake MUST reply before any blocking work. LaunchWorker
    # enforces a 5s timeout on this reply.
    send(parent, {:overwatch_activated, self()})

    # Schedule periodic heartbeat. First tick fires after `interval`, not
    # immediately — WorkerStarted is LaunchWorker's responsibility.
    Process.send_after(self(), :heartbeat, state.interval)

    # Spawn the agent in a Task tied to this GenServer's lifetime via
    # Process.monitor. When the worker dies, the Task is killed.
    parent_pid = self()

    task =
      Task.async(fn ->
        result = run_agent(state.provider, state.prompt, state.driver_opts)
        send(parent_pid, {:agent_done, result})
      end)

    Process.monitor(task.pid)

    {:noreply, %{state | activated?: true}}
  end

  def handle_info(:heartbeat, state) do
    _ = WorkerProtocol.emit(:heartbeat, %{worker_id: state.worker_id, run_id: state.run_id})
    Process.send_after(self(), :heartbeat, state.interval)
    {:noreply, state}
  end

  def handle_info({:agent_done, result}, state) do
    _ = WorkerProtocol.emit(:worker_exited, %{worker_id: state.worker_id, run_id: state.run_id})

    if state.result_recipient do
      send(state.result_recipient, {:worker_result, result})
    end

    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state) do
    # Monitor fired before/after `:agent_done` arrived. Either is benign —
    # `:agent_done` has already been delivered (or will be). Stay alive until
    # it arrives; if it never does, caller-side timeout will surface.
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    # Task crashed without sending :agent_done. Best-effort WorkerExited +
    # surface the failure to the recipient so RunExecutor does not block
    # forever waiting for a result.
    _ = WorkerProtocol.emit(:worker_exited, %{worker_id: state.worker_id, run_id: state.run_id})

    if state.result_recipient do
      send(state.result_recipient, {:worker_result, {:error, {:task_crashed, reason}}})
    end

    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  # Run the agent, handling both sync and detached cases. Normalize to
  # 2-tuple (matches Invocation.run_attempts/5 at invocation.ex:183):
  #
  #   {:ok, content} | {:error, reason}
  @spec run_agent(atom(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defp run_agent(provider, prompt, driver_opts) do
    case Driver.run(provider, prompt, driver_opts) do
      {:ok, %Jido.Harness.RunResult{} = run_result} ->
        normalize_result(run_result)

      {:ok, detached} when is_map(detached) ->
        run_id = detached[:run_id] || detached["run_id"]
        timeout = Keyword.get(driver_opts, :await_timeout, :infinity)

        case Driver.await(run_id, timeout) do
          {:ok, %Jido.Harness.RunResult{} = run_result} -> normalize_result(run_result)
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  # Unwrap RunResult.normalize's 3-tuple to the 2-tuple RunExecutor expects.
  # Metadata is dropped here — Invocation drops it for the same reason.
  defp normalize_result(%Jido.Harness.RunResult{} = run_result) do
    case RunResult.normalize(run_result) do
      {:ok, text, _metadata} -> {:ok, text}
      {:error, _} = err -> err
    end
  end
end
