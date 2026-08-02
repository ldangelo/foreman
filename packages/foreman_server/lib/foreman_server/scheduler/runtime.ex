defmodule ForemanServer.Scheduler.Runtime do
  @moduledoc "Single scheduler runtime process that dispatches ready tasks and tracks fire intents."

  use GenServer

  alias ForemanServer.{CommandRouter, EventStore, ProjectionStore, Recovery, WorkflowInterpreter}

  @default_phases []
  @default_tick_interval_ms 5_000
  @server ForemanServer.Scheduler

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    server = Keyword.get(opts, :name, @server)
    GenServer.start_link(__MODULE__, Keyword.delete(opts, :name), name: server)
  end

  @spec tick(keyword()) :: {:ok, map()} | {:error, term()}
  def tick(opts \\ []) do
    GenServer.call(@server, {:tick, opts})
  end

  @spec state() :: map()
  def state, do: GenServer.call(@server, :state)

  @spec handle_event(map()) :: :ok
  def handle_event(event) when is_map(event) do
    GenServer.cast(@server, {:event_appended, event})
  end

  @spec record_intent(map(), map()) :: {:ok, map()} | {:error, term()}
  def record_intent(task, attrs) when is_map(task) and is_map(attrs) do
    with {:ok, run_id} <- required_binary(Map.get(attrs, :run_id), :run_id),
         {:ok, task_id} <- required_binary(Map.get(task, :task_id), :task_id) do
      fire_id = Map.get(attrs, :fire_id, scheduled_fire_id(run_id))
      phase_order = normalized_phase_order(attrs)
      attempt = normalized_attempt(attrs)

      CommandRouter.handle(%{
        command_id: "scheduler-fire-record:#{fire_id}:#{attempt}",
        command_type: "scheduler.fire.record",
        payload: %{
          fire_id: fire_id,
          run_id: run_id,
          task_id: task_id,
          project_id: Map.get(task, :project_id),
          phase_id: Map.get(attrs, :phase_id) || List.first(phase_order),
          phase_order: phase_order,
          attempt: attempt
        }
      })
    end
  end

  @spec confirm_execution(map()) :: {:ok, map()} | {:error, term()}
  def confirm_execution(attrs) when is_map(attrs) do
    with {:ok, run_id} <- required_binary(Map.get(attrs, :run_id), :run_id),
         {:ok, worker_id} <- required_binary(Map.get(attrs, :worker_id), :worker_id) do
      fire_id = Map.get(attrs, :fire_id, scheduled_fire_id(run_id))

      CommandRouter.handle(%{
        command_id: "scheduler-fire-confirm:#{fire_id}:#{worker_id}",
        command_type: "scheduler.fire.confirm",
        payload: %{
          fire_id: fire_id,
          run_id: run_id,
          worker_id: worker_id,
          phase_id: Map.get(attrs, :phase_id)
        }
      })
    end
  end

  @impl true
  def init(opts) do
    started_at = DateTime.utc_now()

    interval_ms =
      Keyword.get(
        opts,
        :tick_interval_ms,
        scheduler_env(:tick_interval_ms, @default_tick_interval_ms)
      )

    auto_tick = Keyword.get(opts, :auto_tick, scheduler_env(:auto_tick, true))

    state = %{
      started_at: started_at,
      recovery_retry_attempts: 5,
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

    schedule_recovery_probe()

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
    confirm_scheduled_fire(event)

    if dispatch_trigger_event?(event) do
      result = dispatch(state)
      {:noreply, %{state | last_tick: result, last_event_id: event_id(event)}}
    else
      {:noreply, %{state | last_event_id: event_id(event)}}
    end
  end

  def handle_cast({:event_appended, event}, state) do
    confirm_scheduled_fire(event)
    {:noreply, %{state | last_event_id: event_id(event)}}
  end

  @impl true
  def handle_info(:recover_unconfirmed_intents, %{recovery_retry_attempts: attempts} = state)
      when attempts > 0 do
    case Process.whereis(Recovery) do
      pid when is_pid(pid) ->
        _ = Recovery.detect_unconfirmed_intents(older_than: state.started_at)
        {:noreply, %{state | recovery_retry_attempts: 0}}

      _ ->
        schedule_recovery_probe()
        {:noreply, %{state | recovery_retry_attempts: attempts - 1}}
    end
  end

  def handle_info(:recover_unconfirmed_intents, state), do: {:noreply, state}

  def handle_info(:tick, %{auto_tick: true, tick_interval_ms: interval_ms} = state) do
    result = dispatch(state)
    schedule_tick(interval_ms)
    {:noreply, %{state | last_tick: result}}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  defp schedule_recovery_probe do
    Process.send_after(self(), :recover_unconfirmed_intents, 25)
  end

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
    fire_id = scheduled_fire_id(run_id)
    effective_phases = get_effective_phases(task, phases)
    project_id = resolve_project_id(task)

    payload =
      Map.merge(task, %{
        run_id: run_id,
        task_id: task.task_id,
        project_id: project_id,
        phase_order: effective_phases,
        workflow: Map.get(task, :workflow) || Map.get(task, :task_type)
      })

    case CommandRouter.handle(%{
           command_id: "run-start:#{run_id}",
           command_type: "run.start",
           payload: payload
         }) do
      {:ok, _event} ->
        finish_claim(task, run_id, fire_id, project_id, effective_phases, worker_launcher)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish_claim(task, run_id, fire_id, project_id, effective_phases, worker_launcher) do
    with {:ok, _} <- emit_task_in_progress(task, run_id),
         {:ok, _} <-
           record_intent(task, %{
             fire_id: fire_id,
             run_id: run_id,
             phase_id: List.first(effective_phases),
             phase_order: effective_phases,
             attempt: 1
           }),
         {:ok, _launch} <- worker_launcher.launch(task, run_id, effective_phases) do
      {:ok, run_id}
    else
      {:error, reason} ->
        rollback_claim(task, run_id, project_id, reason)
        {:error, reason}
    end
  end

  defp emit_task_in_progress(task, run_id) do
    EventStore.append(%{
      stream_id: "task:#{task.task_id}",
      event_type: "TaskUpdated",
      payload: %{task_id: task.task_id, status: "in_progress", run_id: run_id},
      metadata: %{
        correlation_id: run_id,
        idempotency_key: "claim:#{task.task_id}:#{run_id}"
      }
    })
  end

  defp rollback_claim(task, run_id, project_id, reason) do
    cond do
      not is_binary(project_id) or project_id == "" ->
        :ok

      true ->
        _ =
          CommandRouter.handle(%{
            command_id: "run-fail-rollback:#{run_id}",
            command_type: "run.fail",
            payload: %{
              run_id: run_id,
              project_id: project_id,
              task_id: task.task_id,
              reason: inspect(reason),
              reason_type: classify_claim_failure(reason)
            }
          })

        emit_task_rollback(task, run_id, reason)
        :ok
    end
  end

  defp emit_task_rollback(task, run_id, reason) do
    _ =
      EventStore.append(%{
        stream_id: "task:#{task.task_id}",
        event_type: "TaskUpdated",
        payload: %{
          task_id: task.task_id,
          status: "failed",
          run_id: run_id,
          reason: inspect(reason),
          failure_type: "claim_or_launch"
        },
        metadata: %{
          correlation_id: run_id,
          idempotency_key: "task-rollback:#{task.task_id}:#{run_id}"
        }
      })

    :ok
  end

  defp classify_claim_failure({:error, :run_limit_exceeded}), do: "run_limit_exceeded"
  defp classify_claim_failure({:error, :project_id_required}), do: "missing_project_id"
  defp classify_claim_failure(_), do: "claim_or_launch_failure"

  defp resolve_project_id(task) do
    case Map.get(task, :project_id) do
      pid when is_binary(pid) and pid != "" ->
        pid

      _ ->
        snapshot = ProjectionStore.snapshot()

        case get_in(snapshot.tasks, [task.task_id, :project_id]) do
          pid when is_binary(pid) and pid != "" -> pid
          _ -> nil
        end
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

  defp confirm_scheduled_fire(%{event_type: "WorkerStarted", payload: payload}) do
    _ = confirm_execution(payload)
    :ok
  end

  defp confirm_scheduled_fire(_event), do: :ok

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

  defp scheduled_fire_id(run_id), do: run_id

  defp normalized_phase_order(attrs) do
    case Map.get(attrs, :phase_order) do
      phases when is_list(phases) -> phases
      _ -> []
    end
  end

  defp normalized_attempt(attrs) do
    case Map.get(attrs, :attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt
      _ -> 1
    end
  end

  defp required_binary(value, _field) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary(_value, field), do: {:error, {:missing_or_invalid, field}}

  # Get effective phases for a task:
  # 1. If task has explicit phases, use them
  # 2. Otherwise, load phases from workflow YAML based on task_type
  # 3. Fall back to default_phases if workflow loading fails
  defp get_effective_phases(task, default_phases) do
    if Map.has_key?(task, :phases) do
      Map.get(task, :phases)
    else
      task_type = Map.get(task, :task_type)

      case resolve_workflow_phases(task_type) do
        {:ok, phases} -> phases
        {:error, _reason} -> default_phases
      end
    end
  end

  defp resolve_workflow_phases(nil), do: {:error, :no_task_type}

  defp resolve_workflow_phases(task_type) when is_binary(task_type) do
    global_path = Path.join(foreman_home_workflows_path(), "#{task_type}.yaml")

    if File.exists?(global_path) do
      load_workflow_phase_order(global_path)
    else
      bundled_path = bundled_workflow_path(task_type)

      if File.exists?(bundled_path) do
        load_workflow_phase_order(bundled_path)
      else
        {:error, :workflow_not_found}
      end
    end
  end

  defp foreman_home_workflows_path do
    Path.join([System.user_home!(), ".foreman", "workflows"])
  end

  defp bundled_workflow_path(task_type) do
    app_priv_path = Application.app_dir(:foreman_server, "priv")
    Path.join([app_priv_path, "defaults/workflows", "#{task_type}.yaml"])
  end

  defp load_workflow_phase_order(path) do
    case WorkflowInterpreter.load_file(path) do
      {:ok, workflow} ->
        {:ok, Map.get(workflow, :phase_order, [])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp scheduler_env(key, default) do
    :foreman_server
    |> Application.get_env(:scheduler, [])
    |> Keyword.get(key, default)
  end
end
