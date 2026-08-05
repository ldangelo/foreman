defmodule ForemanServer.Workflow.Dispatcher do
  @moduledoc """
  Supervised workflow dispatcher.

  Subscribes to `ProjectionStore` event broadcasts and reacts to:

    * `TaskApproved` — issues a deterministic `task.dispatch` system
      command so the projection store transitions the task from
      `ready` → `dispatching` and the next-event handler eventually
      emits `TaskDispatched`.
    * `TaskDispatched` — issues `run.start` (system) to append the
      `RunStarted` event and hands the run off to `RunSupervisor`.

  The dispatcher is the bridge between the operator-facing task
  lifecycle and the supervised executor. Subscriptions are
  per-process and unlink automatically when the subscriber exits.
  """

  use GenServer

  alias ForemanServer.CommandGateway
  alias ForemanServer.ProjectionStore

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(init_arg \\ []) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    case ProjectionStore.subscribe() do
      :ok ->
        {:ok, %{pending: %{}}}

      _other ->
        # ProjectionStore may not be up yet. Retry until it answers.
        Process.send_after(self(), :retry_subscribe, 50)
        {:ok, %{pending: %{}, subscriber: :retrying}}
    end
  end

  @impl true
  def handle_info(:retry_subscribe, state) do
    case ProjectionStore.subscribe() do
      :ok ->
        {:noreply, %{state | subscriber: :subscribed}}

      _ ->
        Process.send_after(self(), :retry_subscribe, 50)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:projection_event, %{"event_type" => "TaskApproved"} = envelope}, state) do
    handle_task_approved(envelope, state)
  end

  def handle_info({:projection_event, %{event_type: "TaskApproved"} = envelope}, state) do
    handle_task_approved(envelope, state)
  end

  def handle_info({:projection_event, %{"event_type" => "TaskDispatched"} = envelope}, state) do
    handle_task_dispatched(envelope, state)
  end

  def handle_info({:projection_event, %{event_type: "TaskDispatched"} = envelope}, state) do
    handle_task_dispatched(envelope, state)
  end

  def handle_info({:projection_event, _envelope}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_task_approved(envelope, state) do
    payload = unwrap_data(envelope)
    task_id = payload["task_id"] || payload[:task_id]
    approval_id = payload["approval_id"] || payload[:approval_id]

    if is_binary(task_id) and task_id != "" and is_binary(approval_id) and approval_id != "" do
      # Deterministic command_id keyed on (task_id, approval_id) so retries of
      # the same approval collapse through CommandRouter's idempotency path,
      # but a fresh approval for a re-approved task produces a new dispatch.
      _ =
        CommandGateway.dispatch_system(%{
          type: "task.dispatch",
          command_id: "workflow:dispatcher:task-dispatch:#{task_id}:#{approval_id}",
          aggregate_id: "task:#{task_id}",
          payload: %{task_id: task_id}
        })

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  defp handle_task_dispatched(envelope, state) do
    payload = unwrap_data(envelope)
    task_id = payload["task_id"] || payload[:task_id]
    run_id = payload["run_id"] || payload[:run_id]
    approval_id = payload["approval_id"] || payload[:approval_id]

    case ProjectionStore.task_projection(task_id) do
      nil ->
        {:noreply, state}

      task ->
        phase_specs = extract_phase_specs(task)
        project_id = Map.get(task, :project_id) || Map.get(task, "project_id")
        workflow_snapshot =
          Map.get(task, :workflow_snapshot) || Map.get(task, "workflow_snapshot") || %{}

        result =
          CommandGateway.dispatch_system(%{
            type: "run.start",
            command_id: "workflow:dispatcher:run-start:#{run_id}",
            aggregate_id: "run:#{run_id}",
            payload: %{
              run_id: run_id,
              task_id: task_id,
              project_id: project_id,
              approval_id: approval_id,
              workflow_snapshot: workflow_snapshot,
              phase_specs: phase_specs
            }
          })

        case result do
          {:ok, _} ->
            ForemanServer.Workflow.RunSupervisor.start_run(run_id, task)
            {:noreply, state}

          {:error, reason} ->
            {:noreply, put_in(state, [:pending, task_id], reason)}
        end
    end
  end

  defp unwrap_data(%{data: data}), do: unwrap_data(data)
  defp unwrap_data(%{"data" => data}), do: unwrap_data(data)
  defp unwrap_data(map) when is_map(map), do: map
  defp unwrap_data(_), do: %{}

  defp extract_phase_specs(task) do
    snapshot = Map.get(task, :workflow_snapshot) || Map.get(task, "workflow_snapshot") || %{}

    case Map.get(snapshot, :phases) || Map.get(snapshot, "phases") do
      phases when is_list(phases) -> phases
      _ -> []
    end
  end
end
