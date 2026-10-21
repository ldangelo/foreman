defmodule ForemanServer.Coordinator.ProjectWorker do
  @moduledoc """
  The serialized turn loop of ONE project. One worker per project, registered by
  project id, runs turns strictly one at a time; different projects run in
  parallel. A `notify/2` that arrives mid-turn only marks the worker dirty: the
  next turn consumes every message that arrived meanwhile (coalescing).

  The turn runs in a supervised task so the worker stays responsive; a hard
  `turn_timeout_ms` kills a hung task and records the failure. After a failed
  turn the worker retries after `retry_backoff_ms` until the projection says the
  coordinator is unhealthy; from then on nothing runs until `coordinator.restart`.
  """
  use GenServer, restart: :temporary

  require Logger

  alias ForemanServer.Coordinator.{Runtime, TurnRunner}
  alias ForemanServer.ProjectionStore

  @type state :: %{
          project_id: String.t(),
          rt: Runtime.t(),
          task: {reference(), pid()} | nil,
          dirty?: boolean(),
          timed_out?: boolean()
        }

  def start_link({%Runtime{} = rt, project_id}) do
    GenServer.start_link(__MODULE__, {rt, project_id}, name: via(rt, project_id))
  end

  @doc "Ask the project's worker to look for pending work (starts it when needed)."
  @spec notify(Runtime.t(), String.t()) :: :ok
  def notify(%Runtime{} = rt, project_id) do
    case Registry.lookup(rt.registry, project_id) do
      [{pid, _}] ->
        GenServer.cast(pid, :notify)

      [] ->
        case DynamicSupervisor.start_child(rt.worker_sup, {__MODULE__, {rt, project_id}}) do
          {:ok, pid} ->
            GenServer.cast(pid, :notify)

          {:error, {:already_started, pid}} ->
            GenServer.cast(pid, :notify)

          {:error, reason} ->
            Logger.error("coordinator worker for #{project_id} did not start: #{inspect(reason)}")
        end
    end

    :ok
  end

  @doc "True when the project's worker is currently running a turn."
  @spec busy?(Runtime.t(), String.t()) :: boolean()
  def busy?(%Runtime{} = rt, project_id) do
    case Registry.lookup(rt.registry, project_id) do
      [{pid, _}] -> GenServer.call(pid, :busy?)
      [] -> false
    end
  end

  defp via(rt, project_id), do: {:via, Registry, {rt.registry, project_id}}

  @impl true
  def init({rt, project_id}),
    do: {:ok, %{project_id: project_id, rt: rt, task: nil, dirty?: false, timed_out?: false}}

  @impl true
  def handle_call(:busy?, _from, state), do: {:reply, state.task != nil, state}

  @impl true
  def handle_cast(:notify, state), do: {:noreply, maybe_start(state)}

  @impl true
  def handle_info(:retry, state), do: {:noreply, maybe_start(state)}

  def handle_info({ref, result}, %{task: {ref, _pid}} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, after_turn(%{state | task: nil}, result)}
  end

  # The runtime is shutting down: the turn stays open in the log and is recovered
  # as `interrupted` on the next start.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: {ref, _}} = state)
      when reason == :shutdown or (is_tuple(reason) and elem(reason, 0) == :shutdown),
      do: {:noreply, %{state | task: nil}}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: {ref, _}} = state) do
    Logger.warning("coordinator #{state.project_id}: turn task ended #{inspect(reason)}")

    if state.timed_out? do
      TurnRunner.fail_open_turn(
        state.project_id,
        state.rt,
        :agent_timeout,
        "the turn exceeded #{state.rt.turn_timeout_ms}ms"
      )
    end

    {:noreply, after_turn(%{state | task: nil, timed_out?: false}, {:failed, :crashed})}
  end

  def handle_info({:turn_timeout, ref}, %{task: {ref, pid}} = state) do
    Process.exit(pid, :kill)
    {:noreply, %{state | timed_out?: true}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp maybe_start(%{task: nil} = state) do
    project_id = state.project_id
    rt = state.rt
    task = Task.Supervisor.async_nolink(rt.task_sup, fn -> TurnRunner.run(project_id, rt) end)
    Process.send_after(self(), {:turn_timeout, task.ref}, rt.turn_timeout_ms)
    %{state | task: {task.ref, task.pid}, dirty?: false}
  end

  defp maybe_start(state), do: %{state | dirty?: true}

  defp after_turn(state, :idle), do: if(state.dirty?, do: maybe_start(state), else: state)
  defp after_turn(state, :ok), do: maybe_start(state)

  defp after_turn(state, {:failed, _code}) do
    case ProjectionStore.coordinator_status(state.project_id) do
      {:ok, %{status: :unhealthy}} -> state
      _ -> schedule_retry(state)
    end
  end

  defp after_turn(state, other) do
    Logger.warning("coordinator #{state.project_id}: unexpected turn result #{inspect(other)}")
    state
  end

  defp schedule_retry(state) do
    Process.send_after(self(), :retry, state.rt.retry_backoff_ms)
    state
  end
end
