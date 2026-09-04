defmodule ForemanServer.RunLifecycleReconciler do
  @moduledoc """
  Releases reserved project run slots from terminal run events and periodically
  retries orphaned reservations through RunAdmission.
  """

  use GenServer

  require Logger

  alias EventStore.RecordedEvent

  alias ForemanServer.{
    Aggregate,
    CommandGateway,
    EventStore,
    Identity,
    ProjectionStore,
    RunAdmission,
    Telemetry
  }

  alias ForemanServer.Aggregates.{Project, Run, RunSlots}

  @default_interval_ms 30_000
  @default_timeout_ms 5_000
  @terminal_event_types MapSet.new([
                          "RunCompleted",
                          "RunFailed",
                          "RunCancelled",
                          "RunBlocked",
                          "RunFlaggedStuck"
                        ])
  @definitive_retry_rejections MapSet.new([
                                 :phase_terminal,
                                 :project_archived,
                                 :unknown_project,
                                 :unknown_workflow
                               ])

  @type deps :: %{
          interval_ms: pos_integer(),
          timeout_ms: pos_integer(),
          subscribe_fun: (-> {:ok, term()} | term()),
          ack_fun: (term(), [RecordedEvent.t()] -> :ok | term()),
          list_active_runs_fun: (-> [{String.t(), [String.t()]}]),
          project_loader_fun: (String.t() -> struct()),
          run_loader_fun: (String.t() -> struct()),
          run_admission_fun: (String.t(), map(), pos_integer() ->
                                {:ok, term()} | {:error, term()}),
          dispatch_fun: (map(), pos_integer() -> {:ok, term()} | {:error, term()}),
          telemetry_module: module()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @impl true
  def init(opts) do
    subscriber = self()

    state = %{
      interval_ms:
        Keyword.get(
          opts,
          :interval_ms,
          Application.get_env(:foreman_server, :run_reconciler_interval_ms, @default_interval_ms)
        ),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      subscribe_fun:
        Keyword.get(opts, :subscribe_fun, fn -> subscribe_to_terminal_events(subscriber) end),
      ack_fun: Keyword.get(opts, :ack_fun, &EventStore.ack/2),
      list_active_runs_fun:
        Keyword.get(
          opts,
          :list_active_runs_fun,
          &ProjectionStore.list_projects_with_active_runs/0
        ),
      project_loader_fun: Keyword.get(opts, :project_loader_fun, &load_project_state/1),
      run_loader_fun: Keyword.get(opts, :run_loader_fun, &load_run_state/1),
      run_admission_fun: Keyword.get(opts, :run_admission_fun, &RunAdmission.start/3),
      dispatch_fun: Keyword.get(opts, :dispatch_fun, &CommandGateway.dispatch_system/2),
      telemetry_module: Keyword.get(opts, :telemetry_module, Telemetry),
      subscription: :unknown,
      subscription_ref: nil
    }

    schedule_next_pass(state.interval_ms)

    case state.subscribe_fun.() do
      {:ok, subscription_ref} ->
        {:ok, %{state | subscription: :subscribed, subscription_ref: subscription_ref}}

      :ok ->
        {:ok, %{state | subscription: :subscribed}}

      _other ->
        Process.send_after(self(), :retry_subscribe, 50)
        {:ok, %{state | subscription: :retrying}}
    end
  end

  @impl true
  def handle_info(:retry_subscribe, state) do
    case state.subscribe_fun.() do
      {:ok, subscription_ref} ->
        {:noreply, %{state | subscription: :subscribed, subscription_ref: subscription_ref}}

      :ok ->
        {:noreply, %{state | subscription: :subscribed}}

      _other ->
        Process.send_after(self(), :retry_subscribe, 50)
        {:noreply, state}
    end
  end

  def handle_info({:subscribed, subscription_ref}, state) do
    {:noreply, %{state | subscription: :subscribed, subscription_ref: subscription_ref}}
  end

  def handle_info({:events, events}, %{subscription_ref: nil} = state) when is_list(events) do
    {:noreply, state}
  end

  def handle_info({:events, events}, state) when is_list(events) do
    process_terminal_events(events, state)
    :ok = state.ack_fun.(state.subscription_ref, events)
    {:noreply, state}
  end

  def handle_info(:scheduled, state) do
    reconcile_scheduled(state)
    run_slots_backstop_sweep(state)
    schedule_next_pass(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  @spec process_terminal_event(term(), deps()) :: :ok
  def process_terminal_event(%RecordedEvent{event_type: event_type} = event, state) do
    if MapSet.member?(@terminal_event_types, event_type) do
      payload = Aggregate.event_payload(event)
      run_id = Aggregate.get(payload, :run_id)

      if valid_id?(run_id) do
        run_state = state.run_loader_fun.(run_id)
        project_id = run_project_id(run_state)

        if valid_id?(project_id) do
          started_at_ms = System.monotonic_time(:millisecond)
          release_reservation(project_id, run_id, "terminal_event", state)
          dispatch_slot_release(run_id, "terminal_event", state)

          state.telemetry_module.reconciler_terminal_release(
            elapsed_ms(started_at_ms),
            %{path: :subscribed, project_id: project_id, run_id: run_id, outcome: :released}
          )
        end
      end
    end

    :ok
  end

  def process_terminal_event(_event, _state), do: :ok

  @doc false
  @spec reconcile_scheduled(deps()) :: :ok
  def reconcile_scheduled(state) do
    state.list_active_runs_fun.()
    |> Enum.each(fn {project_id, run_ids} ->
      Enum.each(run_ids, fn run_id ->
        reconcile_pair(project_id, run_id, state)
      end)
    end)

    :ok
  end

  @doc false
  @spec reconcile_pair(String.t(), String.t(), deps()) :: :ok
  def reconcile_pair(project_id, run_id, state)
      when is_binary(project_id) and is_binary(run_id) do
    project_state = state.project_loader_fun.(project_id)
    run_state = state.run_loader_fun.(run_id)

    cond do
      run_terminal?(run_state) ->
        started_at_ms = System.monotonic_time(:millisecond)
        release_reservation(project_id, run_id, "terminal_run", state)

        state.telemetry_module.reconciler_terminal_release(
          elapsed_ms(started_at_ms),
          %{path: :scheduled, project_id: project_id, run_id: run_id, outcome: :released}
        )

      run_absent?(run_state) ->
        retry_absent_run(project_id, run_id, project_state, state)

      run_exists?(run_state) ->
        :ok

      true ->
        :ok
    end
  end

  defp retry_absent_run(project_id, run_id, project_state, state) do
    case reservation_payload(project_state, run_id) do
      nil ->
        :ok

      payload ->
        started_at_ms = System.monotonic_time(:millisecond)
        result = state.run_admission_fun.(project_id, payload, state.timeout_ms)

        state.telemetry_module.reconciler_orphan_retry(
          elapsed_ms(started_at_ms),
          %{project_id: project_id, run_id: run_id, outcome: outcome_for(result)}
        )

        case result do
          {:error, reason} ->
            if MapSet.member?(@definitive_retry_rejections, reason) do
              release_reservation(project_id, run_id, "definitive_retry_rejection", state)
            else
              :ok
            end

          _other ->
            :ok
        end
    end
  end

  defp reservation_payload(%Project.State{active_run_reservations: reservations}, run_id)
       when is_map(reservations) do
    case Aggregate.get(reservations, run_id) do
      reservation when is_map(reservation) -> Aggregate.get(reservation, :run_start_payload)
      _ -> nil
    end
  end

  defp reservation_payload(_project_state, _run_id), do: nil

  defp release_reservation(project_id, run_id, reason, state) do
    state.dispatch_fun.(
      %{
        aggregate_id: "project:#{project_id}",
        command_id:
          Identity.project_run_reservation_release_command_id(project_id, run_id, reason),
        type: "project.release_run_reservation",
        payload: %{project_id: project_id, run_id: run_id, reason: reason}
      },
      state.timeout_ms
    )

    :ok
  end

  defp load_project_state(project_id) do
    {state, _version} = Aggregate.load(Project, "project:#{project_id}")
    state
  end

  defp load_run_state(run_id) do
    {state, _version} = Aggregate.load(Run, "run:#{run_id}")
    state
  end

  defp subscribe_to_terminal_events(subscriber) do
    EventStore.subscribe_to_all_streams(
      terminal_subscription_name(),
      subscriber,
      start_from: :current,
      selector: &terminal_recorded_event?/1
    )
  end

  defp process_terminal_events(events, state) do
    Enum.each(events, &process_terminal_event(&1, state))
  end

  defp terminal_recorded_event?(%RecordedEvent{event_type: event_type}) do
    MapSet.member?(@terminal_event_types, event_type)
  end

  defp terminal_recorded_event?(_event), do: false

  defp terminal_subscription_name do
    "run_lifecycle_reconciler_terminal"
  end

  defp run_project_id(%Run.State{project_id: project_id}), do: project_id
  defp run_project_id(run_state) when is_map(run_state), do: Aggregate.get(run_state, :project_id)
  defp run_project_id(_run_state), do: nil

  defp schedule_next_pass(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :scheduled, interval_ms)
  end

  defp run_terminal?(%Run.State{terminal?: true}), do: true
  defp run_terminal?(_state), do: false

  defp run_absent?(%Run.State{exists?: false}), do: true
  defp run_absent?(_state), do: false

  defp run_exists?(%Run.State{exists?: true}), do: true
  defp run_exists?(_state), do: false
  defp elapsed_ms(started_at_ms), do: max(System.monotonic_time(:millisecond) - started_at_ms, 0)

  defp valid_id?(value), do: is_binary(value) and value != ""

  # TRD-011: Backstop sweep — periodically release stale slot holders whose
  # runs are terminal or absent. This is a safety net for cases where the
  # terminal-event path in the Dispatcher did not fire (e.g. process crash
  # before handle_run_terminated completed).
  defp run_slots_backstop_sweep(state) do
    {run_slots_state, _version} = Aggregate.load(RunSlots, "run_slots:global")

    holders = Map.get(run_slots_state, :holders, %{}) || %{}

    Enum.each(holders, fn {run_id, _holder_data} ->
      if valid_id?(run_id) do
        run_state = state.run_loader_fun.(run_id)

        if run_terminal?(run_state) or run_absent?(run_state) do
          dispatch_slot_release(run_id, "backstop_sweep", state)
        end
      end
    end)

    :ok
  end

  defp dispatch_slot_release(run_id, reason, state) do
    ms = System.monotonic_time(:millisecond)

    command = %{
      aggregate_id: "run_slots:global",
      command_id: "reconciler:slot-release:#{run_id}:#{ms}",
      type: "run_slots.release",
      payload: %{run_id: run_id, reason: reason}
    }

    # Best-effort: the run_slots:global actor can legitimately be mid-restart
    # (e.g. a crash, or a test's deliberate reset) when this fires. This is a
    # reconciliation sweep, not a user-facing command — losing one attempt is
    # safe, since the next terminal event or backstop sweep will retry it. A
    # GenServer.call exit (the target dying mid-call) must NOT be allowed to
    # crash this always-on reconciler process itself.
    try do
      _ = state.dispatch_fun.(command, state.timeout_ms)
      :ok
    catch
      :exit, reason ->
        Logger.warning(
          "RunLifecycleReconciler: run_slots.release dispatch for #{run_id} exited: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp outcome_for({:ok, _}), do: :ok
  defp outcome_for({:error, reason}), do: reason
  defp outcome_for(other), do: other
end
