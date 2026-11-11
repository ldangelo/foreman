defmodule ForemanServer.Workflow.BootReconciliation do
  @moduledoc """
  Reconciles provider coordination state against Foreman's in-progress runs on boot,
  and re-acknowledges task–run bindings whose run became terminal while the
  Dispatcher was down.

  Two responsibilities share the process:

    * `reconcile/0` — drives the provider-claim pass that reopens orphaned
      in-progress issues whose run no longer exists (the original
      `BootReconciliation drives orphan-reopen` contract).
    * `scan_task_run_orphans/0` — iterates `ProjectionStore.list_tasks/0`
      looking for tasks whose `run_id` is bound to a terminal run whose
      run id has not yet been copied into `acknowledged_run_id`. Each
      orphan is dispatched as `task.run_terminated` so the task can be
      retried via the `foreman task retry` operator command.

  The task-run scan covers orphans missed while the Dispatcher was down
  or pre-subscription (`ProjectionStore.subscribe/0` does not replay
  history). The Dispatcher fans live terminal run events into the API
  on `run_terminated/2` so the same dispatch path covers future
  terminals.
  """

  use GenServer

  require Logger

  alias ForemanServer.{
    Aggregate,
    CommandGateway,
    CommandRouter,
    ProjectionStore,
    RunControl,
    RunExecutorLiveness,
    Telemetry
  }

  alias ForemanServer.Aggregates.{BeadsDbLease, RunSlots}
  alias ForemanServer.Idempotency.{CrashRecovery, KeyStore, Reconciler, RestartBackoff}
  alias ForemanServer.Incarnation
  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProvider.Registry, as: TaskProviderRegistry
  @orphan_reopen_event [:foreman_server, :workflow, :boot_reconciliation, :orphan_reopen]
  @matching_in_progress_event [
    :foreman_server,
    :workflow,
    :boot_reconciliation,
    :matching_in_progress
  ]
  @already_closed_event [:foreman_server, :workflow, :boot_reconciliation, :already_closed]
  @healthy_event [:foreman_server, :workflow, :boot_reconciliation, :healthy]
  @ambiguous_reconciled_event [
    :foreman_server,
    :workflow,
    :boot_reconciliation,
    :ambiguous_reconciled
  ]
  @effect_reconciled_event [:foreman_server, :workflow, :boot_reconciliation, :effect_reconciled]
  @effect_on_terminal_run_event [
    :foreman_server,
    :workflow,
    :boot_reconciliation,
    :effect_on_terminal_run
  ]
  @transition_comment "foreman-run-reconciled"
  @scan_retry_ms 50
  @json_schema_cache_name :foreman_server_json_schema_cache
  # The boot cleanup budget of an orphaned slot holder/waiter is durable: it is
  # a `RunSlotRecoveryAttempted` count on the `run_slots:global` stream, because
  # the run is absent or terminal and has no aggregate to carry it. The same
  # 5-restart backoff as the agent crash-recovery loop applies (RTE-T004 /
  # RestartBackoff); the sixth consecutive failure records the entry `exhausted`.
  @dispatch_retry_event [:foreman_server, :workflow, :boot_reconciliation, :dispatch_retry]
  @dispatch_blocked_event [:foreman_server, :workflow, :boot_reconciliation, :dispatch_blocked]
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(init_arg \\ []) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @spec reconcile() :: :ok
  def reconcile do
    runs_by_project = active_runs_by_project()

    ProjectionStore.list_projects()
    |> Enum.each(&reconcile_project(&1, runs_by_project))

    :ok
  end

  @doc """
  Scan unresolved worktrees on demand (no GenServer mailbox hop). Used by
  the boot scan pipeline and by the targeted test suite.
  """
  @spec scan_unresolved_worktrees() :: :ok
  def scan_unresolved_worktrees do
    do_scan_unresolved_worktrees()
  end

  @doc """
  Scan worktree-create orphans on demand (no GenServer mailbox hop). Used by
  the boot scan pipeline and by the targeted test suite.
  """
  @spec scan_worktree_create_orphans() :: :ok
  def scan_worktree_create_orphans do
    do_scan_worktree_create_orphans()
  end

  @doc """
  Request a scan of every projected task for an orphan binding — a task
  whose `run_id` points at a terminal run whose id has not yet been
  copied into `acknowledged_run_id`. Each orphan is dispatched as
  `task.run_terminated` so the task can be retried via the
  `foreman task retry` operator command.

  Dispatches as a cast so the actual scan runs inside the
  `BootReconciliation` process. If `CommandRouter` is not yet registered
  the cast handler defers the scan via `:scan_orphans` until it is. The
  function never reads task provider state. Returns `:ok` once the cast
  is enqueued.
  """
  @spec scan_task_run_orphans() :: :ok
  def scan_task_run_orphans do
    GenServer.cast(__MODULE__, :scan_orphans)
    :ok
  end

  @doc """
  Request a scan of every per-DB Beads lease stream for orphaned entries
  — a holder or waiter whose owner no longer exists. Each orphan is
  dispatched as `lease.release` (for the holder) or `lease.remove_waiter`
  (for queued waiters) so the lease is cleanly transferred or freed after
  a restart that found stranded state.

  The scan lists every `beads_db_lease:` stream in the event store — not
  only the ones a task projection points at: a hold taken around one `br`
  call by `BeadsWatcher`, `BeadsAdapter` or the janitor is bound to no
  task, so a walk keyed on tasks never reaches the holds a killed server
  strands. It loads each lease aggregate via `Aggregate.load/2` and
  inspects the holder and waiter list. An entry is live by one of two
  rules:

    * A hold taken for one call names the `ForemanServer.Incarnation` of
      the server that took it. It is live exactly when that is this
      server: every other incarnation has ended, and the call with it.
    * A hold without an incarnation belongs to a run. It is live only
      when a task bound to that DB path names the run AND the run
      projection exists and `terminal?` is false; everything else (no run
      projection, terminal run, or run whose binding has been cleared) is
      released or removed.

  Both `lease.release` and `lease.remove_waiter` are idempotent no-ops
  against foreign entries, so the scan is safe to re-run.

  Dispatches as a cast so the actual scan runs inside the
  `BootReconciliation` process. Returns `:ok` once the cast is enqueued.
  """
  @spec scan_lease_orphans() :: :ok
  def scan_lease_orphans do
    GenServer.cast(__MODULE__, :scan_lease_orphans)
    :ok
  end

  @doc """
  Scan the `run_slots:global` stream for orphaned holders and waiters — a
  holder or waiter whose `run_id` does not correspond to a non-terminal run
  projection. Orphaned holders are dispatched as `run_slots.release` and
  orphaned waiters as `run_slots.remove_waiter`, mirroring the
  `scan_lease_orphans/0` pattern.

  Dispatches as a cast so the actual scan runs inside the
  `BootReconciliation` process. Returns `:ok` once the cast is enqueued.
  """
  @spec scan_run_slot_orphans() :: :ok
  def scan_run_slot_orphans do
    GenServer.cast(__MODULE__, :scan_run_slot_orphans)
    :ok
  end

  @doc """
  Scan every idempotency key with status `:ambiguous` and apply
  `CrashRecovery.reconcile/1` to each. Keys already marked `:completed`
  are skipped; keys whose side-effect check reports no side effects are
  retried.

  Dispatches as a cast so the scan runs inside the `BootReconciliation`
  process. Returns `:ok` once the cast is enqueued.
  """
  @spec scan_ambiguous_keys() :: :ok
  def scan_ambiguous_keys do
    GenServer.cast(__MODULE__, :scan_ambiguous_keys)
    :ok
  end

  @doc """
  Cast a live terminal-run notification. The Dispatcher calls this on
  every `RunCancelled`, `RunFlaggedStuck`, `RunCompleted`, and `RunFailed`
  projection event so the fan-out path is identical to the boot scan.

  Routes through `CommandRouter` readiness: when the router is registered
  the cast dispatches `task.run_terminated` against every task bound to
  `run_id`; otherwise the run joins the same `:scan_orphans` deferral
  loop the boot path uses, so no terminal run is silently lost during
  startup.
  """
  @spec run_terminated(String.t(), String.t()) :: :ok
  def run_terminated(run_id, reason)
      when is_binary(run_id) and run_id != "" and is_binary(reason) do
    GenServer.cast(__MODULE__, {:run_terminated, run_id, reason})
  end

  @doc """
  Test seam, not an operator API: charge one failed cleanup dispatch to `run_id`'s durable
  budget by running `handle_dispatch_failure/4` inside the reconciler process, exactly as a
  caught exit from the `run_slots.release` / `run_slots.remove_waiter` dispatch would. It lets a
  test force the failure branch without timing a kill of the `run_slots:global` actor.
  """
  @spec record_dispatch_failure(String.t(), term(), :slot_release | :waiter_remove, term()) :: :ok
  def record_dispatch_failure(run_id, reason, kind, exit_reason)
      when is_binary(run_id) and run_id != "" and kind in [:slot_release, :waiter_remove] do
    GenServer.call(
      __MODULE__,
      {:record_dispatch_failure, run_id, reason, kind, exit_reason},
      30_000
    )
  end

  @impl true
  def init(_init_arg) do
    {:ok,
     %{
       reconciled?: false,
       scanned?: false,
       vcs_scan_pid: nil,
       vcs_scan_ref: nil,
       ambiguous_reconciled?: false
     }, {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, state) do
    reconcile()
    state = reconcile_ambiguous_keys(state)
    state = run_scan_or_defer(state)
    state = run_lease_scan_or_defer(state)
    state = run_slot_scan_or_defer(state)
    {:noreply, %{state | reconciled?: true}}
  end

  @impl true
  def handle_call({:record_dispatch_failure, run_id, reason, kind, exit_reason}, _from, state) do
    handle_dispatch_failure(run_id, reason, kind, exit_reason)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:run_terminated, run_id, reason}, state) do
    if command_router_ready?() do
      fan_out_task_run_terminated(run_id, reason)
    else
      schedule_scan(:not_ready)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast(:scan_run_slot_orphans, state) do
    state = run_slot_scan_or_defer(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:scan_orphans, state) do
    state = run_scan_or_defer(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:scan_lease_orphans, state) do
    state = run_lease_scan_or_defer(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:scan_ambiguous_keys, state) do
    state = reconcile_ambiguous_keys(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:scan_orphans, state) do
    state = run_scan_or_defer(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:scan_lease_orphans, state) do
    state = run_lease_scan_or_defer(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:scan_run_slot_orphans, state) do
    state = run_slot_scan_or_defer(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:scan_ambiguous_keys, state) do
    state = reconcile_ambiguous_keys(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:vcs_scan_done, state) do
    {:noreply, %{state | vcs_scan_pid: nil}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{vcs_scan_pid: pid} = state) do
    {:noreply, %{state | vcs_scan_pid: nil, vcs_scan_ref: nil}}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Best-effort: surface any in-flight scan Task to the test caller so it
    # does not mutate ProjectionStore or the filesystem after teardown.
    case state.vcs_scan_pid do
      nil ->
        :ok

      pid when is_pid(pid) ->
        ref = Process.monitor(pid)
        Process.exit(pid, :shutdown)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          200 -> :ok
        end
    end

    :ok
  end

  defp active_runs_by_project do
    active_statuses = ProjectionStore.active_run_statuses()

    ProjectionStore.list_runs()
    |> Enum.reduce(%{}, fn run, acc ->
      if fetch_status(run) in active_statuses do
        with {:ok, project_id} <- fetch_project_id(run),
             {:ok, task_id} <- fetch_task_id(run) do
          Map.update(acc, project_id, MapSet.new([task_id]), &MapSet.put(&1, task_id))
        else
          _ -> acc
        end
      else
        acc
      end
    end)
  end

  defp reconcile_project(project, runs_by_project) do
    with {:ok, project_id} <- fetch_project_id(project),
         {:ok, task_provider} <- fetch_task_provider(project),
         {:ok, project_config} <- fetch_project_config(task_provider),
         {:ok, database_path} <- fetch_database_path(project_config),
         {:ok, provider_module} <-
           TaskProviderRegistry.route(:reopen, {project_id, database_path}),
         :ok <- ensure_coordination_status(provider_module),
         {:ok, issues} <- provider_module.coordination_status(project_config) do
      active_task_ids = Map.get(runs_by_project, project_id, MapSet.new())

      Enum.each(issues, fn issue ->
        reconcile_issue(issue, active_task_ids, provider_module, project_config, project_id)
      end)
    else
      {:error, reason} ->
        log_skip(project, reason)

      :error ->
        :ok
    end
  rescue
    exception ->
      Logger.warning(
        "BootReconciliation failed for project #{inspect(fetch_map_value(project, :project_id))}: #{Exception.message(exception)}"
      )

      :ok
  end

  defp reconcile_issue(
         %Issue{} = issue,
         active_task_ids,
         provider_module,
         project_config,
         project_id
       ) do
    has_matching_run? = MapSet.member?(active_task_ids, issue.id)

    case {issue.status, has_matching_run?} do
      {"in_progress", false} ->
        case ensure_json_schema_cache_started() do
          :ok ->
            case provider_module.reopen(issue.id, @transition_comment, project_config) do
              :ok -> emit(@orphan_reopen_event, project_id, issue, false)
              {:ok, _result} -> emit(@orphan_reopen_event, project_id, issue, false)
              {:error, reason} -> log_reopen_failure(project_id, issue.id, reason)
            end

          {:error, reason} ->
            log_reopen_failure(project_id, issue.id, reason)
        end

      {"in_progress", true} ->
        emit(@matching_in_progress_event, project_id, issue, true)

      {"closed", true} ->
        emit(@already_closed_event, project_id, issue, true)

      _other ->
        emit(@healthy_event, project_id, issue, has_matching_run?)
    end
  end

  defp reconcile_issue(_issue, _active_task_ids, _provider_module, _project_config, _project_id),
    do: :ok

  defp ensure_coordination_status(provider_module) when is_atom(provider_module) do
    if function_exported?(provider_module, :coordination_status, 1) do
      :ok
    else
      {:error, :coordination_status_not_supported}
    end
  end

  defp ensure_json_schema_cache_started do
    case Process.whereis(@json_schema_cache_name) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        if application_supervisor = Process.whereis(ForemanServer.Application) do
          case Supervisor.start_child(
                 application_supervisor,
                 ForemanServer.TaskProviders.JsonSchemaCache
               ) do
            {:ok, _pid} -> :ok
            {:ok, _pid, _info} -> :ok
            {:error, {:already_started, _pid}} -> :ok
            {:error, :already_present} -> :ok
            {:error, reason} -> {:error, reason}
          end
        else
          case ForemanServer.TaskProviders.JsonSchemaCache.start_link() do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  defp emit(event, project_id, %Issue{} = issue, has_matching_run?) do
    Telemetry.execute(event, %{count: 1}, %{
      project_id: project_id,
      issue_id: issue.id,
      status: issue.status,
      has_matching_run?: has_matching_run?
    })
  end

  defp fetch_project_id(map) when is_map(map) do
    case fetch_map_value(map, :project_id) do
      project_id when is_binary(project_id) and project_id != "" -> {:ok, project_id}
      _ -> :error
    end
  end

  defp fetch_task_id(map) when is_map(map) do
    case fetch_map_value(map, :task_id) do
      task_id when is_binary(task_id) and task_id != "" -> {:ok, task_id}
      _ -> :error
    end
  end

  defp fetch_status(map) when is_map(map) do
    fetch_map_value(map, :status)
  end

  defp fetch_task_provider(project) do
    task_provider =
      Map.get(project, :task_provider) ||
        Map.get(project, "task_provider") ||
        get_in(project, [:config, :task_provider]) ||
        get_in(project, [:config, "task_provider"])

    if is_map(task_provider),
      do: {:ok, task_provider},
      else: {:error, :task_provider_not_configured}
  end

  defp fetch_project_config(task_provider) do
    project_config = Map.get(task_provider, :config) || Map.get(task_provider, "config")

    if is_map(project_config),
      do: {:ok, project_config},
      else: {:error, :task_provider_not_configured}
  end

  defp fetch_database_path(project_config) do
    case fetch_map_value(project_config, :database_path) do
      database_path when is_binary(database_path) and database_path != "" -> {:ok, database_path}
      _ -> {:error, :task_provider_not_configured}
    end
  end

  defp fetch_map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp log_skip(project, reason) do
    project_id = fetch_map_value(project, :project_id) || "unknown"
    Logger.debug("BootReconciliation skipping project #{inspect(project_id)}: #{inspect(reason)}")
  end

  defp log_reopen_failure(project_id, issue_id, reason) do
    Logger.warning(
      "BootReconciliation failed reopening #{inspect(issue_id)} for project #{inspect(project_id)}: #{inspect(reason)}"
    )
  end

  defp orphan_task?(task) when is_map(task) do
    run_id = fetch_map_value(task, :run_id)
    ack_run_id = fetch_map_value(task, :acknowledged_run_id)

    is_binary(run_id) and run_id != "" and run_id != ack_run_id and
      fetch_map_value(task, :status) == "in_progress" and run_terminal?(run_id)
  end

  defp orphan_task?(_), do: false

  defp run_terminal?(run_id) do
    case ProjectionStore.run(run_id) do
      nil -> false
      run -> fetch_map_value(run, :terminal?) == true
    end
  end

  defp do_scan_task_run_orphans do
    tasks = ProjectionStore.list_tasks()
    orphans = Enum.filter(tasks, &orphan_task?/1)

    Enum.each(orphans, &ack_orphan_task/1)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Per-DB Beads lease orphan scan
  # ---------------------------------------------------------------------------

  defp run_lease_scan_or_defer(state) do
    case scan_branch() do
      :schedule_not_ready ->
        schedule_lease_scan(:not_ready)
        state

      :schedule_worker_registry ->
        schedule_lease_scan(:worker_registry_not_ready)
        state

      :scan ->
        do_scan_lease_orphans()
        state
    end
  end

  defp schedule_lease_scan(_reason) do
    Process.send_after(self(), :scan_lease_orphans, @scan_retry_ms)
  end

  @lease_stream_prefix "beads_db_lease:"
  @lease_stream_page_size 100

  defp do_scan_lease_orphans do
    active_runs_by_db = Enum.group_by(tasks_with_db_path(), & &1.db_path, & &1.run_id)

    case lease_stream_ids(1, []) do
      {:ok, stream_ids} ->
        Enum.each(stream_ids, &reconcile_lease_stream(&1, active_runs_by_db))

      {:error, reason} ->
        Logger.error(
          "BootReconciliation could not list the Beads lease streams: #{inspect(reason)}"
        )
    end

    :ok
  end

  # Candidates come from the event store, not from task projections: a lease
  # taken around one `br` call is bound to no task, so a stream reachable only
  # through tasks misses exactly the holds a killed server strands
  # (foreman-w29up). `paginate_streams(search: term)` matches `%term%`, so the
  # prefix is re-checked; sorting by `stream_uuid` keeps paging stable.
  defp lease_stream_ids(page_number, acc) do
    opts = [
      search: @lease_stream_prefix,
      page_number: page_number,
      page_size: @lease_stream_page_size,
      sort_by: :stream_uuid
    ]

    case ForemanServer.EventStore.paginate_streams(opts) do
      {:ok, %EventStore.Page{entries: entries, total_pages: total_pages}} ->
        acc =
          Enum.reduce(entries, acc, fn %EventStore.Streams.StreamInfo{stream_uuid: stream_uuid},
                                       uuids ->
            if String.starts_with?(stream_uuid, @lease_stream_prefix),
              do: [stream_uuid | uuids],
              else: uuids
          end)

        if page_number >= total_pages,
          do: {:ok, Enum.reverse(acc)},
          else: lease_stream_ids(page_number + 1, acc)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_lease_stream(stream_id, active_runs_by_db) do
    {state, _version} = Aggregate.load(BeadsDbLease, stream_id)

    if state.exists? do
      db_path = state.db_path
      active_run_ids = active_runs_by_db |> Map.get(db_path, []) |> MapSet.new()

      if holder_orphan?(state, active_run_ids) do
        release_lease(db_path, state.holder.run_id, :boot_orphan_holder)
      end

      state.waiters
      |> Enum.reject(&lease_entry_live?(&1, active_run_ids))
      |> Enum.each(&remove_lease_waiter(db_path, &1, :boot_orphan_waiter))
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Run slots orphan scan
  # ---------------------------------------------------------------------------

  defp run_slot_scan_or_defer(state) do
    case scan_branch() do
      :schedule_not_ready ->
        schedule_slot_scan(:not_ready)
        state

      :schedule_worker_registry ->
        schedule_slot_scan(:worker_registry_not_ready)
        state

      :scan ->
        do_scan_run_slot_orphans()
        state
    end
  end

  defp schedule_slot_scan(_reason) do
    Process.send_after(self(), :scan_run_slot_orphans, @scan_retry_ms)
  end

  defp do_scan_run_slot_orphans do
    reconcile_run_slots_stream()
  end

  # --- ambiguous key reconciliation (TRD-077) ---

  # Scans every key with status :ambiguous and applies CrashRecovery.reconcile/1.
  # Runs once at boot via handle_continue(:reconcile, ...). Deferred if the
  # CommandRouter is not yet registered.
  @doc false
  def reconcile_ambiguous_keys(state) do
    case scan_branch() do
      :schedule_not_ready ->
        schedule_ambiguous_scan(:not_ready)
        state

      _ ->
        # :schedule_worker_registry or :scan
        do_reconcile_ambiguous_keys()
        %{state | ambiguous_reconciled?: true}
    end
  end

  defp schedule_ambiguous_scan(_reason) do
    Process.send_after(self(), :scan_ambiguous_keys, @scan_retry_ms)
  end

  @doc false
  def do_reconcile_ambiguous_keys(
        side_effects_check \\ &CrashRecovery.has_no_side_effects?/1,
        opts \\ []
      ) do
    orphaned = mark_orphaned_started_keys()

    if orphaned > 0 do
      Logger.warning(
        "BootReconciliation: #{orphaned} orphaned started idempotency key(s) marked ambiguous"
      )
    end

    {effect_keys, agent_keys} =
      :ambiguous
      |> KeyStore.list_by_status()
      |> Enum.split_with(&KeyStore.effect_key?/1)

    {skipped, retried} =
      Enum.reduce(agent_keys, {0, 0}, fn key, {skipped, retried} ->
        case CrashRecovery.reconcile(key, side_effects_check) do
          {:skip, :already_completed} ->
            {skipped + 1, retried}

          {:retry, reason} ->
            Logger.warning(
              "BootReconciliation: ambiguous key #{inspect(key)} retried (#{reason})",
              key: key,
              reason: reason
            )

            {skipped, retried + 1}
        end
      end)

    reconcile_effect_keys(effect_keys, opts)
    emit_ambiguous_reconciled(skipped, retried)
  end

  # A `started` key is written by `HeartbeatLease.acquire/5` (agent phase) and by
  # `Effect.run/4` (effect keys). The expiry timer of a lease lives inside the
  # HeartbeatLease GenServer and dies with the app, so after a restart nothing
  # resolves such a key and it stays `started` forever. Turn the orphans into
  # `ambiguous` so the reconcile path below inspects them.
  #
  # A key is an orphan only when its owning run has no executor alive in this
  # node. `RunExecutorLiveness` (in-memory, written by the jobsite runner only)
  # has an entry for a live jobsite executor; a workflow-door `RunExecutor` has
  # none, but is registered in `RunExecutorRegistry`, which an effect key also
  # consults (agent-phase keys keep the liveness check alone). The scan can be
  # re-armed while a run is mid-effect, so `started` alone is not evidence of
  # orphanhood. Keys without a run_id cannot be attributed to a run, so they are
  # left untouched and logged.
  defp mark_orphaned_started_keys do
    :started
    |> KeyStore.list_by_status()
    |> Enum.count(&orphaned_started_key?/1)
  end

  defp orphaned_started_key?(key) do
    case KeyStore.get(key) do
      {:ok, %{status: :started, metadata: metadata}} when is_map(metadata) ->
        case started_key_run_id(string_keys(metadata)) do
          {:ok, run_id} -> mark_if_run_not_live(key, run_id)
          :none -> skip_unattributable_started_key(key)
        end

      _changed_or_missing ->
        false
    end
  end

  defp started_key_run_id(%{"run_id" => run_id}) when is_binary(run_id) and run_id != "",
    do: {:ok, run_id}

  defp started_key_run_id(_metadata), do: :none

  defp mark_if_run_not_live(key, run_id) do
    if run_executor_alive?(key, run_id) do
      false
    else
      :ok = KeyStore.mark_ambiguous(key, "orphaned_started_key")
      true
    end
  end

  defp run_executor_alive?(key, run_id) do
    liveness? =
      RunExecutorLiveness.lookup(run_id, System.system_time(:millisecond)) != :none

    liveness? or
      (KeyStore.effect_key?(key) and ForemanServer.Workflow.RunExecutor.pid_for(run_id) != nil)
  end

  defp skip_unattributable_started_key(key) do
    Logger.warning(
      "BootReconciliation: started idempotency key #{inspect(key)} has no run_id; leaving it started",
      key: key
    )

    false
  end

  defp emit_ambiguous_reconciled(skipped, retried) do
    :telemetry.execute(
      @ambiguous_reconciled_event,
      %{skipped: skipped, retried: retried},
      %{}
    )
  end

  # --- effect-key recovery (TRD-012) ---
  #
  # An ambiguous `effect:` key is a keyed external effect (`Idempotency.Effect`)
  # whose outcome the crash left unknown. It never goes through
  # `CrashRecovery.reconcile/2`, whose `:side_effects_present` marks the key
  # completed and retries: the opposite of what a push or PR create needs. The
  # class's `Idempotency.Reconciler` is asked instead, and the verdict maps to:
  #
  #   * `:not_done`          -> record `effect_retried`; the key stays ambiguous
  #                             so the next `Effect.run` for the identity re-marks it
  #   * `:done`              -> block `effect_already_done`
  #   * `:unknown`, or an unexpected store status -> block `effect_outcome_ambiguous`
  #   * unregistered class   -> block `effect_class_unregistered` (fail closed)
  #
  # A block appends the `effect_blocked` record first (a terminal run rejects it,
  # and that rejection decides the terminal-run branch), then `run.block`, then
  # cancels any live executor and agent: the Dispatcher cancels only for
  # `RunCancelled`/`RunFlaggedStuck`/`RunFailed`/`RunDeleted`, never `RunBlocked`.
  # A terminal (or absent) run cannot be blocked: the verdict is logged and
  # counted and the key stays ambiguous, which is how `foreman_doctor` lists it.
  # No path marks the key completed.
  @effect_block_reasons %{
    done: "effect_already_done",
    unknown: "effect_outcome_ambiguous",
    unregistered: "effect_class_unregistered"
  }

  defp reconcile_effect_keys([], _opts), do: :ok

  defp reconcile_effect_keys(keys, opts) do
    counts =
      Enum.reduce(
        keys,
        %{blocked: 0, retried: 0, on_terminal_run: 0, unresolved: 0, skipped: 0},
        fn key, counts -> Map.update!(counts, reconcile_effect_key(key, opts), &(&1 + 1)) end
      )

    :telemetry.execute(@effect_reconciled_event, counts, %{})
  end

  defp reconcile_effect_key(key, opts) do
    case read_effect_key(key) do
      {:ok, %{status: status}} when status in [:started, :completed, :failed] ->
        # The sweep listed this key `ambiguous`. A retried run re-marks it `started`
        # (`Effect.run`) and an effect that finished settles it, so a status that is
        # no longer `ambiguous` is the key moving on, not evidence of a verdict.
        skip_effect_key(key, "is now #{status}")

      {:ok, %{run_id: run_id, class: class, metadata: metadata, status: status}} ->
        case KeyStore.unresolved_version(metadata) do
          :none ->
            {verdict, reason} = effect_verdict(status, class, metadata, opts)
            handle_effect_verdict(key, run_id, class, verdict, reason)

          # The outcome was decided at an earlier boot (the key carries its marker):
          # `Effect.run/4` refuses it until an operator `run.reset`, and honours the
          # reset. Re-deciding it would block a run the operator just reset, or write
          # a marker past the `RunReset` and refuse the key for good.
          _marked ->
            skip_effect_key(key, "is already unresolved (marked)")
        end

      :gone ->
        skip_effect_key(key, "no longer exists")

      {:error, reason} ->
        Logger.warning(
          "BootReconciliation: effect key #{inspect(key)} cannot be reconciled (#{inspect(reason)}); leaving it ambiguous",
          key: key
        )

        :unresolved
    end
  end

  defp skip_effect_key(key, what) do
    Logger.info("BootReconciliation: effect key #{inspect(key)} #{what}; not reconciled",
      key: key
    )

    :skipped
  end

  # The one place stored metadata is normalised: `Effect` writes string keys while
  # `KeyStore.mark_ambiguous/2` and `mark_failed/2` add an atom-keyed `reason` on the
  # ETS path. Past this point the effect step and the reconcilers read string keys only.
  defp read_effect_key(key) do
    case KeyStore.get(key) do
      {:ok, %{status: status, metadata: metadata}} when is_map(metadata) ->
        metadata = string_keys(metadata)

        case Reconciler.run_id_of(metadata) do
          nil ->
            {:error, :no_run_id}

          run_id ->
            {:ok,
             %{
               run_id: run_id,
               class: Reconciler.class_of(metadata) || "unclassified",
               metadata: metadata,
               status: status
             }}
        end

      :not_found ->
        :gone

      other ->
        {:error, {:unreadable, other}}
    end
  catch
    :exit, exit_reason -> {:error, {:key_store_unavailable, exit_reason}}
  end

  defp string_keys(metadata) do
    Map.new(metadata, fn {k, v} -> {if(is_atom(k), do: Atom.to_string(k), else: k), v} end)
  end

  # `:ambiguous` is the status the sweep listed. Any other status reaching here is
  # not one of the four the store writes (started, completed, failed, ambiguous), so
  # the outcome cannot be read from the store: the run blocks (TRD-012).
  defp effect_verdict(:ambiguous, class, metadata, opts) do
    case Reconciler.verdict(class, metadata, Keyword.take(opts, [:classes])) do
      :not_done -> {"not_done", nil}
      :done -> {"done", @effect_block_reasons.done}
      :unknown -> {"unknown", @effect_block_reasons.unknown}
      :unregistered -> {"unregistered", @effect_block_reasons.unregistered}
    end
  end

  defp effect_verdict(_status, _class, _metadata, _opts),
    do: {"unknown", @effect_block_reasons.unknown}

  defp handle_effect_verdict(key, run_id, class, "not_done" = verdict, nil) do
    fields = %{effect_class: class, effect_key: key, effect_verdict: verdict}

    command =
      effect_recovery_command(
        run_id,
        "effect_retried",
        fields,
        nil,
        "effect-retried:#{run_id}:#{key_digest(key)}:#{Incarnation.id()}"
      )

    case dispatch_effect_command(command) do
      {:ok, _} ->
        Logger.warning(
          "BootReconciliation: effect #{inspect(key)} (#{class}) did not happen; the next attempt may run it",
          key: key,
          run_id: run_id
        )

        :retried

      {:error, rejection} ->
        effect_not_recorded(key, run_id, class, verdict, nil, rejection)
    end
  end

  defp handle_effect_verdict(key, run_id, class, verdict, reason) do
    fields = %{effect_class: class, effect_key: key, effect_verdict: verdict}
    {_state, version} = load_run_stream(run_id)

    # The key is marked unresolved BEFORE anything is dispatched, at the stream
    # version as it stands: from here on `Effect.run/4` refuses it, so no failed or
    # slow dispatch below leaves an unmarked ambiguous key that a retry would
    # repeat. A marker that cannot be written leaves the key unresolved and the run
    # untouched (`:unresolved`), never counted as a block.
    with :ok <- mark_effect_unresolved(key, version, reason) do
      block_for_effect(key, run_id, class, verdict, reason, fields, version)
    else
      {:error, marker_error} ->
        Logger.error(
          "BootReconciliation: effect #{inspect(key)} of run #{run_id} has verdict #{verdict} but could not be marked unresolved (#{inspect(marker_error)}); run not blocked, key left ambiguous",
          key: key,
          run_id: run_id
        )

        :unresolved
    end
  end

  defp block_for_effect(key, run_id, class, verdict, reason, fields, version) do
    # The ids carry the run stream's version, so a block after an operator
    # `run.reset` (the stream continues, the run restarts) is a new command and
    # is recorded again, while a repeat at the same version is deduplicated.
    record =
      effect_recovery_command(
        run_id,
        "effect_blocked",
        fields,
        reason,
        "effect-blocked-record:#{run_id}:#{version}"
      )

    with {:ok, _} <- dispatch_effect_command(record),
         {:ok, _} <- dispatch_effect_command(effect_block_command(run_id, reason, version)) do
      refresh_effect_marker(key, run_id, reason)
      RunControl.request(run_id, :cancel)
      _ = RunControl.cancel_agent(run_id)

      Logger.error(
        "BootReconciliation: run #{run_id} blocked: effect #{inspect(key)} (#{class}) #{reason}",
        key: key,
        run_id: run_id
      )

      :blocked
    else
      {:error, rejection} ->
        effect_not_recorded(key, run_id, class, verdict, reason, rejection)
    end
  end

  defp effect_not_recorded(key, run_id, class, verdict, reason, {:run_terminal, status}),
    do: effect_on_terminal_run(key, run_id, class, verdict, reason, status)

  defp effect_not_recorded(key, run_id, class, verdict, reason, {:not_found, :run, _}),
    do: effect_on_terminal_run(key, run_id, class, verdict, reason, "absent")

  defp effect_not_recorded(key, run_id, _class, _verdict, _reason, rejection) do
    Logger.error(
      "BootReconciliation: effect #{inspect(key)} of run #{run_id} not recorded: #{inspect(rejection)}; leaving it ambiguous",
      key: key,
      run_id: run_id
    )

    :unresolved
  end

  defp effect_on_terminal_run(key, run_id, class, verdict, reason, status) do
    metadata = %{
      run_id: run_id,
      status: status,
      effect_key: key,
      effect_class: class,
      effect_verdict: verdict,
      reason: reason
    }

    Logger.warning(
      "BootReconciliation: effect #{inspect(key)} (#{class}) of run #{run_id} has verdict #{verdict} " <>
        "but the run is #{status} and cannot be blocked (reason #{inspect(reason)}); key stays ambiguous",
      Map.to_list(metadata)
    )

    :telemetry.execute(@effect_on_terminal_run_event, %{count: 1}, metadata)
    :on_terminal_run
  end

  # An unresolved key (a verdict that blocks, whether or not the block could be
  # recorded) records the run stream's version. `Effect.run/4` refuses to repeat
  # the effect, such as the operator's Create PR, until a `run.reset` follows
  # that version. The `:not_done` verdict never gets here: that retry is
  # legitimate. Returns `:ok` or `{:error, reason}`.
  defp mark_effect_unresolved(key, version, reason) do
    case KeyStore.mark_unresolved(key, version, reason) do
      :ok -> :ok
      {:error, _} = error -> error
      other -> {:error, other}
    end
  catch
    :exit, exit_reason -> {:error, {:key_store_unavailable, exit_reason}}
  end

  # After a successful block the marker moves to the post-block version. Best
  # effort: the marker written before the block already refuses the effect, and
  # the `RunReset` an operator appends lies after either version.
  defp refresh_effect_marker(key, run_id, reason) do
    {_state, version} = load_run_stream(run_id)

    case mark_effect_unresolved(key, version, reason) do
      :ok ->
        :ok

      {:error, error} ->
        Logger.warning(
          "BootReconciliation: effect #{inspect(key)} of run #{run_id}: marker not refreshed after the block (#{inspect(error)})",
          key: key,
          run_id: run_id
        )
    end
  end

  defp effect_recovery_command(run_id, outcome, fields, reason, command_id) do
    payload =
      Map.merge(fields, %{
        run_id: run_id,
        outcome: outcome,
        elapsed_since_boot_ms: System.monotonic_time(:millisecond) - Incarnation.started_at_ms()
      })

    %{
      type: "run.recovery_attempt",
      command_id: command_id,
      aggregate_id: "run:#{run_id}",
      payload: if(reason, do: Map.put(payload, :reason, reason), else: payload)
    }
  end

  # String-keyed, and no `project_id`: the aggregate adds the run's own, so the
  # command cannot disagree with it.
  defp effect_block_command(run_id, reason, version) do
    %{
      type: "run.block",
      command_id: "effect-blocked:#{run_id}:#{version}",
      aggregate_id: "run:#{run_id}",
      payload: %{"run_id" => run_id, "reason" => reason}
    }
  end

  defp load_run_stream(run_id) do
    Aggregate.load(ForemanServer.Aggregates.Run, "run:#{run_id}")
  end

  defp dispatch_effect_command(command) do
    case CommandGateway.dispatch_system(command) do
      {:ok, _} = ok -> ok
      {:error, _} = error -> error
      other -> {:error, {:unexpected_dispatch_result, other}}
    end
  catch
    :exit, exit_reason -> {:error, {:dispatch_exit, exit_reason}}
  end

  defp key_digest(key) do
    :sha256 |> :crypto.hash(key) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp reconcile_run_slots_stream do
    {state, _version} = Aggregate.load(RunSlots, "run_slots:global")

    if state.capacity == nil and state.holders == %{} and state.waiters == [] do
      :ok
    else
      holders_dropped =
        Enum.count(state.holders, fn {run_id, _holder} ->
          cond do
            not run_absent_or_terminal?(run_id) ->
              false

            skip_exhausted?(state, run_id) ->
              false

            true ->
              Logger.warning("BootReconciliation: dropping orphan slot holder #{run_id}")
              release_run_slot(run_id, :boot_orphan_holder, Map.has_key?(state.recovery, run_id))
              true
          end
        end)

      waiters_dropped =
        Enum.count(state.waiters, fn waiter ->
          cond do
            not waiter_run_absent_or_terminal?(waiter.run_id) ->
              false

            skip_exhausted?(state, waiter.run_id) ->
              false

            true ->
              Logger.warning("BootReconciliation: removing orphan waiter #{waiter.run_id}")

              remove_run_slot_waiter(
                waiter.run_id,
                :boot_orphan_waiter,
                Map.has_key?(state.recovery, waiter.run_id)
              )

              true
          end
        end)

      Telemetry.run_slots_reconciled(holders_dropped, waiters_dropped, :boot)
    end
  end

  # An entry that reached the cleanup limit stays in the stream and is not
  # re-dispatched with a fresh budget; it is logged, emitted as skipped, and
  # listed in `queue_status/0`. Only its holder or waiter leaving by another
  # route (the Dispatcher's terminal release, the periodic sweep) removes it.
  defp skip_exhausted?(state, run_id) do
    case Map.get(state.recovery, run_id) do
      %{outcome: "exhausted"} = entry ->
        Logger.error(
          "BootReconciliation: orphan slot entry #{run_id} (#{entry.kind}) is exhausted " <>
            "after #{entry.attempt} failed cleanups; skipping. Operator intervention required."
        )

        :telemetry.execute(
          @dispatch_blocked_event,
          %{count: 1},
          %{
            run_id: run_id,
            kind: entry.kind,
            attempts: entry.attempt,
            exit_reason: entry.reason,
            skipped: true
          }
        )

        true

      _ ->
        false
    end
  end

  defp run_absent_or_terminal?(run_id) do
    case ProjectionStore.run(run_id) do
      nil -> true
      _run -> run_terminal?(run_id)
    end
  end

  defp waiter_run_absent_or_terminal?(run_id), do: run_absent_or_terminal?(run_id)

  defp release_run_slot(run_id, reason, recorded?) when is_binary(run_id) and run_id != "" do
    ms = System.system_time(:millisecond)

    result =
      try do
        %{
          type: "run_slots.release",
          command_id: "foreman:boot-slot-release:#{run_id}:#{ms}",
          aggregate_id: "run_slots:global",
          payload: %{
            run_id: run_id,
            released_at_ms: ms,
            reason: reason
          }
        }
        |> dispatch_slot_command()
        |> dispatch_outcome(run_id, reason, :slot_release)
      catch
        # The `run_slots:global` actor is shared across the application and
        # any process (test reset, operator intervention, runtime supervisor)
        # can force-kill it between BootReconciliation's load and dispatch.
        # Without this rescue the synchronous `GenServer.call` exits with
        # `:killed` and terminates BootReconciliation, which cascades up to
        # `:foreman_server` shutting down. Apply the 5-restart exponential
        # backoff (RTE-T004 / RestartBackoff); after the limit the orphan is
        # recorded `exhausted` and skipped by later boots.
        :exit, exit_reason ->
          handle_dispatch_failure(run_id, reason, :slot_release, exit_reason)
          :failed
      end

    if result == :ok and recorded? do
      record_recovery(run_id, 0, "dispatched", :slot_release, nil)
    end

    :ok
  end

  defp remove_run_slot_waiter(run_id, reason, recorded?)
       when is_binary(run_id) and run_id != "" do
    ms = System.system_time(:millisecond)

    result =
      try do
        %{
          type: "run_slots.remove_waiter",
          command_id: "foreman:boot-slot-remove-waiter:#{run_id}:#{ms}",
          aggregate_id: "run_slots:global",
          payload: %{
            run_id: run_id,
            removed_at_ms: ms,
            reason: reason
          }
        }
        |> dispatch_slot_command()
        |> dispatch_outcome(run_id, reason, :waiter_remove)
      catch
        :exit, exit_reason ->
          handle_dispatch_failure(run_id, reason, :waiter_remove, exit_reason)
          :failed
      end

    if result == :ok and recorded? do
      record_recovery(run_id, 0, "dispatched", :waiter_remove, nil)
    end

    :ok
  end

  # The test hook stands in for an answer `CommandGateway.dispatch_system/1`
  # gives only under conditions a test cannot force (an append that errors).
  defp dispatch_slot_command(command) do
    case Application.get_env(:foreman_server, :boot_reconciliation_slot_dispatch_hook) do
      hook when is_function(hook, 1) -> hook.(command)
      _ -> CommandGateway.dispatch_system(command)
    end
  end

  # An `{:error, _}` answer leaves the holder or waiter in place, so it is a
  # failed dispatch exactly like an exit: it is counted, never cleared.
  defp dispatch_outcome({:ok, _}, _run_id, _reason, _kind), do: :ok

  defp dispatch_outcome({:error, error}, run_id, reason, kind) do
    handle_dispatch_failure(run_id, reason, kind, error)
    :failed
  end

  defp holder_orphan?(%BeadsDbLease.State{holder: nil}, _active_run_ids), do: false

  defp holder_orphan?(
         %BeadsDbLease.State{holder: %BeadsDbLease.Holder{} = holder},
         active_run_ids
       ) do
    not lease_entry_live?(holder, active_run_ids)
  end

  # A hold taken for one call names the incarnation of the server that took it
  # and is live exactly when that is this server: its `run_id` is a synthetic
  # one (`watcher:...`) or a run long since done, so no run projection can
  # speak for it. A hold without an incarnation belongs to a run and is live
  # while that run is.
  defp lease_entry_live?(%{incarnation: incarnation}, _active_run_ids)
       when is_binary(incarnation),
       do: incarnation == Incarnation.id()

  defp lease_entry_live?(%{run_id: run_id}, active_run_ids) when is_binary(run_id) do
    MapSet.member?(active_run_ids, run_id) and not run_terminal?(run_id)
  end

  defp tasks_with_db_path do
    ProjectionStore.list_tasks()
    |> Enum.flat_map(&task_db_path_entry/1)
  end

  defp task_db_path_entry(task) when is_map(task) do
    run_id = fetch_map_value(task, :run_id)
    db_path = beads_db_path_from_task(task)

    if is_binary(run_id) and run_id != "" and is_binary(db_path) and db_path != "" do
      [%{run_id: run_id, db_path: db_path}]
    else
      []
    end
  end

  defp task_db_path_entry(_), do: []

  defp beads_db_path_from_task(task) do
    snapshot =
      fetch_map_value(task, :workflow_snapshot) || %{}

    impl = fetch_map_value(snapshot, :implementation) || %{}

    fetch_map_value(impl, :beads_database_path)
  end

  defp release_lease(db_path, run_id, reason)
       when is_binary(db_path) and db_path != "" and is_binary(run_id) and run_id != "" do
    ms = System.system_time(:millisecond)

    _ =
      CommandGateway.dispatch_system(%{
        type: "lease.release",
        command_id: "foreman:boot-lease-release:#{run_id}:#{ms}",
        aggregate_id: BeadsDbLease.stream_id(db_path),
        payload: %{
          db_path: db_path,
          run_id: run_id,
          released_at_ms: ms,
          reason: reason
        }
      })

    :ok
  end

  defp remove_lease_waiter(db_path, %BeadsDbLease.Waiter{run_id: run_id}, reason)
       when is_binary(db_path) and db_path != "" and is_binary(run_id) and run_id != "" do
    ms = System.system_time(:millisecond)

    _ =
      CommandGateway.dispatch_system(%{
        type: "lease.remove_waiter",
        command_id: "foreman:boot-lease-remove-waiter:#{run_id}:#{ms}",
        aggregate_id: BeadsDbLease.stream_id(db_path),
        payload: %{
          db_path: db_path,
          run_id: run_id,
          removed_at_ms: ms,
          reason: reason
        }
      })

    :ok
  end

  defp remove_lease_waiter(_db_path, _waiter, _reason), do: :ok

  defp ack_orphan_task(task) do
    task_id = fetch_map_value(task, :task_id)
    run_id = fetch_map_value(task, :run_id)

    if is_binary(task_id) and task_id != "" and is_binary(run_id) and run_id != "" do
      reason =
        case ProjectionStore.run(run_id) do
          nil -> "run_terminated"
          run -> fetch_map_value(run, :status) || "run_terminated"
        end

      dispatch_task_run_terminated(task_id, run_id, reason)
    end
  end

  defp fan_out_task_run_terminated(run_id, reason) do
    ProjectionStore.tasks_by_run_id(run_id)
    |> Enum.each(fn task ->
      task_id = fetch_map_value(task, :task_id)
      dispatch_task_run_terminated(task_id, run_id, reason)
    end)
  end

  defp dispatch_task_run_terminated(task_id, run_id, reason) do
    if is_binary(task_id) and task_id != "" do
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
  end

  defp iso8601_now do
    {{y, mo, d}, {h, mi, s}} = :calendar.universal_time()

    :io_lib.format(
      "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ",
      [y, mo, d, h, mi, s]
    )
    |> List.to_string()
  end

  defp run_scan_or_defer(state) do
    case scan_branch() do
      :schedule_not_ready ->
        schedule_scan(:not_ready)
        state

      :schedule_worker_registry ->
        schedule_scan(:worker_registry_not_ready)
        state

      :scan ->
        do_scan_task_run_orphans()
        # Worktree-create and unresolved-worktree reconciliation runs an
        # O(orhpans) `git status --porcelain` via System.cmd per orphan and
        # must NEVER block the BootReconciliation mailbox: a slow scan
        # would starve run_terminated/2 casts dispatched from the live
        # Dispatcher. Off-load both passes to a tracked, monitor'd Task so
        # subsequent :scan_orphans / {:run_terminated, _, _} casts are
        # processed immediately, overlap is prevented, and the task can be
        # signalled to shut down during GenServer.terminate/2.
        spawn_async_vcs_scan(state)
    end
  end

  defp scan_branch do
    cond do
      not command_router_ready?() -> :schedule_not_ready
      not worker_registry_ready?() -> :schedule_worker_registry
      true -> :scan
    end
  end

  defp spawn_async_vcs_scan(%{vcs_scan_pid: pid} = state) when is_pid(pid) do
    if Process.alive?(pid) do
      # An earlier scan is still in progress; do not start another. The
      # :vcs_scan_done handler will clear vcs_scan_pid when the in-flight
      # task ends and a subsequent :scan_orphans cast will then schedule a
      # fresh pass.
      state
    else
      spawn_async_vcs_scan(%{state | vcs_scan_pid: nil})
    end
  end

  defp spawn_async_vcs_scan(state) do
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        do_scan_unresolved_worktrees()
        do_scan_worktree_create_orphans()
        send(parent, :vcs_scan_done)
      end)

    ref = Process.monitor(pid)
    %{state | vcs_scan_pid: pid, vcs_scan_ref: ref}
  end

  defp do_scan_worktree_create_orphans do
    ProjectionStore.list_worktree_create_orphans()
    |> Enum.each(&reconcile_worktree_create_orphan/1)

    :ok
  end

  defp reconcile_worktree_create_orphan(%{
         operation_id: op_id,
         project_id: project_id,
         run_id: run_id,
         phase_id: phase_id,
         worktree_path: worktree_path,
         repo_path: repo_path
       })
       when is_binary(worktree_path) and worktree_path != "" do
    cond do
      run_terminal?(run_id) == false ->
        :ok

      dirty_worktree?(worktree_path) ->
        emit_orphan_preserved(op_id, run_id, phase_id, worktree_path, :dirty)

      active_workers_for_run?(run_id) ->
        emit_orphan_preserved(op_id, run_id, phase_id, worktree_path, :active_workers)

      true ->
        case retry_clean_orphan(op_id, project_id, run_id, phase_id, repo_path, worktree_path) do
          :ok ->
            dispatch_orphan_resolve(op_id, run_id, phase_id, project_id, worktree_path)

          {:error, _} ->
            emit_orphan_preserved(op_id, run_id, phase_id, worktree_path, :clean_failed)
        end
    end
  end

  defp reconcile_worktree_create_orphan(_), do: :ok

  defp retry_clean_orphan(op_id, project_id, run_id, phase_id, repo_path, worktree_path) do
    ForemanServer.Workflow.Worktree.clean_orphan(%{
      operation_id: op_id,
      project_id: project_id || "",
      run_id: run_id,
      phase_id: phase_id,
      repo_path: repo_path || "",
      worktree_path: worktree_path
    })
  end

  defp dispatch_orphan_resolve(op_id, run_id, phase_id, project_id, worktree_path) do
    case orphan_resolve_dispatch_fn().(%{
           aggregate_id: "vcs:" <> op_id,
           command_id: "vcs.worktree.create.orphan_resolve:" <> op_id,
           type: "vcs.worktree.create.orphan_resolve",
           payload: %{
             operation_id: op_id,
             project_id: project_id || "",
             run_id: run_id,
             phase_id: phase_id,
             resolution: "recovered_via_clean_retry"
           }
         }) do
      {:ok, _event_spec} ->
        :ok

      {:error, reason} = err ->
        Logger.warning(
          "BootReconciliation failed to dispatch orphan_resolve for #{op_id}: #{inspect(reason)}"
        )

        emit_orphan_preserved(op_id, run_id, phase_id, worktree_path, :resolve_dispatch_failed)

        err
    end
  end

  defp orphan_resolve_dispatch_fn do
    case Process.get(:boot_reconciliation_orphan_resolve_dispatch) do
      nil -> &ForemanServer.CommandGateway.dispatch_system/1
      fun when is_function(fun, 1) -> fun
    end
  end

  defp do_scan_unresolved_worktrees do
    ProjectionStore.list_unresolved_worktrees()
    |> Enum.each(&reconcile_unresolved_worktree/1)

    :ok
  end

  defp reconcile_unresolved_worktree(%{
         operation_id: op_id,
         run_id: run_id,
         phase_id: phase_id,
         worktree_path: worktree_path,
         repo_path: repo_path
       })
       when is_binary(worktree_path) and worktree_path != "" do
    cond do
      run_terminal?(run_id) == false ->
        :ok

      dirty_worktree?(worktree_path) ->
        emit_orphan_preserved(op_id, run_id, phase_id, worktree_path, :dirty)

      active_workers_for_run?(run_id) ->
        emit_orphan_preserved(op_id, run_id, phase_id, worktree_path, :active_workers)

      true ->
        case retry_clean(op_id, run_id, phase_id, repo_path, worktree_path) do
          :ok ->
            :ok

          {:error, _} ->
            emit_orphan_preserved(op_id, run_id, phase_id, worktree_path, :clean_failed)
        end
    end
  end

  defp reconcile_unresolved_worktree(_), do: :ok

  defp dirty_worktree?(path) do
    case System.cmd("git", ["-C", path, "status", "--porcelain"]) do
      {output, 0} -> String.trim(output) != ""
      _ -> false
    end
  end

  defp active_workers_for_run?(run_id) do
    ForemanServer.Overwatch.WorkerSupervisor.list_pids_for_run(run_id) != []
  end

  defp worker_registry_ready? do
    case Application.get_env(:foreman_server, ForemanServer.Overwatch, [])[:enabled] do
      enabled when enabled in [true, "true"] ->
        is_pid(Process.whereis(ForemanServer.Overwatch.WorkerRegistry))

      _ ->
        true
    end
  end

  defp retry_clean(op_id, run_id, phase_id, repo_path, _worktree_path) do
    ForemanServer.Workflow.Worktree.clean(%{
      operation_id: op_id,
      project_id: project_id_for(op_id),
      run_id: run_id,
      phase_id: phase_id,
      repo_path: repo_path || ""
    })
  end

  defp project_id_for(op_id) do
    case ProjectionStore.worktree(op_id) do
      %{project_id: pid} when is_binary(pid) -> pid
      _ -> ""
    end
  end

  defp emit_orphan_preserved(op_id, run_id, phase_id, worktree_path, reason) do
    :telemetry.execute(
      [:foreman_server, :vcs, :worktree, :orphan_preserved],
      %{operation_id: op_id},
      %{
        run_id: run_id,
        phase_id: phase_id,
        worktree_path: worktree_path,
        reason: reason
      }
    )
  end

  defp schedule_scan(_reason) do
    Process.send_after(self(), :scan_orphans, @scan_retry_ms)
  end

  # Charge one failed cleanup dispatch to the run's durable budget (TRD-003) and
  # apply the 5-restart backoff (RTE-T004). The count is read from the
  # `run_slots:global` state and appended as `RunSlotRecoveryAttempted`: the
  # run is absent or terminal here, so it has no aggregate that could carry it.
  # A successful dispatch appends `dispatched` after a recorded failure.
  defp handle_dispatch_failure(run_id, reason, kind, exit_reason) do
    attempt = recorded_attempt(run_id) + 1

    case RestartBackoff.next_attempt(attempt) do
      {:retry, delay_ms} ->
        Logger.warning(
          "BootReconciliation: #{kind} for #{run_id} attempt #{attempt} failed " <>
            "(#{inspect(exit_reason)}); next retry in #{delay_ms}ms"
        )

        :telemetry.execute(
          @dispatch_retry_event,
          %{count: 1},
          %{run_id: run_id, kind: kind, attempt: attempt, exit_reason: inspect(exit_reason)}
        )

        record_recovery(run_id, attempt, "failed", kind, inspect(exit_reason))

      {:blocked, :max_attempts_exceeded} ->
        Logger.error(
          "BootReconciliation: #{kind} for #{run_id} marked BLOCKED after " <>
            "#{attempt} consecutive dispatch failures (#{inspect(exit_reason)}); " <>
            "operator intervention required. Reason: #{inspect(reason)}"
        )

        :telemetry.execute(
          @dispatch_blocked_event,
          %{count: 1},
          %{
            run_id: run_id,
            kind: kind,
            attempts: attempt,
            exit_reason: inspect(exit_reason),
            reason: inspect(reason)
          }
        )

        # The entry stays in the stream as `exhausted`; boot skips it from now on.
        record_recovery(run_id, attempt, "exhausted", kind, inspect(exit_reason))
    end
  end

  defp recorded_attempt(run_id) do
    {state, _version} = Aggregate.load(RunSlots, "run_slots:global")

    case Map.get(state.recovery, run_id) do
      %{attempt: attempt} when is_integer(attempt) -> attempt
      nil -> 0
    end
  end

  # Append one `RunSlotRecoveryAttempted`. A dead `run_slots:global` actor makes
  # the append exit; that is logged and not counted, and the reconciler stays up.
  defp record_recovery(run_id, attempt, outcome, kind, detail) do
    ms = System.system_time(:millisecond)

    command = %{
      type: "run_slots.recovery_attempt",
      command_id: "foreman:boot-slot-recovery:#{run_id}:#{outcome}:#{attempt}:#{ms}",
      aggregate_id: "run_slots:global",
      payload: %{
        run_id: run_id,
        attempt: attempt,
        outcome: outcome,
        kind: Atom.to_string(kind),
        reason: detail,
        elapsed_since_boot_ms: System.monotonic_time(:millisecond) - Incarnation.started_at_ms()
      }
    }

    try do
      case CommandGateway.dispatch_system(command) do
        {:error, error} ->
          Logger.error(
            "BootReconciliation: recovery record #{outcome} for #{run_id} rejected: " <>
              inspect(error)
          )

        {:ok, _} ->
          :ok
      end
    catch
      :exit, exit_reason ->
        Logger.error(
          "BootReconciliation: recovery record #{outcome} for #{run_id} not written: " <>
            inspect(exit_reason)
        )
    end

    :ok
  end

  defp command_router_ready? do
    is_pid(Process.whereis(CommandRouter))
  end
end
