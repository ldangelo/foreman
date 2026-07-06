defmodule ForemanServer.Scheduler do
  @moduledoc "Supervised scheduler that claims dispatchable tasks under global and project capacity."

  use GenServer

  alias ForemanServer.{EventStore, ProjectionStore}

  @default_phases []
  @default_tick_interval_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec tick(keyword()) :: {:ok, map()} | {:error, term()}
  def tick(opts \\ []) do
    GenServer.call(__MODULE__, {:tick, opts})
  end

  @spec state() :: map()
  def state, do: GenServer.call(__MODULE__, :state)

  @spec handle_event(map()) :: :ok
  def handle_event(event) when is_map(event) do
    GenServer.cast(__MODULE__, {:event_appended, event})
  end

  @impl true
  def init(opts) do
    interval_ms =
      Keyword.get(
        opts,
        :tick_interval_ms,
        scheduler_env(:tick_interval_ms, @default_tick_interval_ms)
      )

    auto_tick = Keyword.get(opts, :auto_tick, scheduler_env(:auto_tick, true))

    state = %{
      max_concurrent: Keyword.get(opts, :max_concurrent, scheduler_env(:max_concurrent, 2)),
      project_limits: Keyword.get(opts, :project_limits, scheduler_env(:project_limits, %{})),
      default_phases: Keyword.get(opts, :default_phases, @default_phases),
      worker_launcher:
        Keyword.get(
          opts,
          :worker_launcher,
          scheduler_env(:worker_launcher, ForemanServer.WorkerLauncher)
        ),
      auto_tick: auto_tick,
      event_triggered_ticks:
        Keyword.get(opts, :event_triggered_ticks, scheduler_env(:event_triggered_ticks, true)),
      tick_interval_ms: interval_ms,
      last_tick: nil,
      last_event_id: nil
    }

    if auto_tick, do: schedule_tick(interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_call({:tick, opts}, _from, state) do
    effective = %{
      state
      | max_concurrent: Keyword.get(opts, :max_concurrent, state.max_concurrent),
        project_limits: Keyword.get(opts, :project_limits, state.project_limits),
        default_phases: Keyword.get(opts, :default_phases, state.default_phases),
        worker_launcher: Keyword.get(opts, :worker_launcher, state.worker_launcher)
    }

    result = dispatch(effective)
    {:reply, {:ok, result}, %{effective | last_tick: result}}
  end

  @impl true
  def handle_cast({:event_appended, event}, %{event_triggered_ticks: true} = state) do
    if dispatch_trigger_event?(event) do
      result = dispatch(state)
      {:noreply, %{state | last_tick: result, last_event_id: event_id(event)}}
    else
      {:noreply, %{state | last_event_id: event_id(event)}}
    end
  end

  def handle_cast({:event_appended, event}, state),
    do: {:noreply, %{state | last_event_id: event_id(event)}}

  @impl true
  def handle_info(:tick, %{auto_tick: true, tick_interval_ms: interval_ms} = state) do
    result = dispatch(state)
    schedule_tick(interval_ms)
    {:noreply, %{state | last_tick: result}}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  defp schedule_tick(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp dispatch_trigger_event?(%{event_type: event_type, payload: payload})
       when event_type in ["TaskCreated", "TaskUpdated", "TaskApproved", "TaskStatusChanged"] do
    Map.get(payload, :status) in ["ready", "approved"]
  end

  defp dispatch_trigger_event?(_event), do: false

  defp event_id(%{event_id: event_id}), do: event_id
  defp event_id(_event), do: nil

  defp dispatch(state) do
    tasks = ProjectionStore.dispatchable_tasks()
    active_runs = active_runs()

    {claimed, skipped, _active_count, _project_counts} =
      Enum.reduce(tasks, {[], [], length(active_runs), project_counts(active_runs)}, fn task,
                                                                                        {claimed,
                                                                                         skipped,
                                                                                         active_count,
                                                                                         project_counts} ->
        project_id = Map.get(task, :project_id)

        cond do
          active_count >= state.max_concurrent ->
            skip(
              task,
              "global_capacity_exhausted",
              skipped,
              claimed,
              active_count,
              project_counts
            )

          project_at_capacity?(project_id, project_counts, state.project_limits) ->
            skip(
              task,
              "project_capacity_exhausted",
              skipped,
              claimed,
              active_count,
              project_counts
            )

          true ->
            case claim_task(task, state.default_phases, state.worker_launcher) do
              {:ok, run_id} ->
                next_project_counts = Map.update(project_counts, project_id, 1, &(&1 + 1))

                {claimed ++ [%{task_id: task.task_id, run_id: run_id}], skipped, active_count + 1,
                 next_project_counts}

              {:error, reason} ->
                skip(task, inspect(reason), skipped, claimed, active_count, project_counts)
            end
        end
      end)

    %{
      claimed: claimed,
      skipped: skipped,
      active_runs: length(active_runs),
      active_run_details: active_runs,
      stale_active_runs: stale_active_runs(active_runs)
    }
  end

  defp claim_task(task, phases, worker_launcher) do
    run_id = uuid()
    effective_phases = Map.get(task, :phases, phases)

    with {:ok, _event} <-
           EventStore.append(%{
             stream_id: "task:#{task.task_id}",
             event_type: "TaskUpdated",
             payload: %{task_id: task.task_id, status: "in_progress", run_id: run_id},
             metadata: %{
               correlation_id: run_id,
               idempotency_key: "claim:#{task.task_id}:#{run_id}"
             }
           }),
         {:ok, _event} <-
           EventStore.append(%{
             stream_id: "run:#{run_id}",
             event_type: "RunStarted",
             payload: %{
               run_id: run_id,
               task_id: task.task_id,
               phase_order: effective_phases,
               workflow: Map.get(task, :workflow) || Map.get(task, :task_type)
             },
             metadata: %{
               correlation_id: run_id,
               idempotency_key: "run-start:#{run_id}"
             }
           }),
         {:ok, _launch} <- worker_launcher.launch(task, run_id, effective_phases) do
      {:ok, run_id}
    end
  end

  defp skip(task, reason, skipped, claimed, active_count, project_counts) do
    payload = %{task_id: task.task_id, project_id: Map.get(task, :project_id), reason: reason}

    _ =
      EventStore.append(%{
        stream_id: "scheduler:#{task.task_id}",
        event_type: "SchedulerTaskSkipped",
        payload: payload,
        metadata: %{
          correlation_id: task.task_id,
          idempotency_key: "skip:#{task.task_id}:#{reason}"
        }
      })

    {claimed, skipped ++ [payload], active_count, project_counts}
  end

  defp active_runs do
    snapshot = ProjectionStore.snapshot()
    now = DateTime.utc_now()

    snapshot.runs
    |> Map.values()
    |> Enum.filter(fn run ->
      task = Map.get(snapshot.tasks, Map.get(run, :task_id))

      Map.get(run, :status) == "in_progress" and
        Map.get(task || %{}, :status) in ["in_progress", "in-progress"]
    end)
    |> Enum.map(fn run ->
      task = Map.get(snapshot.tasks, Map.get(run, :task_id), %{})
      updated_at = Map.get(run, :updated_at) || Map.get(task, :updated_at)

      %{
        run_id: Map.get(run, :run_id),
        task_id: Map.get(run, :task_id),
        project_id: Map.get(task, :project_id),
        task_status: Map.get(task, :status),
        run_status: Map.get(run, :status),
        updated_at: updated_at,
        age_seconds: age_seconds(updated_at, now),
        stale: stale?(updated_at, now)
      }
    end)
  end

  defp stale_active_runs(active_runs), do: Enum.filter(active_runs, &Map.get(&1, :stale))

  defp stale?(nil, _now), do: true

  defp stale?(updated_at, now),
    do: age_seconds(updated_at, now) > scheduler_env(:stale_active_seconds, 30 * 60)

  defp age_seconds(nil, _now), do: nil
  defp age_seconds(%DateTime{} = updated_at, now), do: DateTime.diff(now, updated_at, :second)

  defp age_seconds(updated_at, now) when is_binary(updated_at) do
    case DateTime.from_iso8601(updated_at) do
      {:ok, parsed, _offset} -> DateTime.diff(now, parsed, :second)
      _ -> nil
    end
  end

  defp project_counts(runs) do
    tasks = ProjectionStore.snapshot().tasks

    Enum.reduce(runs, %{}, fn run, acc ->
      project_id = get_in(tasks, [Map.get(run, :task_id), :project_id])
      Map.update(acc, project_id, 1, &(&1 + 1))
    end)
  end

  defp project_at_capacity?(nil, _counts, _limits), do: false

  defp project_at_capacity?(project_id, counts, limits) do
    case Map.get(limits, project_id) || Map.get(limits, to_string(project_id)) do
      limit when is_integer(limit) -> Map.get(counts, project_id, 0) >= limit
      _ -> false
    end
  end

  defp uuid do
    bytes = :crypto.strong_rand_bytes(16)
    <<a::32, b::16, c::16, d::16, e::48>> = bytes

    Enum.join(
      [
        Base.encode16(<<a::32>>, case: :lower),
        Base.encode16(<<b::16>>, case: :lower),
        Base.encode16(<<c::16>>, case: :lower),
        Base.encode16(<<d::16>>, case: :lower),
        Base.encode16(<<e::48>>, case: :lower)
      ],
      "-"
    )
  end

  defp scheduler_env(key, default) do
    :foreman_server
    |> Application.get_env(:scheduler, [])
    |> Keyword.get(key, default)
  end
end
