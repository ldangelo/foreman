defmodule ForemanServer.Scheduler do
  @moduledoc "Supervised scheduler that claims dispatchable tasks under global and project capacity."

  use GenServer

  alias ForemanServer.{EventStore, ProjectionStore, RunActor}

  @default_phases ["developer"]

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

  @impl true
  def init(opts) do
    {:ok,
     %{
       max_concurrent: Keyword.get(opts, :max_concurrent, scheduler_env(:max_concurrent, 2)),
       project_limits: Keyword.get(opts, :project_limits, scheduler_env(:project_limits, %{})),
       default_phases: Keyword.get(opts, :default_phases, @default_phases),
       last_tick: nil
     }}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_call({:tick, opts}, _from, state) do
    effective = %{
      state
      | max_concurrent: Keyword.get(opts, :max_concurrent, state.max_concurrent),
        project_limits: Keyword.get(opts, :project_limits, state.project_limits),
        default_phases: Keyword.get(opts, :default_phases, state.default_phases)
    }

    result = dispatch(effective)
    {:reply, {:ok, result}, %{effective | last_tick: result}}
  end

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
            case claim_task(task, state.default_phases) do
              {:ok, run_id} ->
                next_project_counts = Map.update(project_counts, project_id, 1, &(&1 + 1))

                {claimed ++ [%{task_id: task.task_id, run_id: run_id}], skipped, active_count + 1,
                 next_project_counts}

              {:error, reason} ->
                skip(task, inspect(reason), skipped, claimed, active_count, project_counts)
            end
        end
      end)

    %{claimed: claimed, skipped: skipped, active_runs: length(active_runs)}
  end

  defp claim_task(task, phases) do
    run_id = "run-#{task.task_id}"

    with {:ok, _event} <-
           EventStore.append(%{
             stream_id: "task:#{task.task_id}",
             event_type: "TaskUpdated",
             payload: %{task_id: task.task_id, status: "in_progress", run_id: run_id},
             metadata: %{correlation_id: run_id, idempotency_key: "claim:#{task.task_id}"}
           }),
         {:ok, _pid} <-
           RunActor.start_run(%{
             run_id: run_id,
             task_id: task.task_id,
             phases: Map.get(task, :phases, phases)
           }) do
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
    ProjectionStore.snapshot().runs
    |> Map.values()
    |> Enum.filter(&(Map.get(&1, :status) == "in_progress"))
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

  defp scheduler_env(key, default) do
    :foreman_server
    |> Application.get_env(:scheduler, [])
    |> Keyword.get(key, default)
  end
end
