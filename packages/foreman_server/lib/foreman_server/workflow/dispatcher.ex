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
    * `RunCancelled`, `RunFlaggedStuck`, `RunCompleted`, `RunFailed`,
      `RunBlocked` — fans out to `BootReconciliation.run_terminated/2`
      so the orphan-task dispatch path is identical to the boot scan.
      Earlier builds only reacted to `RunCancelled`; the other terminal
      events were silently dropped, leaving tasks bound to dead runs.
      `RunBlocked` is also terminal for lease cleanup: a blocked run
      must release its Beads-DB lease so queued peers can be promoted.
    * Any of the terminal run events above also dispatches the matching
      per-DB Beads lease command (`lease.release` for the holder,
      `lease.remove_waiter` for queued waiters). Both commands are
      idempotent no-ops when the run_id is not bound to the lease, so
      the dispatcher can fire them unconditionally once it has the
      lease key. The wire-up prevents a queued waiter from being
      promoted after its run has terminated.
    * `BeadsDbLeaseTransferred` — re-triggers admission for the run
      promoted to holder. Looks up the task projection by the new
      `acquired_task_id`, re-enters `RunAdmission.start/2`, and
      starts the run supervisor if the lease decision is now
      `:proceed`. Together with the queued-return contract, this
      is what drains the wait queue after a holder releases.
  The dispatcher is the bridge between the operator-facing task
  lifecycle and the supervised executor. Subscriptions are
  per-process and unlink automatically when the subscriber exits.
  """

  use GenServer
  require Logger

  alias ForemanServer.{ProjectionStore, RunAdmission}
  alias ForemanServer.Aggregates.BeadsDbLease
  alias ForemanServer.CommandGateway
  alias ForemanServer.Workflow.BootReconciliation

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

  @task_dispatch_event_types ~w(TaskApproved TaskDispatched)
  @run_terminated_event_types ~w(RunCancelled RunFlaggedStuck RunCompleted RunFailed RunBlocked)
  @lease_promotion_event_types ~w(BeadsDbLeaseTransferred)
  @slot_promotion_event_types ~w(RunSlotTransferred)


  for event_type <- @task_dispatch_event_types do
    @impl true
    def handle_info({:projection_event, %{"event_type" => unquote(event_type)} = envelope}, state) do
      apply_task_dispatch_handler(unquote(event_type), envelope, state)
    end

    def handle_info({:projection_event, %{event_type: unquote(event_type)} = envelope}, state) do
      apply_task_dispatch_handler(unquote(event_type), envelope, state)
    end
  end

  for event_type <- @run_terminated_event_types do
    @impl true
    def handle_info({:projection_event, %{"event_type" => unquote(event_type)} = envelope}, state) do
      handle_run_terminated(unquote(event_type), envelope, state)
    end

    def handle_info({:projection_event, %{event_type: unquote(event_type)} = envelope}, state) do
      handle_run_terminated(unquote(event_type), envelope, state)
    end
  end

  for event_type <- @lease_promotion_event_types do
    @impl true
    def handle_info({:projection_event, %{"event_type" => unquote(event_type)} = envelope}, state) do
      handle_lease_promoted(envelope, state)
    end

    def handle_info({:projection_event, %{event_type: unquote(event_type)} = envelope}, state) do
      handle_lease_promoted(envelope, state)
    end
  end

  for event_type <- @slot_promotion_event_types do
    @impl true
    def handle_info({:projection_event, %{"event_type" => unquote(event_type)} = envelope}, state) do
      handle_slot_promoted(envelope, state)
    end

    def handle_info({:projection_event, %{event_type: unquote(event_type)} = envelope}, state) do
      handle_slot_promoted(envelope, state)
    end
  end


  @impl true
  def handle_info({:projection_event, _envelope}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp apply_task_dispatch_handler("TaskApproved", envelope, state),
    do: handle_task_approved(envelope, state)

  defp apply_task_dispatch_handler("TaskDispatched", envelope, state),
    do: handle_task_dispatched(envelope, state)

  defp handle_run_terminated(event_type, envelope, state) do
    payload = unwrap_data(envelope)
    run_id = payload["run_id"] || payload[:run_id]
    reason = payload["reason"] || payload[:reason] || terminal_reason_from_event_type(event_type)

    if is_binary(run_id) and run_id != "" do
      BootReconciliation.run_terminated(run_id, reason)
      terminate_lease(run_id, reason)
    end

    {:noreply, state}
  end

  defp terminate_lease(run_id, reason) do
    with {:ok, db_path} <- db_path_for_run(run_id) do
      ms = System.system_time(:millisecond)

      _ =
        CommandGateway.dispatch_system(%{
          type: "lease.release",
          command_id: "workflow:dispatcher:lease-release:#{run_id}:#{ms}",
          aggregate_id: ForemanServer.Aggregates.BeadsDbLease.stream_id(db_path),
          payload: %{
            db_path: db_path,
            run_id: run_id,
            released_at_ms: ms,
            reason: reason
          }
        })

      _ =
        CommandGateway.dispatch_system(%{
          type: "lease.remove_waiter",
          command_id: "workflow:dispatcher:lease-remove-waiter:#{run_id}:#{ms}",
          aggregate_id: ForemanServer.Aggregates.BeadsDbLease.stream_id(db_path),
          payload: %{
            db_path: db_path,
            run_id: run_id,
            removed_at_ms: ms,
            reason: reason
          }
        })
    else
      _ -> :ok
    end
  end

  # Locate the Beads database path bound to the run by inspecting the
  # task projection for that run. Returns `:error` when the run is not
  # associated with a Beads workflow or has no projection yet.
  defp db_path_for_run(run_id) do
    case ProjectionStore.tasks_by_run_id(run_id) do
      [task | _] when is_map(task) ->
        task
        |> beads_db_path_from_task()
        |> case do
          nil -> {:error, :no_beads_db_path}
          path -> {:ok, path}
        end

      _ ->
        {:error, :no_task_projection}
    end
  end

  defp beads_db_path_from_task(task) do
    snapshot =
      Map.get(task, :workflow_snapshot) || Map.get(task, "workflow_snapshot") || %{}

    impl = Map.get(snapshot, :implementation) || Map.get(snapshot, "implementation") || %{}

    Map.get(impl, :beads_database_path) ||
      Map.get(impl, "beads_database_path")
  end

  defp terminal_reason_from_event_type("RunCancelled"), do: "run_cancelled"
  defp terminal_reason_from_event_type("RunFlaggedStuck"), do: "run_flagged_stuck"
  defp terminal_reason_from_event_type("RunCompleted"), do: "run_completed"
  defp terminal_reason_from_event_type("RunFailed"), do: "run_failed"
  defp terminal_reason_from_event_type("RunBlocked"), do: "run_blocked"
  defp terminal_reason_from_event_type(_), do: "run_terminated"

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
          {:ok, :queued} ->
            # RunAdmission decided this run is a Beads-DB waiter;
            # do NOT start the supervisor. The lease aggregate will
            # emit BeadsDbLeaseTransferred when the holder releases
            # and promotes this waiter; a re-dispatch at that point
            # will succeed.
            {:noreply, state}

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

  defp handle_lease_promoted(envelope, state) do
    payload = unwrap_data(envelope)
    promoted_run_id = payload["acquired_run_id"] || payload[:acquired_run_id]
    acquired_task_id = payload["acquired_task_id"] || payload[:acquired_task_id]

    cond do
      not (is_binary(promoted_run_id) and promoted_run_id != "") ->
        {:noreply, state}

      not (is_binary(acquired_task_id) and acquired_task_id != "") ->
        {:noreply, state}

      true ->
        re_dispatch_promoted(acquired_task_id, promoted_run_id, state)
    end
  end

  # Handle slot promotion:

  # Handle slot promotion: when a waiter is promoted to holder via RunSlotTransferred,
  # re-enter admission for the promoted run so it can acquire the slot and proceed.
  defp handle_slot_promoted(envelope, state) do
    payload = unwrap_data(envelope)
    acquired_run_id = payload["acquired_run_id"] || payload[:acquired_run_id]

    if is_binary(acquired_run_id) and acquired_run_id != "" do
      reenter_slot_admission(acquired_run_id, state)
    else
      {:noreply, state}
    end
  end

  defp reenter_slot_admission(run_id, state) do
    # Find the task associated with this run to build the admission payload.
    # A run is associated with exactly one task during dispatch.
    case ProjectionStore.tasks_by_run_id(run_id) do
      [] ->
        Logger.warning("handle_slot_promoted: no task found for run #{run_id}")
        {:noreply, state}

      [task | _] ->
        phase_specs = extract_phase_specs(task)
        project_id = Map.get(task, :project_id) || Map.get(task, "project_id")
        approval_id = Map.get(task, :approval_id) || Map.get(task, "approval_id")

        workflow_snapshot =
          Map.get(task, :workflow_snapshot) || Map.get(task, "workflow_snapshot") || %{}

        payload = %{
          run_id: run_id,
          task_id: Map.get(task, :task_id) || Map.get(task, "task_id"),
          project_id: project_id,
          approval_id: approval_id,
          workflow_snapshot: workflow_snapshot,
          phase_specs: phase_specs
        }

        case RunAdmission.start(project_id, payload, []) do
          {:ok, :slot_queued} ->
            {:noreply, state}

          {:ok, :queued} ->
            {:noreply, state}

          {:ok, _} ->
            ForemanServer.Workflow.RunSupervisor.start_run(run_id, task)
            {:noreply, state}

          {:error, reason} ->
            Logger.warning("handle_slot_promoted: admission failed for #{run_id}: #{inspect(reason)}")
            {:noreply, state}
        end
    end
  end

  defp re_dispatch_promoted(task_id, run_id, state) do
    case ProjectionStore.task_projection(task_id) do
      nil ->
        {:noreply, state}

      task ->
        phase_specs = extract_phase_specs(task)
        project_id = Map.get(task, :project_id) || Map.get(task, "project_id")
        approval_id = Map.get(task, :approval_id) || Map.get(task, "approval_id")

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
          {:ok, :queued} ->
            {:noreply, state}

          {:ok, %{} = _run_started_event} ->
            ForemanServer.Workflow.RunSupervisor.start_run(run_id, task)
            {:noreply, state}

          {:ok, nil} ->
            # run.start was accepted but produced no new event (e.g. the
            # task was already started). Treat as admitted.
            ForemanServer.Workflow.RunSupervisor.start_run(run_id, task)
            {:noreply, state}

          {:error, reason} ->
            {:noreply, put_in(state, [:pending, task_id], reason)}
        end
    end
  end
end
