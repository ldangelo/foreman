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
      `RunStarted` before handing the run handoff to `RunSupervisor`.

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

  alias ForemanServer.Work.RunPayload
  alias ForemanServer.{ProjectionStore, RunAdmission, Telemetry}
  alias ForemanServer.CommandGateway
  alias ForemanServer.Workflow.{BootReconciliation, RunSupervisor, Worktree}
  alias ForemanServer.RunControl

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(init_arg \\ []) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    case safe_subscribe() do
      :ok ->
        {:ok, %{}}

      _other ->
        # ProjectionStore may not be up yet. Retry until it answers.
        Process.send_after(self(), :retry_subscribe, 50)
        {:ok, %{subscriber: :retrying}}
    end
  end

  @impl true
  def handle_info(:retry_subscribe, state) do
    case safe_subscribe() do
      :ok ->
        {:noreply, %{state | subscriber: :subscribed}}

      _ ->
        Process.send_after(self(), :retry_subscribe, 50)
        {:noreply, state}
    end
  end

  # Same rationale as safe_dispatch_system/1 below: replay_existing: true
  # reads and replays the full committed event log inside ProjectionStore's
  # own handle_call, which grows with the event log's lifetime. subscribe/1
  # already raises its own GenServer.call timeout to 30s to make that
  # unlikely in practice, but a sufficiently large log (or a genuinely
  # wedged ProjectionStore) must still degrade into this module's existing
  # retry loop rather than crash Dispatcher's boot -- an uncaught
  # GenServer.call exit here is exactly the "sweep's own
  # ProjectionStore.list_tasks() GenServer.call timed out under load and
  # crashed Dispatcher itself" failure mode this bug's own history records.
  defp safe_subscribe do
    try do
      ProjectionStore.subscribe(replay_existing: true)
    catch
      :exit, exit_reason ->
        Logger.warning(
          "ForemanServer.Workflow.Dispatcher: ProjectionStore.subscribe exited: #{inspect(exit_reason)}"
        )

        {:error, {:subscribe_exit, exit_reason}}
    end
  end

  @task_dispatch_event_types ~w(TaskApproved TaskDispatched)
  @run_terminated_event_types ~w(RunCancelled RunFlaggedStuck RunCompleted RunFailed RunBlocked RunDeleted)
  # Subset of @run_terminated_event_types whose executor may still be
  # blocked on a live agent — RunCompleted and RunBlocked are excluded
  # because the executor is already finished or halting on its own for
  # those, so there is nothing left to cancel.
  @agent_killing_terminal_event_types ~w(RunCancelled RunFlaggedStuck RunFailed RunDeleted)
  @lease_promotion_event_types ~w(BeadsDbLeaseTransferred)
  @slot_promotion_event_types ~w(RunSlotTransferred)
  @run_stop_event_types ~w(RunPaused)
  @run_resume_event_types ~w(RunResumed)

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

  for event_type <- @run_stop_event_types do
    @impl true
    def handle_info({:projection_event, %{"event_type" => unquote(event_type)} = envelope}, state) do
      handle_run_stopped(unquote(event_type), envelope, state)
    end

    def handle_info({:projection_event, %{event_type: unquote(event_type)} = envelope}, state) do
      handle_run_stopped(unquote(event_type), envelope, state)
    end
  end

  for event_type <- @run_resume_event_types do
    @impl true
    def handle_info({:projection_event, %{"event_type" => unquote(event_type)} = envelope}, state) do
      handle_run_resumed(unquote(event_type), envelope, state)
    end

    def handle_info({:projection_event, %{event_type: unquote(event_type)} = envelope}, state) do
      handle_run_resumed(unquote(event_type), envelope, state)
    end
  end

  @impl true
  def handle_info({:projection_event, _envelope}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # `replay_existing: true` (init/1, handle_info(:retry_subscribe, ...))
  # means this function now runs against the ENTIRE accumulated event
  # history on every Dispatcher restart, not just live events -- an
  # exposure that did not exist before that change. A malformed or
  # partial projection shape anywhere in that history (verified live: a
  # task_projection missing run_id/project_id/approval_id/
  # workflow_snapshot reaching RunPayload.from_task_projection/1's
  # required-field match) must degrade to a logged skip, not crash this
  # always-on Dispatcher -- an uncaught crash here restarts Dispatcher,
  # which replays the SAME historical event again on the next boot,
  # which crashes again: an unbounded crash loop that exhausts the
  # supervisor's restart budget and takes the whole application down.
  # Reproduced in CI (506 failures, "no process ... possibly because its
  # application isn't started" cascading from exactly this crash).
  defp apply_task_dispatch_handler(event_type, envelope, state) do
    dispatch_task_event(event_type, envelope, state)
  rescue
    exception ->
      Logger.error(
        "ForemanServer.Workflow.Dispatcher: #{event_type} handling crashed: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:noreply, state}
  end

  defp dispatch_task_event("TaskApproved", envelope, state),
    do: handle_task_approved(envelope, state)

  defp dispatch_task_event("TaskDispatched", envelope, state),
    do: handle_task_dispatched(envelope, state)

  defp handle_run_terminated(event_type, envelope, state) do
    payload = unwrap_data(envelope)
    run_id = payload["run_id"] || payload[:run_id]
    reason = payload["reason"] || payload[:reason] || terminal_reason_from_event_type(event_type)

    if is_binary(run_id) and run_id != "" do
      if event_type in @agent_killing_terminal_event_types do
        RunControl.request(run_id, :cancel)
        RunControl.cancel_agent(run_id)
      end

      if event_type == "RunDeleted", do: Worktree.clean_for_run(run_id)
      BootReconciliation.run_terminated(run_id, reason)
      terminate_lease(run_id, reason)
      terminate_slot(run_id, reason)
    end

    {:noreply, state}
  end

  # RunPaused does NOT route through handle_run_terminated/3:
  # `BootReconciliation.run_terminated/2` reopens the provider issue on
  # the assumption the run is over, which is wrong for a pause the
  # operator expects to resume. A paused run still releases its slot and
  # Beads lease (below) so it does not hold either resource for the
  # duration of the pause.
  defp handle_run_stopped(_event_type, envelope, state) do
    payload = unwrap_data(envelope)
    run_id = payload["run_id"] || payload[:run_id]

    if is_binary(run_id) and run_id != "" do
      RunControl.request(run_id, :pause)

      case RunControl.cancel_agent(run_id) do
        :ok ->
          :ok

        {:error, :no_agent} ->
          Logger.info(
            "ForemanServer.Workflow.Dispatcher: run.pause for #{run_id} had no active agent to cancel"
          )
      end

      terminate_lease(run_id, "run_paused")
      terminate_slot(run_id, "run_paused")
    end

    {:noreply, state}
  end

  # TRD-009: Release the global slot on terminal run events.
  defp terminate_slot(run_id, reason) do
    ms = System.monotonic_time(:millisecond)

    safe_dispatch_system(%{
      type: "run_slots.release",
      command_id: "workflow:dispatcher:slot-release:#{run_id}:#{ms}",
      aggregate_id: "run_slots:global",
      payload: %{
        run_id: run_id,
        reason: reason
      }
    })
  end

  defp terminate_lease(run_id, reason) do
    with {:ok, db_path} <- db_path_for_run(run_id) do
      ms = System.system_time(:millisecond)
      lease_stream_id = ForemanServer.Aggregates.BeadsDbLease.stream_id(db_path)

      safe_dispatch_system(%{
        type: "lease.release",
        command_id: "workflow:dispatcher:lease-release:#{run_id}:#{ms}",
        aggregate_id: lease_stream_id,
        payload: %{
          db_path: db_path,
          run_id: run_id,
          released_at_ms: ms,
          reason: reason
        }
      })

      safe_dispatch_system(%{
        type: "lease.remove_waiter",
        command_id: "workflow:dispatcher:lease-remove-waiter:#{run_id}:#{ms}",
        aggregate_id: lease_stream_id,
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

  # Best-effort dispatch used from terminal-event reactions: the target
  # aggregate actor can legitimately be mid-restart (a crash, or a test's
  # deliberate reset) when these fire. A GenServer.call exit from the
  # target dying mid-call must not crash this always-on Dispatcher — that
  # would drop its ProjectionStore subscription and stall admission for
  # every other in-flight run until it restarts and resubscribes.
  defp safe_dispatch_system(command) do
    try do
      _ = CommandGateway.dispatch_system(command)
      :ok
    catch
      :exit, exit_reason ->
        Logger.warning(
          "ForemanServer.Workflow.Dispatcher: #{command.type} dispatch for #{inspect(command.aggregate_id)} exited: #{inspect(exit_reason)}"
        )

        :ok
    end
  end

  # Same rationale as safe_dispatch_system, for the multi-actor admission
  # path (run_slots:global, the Beads lease, the run aggregate). Any of
  # those actors can be mid-restart when RunAdmission.start/2 calls into
  # them; an uncaught exit here must not crash this always-on Dispatcher.
  defp safe_run_admission_start(project_id, payload) do
    try do
      RunAdmission.start(project_id, payload)
    catch
      :exit, exit_reason ->
        Logger.warning(
          "ForemanServer.Workflow.Dispatcher: RunAdmission.start for #{inspect(Map.get(payload, :run_id))} exited: #{inspect(exit_reason)}"
        )

        {:error, {:run_admission_exit, exit_reason}}
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
  defp terminal_reason_from_event_type("RunDeleted"), do: "run_removed"
  defp terminal_reason_from_event_type(_), do: "run_terminated"

  defp handle_task_approved(envelope, state) do
    payload = unwrap_data(envelope)
    task_id = payload["task_id"] || payload[:task_id]
    approval_id = payload["approval_id"] || payload[:approval_id]

    if is_binary(task_id) and task_id != "" and is_binary(approval_id) and approval_id != "" and
         task_ready_for_approval?(task_id, approval_id) do
      # Deterministic command_id keyed on (task_id, approval_id) so retries of
      # the same approval collapse through CommandRouter's idempotency path,
      # but a fresh approval for a re-approved task produces a new dispatch.
      # Uses safe_dispatch_system: the task aggregate actor can legitimately
      # be mid-restart (crash, or a test's deliberate reset) when this
      # fires, and an uncaught exit here would crash this always-on
      # Dispatcher, dropping its ProjectionStore subscription and losing
      # every other event queued in its mailbox at the moment of the crash.
      safe_dispatch_system(%{
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

    if is_binary(task_id) and task_id != "" do
      dispatch_task_projection(task_id, state)
    else
      {:noreply, state}
    end
  end

  defp dispatch_task_projection(task_id, state) do
    case ProjectionStore.task_projection(task_id) do
      nil ->
        {:noreply, state}

      %{
        status: "in_progress",
        run_id: _,
        task_id: _,
        project_id: _,
        approval_id: _,
        workflow_snapshot: _
      } = task_proj ->
        run_payload = RunPayload.from_task_projection(task_proj)

        # RunAdmission.start dispatches through several aggregate actors
        # (run_slots:global, the Beads lease, the run aggregate). Any of
        # them can legitimately be mid-restart (crash, or a test's
        # deliberate reset) when this fires; an uncaught exit here would
        # crash this always-on Dispatcher, dropping its ProjectionStore
        # subscription and losing every other event queued in its mailbox.
        result =
          safe_run_admission_start(run_payload.project_id, %{
            run_id: run_payload.run_id,
            task_id: run_payload.task_id,
            project_id: run_payload.project_id,
            approval_id: run_payload.approval_id,
            workflow_snapshot: run_payload.workflow_snapshot,
            phase_specs: run_payload.phase_specs
          })

        case result do
          {:ok, :slot_queued} ->
            # RunAdmission decided this run must wait for a free run slot;
            # do NOT start the supervisor. A RunSlotTransferred promotion
            # will re-enter admission for this run via handle_slot_promoted.
            {:noreply, state}

          {:ok, :queued} ->
            # RunAdmission decided this run is a Beads-DB waiter;
            # do NOT start the supervisor. The lease aggregate will
            # emit BeadsDbLeaseTransferred when the holder releases
            # and promotes this waiter; a re-dispatch at that point
            # will succeed.
            {:noreply, state}

          {:ok, _} ->
            ForemanServer.Workflow.RunSupervisor.start_run(run_payload.run_id, task_proj)
            {:noreply, state}

          {:error, reason} ->
            Logger.warning(
              "ForemanServer.Workflow.Dispatcher: admission failed for task #{task_id}: #{inspect(reason)}"
            )

            Telemetry.run_dispatcher_admission_failed(task_id: task_id, reason: inspect(reason))
            {:noreply, state}
        end

      _task_proj ->
        {:noreply, state}
    end
  end

  defp task_ready_for_approval?(task_id, approval_id) do
    case ProjectionStore.task_projection(task_id) do
      %{status: "ready", approval_id: ^approval_id} -> true
      _ -> false
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

        case safe_run_admission_start(project_id, payload) do
          {:ok, :slot_queued} ->
            {:noreply, state}

          {:ok, :queued} ->
            {:noreply, state}

          {:ok, _} ->
            ForemanServer.Workflow.RunSupervisor.start_run(run_id, task)
            {:noreply, state}

          {:error, reason} ->
            Logger.warning(
              "handle_slot_promoted: admission failed for #{run_id}: #{inspect(reason)}"
            )

            {:noreply, state}
        end
    end
  end

  defp handle_run_resumed(_event_type, envelope, state) do
    payload = unwrap_data(envelope)
    run_id = payload["run_id"] || payload[:run_id]

    if is_binary(run_id) and run_id != "" do
      RunControl.clear(run_id)
      resume_run(run_id, state)
    else
      {:noreply, state}
    end
  end

  defp resume_run(run_id, state) do
    case ProjectionStore.tasks_by_run_id(run_id) do
      [] ->
        Logger.warning("handle_run_resumed: no task found for run #{run_id}")
        {:noreply, state}

      [task | _] ->
        phase_specs = extract_phase_specs(task)
        project_id = Map.get(task, :project_id) || Map.get(task, "project_id")
        approval_id = Map.get(task, :approval_id) || Map.get(task, "approval_id")

        workflow_snapshot =
          Map.get(task, :workflow_snapshot) || Map.get(task, "workflow_snapshot") || %{}

        admission_payload = %{
          run_id: run_id,
          task_id: Map.get(task, :task_id) || Map.get(task, "task_id"),
          project_id: project_id,
          approval_id: approval_id,
          workflow_snapshot: workflow_snapshot,
          phase_specs: phase_specs
        }

        resume_from = resume_from_index(run_id, phase_specs)

        case safe_run_admission_resume(admission_payload) do
          {:ok, :slot_queued} ->
            {:noreply, state}

          {:ok, :queued} ->
            {:noreply, state}

          {:ok, _} ->
            RunSupervisor.start_run(run_id, task, resume_from: resume_from)
            {:noreply, state}

          {:error, reason} ->
            Logger.warning(
              "handle_run_resumed: admission failed for #{run_id}: #{inspect(reason)}"
            )

            {:noreply, state}
        end
    end
  end

  # 0-based index of the first non-completed phase. Phase projection
  # `:index` is 1-based (`PhaseStarted.index :: pos_integer()`), so the
  # completed 0-based set is each completed phase's `index - 1`. An empty
  # phase list resumes at 0. When every phase in range is already
  # completed, the default must be `total` (out of range), not `0` —
  # `handle_cast({:advance_to, ...})`'s finalize branch (`run_executor.ex`)
  # only fires for an out-of-range `next_index`; falling back to `0` would
  # instead re-run the first phase of an already-finished run.
  defp resume_from_index(run_id, phase_specs) do
    completed_0based =
      run_id
      |> ProjectionStore.phases_for_run()
      |> Enum.filter(&(&1.status == "completed"))
      |> MapSet.new(&(&1.index - 1))

    total = length(phase_specs)
    Enum.find(0..(total - 1)//1, total, &(&1 not in completed_0based))
  end

  # Re-acquires the run's admission gates (global slot, and the per-DB
  # Beads lease when applicable) WITHOUT re-dispatching `run.start` — the
  # Run aggregate already re-entered a live state via `run.resume`/
  # `RunResumed`, and `RunAdmission.start/2` would reject a second
  # `run.start` against an existing run (`require_absent/2`). Same
  # best-effort exit shielding as `safe_run_admission_start/2`.
  defp safe_run_admission_resume(payload) do
    try do
      RunAdmission.resume(payload)
    catch
      :exit, exit_reason ->
        Logger.warning(
          "ForemanServer.Workflow.Dispatcher: RunAdmission.resume for #{inspect(Map.get(payload, :run_id))} exited: #{inspect(exit_reason)}"
        )

        {:error, {:run_admission_exit, exit_reason}}
    end
  end

  @doc false
  def __resume_from_index_for_test__(run_id, phase_specs),
    do: resume_from_index(run_id, phase_specs)

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
          safe_run_admission_start(project_id, %{
            run_id: run_id,
            task_id: task_id,
            project_id: project_id,
            approval_id: approval_id,
            workflow_snapshot: workflow_snapshot,
            phase_specs: phase_specs
          })

        case result do
          {:ok, :slot_queued} ->
            {:noreply, state}

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
            Logger.warning(
              "ForemanServer.Workflow.Dispatcher: admission failed for task #{task_id}: #{inspect(reason)}"
            )

            Telemetry.run_dispatcher_admission_failed(task_id: task_id, reason: inspect(reason))
            {:noreply, state}
        end
    end
  end
end
