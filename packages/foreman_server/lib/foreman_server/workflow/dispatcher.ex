defmodule ForemanServer.Workflow.Dispatcher do
  @moduledoc """
  Supervised workflow dispatcher.

  Subscribes to `ProjectionStore` event broadcasts and reacts to:

    * `TaskApproved` — issues a deterministic `task.dispatch` system
      command so the projection store transitions the task from
      `ready` → `dispatching` and the next-event handler eventually
      emits `TaskDispatched`.
    * `TaskDispatched` — enters the run admission flow through
      `RunAdmission.start/2`, which reserves the project slot and appends
      `RunStarted` before handing the run off to `RunSupervisor`.
  The dispatcher is the bridge between the operator-facing task
  lifecycle and the supervised executor. Subscriptions are
  per-process and unlink automatically when the subscriber exits.
  """

  use GenServer

  alias ForemanServer.{ProjectionStore, RunAdmission}
  alias ForemanServer.CommandGateway

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

  def handle_info({:projection_event, %{"event_type" => "RunCancelled"} = envelope}, state) do
    handle_run_cancelled(envelope, state)
  end

  def handle_info({:projection_event, %{event_type: "RunCancelled"} = envelope}, state) do
    handle_run_cancelled(envelope, state)
  end

  def handle_info({:projection_event, _envelope}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_run_cancelled(envelope, state) do
    payload = unwrap_data(envelope)
    run_id = payload["run_id"] || payload[:run_id]
    reason = payload["reason"] || payload[:reason] || "run_cancelled"

    if is_binary(run_id) and run_id != "" do
      tasks = ProjectionStore.tasks_by_run_id(run_id)

      Enum.each(tasks, fn task ->
        task_id = Map.get(task, :task_id) || Map.get(task, "task_id")

        if is_binary(task_id) and task_id != "" do
          _ =
            CommandGateway.dispatch_system(%{
              type: "task.run_terminated",
              command_id: "foreman:task-ack:#{task_id}:#{run_id}",
              aggregate_id: "task:#{task_id}",
              payload: %{
                task_id: task_id,
                run_id: run_id,
                reason: reason,
                acknowledged_at: iso8601_now()
              }
            })
        end
      end)
    end

    {:noreply, state}
  end

  defp iso8601_now do
    {{y, mo, d}, {h, mi, s}} = :calendar.universal_time()

    :io_lib.format(
      "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ",
      [y, mo, d, h, mi, s]
    )
    |> List.to_string()
  end

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
          RunAdmission.start(project_id, %{
            run_id: run_id,
            task_id: task_id,
            project_id: project_id,
            approval_id: approval_id,
            workflow_snapshot: workflow_snapshot,
            phase_specs: phase_specs
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
