defmodule ForemanServer.RunActor do
  @moduledoc "OTP run state machine that records deterministic phase transitions as events."

  use GenServer

  alias ForemanServer.{EventStore, Inbox, PhaseActor}

  @terminal [:completed, :failed]

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(%{run_id: run_id} = spec) do
    GenServer.start_link(__MODULE__, spec, name: via(run_id))
  end

  @spec child_spec(map()) :: Supervisor.child_spec()
  def child_spec(%{run_id: run_id} = spec) do
    %{
      id: {__MODULE__, run_id},
      start: {__MODULE__, :start_link, [spec]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  @spec start_run(map()) :: {:ok, pid()} | {:error, term()}
  def start_run(%{run_id: _run_id} = spec) do
    case DynamicSupervisor.start_child(ForemanServer.RunDynamicSupervisor, {__MODULE__, spec}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  rescue
    ArgumentError -> start_link(spec)
  end

  @spec state(String.t()) :: map() | nil
  def state(run_id) do
    case GenServer.whereis(via(run_id)) do
      nil -> nil
      pid -> GenServer.call(pid, :state)
    end
  end

  @spec pass(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def pass(run_id, details \\ %{}), do: transition(run_id, :pass, details)

  @spec fail(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def fail(run_id, details \\ %{}), do: transition(run_id, :fail, details)

  @spec timeout(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def timeout(run_id, details \\ %{}), do: transition(run_id, :timeout, details)

  defp transition(run_id, action, details) do
    case GenServer.whereis(via(run_id)) do
      nil -> {:error, :run_not_found}
      pid -> GenServer.call(pid, {action, details})
    end
  end

  @impl true
  def init(%{run_id: run_id, phases: phases} = spec) when is_list(phases) and phases != [] do
    phase_order = Enum.map(phases, &phase_id/1)
    current_phase = hd(phase_order)

    state = %{
      run_id: run_id,
      task_id: Map.get(spec, :task_id),
      phase_order: phase_order,
      current_phase: current_phase,
      phase_index: 0,
      status: :in_progress,
      retry_counts: %{},
      retry_history: [],
      max_retries: Map.get(spec, :max_retries, 0),
      mail_hooks: Map.get(spec, :mail_hooks, %{})
    }

    with {:ok, _event} <-
           append(run_id, "RunStarted", %{
             run_id: run_id,
             task_id: state.task_id,
             phase_order: phase_order,
             current_phase: current_phase
           }),
         :ok <- start_phase(state, current_phase) do
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  def init(_spec), do: {:stop, :invalid_run_spec}

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_call({_action, _details}, _from, %{status: status} = state)
      when status in @terminal do
    {:reply, {:error, {:terminal_run, status}}, state}
  end

  def handle_call({:pass, details}, _from, state) do
    phase_id = state.current_phase

    with :ok <- PhaseActor.transition(state.run_id, phase_id, :completed, details),
         {:ok, _event} <-
           append(state.run_id, "PhaseCompleted", phase_payload(state, phase_id, details)),
         {:ok, _messages} <-
           append_phase_mail(state, "PhaseCompleted", phase_payload(state, phase_id, details)) do
      advance_after_pass(state)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:fail, details}, _from, state),
    do: fail_or_retry(state, "PhaseFailed", details)

  def handle_call({:timeout, details}, _from, state),
    do: fail_or_retry(state, "PhaseTimedOut", details)

  defp advance_after_pass(%{phase_index: index, phase_order: phase_order} = state)
       when index + 1 < length(phase_order) do
    next_phase = Enum.at(phase_order, index + 1)
    next = %{state | current_phase: next_phase, phase_index: index + 1}

    with :ok <- start_phase(next, next_phase) do
      {:reply, {:ok, next}, next}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp advance_after_pass(state) do
    next = %{state | status: :completed, current_phase: nil}

    case append(state.run_id, "RunCompleted", %{run_id: state.run_id}) do
      {:ok, _event} -> {:reply, {:ok, next}, next}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp fail_or_retry(state, event_type, details) do
    phase_id = state.current_phase
    retry_count = Map.get(state.retry_counts, phase_id, 0)

    with :ok <- PhaseActor.transition(state.run_id, phase_id, failed_status(event_type), details),
         {:ok, _event} <-
           append(state.run_id, event_type, phase_payload(state, phase_id, details)),
         {:ok, _messages} <- maybe_append_failed_mail(state, event_type, phase_id, details) do
      if retry_count < state.max_retries do
        retry_phase(state, phase_id, retry_count + 1, event_type, details)
      else
        fail_run(state, phase_id, retry_count, event_type, details)
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp retry_phase(state, phase_id, attempt, reason, details) do
    history_entry = %{phase_id: phase_id, attempt: attempt, reason: reason, details: details}

    next = %{
      state
      | retry_counts: Map.put(state.retry_counts, phase_id, attempt),
        retry_history: state.retry_history ++ [history_entry]
    }

    with {:ok, _event} <-
           append(state.run_id, "PhaseRetried", %{
             run_id: state.run_id,
             phase_id: phase_id,
             attempt: attempt,
             reason: reason,
             retry_history: next.retry_history
           }),
         :ok <- PhaseActor.transition(state.run_id, phase_id, :in_progress, %{attempt: attempt}),
         {:ok, _event} <-
           append(
             state.run_id,
             "PhaseStarted",
             phase_payload(next, phase_id, %{attempt: attempt})
           ),
         {:ok, _messages} <-
           append_phase_mail(
             next,
             "PhaseStarted",
             phase_payload(next, phase_id, %{attempt: attempt})
           ) do
      {:reply, {:ok, next}, next}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp fail_run(state, phase_id, retry_count, reason, details) do
    history_entry = %{phase_id: phase_id, attempt: retry_count, reason: reason, details: details}
    history = state.retry_history ++ [history_entry]
    next = %{state | status: :failed, retry_history: history}

    case append(state.run_id, "RunFailed", %{
           run_id: state.run_id,
           phase_id: phase_id,
           reason: reason,
           retry_history: history
         }) do
      {:ok, _event} -> {:reply, {:ok, next}, next}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp start_phase(state, phase_id) do
    case PhaseActor.start_link(%{run_id: state.run_id, phase_id: phase_id, status: :in_progress}) do
      {:ok, _pid} -> append_phase_started(state, phase_id)
      {:error, {:already_started, _pid}} -> append_phase_started(state, phase_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_phase_started(state, phase_id) do
    payload = phase_payload(state, phase_id, %{})

    with {:ok, _event} <- append(state.run_id, "PhaseStarted", payload),
         {:ok, _messages} <- append_phase_mail(state, "PhaseStarted", payload) do
      :ok
    end
  end

  defp append(run_id, event_type, payload) do
    EventStore.append(%{
      stream_id: "run:#{run_id}",
      event_type: event_type,
      payload: payload,
      metadata: %{correlation_id: run_id}
    })
  end

  defp phase_payload(state, phase_id, details) do
    %{
      run_id: state.run_id,
      phase_id: phase_id,
      details: details,
      retry_history: state.retry_history
    }
  end

  defp append_phase_mail(state, event_type, payload) do
    Inbox.append_phase_mail(event_type, payload, phase_hooks(state, payload.phase_id))
  end

  defp maybe_append_failed_mail(state, "PhaseFailed", phase_id, details),
    do: append_phase_mail(state, "PhaseFailed", phase_payload(state, phase_id, details))

  defp maybe_append_failed_mail(_state, _event_type, _phase_id, _details), do: {:ok, []}

  defp phase_hooks(state, phase_id) do
    state.mail_hooks
    |> Map.get(phase_id, Map.get(state.mail_hooks, to_string(phase_id), %{}))
  end

  defp phase_id(%{id: id}) when is_binary(id), do: id
  defp phase_id(%{"id" => id}) when is_binary(id), do: id
  defp phase_id(id) when is_binary(id), do: id

  defp failed_status("PhaseTimedOut"), do: :timed_out
  defp failed_status(_event_type), do: :failed

  defp via(run_id), do: {:global, {__MODULE__, run_id}}
end
