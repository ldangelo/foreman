defmodule ForemanServer.ProjectionStore do
  @moduledoc "In-memory CQRS read models rebuilt from the durable event log."

  use GenServer

  @terminal_run_statuses MapSet.new(["completed", "failed", "blocked"])

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec apply_event(map()) :: :ok
  def apply_event(event) when is_map(event) do
    GenServer.call(__MODULE__, {:apply_event, event})
  end

  @spec rebuild([map()]) :: {:ok, map()}
  def rebuild(events) when is_list(events) do
    GenServer.call(__MODULE__, {:rebuild, events})
  end

  @spec snapshot() :: map()
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @spec project(String.t()) :: map() | nil
  def project(project_id) when is_binary(project_id) do
    GenServer.call(__MODULE__, {:project, project_id})
  end

  @spec project_list() :: [map()]
  def project_list do
    GenServer.call(__MODULE__, :project_list)
  end

  @spec task(String.t()) :: map() | nil
  def task(task_id) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:task, task_id})
  end

  @spec task_list() :: [map()]
  def task_list do
    GenServer.call(__MODULE__, :task_list)
  end

  @spec status_counts() :: map()
  def status_counts do
    GenServer.call(__MODULE__, :status_counts)
  end

  @spec dispatchable_tasks() :: [map()]
  def dispatchable_tasks do
    GenServer.call(__MODULE__, :dispatchable_tasks)
  end

  @impl true
  def init(_opts) do
    {:ok, empty_projection()}
  end

  @impl true
  def handle_call({:apply_event, event}, _from, projection) do
    {:reply, :ok, reduce_event(projection, event)}
  end

  def handle_call({:rebuild, events}, _from, _projection) do
    rebuilt = Enum.reduce(events, empty_projection(), &reduce_event(&2, &1))
    {:reply, {:ok, rebuilt}, rebuilt}
  end

  def handle_call(:snapshot, _from, projection) do
    {:reply, projection, projection}
  end

  def handle_call({:project, project_id}, _from, projection) do
    {:reply, get_in(projection, [:projects, project_id]), projection}
  end

  def handle_call(:project_list, _from, projection) do
    projects =
      projection.projects
      |> Map.values()
      |> Enum.sort_by(& &1.project_id)

    {:reply, projects, projection}
  end

  def handle_call({:task, task_id}, _from, projection) do
    {:reply, get_in(projection, [:tasks, task_id]), projection}
  end

  def handle_call(:task_list, _from, projection) do
    tasks =
      projection.tasks
      |> Map.values()
      |> Enum.sort_by(& &1.task_id)

    {:reply, tasks, projection}
  end

  def handle_call(:status_counts, _from, projection) do
    {:reply, projection.status_counts, projection}
  end

  def handle_call(:dispatchable_tasks, _from, projection) do
    tasks =
      projection.tasks
      |> Map.values()
      |> Enum.filter(&dispatchable?(&1, projection.tasks))
      |> Enum.sort_by(& &1.task_id)

    {:reply, tasks, projection}
  end

  defp empty_projection do
    %{
      commands: %{},
      projects: %{},
      tasks: %{},
      runs: %{},
      status_counts: %{active: 0, in_progress: 0, failed: 0, blocked: 0, completed: 0},
      checkpoint: %{last_event_id: nil, last_stream_version: 0, updated_at: nil},
      last_sequence: 0
    }
  end

  defp reduce_event(projection, event) do
    projection
    |> apply_domain_event(normalize_event(event))
    |> update_checkpoint(event)
    |> recompute_status_counts()
  end

  defp apply_domain_event(projection, %{
         type: "CommandAccepted",
         payload: %{command_id: command_id} = payload
       }) do
    put_in(projection, [:commands, command_id], payload)
  end

  defp apply_domain_event(projection, %{
         type: "ProjectRegistered",
         payload: %{project_id: project_id} = payload
       }) do
    project = %{
      project_id: project_id,
      path: Map.fetch!(payload, :path),
      status: Map.get(payload, :status, "active"),
      default_branch: Map.get(payload, :default_branch, "main"),
      config: Map.get(payload, :config, %{}),
      health: Map.get(payload, :health, %{ok: true}),
      updated_at: Map.get(payload, :updated_at)
    }

    put_in(projection, [:projects, project_id], project)
  end

  defp apply_domain_event(projection, %{
         type: "TaskCreated",
         payload: %{task_id: task_id} = payload
       }) do
    task =
      %{
        task_id: task_id,
        title: Map.get(payload, :title, task_id),
        status: Map.get(payload, :status, "open"),
        updated_at: Map.get(payload, :updated_at)
      }
      |> maybe_put(:project_id, Map.get(payload, :project_id))
      |> maybe_put(:dependencies, Map.get(payload, :dependencies))

    put_in(projection, [:tasks, task_id], task)
  end

  defp apply_domain_event(projection, %{
         type: "TaskUpdated",
         payload: %{task_id: task_id} = payload
       }) do
    existing = empty_task(task_id)
    existing = get_in(projection, [:tasks, task_id]) || existing

    put_in(projection, [:tasks, task_id], Map.merge(existing, Map.drop(payload, [:task_id])))
  end

  defp apply_domain_event(projection, %{
         type: "TaskAnnotated",
         payload: %{task_id: task_id} = payload
       }) do
    existing = get_in(projection, [:tasks, task_id]) || empty_task(task_id)

    annotation = %{
      body: Map.fetch!(payload, :body),
      author: Map.get(payload, :author),
      created_at: Map.get(payload, :created_at)
    }

    task =
      existing
      |> Map.update(:annotations, [annotation], &(&1 ++ [annotation]))
      |> Map.put(:updated_at, annotation.created_at)

    put_in(projection, [:tasks, task_id], task)
  end

  defp apply_domain_event(projection, %{
         type: "TaskDependencyAdded",
         payload: %{task_id: task_id, depends_on: depends_on} = payload
       }) do
    existing = get_in(projection, [:tasks, task_id]) || empty_task(task_id)

    task =
      existing
      |> Map.update(:dependencies, [depends_on], fn deps -> Enum.uniq(deps ++ [depends_on]) end)
      |> Map.put(:updated_at, Map.get(payload, :updated_at))

    put_in(projection, [:tasks, task_id], task)
  end

  defp apply_domain_event(projection, %{type: "RunStarted", payload: %{run_id: run_id} = payload}) do
    run = %{
      run_id: run_id,
      task_id: Map.get(payload, :task_id),
      status: "in_progress",
      phase_order: Map.get(payload, :phase_order, []),
      current_phase: Map.get(payload, :current_phase),
      phase_status: %{},
      worker_status: %{},
      retry_history: []
    }

    put_in(projection, [:runs, run_id], run)
  end

  defp apply_domain_event(projection, %{type: "RunCompleted", payload: %{run_id: run_id}}) do
    projection
    |> update_run_status(run_id, "completed")
    |> update_run(run_id, &Map.put(&1, :current_phase, nil))
  end

  defp apply_domain_event(projection, %{type: "RunFailed", payload: %{run_id: run_id} = payload}) do
    projection
    |> update_run_status(run_id, "failed")
    |> update_run(run_id, fn run ->
      run
      |> Map.put(:current_phase, Map.get(payload, :phase_id, Map.get(run, :current_phase)))
      |> Map.put(
        :retry_history,
        Map.get(payload, :retry_history, Map.get(run, :retry_history, []))
      )
    end)
  end

  defp apply_domain_event(projection, %{type: "RunBlocked", payload: %{run_id: run_id}}) do
    update_run_status(projection, run_id, "blocked")
  end

  defp apply_domain_event(projection, %{
         type: "PhaseStarted",
         payload: %{run_id: run_id, phase_id: phase_id}
       }) do
    update_run(projection, run_id, fn run ->
      run
      |> Map.put(:current_phase, phase_id)
      |> update_in([:phase_status], &Map.put(&1 || %{}, phase_id, "in_progress"))
    end)
  end

  defp apply_domain_event(projection, %{
         type: "PhaseCompleted",
         payload: %{run_id: run_id, phase_id: phase_id}
       }) do
    update_run(projection, run_id, fn run ->
      update_in(run, [:phase_status], &Map.put(&1 || %{}, phase_id, "completed"))
    end)
  end

  defp apply_domain_event(projection, %{
         type: type,
         payload: %{run_id: run_id, phase_id: phase_id} = payload
       })
       when type in ["PhaseFailed", "PhaseTimedOut"] do
    status = if type == "PhaseTimedOut", do: "timed_out", else: "failed"

    update_run(projection, run_id, fn run ->
      run
      |> update_in([:phase_status], &Map.put(&1 || %{}, phase_id, status))
      |> Map.put(
        :retry_history,
        Map.get(payload, :retry_history, Map.get(run, :retry_history, []))
      )
    end)
  end

  defp apply_domain_event(projection, %{
         type: "PhaseRetried",
         payload: %{run_id: run_id, phase_id: phase_id} = payload
       }) do
    update_run(projection, run_id, fn run ->
      run
      |> Map.put(:current_phase, phase_id)
      |> update_in([:phase_status], &Map.put(&1 || %{}, phase_id, "retrying"))
      |> Map.put(
        :retry_history,
        Map.get(payload, :retry_history, Map.get(run, :retry_history, []))
      )
    end)
  end

  defp apply_domain_event(projection, %{
         type: "WorkerStatusChanged",
         payload: %{run_id: run_id, worker_id: worker_id, status: status}
       }) do
    update_run(projection, run_id, fn run ->
      update_in(run, [:worker_status], &Map.put(&1 || %{}, worker_id, status))
    end)
  end

  defp apply_domain_event(projection, _event), do: projection

  defp update_run_status(projection, run_id, status) do
    update_run(projection, run_id, &Map.put(&1, :status, status))
  end

  defp update_run(projection, run_id, fun) do
    existing =
      get_in(projection, [:runs, run_id]) ||
        %{
          run_id: run_id,
          status: "in_progress",
          phase_order: [],
          current_phase: nil,
          phase_status: %{},
          worker_status: %{},
          retry_history: []
        }

    put_in(projection, [:runs, run_id], fun.(existing))
  end

  defp update_checkpoint(projection, event) do
    checkpoint = %{
      last_event_id: Map.get(event, :event_id),
      last_stream_version: Map.get(event, :stream_version, Map.get(event, :sequence, 0)),
      updated_at: DateTime.utc_now()
    }

    projection
    |> Map.put(:checkpoint, checkpoint)
    |> Map.put(:last_sequence, checkpoint.last_stream_version)
  end

  defp recompute_status_counts(projection) do
    counts = %{active: 0, in_progress: 0, failed: 0, blocked: 0, completed: 0}

    status_counts =
      Enum.reduce(projection.runs, counts, fn {_run_id, run}, acc ->
        status = Map.get(run, :status, "in_progress")

        acc
        |> increment_run_status(status)
        |> maybe_increment_active(status)
      end)

    Map.put(projection, :status_counts, status_counts)
  end

  defp increment_run_status(counts, "in_progress"),
    do: Map.update!(counts, :in_progress, &(&1 + 1))

  defp increment_run_status(counts, "failed"), do: Map.update!(counts, :failed, &(&1 + 1))
  defp increment_run_status(counts, "blocked"), do: Map.update!(counts, :blocked, &(&1 + 1))
  defp increment_run_status(counts, "completed"), do: Map.update!(counts, :completed, &(&1 + 1))
  defp increment_run_status(counts, _status), do: counts

  defp maybe_increment_active(counts, status) do
    if MapSet.member?(@terminal_run_statuses, status),
      do: counts,
      else: Map.update!(counts, :active, &(&1 + 1))
  end

  defp dispatchable?(%{status: status} = task, tasks) when status in ["ready", "approved"] do
    task
    |> Map.get(:dependencies, [])
    |> Enum.all?(fn dependency_id ->
      match?(%{status: "closed"}, Map.get(tasks, dependency_id))
    end)
  end

  defp dispatchable?(_task, _tasks), do: false

  defp empty_task(task_id) do
    %{task_id: task_id, title: task_id, status: "open", updated_at: nil}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_event(%ForemanServer.Event{} = event) do
    %{type: event.event_type, payload: event.payload}
  end

  defp normalize_event(%{event_type: event_type, payload: payload}) do
    %{type: event_type, payload: payload}
  end

  defp normalize_event(%{type: type, payload: payload}) do
    %{type: type, payload: payload}
  end
end
