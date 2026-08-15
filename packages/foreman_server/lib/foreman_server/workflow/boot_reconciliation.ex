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

  alias ForemanServer.{Aggregate, CommandGateway, CommandRouter, ProjectionStore, Telemetry}
  alias ForemanServer.Aggregates.{BeadsDbLease, RunSlots}
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
  @transition_comment "foreman-run-reconciled"
  @scan_retry_ms 50
  @json_schema_cache_name :foreman_server_json_schema_cache
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
  — a holder or waiter whose `run_id` does not correspond to a non-terminal
  run projection. Each orphan is dispatched as `lease.release` (for the
  holder) or `lease.remove_waiter` (for queued waiters) so the lease is
  cleanly transferred or freed after a restart that found stranded state.

  The scan walks every task projection that has a Beads DB path, groups
  by `db_path`, loads the lease aggregate via `Aggregate.load/2`, and
  inspects the lease holder and waiter list. A lease entry is considered
  live only when the run projection exists AND `terminal?` is false;
  everything else (no run projection, terminal run, or run whose binding
  has been cleared) is released or removed. Both `lease.release` and
  `lease.remove_waiter` are idempotent no-ops against foreign entries, so
  the scan is safe to re-run.

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

  @impl true
  def init(_init_arg) do
    {:ok,
     %{
       reconciled?: false,
       scanned?: false,
       vcs_scan_pid: nil,
       vcs_scan_ref: nil
     }, {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, state) do
    reconcile()
    state = run_scan_or_defer(state)
    state = run_lease_scan_or_defer(state)
    state = run_slot_scan_or_defer(state)
    {:noreply, %{state | reconciled?: true}}
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
    ProjectionStore.list_runs()
    |> Enum.reduce(%{}, fn run, acc ->
      if fetch_status(run) == "in_progress" do
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

  defp do_scan_lease_orphans do
    tasks_with_db_path()
    |> Enum.group_by(& &1.db_path, & &1.run_id)
    |> Enum.each(&reconcile_lease_stream/1)

    :ok
  end

  defp reconcile_lease_stream({db_path, run_ids}) when is_binary(db_path) and db_path != "" do
    active_run_ids = MapSet.new(run_ids)
    {state, _version} = Aggregate.load(BeadsDbLease, BeadsDbLease.stream_id(db_path))

    cond do
      not state.exists? ->
        :ok

      holder_orphan?(state, active_run_ids) ->
        release_lease(db_path, state.holder.run_id, :boot_orphan_holder)

      true ->
        :ok
    end

    state.waiters
    |> Enum.reject(fn waiter -> lease_entry_live?(waiter.run_id, active_run_ids) end)
    |> Enum.each(&remove_lease_waiter(db_path, &1, :boot_orphan_waiter))
  end

  defp reconcile_lease_stream(_), do: :ok

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
    :ok
  end

  defp reconcile_run_slots_stream do
    {state, _version} = Aggregate.load(RunSlots, "run_slots:global")

    if state.capacity == nil and state.holders == %{} and state.waiters == [] do
      :ok
    else
      holders_dropped =
        Enum.count(state.holders, fn {run_id, _holder} ->
          if run_absent_or_terminal?(run_id) do
            Logger.warning("BootReconciliation: dropping orphan slot holder #{run_id}")
            release_run_slot(run_id, :boot_orphan_holder)
            true
          else
            false
          end
        end)

      waiters_dropped =
        Enum.count(state.waiters, fn waiter ->
          if waiter_run_absent_or_terminal?(waiter.run_id) do
            Logger.warning("BootReconciliation: removing orphan waiter #{waiter.run_id}")
            remove_run_slot_waiter(waiter.run_id, :boot_orphan_waiter)
            true
          else
            false
          end
        end)

      Telemetry.run_slots_reconciled(holders_dropped, waiters_dropped, :boot)
    end
  end

  defp run_absent_or_terminal?(run_id) do
    case ProjectionStore.run(run_id) do
      nil -> true
      _run -> run_terminal?(run_id)
    end
  end

  defp waiter_run_absent_or_terminal?(run_id), do: run_absent_or_terminal?(run_id)

  defp release_run_slot(run_id, reason) when is_binary(run_id) and run_id != "" do
    ms = System.system_time(:millisecond)

    _ =
      CommandGateway.dispatch_system(%{
        type: "run_slots.release",
        command_id: "foreman:boot-slot-release:#{run_id}:#{ms}",
        aggregate_id: "run_slots:global",
        payload: %{
          run_id: run_id,
          released_at_ms: ms,
          reason: reason
        }
      })

    :ok
  end

  defp remove_run_slot_waiter(run_id, reason) when is_binary(run_id) and run_id != "" do
    ms = System.system_time(:millisecond)

    _ =
      CommandGateway.dispatch_system(%{
        type: "run_slots.remove_waiter",
        command_id: "foreman:boot-slot-remove-waiter:#{run_id}:#{ms}",
        aggregate_id: "run_slots:global",
        payload: %{
          run_id: run_id,
          removed_at_ms: ms,
          reason: reason
        }
      })

    :ok
  end

  defp holder_orphan?(%BeadsDbLease.State{holder: nil}, _active_run_ids), do: false

  defp holder_orphan?(
         %BeadsDbLease.State{holder: %BeadsDbLease.Holder{run_id: run_id}},
         active_run_ids
       )
       when is_binary(run_id) do
    not lease_entry_live?(run_id, active_run_ids)
  end

  defp lease_entry_live?(run_id, active_run_ids) when is_binary(run_id) do
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

  defp command_router_ready? do
    is_pid(Process.whereis(CommandRouter))
  end
end
