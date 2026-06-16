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

  defp empty_projection do
    %{
      commands: %{},
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
         type: "TaskCreated",
         payload: %{task_id: task_id} = payload
       }) do
    task = %{
      task_id: task_id,
      title: Map.get(payload, :title, task_id),
      status: Map.get(payload, :status, "open"),
      updated_at: Map.get(payload, :updated_at)
    }

    put_in(projection, [:tasks, task_id], task)
  end

  defp apply_domain_event(projection, %{
         type: "TaskUpdated",
         payload: %{task_id: task_id} = payload
       }) do
    existing =
      get_in(projection, [:tasks, task_id]) || %{task_id: task_id, title: task_id, status: "open"}

    put_in(projection, [:tasks, task_id], Map.merge(existing, Map.drop(payload, [:task_id])))
  end

  defp apply_domain_event(projection, %{type: "RunStarted", payload: %{run_id: run_id} = payload}) do
    run = %{
      run_id: run_id,
      task_id: Map.get(payload, :task_id),
      status: "in_progress",
      phase_status: %{},
      worker_status: %{}
    }

    put_in(projection, [:runs, run_id], run)
  end

  defp apply_domain_event(projection, %{type: "RunCompleted", payload: %{run_id: run_id}}) do
    update_run_status(projection, run_id, "completed")
  end

  defp apply_domain_event(projection, %{type: "RunFailed", payload: %{run_id: run_id}}) do
    update_run_status(projection, run_id, "failed")
  end

  defp apply_domain_event(projection, %{type: "RunBlocked", payload: %{run_id: run_id}}) do
    update_run_status(projection, run_id, "blocked")
  end

  defp apply_domain_event(projection, %{
         type: "PhaseStarted",
         payload: %{run_id: run_id, phase_id: phase_id}
       }) do
    update_run(projection, run_id, fn run ->
      update_in(run, [:phase_status], &Map.put(&1 || %{}, phase_id, "in_progress"))
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
        %{run_id: run_id, status: "in_progress", phase_status: %{}, worker_status: %{}}

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
