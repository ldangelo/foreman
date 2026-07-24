defmodule ForemanServer.ProjectionStore do
  @moduledoc "CQRS read models rebuilt from the durable event log."

  use GenServer

  alias ForemanServer.ProjectionStore.Postgres

  @terminal_run_statuses MapSet.new(["completed", "failed", "blocked", "merged"])
  @terminal_task_to_run_status %{
    "blocked" => "blocked",
    "closed" => "completed",
    "conflict" => "failed",
    "failed" => "failed",
    "merged" => "merged",
    "stuck" => "failed"
  }
  @task_statuses MapSet.new([
                   "backlog",
                   "ready",
                   "approved",
                   "in_progress",
                   "in-progress",
                   "review",
                   "merged",
                   "closed",
                   "conflict",
                   "failed",
                   "stuck",
                   "blocked",
                   "cooldown"
                 ])

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec apply_event(map()) :: :ok
  def apply_event(event) when is_map(event) do
    GenServer.call(__MODULE__, {:apply_event, event})
  end

  @spec rebuild([map()], timeout()) :: {:ok, map()} | {:error, term()}
  def rebuild(events, timeout) when is_list(events) do
    # Give the outer GenServer.call a small cushion over the internal
    # Task.yield timeout. At the deadline, both fire near-simultaneously;
    # the cushion lets the handler's internal nil branch fire first and
    # reply with {:error, :rebuild_timeout} so the caller gets a clean
    # structured error rather than a GenServer.call :exit timeout. For
    # non-integer timeouts (e.g. :infinity) no cushion is added.
    call_timeout = with_timeout_cushion(timeout)
    GenServer.call(__MODULE__, {:rebuild, events, timeout}, call_timeout)
  end

  # Backward-compatible 1-arg wrapper. New code should call rebuild/2 with an
  # explicit finite timeout. This wrapper exists so the existing tests and
  # internal callers (handle_call(:rebuild_projections, ...)) keep working
  # during the transition; new callers should pass a timeout.
  @spec rebuild([map()]) :: {:ok, map()} | {:error, term()}
  def rebuild(events) when is_list(events) do
    rebuild(events, ForemanServer.RuntimeInfo.projection_rebuild_timeout_ms())
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
    updated = reduce_event(projection, event, :live)
    persist_changes(projection, updated, event)
    {:reply, :ok, updated}
  end

  def handle_call({:rebuild, events, timeout}, _from, projection) do
    # Run the rebuild + persist on a linked task so we can enforce an
    # internal deadline matching the caller's timeout. GenServer.call/3's
    # timeout only bounds the caller; without this, a slow rebuild would
    # still block subsequent requests even after the caller gives up.
    # Task.yield returns {:ok, task_result}, {:exit, reason} on completed,
    # or nil on timeout; Task.shutdown brutally kills the linked task on
    # timeout so the GenServer stays responsive. The case arms unwrap the
    # inner {:ok, _} | {:error, _} returned by do_rebuild/1 and only set
    # the GenServer state to the new projection on success; errors keep
    # the prior projection.
    task = Task.async(fn -> do_rebuild(events) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, rebuilt}} ->
        {:reply, {:ok, rebuilt}, rebuilt}

      {:ok, {:error, reason}} ->
        {:reply, {:error, reason}, projection}

      {:exit, reason} ->
        {:reply, {:error, {:rebuild_crashed, reason}}, projection}

      nil ->
        {:reply, {:error, :rebuild_timeout}, projection}
    end
  end

  defp do_rebuild(events) do
    rebuilt = Enum.reduce(events, empty_projection(), &reduce_event(&2, &1, :replay))

    case persist_all(rebuilt) do
      :ok -> {:ok, rebuilt}
      {:ok, _result} -> {:ok, rebuilt}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_persist_result, other}}
    end
  end

  # Give the outer GenServer.call a small cushion over the internal
  # Task.yield timeout. At the deadline, both fire near-simultaneously;
  # the cushion lets the handler's internal nil branch fire first and
  # reply with {:error, :rebuild_timeout} so the caller gets a clean
  # structured error rather than a GenServer.call :exit timeout. For
  # non-integer timeouts (e.g. :infinity) no cushion is added.
  defp with_timeout_cushion(timeout) when is_integer(timeout) and timeout > 0, do: timeout + 1_000
  defp with_timeout_cushion(timeout), do: timeout

  def handle_call(:snapshot, _from, projection) do
    {:reply, projection, projection}
  end

  def handle_call({:project, project_id}, _from, projection) do
    project =
      if Postgres.enabled?(),
        do: Postgres.project(project_id),
        else: get_in(projection, [:projects, project_id])

    {:reply, project, projection}
  end

  def handle_call(:project_list, _from, projection) do
    projects =
      if Postgres.enabled?() do
        Postgres.project_list()
      else
        projection.projects
        |> Map.values()
        |> Enum.sort_by(& &1.project_id)
      end

    {:reply, projects, projection}
  end

  def handle_call({:task, task_id}, _from, projection) do
    task =
      if Postgres.enabled?(),
        do: Postgres.task(task_id),
        else: get_in(projection, [:tasks, task_id])

    {:reply, task, projection}
  end

  def handle_call(:task_list, _from, projection) do
    tasks =
      if Postgres.enabled?() do
        Postgres.task_list()
      else
        projection.tasks
        |> Map.values()
        |> Enum.sort_by(& &1.task_id)
      end

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

  @spec board(String.t()) :: map()
  def board(project_id) do
    GenServer.call(__MODULE__, {:board, project_id})
  end

  @impl true
  def handle_call({:board, project_id}, _from, projection) do
    result =
      if Postgres.enabled?() do
        {tasks_map, runs_map} = Postgres.board_data(project_id)
        build_board_from_maps(tasks_map, runs_map, project_id)
      else
        projection
        |> build_board(project_id)
      end
      |> normalize_board_output()

    {:reply, result, projection}
  end

  defp persist_changes(old_projection, new_projection, event) do
    if Postgres.enabled?(), do: Postgres.persist_changes(old_projection, new_projection, event)
  end

  defp persist_all(projection) do
    if Postgres.enabled?() do
      Postgres.replace_all(projection)
    else
      :ok
    end
  end

  defp empty_projection do
    %{
      commands: %{},
      projects: %{},
      tasks: %{},
      runs: %{},
      scheduler_skips: %{},
      worker_sequences: %{},
      worker_heartbeats: %{},
      recovery_events: [],
      worktrees: %{},
      vcs_operations: %{},
      pr_gates: %{},
      merge_failures: %{},
      inbox_messages: %{},
      inbox_by_run: %{},
      inbox_updates: [],
      integration_commands: %{},
      integration_dedupe: %{},
      logs_by_run: %{},
      attach_requests: %{},
      interactive_recovery: %{},
      planning_flows: %{},
      planning_traceability: %{},
      migration_imports: %{},
      migration_records: %{},
      authorization_audits: [],
      status_counts: %{active: 0, in_progress: 0, failed: 0, blocked: 0, completed: 0},
      checkpoint: %{last_event_id: nil, last_stream_version: 0, updated_at: nil},
      last_sequence: 0
    }
  end

  defp reduce_event(projection, event, mode) do
    projection
    |> apply_domain_event(normalize_event(event), mode)
    |> update_checkpoint(event)
    |> recompute_status_counts()
  end

  defp apply_domain_event(
         projection,
         %{
           type: "CommandAccepted",
           payload: %{command_id: command_id} = payload
         },
         _mode
       ) do
    put_in(projection, [:commands, command_id], payload)
  end

  defp apply_domain_event(
         projection,
         %{
           type: "ProjectRegistered",
           payload: %{project_id: project_id} = payload
         },
         _mode
       ) do
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

  defp apply_domain_event(
         projection,
         %{
           type: "ProjectUpdated",
           payload: %{project_id: project_id} = payload
         },
         _mode
       ) do
    update_in(projection, [:projects, project_id], fn
      nil ->
        nil

      project ->
        config =
          project
          |> Map.get(:config, %{})
          |> Map.merge(Map.get(payload, :config, %{}))
          |> maybe_put(:name, Map.get(payload, :name))

        project
        |> maybe_put(:status, Map.get(payload, :status))
        |> maybe_put(:default_branch, Map.get(payload, :default_branch))
        |> maybe_put(:health, Map.get(payload, :health))
        |> Map.put(:config, config)
        |> Map.put(:updated_at, Map.get(payload, :updated_at))
    end)
  end

  defp apply_domain_event(
         projection,
         %{
           type: "ProjectArchived",
           payload: %{project_id: project_id} = payload
         },
         _mode
       ) do
    update_in(projection, [:projects, project_id], fn
      nil ->
        nil

      project ->
        project
        |> Map.put(:status, "archived")
        |> Map.put(:archived_at, Map.get(payload, :updated_at))
        |> Map.put(:updated_at, Map.get(payload, :updated_at))
    end)
  end

  defp apply_domain_event(
         projection,
         %{
           type: "TaskCreated",
           payload: %{task_id: task_id} = payload
         },
         _mode
       ) do
    task =
      %{
        task_id: task_id,
        title: Map.get(payload, :title, task_id),
        status: Map.get(payload, :status, "open"),
        updated_at: Map.get(payload, :updated_at)
      }
      |> maybe_put(:project_id, Map.get(payload, :project_id))
      |> maybe_put(:description, Map.get(payload, :description))
      |> maybe_put(:priority, Map.get(payload, :priority))
      |> maybe_put(:dependencies, Map.get(payload, :dependencies))
      |> maybe_put(:source, Map.get(payload, :source))
      |> maybe_put(:external_id, Map.get(payload, :external_id))
      |> maybe_put(:external_link, Map.get(payload, :external_link))
      |> maybe_put(:dedupe_key, Map.get(payload, :dedupe_key))
      |> maybe_put(:task_type, Map.get(payload, :task_type))
      |> maybe_put(:integration_event_type, Map.get(payload, :integration_event_type))
      |> maybe_put(:planning_run_id, Map.get(payload, :planning_run_id))
      |> maybe_put(:planning_kind, Map.get(payload, :planning_kind))
      |> maybe_put(:planning_phase_id, Map.get(payload, :planning_phase_id))
      |> maybe_put(:trace_event_id, Map.get(payload, :trace_event_id))

    put_in(projection, [:tasks, task_id], task)
  end

  defp apply_domain_event(
         projection,
         %{
           type: "TaskUpdated",
           payload: %{task_id: task_id} = payload
         } = event,
         _mode
       ) do
    existing = empty_task(task_id)
    existing = get_in(projection, [:tasks, task_id]) || existing

    updates =
      payload
      |> Map.drop([:task_id])
      |> keep_only_task_status_values()
      |> clear_failure_fields_for_active_status()

    task = Map.merge(existing, updates)
    now = Map.get(event, :occurred_at) || DateTime.utc_now()

    projection
    |> put_worker_sequence(payload)
    |> put_in([:tasks, task_id], task)
    |> maybe_terminalize_run_from_task(task, payload, now)
  end

  defp apply_domain_event(
         projection,
         %{
           type: "TaskAnnotated",
           payload: %{task_id: task_id} = payload
         },
         _mode
       ) do
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

  defp apply_domain_event(
         projection,
         %{
           type: "TaskDependencyAdded",
           payload: %{task_id: task_id, depends_on: depends_on} = payload
         },
         _mode
       ) do
    existing = get_in(projection, [:tasks, task_id]) || empty_task(task_id)

    task =
      existing
      |> Map.update(:dependencies, [depends_on], fn deps -> Enum.uniq(deps ++ [depends_on]) end)
      |> Map.put(:updated_at, Map.get(payload, :updated_at))

    put_in(projection, [:tasks, task_id], task)
  end

  defp apply_domain_event(
         projection,
         %{type: "RunStarted", payload: %{run_id: run_id} = payload, occurred_at: occurred_at},
         _mode
       ) do
    now = occurred_at || DateTime.utc_now()

    run =
      %{
        run_id: run_id,
        task_id: Map.get(payload, :task_id),
        status: "in_progress",
        phase_order: Map.get(payload, :phase_order, []),
        current_phase: Map.get(payload, :current_phase),
        phase_status: %{},
        worker_status: %{},
        retry_history: [],
        created_at: now,
        started_at: now,
        updated_at: now
      }
      |> Map.merge(payload)
      |> Map.put_new(:status, "in_progress")

    put_in(projection, [:runs, run_id], run)
  end

  defp apply_domain_event(
         projection,
         %{type: "RunUpdated", payload: %{run_id: run_id} = payload, occurred_at: occurred_at},
         _mode
       ) do
    now = occurred_at || DateTime.utc_now()

    update_run(projection, run_id, fn run ->
      run
      |> Map.merge(payload)
      |> Map.put(:updated_at, now)
    end)
  end

  defp apply_domain_event(
         projection,
         %{type: "PrUpdated", payload: %{run_id: run_id} = payload},
         _mode
       ) do
    update_run(projection, run_id, fn run ->
      run
      |> Map.merge(payload)
      |> Map.put(:pr_url, Map.get(payload, :pr_url))
      |> Map.put(:pr_state, Map.get(payload, :pr_state, Map.get(run, :pr_state, "draft")))
      |> Map.put(:pr_head_sha, Map.get(payload, :head_sha))
      |> Map.put(:commit_sha, Map.get(payload, :head_sha))
      |> Map.put(:base_branch, Map.get(payload, :base_branch))
    end)
  end

  defp apply_domain_event(
         projection,
         %{type: "PrReady", payload: %{run_id: run_id} = payload},
         _mode
       ) do
    update_run(projection, run_id, fn run ->
      run
      |> Map.merge(payload)
      |> Map.put(:pr_url, Map.get(payload, :pr_url))
      |> Map.put(:pr_state, "open")
      |> Map.put(:pr_head_sha, Map.get(payload, :head_sha))
      |> Map.put(:commit_sha, Map.get(payload, :head_sha))
      |> Map.put(:base_branch, Map.get(payload, :base_branch))
    end)
  end

  defp apply_domain_event(
         projection,
         %{
           type: "PrMerged",
           payload: %{run_id: run_id, task_id: _task_id, pr_url: _pr_url} = payload
         },
         _mode
       ) do
    update_run(projection, run_id, fn run ->
      run
      |> Map.merge(payload)
      |> Map.put(:pr_url, Map.get(payload, :pr_url, Map.get(run, :pr_url)))
      |> Map.put(:pr_state, "merged")
      |> Map.put(:status, "merged")
      |> Map.put(:completed_at, Map.get(payload, :merged_at, Map.get(payload, :completed_at)))
    end)
  end

  defp apply_domain_event(
         projection,
         %{type: "PrRetargeted", payload: %{run_id: run_id} = payload},
         _mode
       ) do
    update_run(projection, run_id, fn run ->
      run
      |> Map.merge(payload)
      |> Map.put(:pr_url, Map.get(payload, :pr_url))
      |> Map.put(:pr_head_sha, Map.get(payload, :head_sha))
      |> Map.put(:commit_sha, Map.get(payload, :head_sha))
      |> Map.put(:base_branch, Map.get(payload, :new_base_branch))
    end)
  end

  defp apply_domain_event(
         projection,
         %{type: "PrReset", payload: %{run_id: run_id} = payload},
         _mode
       ) do
    update_run(projection, run_id, fn run ->
      run
      |> Map.merge(payload)
      |> Map.put(:pr_url, Map.get(payload, :pr_url, Map.get(run, :pr_url)))
      |> Map.put(:pr_state, "closed")
    end)
  end

  defp apply_domain_event(projection, %{type: "RunDeleted", payload: %{run_id: run_id}}, _mode) do
    update_in(projection, [:runs], &Map.delete(&1 || %{}, run_id))
  end

  defp apply_domain_event(
         projection,
         %{type: "CliEventLogged", payload: %{run_id: run_id} = payload},
         _mode
       )
       when is_binary(run_id) and run_id != "" do
    projection
    |> put_log_entry("CliEventLogged", payload)
    |> update_run(run_id, fn run ->
      cost_usd = Map.get(payload, :costUsd, 0) || 0
      turns = Map.get(payload, :turns, 0) || 0

      run
      |> Map.update(:costUsd, cost_usd, &(&1 + cost_usd))
      |> Map.update(:turns, turns, &(&1 + turns))
    end)
  end

  defp apply_domain_event(projection, %{type: "CliEventLogged"}, _mode), do: projection

  defp apply_domain_event(
         projection,
         %{type: "RunCompleted", payload: %{run_id: run_id} = payload, occurred_at: occurred_at},
         _mode
       ) do
    now = occurred_at || DateTime.utc_now()

    projection
    |> put_worker_sequence(payload)
    |> update_run_status(run_id, "completed")
    |> update_run(run_id, fn run ->
      started_at = Map.get(run, :started_at) || now
      total_duration_ms = duration_ms(started_at, now)

      run
      |> put_terminal_phase_status(payload, "completed")
      |> Map.put(:current_phase, nil)
      |> put_terminal_worker_status(payload, "completed")
      |> Map.put(:updated_at, now)
      |> Map.put(:completed_at, now)
      |> Map.put(:totalDurationMs, total_duration_ms)
    end)
    |> maybe_update_task_from_run_terminal(payload, "completed", now)
  end

  defp apply_domain_event(
         projection,
         %{type: "RunFailed", payload: %{run_id: run_id} = payload, occurred_at: occurred_at},
         _mode
       ) do
    now = occurred_at || DateTime.utc_now()

    projection
    |> put_worker_sequence(payload)
    |> update_run_status(run_id, "failed")
    |> update_run(run_id, fn run ->
      started_at = Map.get(run, :started_at) || now
      total_duration_ms = duration_ms(started_at, now)

      run
      |> put_terminal_current_phase(payload)
      |> put_terminal_phase_status(payload, "failed")
      |> put_terminal_worker_status(payload, "failed")
      |> Map.put(
        :retry_history,
        Map.get(payload, :retry_history, Map.get(run, :retry_history, []))
      )
      |> Map.put(:updated_at, now)
      |> Map.put(:failed_at, now)
      |> Map.put(:totalDurationMs, total_duration_ms)
    end)
    |> maybe_update_task_from_run_terminal(payload, "failed", now)
  end

  defp apply_domain_event(
         projection,
         %{type: "RunBlocked", payload: %{run_id: run_id} = payload, occurred_at: occurred_at},
         _mode
       ) do
    now = occurred_at || DateTime.utc_now()

    projection
    |> update_run(run_id, fn run ->
      run
      |> Map.put(:status, "blocked")
      |> Map.put(:updated_at, now)
    end)
    |> maybe_update_task_from_run_terminal(payload, "blocked", now)
  end

  defp apply_domain_event(
         projection,
         %{
           type: "PhaseStarted",
           payload: %{run_id: run_id, phase_id: phase_id} = payload
         },
         _mode
       ) do
    projection
    |> put_worker_sequence(payload)
    |> update_run(run_id, fn run ->
      if terminal_run?(run) do
        run
      else
        run
        |> Map.put(:current_phase, phase_id)
        |> update_in([:phase_status], &Map.put(&1 || %{}, phase_id, "in_progress"))
      end
    end)
  end

  defp apply_domain_event(
         projection,
         %{
           type: "PhaseCompleted",
           payload: %{run_id: run_id, phase_id: phase_id} = payload
         },
         _mode
       ) do
    projection
    |> put_worker_sequence(payload)
    |> update_run(run_id, fn run ->
      run
      |> update_in([:phase_status], &Map.put(&1 || %{}, phase_id, "completed"))
      |> maybe_complete_worker(payload)
      |> Map.put(
        :artifact_paths,
        Map.get(payload, :artifact_paths, Map.get(run, :artifact_paths, []))
      )
      |> Map.put(:report_paths, Map.get(payload, :report_paths, Map.get(run, :report_paths, [])))
    end)
  end

  defp apply_domain_event(
         projection,
         %{
           type: type,
           payload: %{run_id: run_id, phase_id: phase_id} = payload
         },
         _mode
       )
       when type in ["PhaseFailed", "PhaseTimedOut"] do
    status = if type == "PhaseTimedOut", do: "timed_out", else: "failed"

    projection
    |> put_worker_sequence(payload)
    |> update_run(run_id, fn run ->
      run
      |> update_in([:phase_status], &Map.put(&1 || %{}, phase_id, status))
      |> Map.put(
        :retry_history,
        Map.get(payload, :retry_history, Map.get(run, :retry_history, []))
      )
    end)
  end

  defp apply_domain_event(
         projection,
         %{
           type: "PhaseRetried",
           payload: %{run_id: run_id, phase_id: phase_id} = payload
         },
         _mode
       ) do
    projection
    |> put_worker_sequence(payload)
    |> update_run(run_id, fn run ->
      run
      |> Map.put(:current_phase, phase_id)
      |> update_in([:phase_status], &Map.put(&1 || %{}, phase_id, "retrying"))
      |> Map.put(
        :retry_history,
        Map.get(payload, :retry_history, Map.get(run, :retry_history, []))
      )
    end)
  end

  defp apply_domain_event(
         projection,
         %{
           type: "WorkerStatusChanged",
           payload: %{run_id: run_id, worker_id: worker_id, status: status}
         },
         _mode
       ) do
    update_run(projection, run_id, fn run ->
      put_active_worker_status(run, worker_id, status)
    end)
  end

  defp apply_domain_event(
         projection,
         %{
           type: "WorkerStarted",
           payload: %{run_id: run_id, worker_id: worker_id, phase_id: phase_id} = payload
         },
         _mode
       ) do
    projection
    |> put_worker_sequence(payload)
    |> update_run(run_id, fn run ->
      if terminal_run?(run) do
        run
      else
        run
        |> put_active_worker_status(worker_id, "running")
        |> Map.put(:current_phase, phase_id)
        |> Map.put(:adapter, Map.get(payload, :adapter))
        |> Map.put(:artifact_paths, Map.get(payload, :artifact_paths, []))
      end
    end)
  end

  defp apply_domain_event(
         projection,
         %{
           type: "WorkerHeartbeat",
           payload: %{run_id: run_id, worker_id: worker_id} = payload
         },
         _mode
       ) do
    projection
    |> put_worker_sequence(payload)
    |> put_in([:worker_heartbeats, "#{run_id}:#{worker_id}"], payload)
    |> update_run(run_id, fn run ->
      put_active_worker_status(run, worker_id, "heartbeat")
    end)
  end

  defp apply_domain_event(
         projection,
         %{
           type: "ToolCallFinished",
           payload: %{run_id: run_id, worker_id: worker_id} = payload
         },
         _mode
       ) do
    projection
    |> put_worker_sequence(payload)
    |> put_log_entry("ToolCallFinished", payload)
    |> update_run(run_id, fn run ->
      run
      |> update_in([:tool_events], &((&1 || []) ++ [payload]))
      |> put_active_worker_status(worker_id, "running")
    end)
  end

  defp apply_domain_event(
         projection,
         %{
           type: type,
           payload: %{run_id: run_id, worker_id: worker_id} = payload
         },
         _mode
       )
       when type in ["WorkerStdout", "WorkerStderr", "AssistantMessage"] do
    projection
    |> put_worker_sequence(payload)
    |> put_log_entry(type, payload)
    |> update_run(run_id, fn run ->
      put_active_worker_status(run, worker_id, "running")
    end)
  end

  defp apply_domain_event(
         projection,
         %{
           type: "SchedulerTaskSkipped",
           payload: %{task_id: task_id} = payload
         },
         _mode
       ) do
    put_in(projection, [:scheduler_skips, task_id], payload)
  end

  defp apply_domain_event(projection, %{type: type, payload: payload}, _mode)
       when type in [
              "WorkerFailureSimulated",
              "WorkerRecoveryRequired",
              "ExternalWorkerObserved",
              "WorkerReattached",
              "WorkerRestarted",
              "NeedsOperator"
            ] do
    update_in(
      projection,
      [:recovery_events],
      &((&1 || []) ++ [Map.put(payload, :event_type, type)])
    )
  end

  defp apply_domain_event(
         projection,
         %{type: type, payload: %{run_id: run_id} = payload},
         _mode
       )
       when type in ["AttachRequested", "AttachUnsupported"] do
    put_in(projection, [:attach_requests, run_id], Map.put(payload, :event_type, type))
  end

  defp apply_domain_event(
         projection,
         %{type: type, payload: %{run_id: run_id, phase_id: phase_id} = payload},
         _mode
       )
       when type in ["HumanInterruptionRecorded", "InteractiveRecoveryResumed"] do
    projection
    |> update_in([:interactive_recovery, run_id], fn events ->
      (events || []) ++ [Map.put(payload, :event_type, type)]
    end)
    |> update_run(run_id, fn run ->
      run
      |> put_in([:phase_status, phase_id], Map.get(payload, :status))
      |> Map.put(:recovery_next_action, Map.get(payload, :next_action))
    end)
  end

  defp apply_domain_event(
         projection,
         %{
           type: "WorktreeCreated",
           payload: %{run_id: run_id} = payload
         },
         _mode
       ) do
    projection = put_in(projection, [:worktrees, run_id], payload)

    case Map.get(payload, :operation_id) do
      operation_id when is_binary(operation_id) ->
        put_in(
          projection,
          [:vcs_operations, operation_id],
          Map.put(payload, :event_type, "WorktreeCreated")
        )

      _ ->
        projection
    end
  end

  defp apply_domain_event(
         projection,
         %{
           type: "WorktreeCleaned",
           payload: %{run_id: run_id} = payload
         },
         _mode
       ) do
    projection = update_in(projection, [:worktrees], &Map.delete(&1 || %{}, run_id))

    case Map.get(payload, :operation_id) do
      operation_id when is_binary(operation_id) ->
        put_in(
          projection,
          [:vcs_operations, operation_id],
          Map.put(payload, :event_type, "WorktreeCleaned")
        )

      _ ->
        projection
    end
  end

  defp apply_domain_event(
         projection,
         %{
           type: "VcsMergeRequested",
           payload: payload
         },
         _mode
       ) do
    put_in(
      projection,
      [:vcs_operations, payload.operation_id],
      Map.put(payload, :event_type, "VcsMergeRequested")
    )
  end

  defp apply_domain_event(
         projection,
         %{
           type: "PrGateObserved",
           payload: %{pr_id: pr_id} = payload
         },
         _mode
       ) do
    put_in(projection, [:pr_gates, pr_id], payload)
  end

  defp apply_domain_event(
         projection,
         %{
           type: "PrMerged",
           payload: %{pr_id: pr_id} = payload
         },
         _mode
       ) do
    put_in(projection, [:pr_gates, pr_id], Map.put(payload, :state, "merged"))
  end

  defp apply_domain_event(
         projection,
         %{
           type: type,
           payload: %{pr_id: pr_id} = payload
         },
         _mode
       )
       when type in ["MergeFailed", "MergeBlocked"] do
    projection
    |> put_in([:merge_failures, pr_id], Map.put(payload, :event_type, type))
    |> put_in([:pr_gates, pr_id], Map.put(payload, :state, "failed"))
  end

  defp apply_domain_event(
         projection,
         %{
           type: "InboxMessageAppended",
           payload: %{message_id: message_id, run_id: run_id} = payload
         },
         mode
       ) do
    message = Map.put(payload, :event_type, "InboxMessageAppended")
    maybe_notify_inbox_watchers(mode, run_id, message)

    projection
    |> put_in([:inbox_messages, message_id], message)
    |> update_in([:inbox_by_run, run_id], fn ids -> Enum.uniq((ids || []) ++ [message_id]) end)
    |> update_in([:inbox_updates], &((&1 || []) ++ [message]))
  end

  defp apply_domain_event(
         projection,
         %{
           type: "InboxDeliveryUpdated",
           payload: %{message_id: message_id, run_id: run_id} = payload
         },
         mode
       ) do
    existing =
      get_in(projection, [:inbox_messages, message_id]) ||
        %{message_id: message_id, run_id: run_id}

    message = existing |> Map.merge(payload) |> Map.put(:event_type, "InboxDeliveryUpdated")
    maybe_notify_inbox_watchers(mode, run_id, message)

    projection
    |> put_in([:inbox_messages, message_id], message)
    |> update_in([:inbox_by_run, run_id], fn ids -> Enum.uniq((ids || []) ++ [message_id]) end)
    |> update_in([:inbox_updates], &((&1 || []) ++ [message]))
  end

  defp apply_domain_event(
         projection,
         %{
           type: "IntegrationCommandIngested",
           payload: %{dedupe_key: dedupe_key} = payload
         },
         _mode
       ) do
    record = Map.put(payload, :event_type, "IntegrationCommandIngested")

    projection
    |> put_in([:integration_commands, dedupe_key], record)
    |> put_in([:integration_dedupe, dedupe_key], record)
  end

  defp apply_domain_event(
         projection,
         %{type: "PlanningFlowStarted", payload: %{run_id: run_id} = payload},
         _mode
       ) do
    put_in(projection, [:planning_flows, run_id], Map.put(payload, :status, "in_progress"))
  end

  defp apply_domain_event(
         projection,
         %{
           type: "PlanningTraceLinked",
           payload: %{traceability_key: key, run_id: run_id} = payload
         },
         _mode
       ) do
    projection
    |> put_in([:planning_traceability, key], payload)
    |> update_in([:planning_flows, run_id, :traceability_keys], &Enum.uniq((&1 || []) ++ [key]))
  end

  defp apply_domain_event(
         projection,
         %{type: "PlanningFlowCompleted", payload: %{run_id: run_id} = payload},
         _mode
       ) do
    projection
    |> update_in([:planning_flows, run_id], &Map.merge(&1 || %{}, payload))
    |> put_in([:planning_flows, run_id, :status], "completed")
  end

  defp apply_domain_event(
         projection,
         %{type: "MigrationImportStarted", payload: %{migration_id: migration_id} = payload},
         _mode
       ) do
    put_in(
      projection,
      [:migration_imports, migration_id],
      Map.put(payload, :status, "in_progress")
    )
  end

  defp apply_domain_event(
         projection,
         %{
           type: "MigrationRecordImported",
           payload: %{migration_id: migration_id, record_type: type, record_id: id} = payload
         },
         _mode
       ) do
    projection
    |> put_in([:migration_records, "#{migration_id}:#{type}:#{id}"], payload)
    |> update_in([:migration_imports, migration_id], fn import ->
      import = import || %{migration_id: migration_id, status: "in_progress"}
      counts = Map.update(Map.get(import, :record_counts, %{}), type, 1, &(&1 + 1))
      Map.put(import, :record_counts, counts)
    end)
  end

  defp apply_domain_event(
         projection,
         %{type: "MigrationImportCompleted", payload: %{migration_id: migration_id} = payload},
         _mode
       ) do
    projection
    |> update_in([:migration_imports, migration_id], &Map.merge(&1 || %{}, payload))
    |> put_in([:migration_imports, migration_id, :status], "completed")
  end

  defp apply_domain_event(projection, %{type: type, payload: payload}, _mode)
       when type in ["AuthorizationChecked", "AuditRecorded"] do
    update_in(
      projection,
      [:authorization_audits],
      &((&1 || []) ++ [Map.put(payload, :event_type, type)])
    )
  end

  defp apply_domain_event(
         projection,
         %{payload: %{run_id: run_id, worker_id: worker_id, sequence: sequence} = payload},
         _mode
       )
       when is_binary(run_id) and is_binary(worker_id) and is_integer(sequence) do
    put_worker_sequence(projection, payload)
  end

  defp apply_domain_event(projection, _event, _mode), do: projection

  defp terminal_run?(%{status: status}) when is_binary(status) do
    MapSet.member?(@terminal_run_statuses, status)
  end

  defp terminal_run?(_run), do: false

  defp terminal_run_status_for_task_status(status) when is_binary(status) do
    Map.get(@terminal_task_to_run_status, status)
  end

  defp terminal_run_status_for_task_status(_status), do: nil

  defp maybe_terminalize_run_from_task(projection, task, payload, now) do
    task_status = Map.get(task, :status)
    run_status = terminal_run_status_for_task_status(task_status)
    run_id = payload_value(payload, :run_id) || Map.get(task, :run_id)

    case {run_status, run_id} do
      {status, run_id} when is_binary(status) and is_binary(run_id) and run_id != "" ->
        update_run(projection, run_id, fn run ->
          if terminal_run?(run) do
            run
          else
            run
            |> Map.put(:status, status)
            |> put_terminal_current_phase(payload)
            |> put_terminal_phase_status(payload, status)
            |> put_terminal_worker_status(payload, status)
            |> Map.put(:updated_at, now)
            |> maybe_put(:completed_at, if(status in ["completed", "merged"], do: now, else: nil))
            |> maybe_put(:failed_at, if(status == "failed", do: now, else: nil))
          end
        end)

      _ ->
        projection
    end
  end

  defp put_active_worker_status(run, worker_id, status)
       when is_binary(worker_id) and worker_id != "" do
    if terminal_run?(run) do
      run
    else
      update_in(run, [:worker_status], &Map.put(&1 || %{}, worker_id, status))
    end
  end

  defp put_active_worker_status(run, _worker_id, _status), do: run

  defp put_terminal_worker_status(run, payload, status) do
    case payload_value(payload, :worker_id) do
      worker_id when is_binary(worker_id) and worker_id != "" ->
        update_in(run, [:worker_status], &Map.put(&1 || %{}, worker_id, status))

      _ ->
        update_in(run, [:worker_status], fn worker_status ->
          worker_status
          |> Kernel.||(%{})
          |> Map.new(fn {worker_id, worker_status} ->
            if active_worker_status?(worker_status),
              do: {worker_id, status},
              else: {worker_id, worker_status}
          end)
        end)
    end
  end

  defp active_worker_status?(status) when is_binary(status) do
    status in ["running", "heartbeat", "active", "started", "in_progress"]
  end

  defp active_worker_status?(_status), do: false

  defp put_terminal_current_phase(run, payload) do
    case payload_value(payload, :phase_id) || Map.get(run, :current_phase) do
      phase_id when is_binary(phase_id) and phase_id != "" ->
        Map.put(run, :current_phase, phase_id)

      _ ->
        run
    end
  end

  defp put_terminal_phase_status(run, payload, status) do
    case payload_value(payload, :phase_id) || Map.get(run, :current_phase) do
      phase_id when is_binary(phase_id) and phase_id != "" ->
        update_in(run, [:phase_status], &Map.put(&1 || %{}, phase_id, status))

      _ ->
        run
    end
  end

  defp payload_value(payload, key) when is_map(payload) and is_atom(key) do
    Map.get(payload, key, Map.get(payload, Atom.to_string(key)))
  end

  defp maybe_complete_worker(run, %{worker_id: worker_id})
       when is_binary(worker_id) and worker_id != "" do
    update_in(run, [:worker_status], &Map.put(&1 || %{}, worker_id, "completed"))
  end

  defp maybe_complete_worker(run, _payload), do: run

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

  defp maybe_update_task_from_run_terminal(
         projection,
         payload,
         status,
         fallback_updated_at
       )
       when is_map(payload) do
    task_id = terminal_task_id(projection, payload)

    if is_binary(task_id) and task_id != "" do
      existing = get_in(projection, [:tasks, task_id]) || empty_task(task_id)

      task =
        existing
        |> Map.put(:status, status)
        |> Map.put(:run_id, Map.get(payload, :run_id, Map.get(existing, :run_id)))
        |> maybe_put(
          :updated_at,
          Map.get(
            payload,
            :updated_at,
            Map.get(payload, :completed_at, Map.get(payload, :failed_at, fallback_updated_at))
          )
        )
        |> maybe_put(
          :failure_reason,
          Map.get(payload, :reason, Map.get(payload, :failure_reason))
        )

      put_in(projection, [:tasks, task_id], task)
    else
      projection
    end
  end

  defp maybe_update_task_from_run_terminal(projection, _payload, _status, _fallback_updated_at),
    do: projection

  defp terminal_task_id(_projection, %{task_id: task_id}) when is_binary(task_id), do: task_id

  defp terminal_task_id(projection, %{run_id: run_id}) when is_binary(run_id),
    do: get_in(projection, [:runs, run_id, :task_id])

  defp terminal_task_id(_projection, _payload), do: nil

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

  defp keep_only_task_status_values(%{status: nil} = updates), do: Map.delete(updates, :status)

  defp keep_only_task_status_values(%{status: status} = updates) when is_binary(status) do
    if MapSet.member?(@task_statuses, status), do: updates, else: Map.delete(updates, :status)
  end

  defp keep_only_task_status_values(updates), do: updates

  defp clear_failure_fields_for_active_status(%{status: status} = updates)
       when status in ["ready", "approved", "in_progress", "in-progress"] do
    updates
    |> Map.put(:failure_reason, nil)
    |> Map.put(:failure_output, nil)
  end

  defp clear_failure_fields_for_active_status(updates), do: updates

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp put_worker_sequence(projection, %{run_id: run_id, worker_id: worker_id, sequence: sequence})
       when is_integer(sequence) do
    put_in(projection, [:worker_sequences, "#{run_id}:#{worker_id}"], sequence)
  end

  defp put_worker_sequence(projection, _payload), do: projection

  defp put_log_entry(projection, type, %{run_id: run_id} = payload) do
    entry = Map.put(payload, :event_type, type)
    update_in(projection, [:logs_by_run, run_id], &((&1 || []) ++ [entry]))
  end

  defp maybe_notify_inbox_watchers(:live, run_id, message),
    do: notify_inbox_watchers(run_id, message)

  defp maybe_notify_inbox_watchers(:replay, _run_id, _message), do: :ok

  defp notify_inbox_watchers(run_id, message) do
    if Process.whereis(ForemanServer.InboxRegistry) do
      Registry.dispatch(ForemanServer.InboxRegistry, run_id, fn entries ->
        for {pid, _value} <- entries do
          send(pid, {:inbox_update, run_id, message})
        end
      end)
    end
  end

  defp normalize_event(%ForemanServer.Event{} = event) do
    %{type: event.event_type, payload: event.payload, occurred_at: event.occurred_at}
  end

  defp normalize_event(%{event_type: event_type, payload: payload} = event) do
    %{type: event_type, payload: payload, occurred_at: Map.get(event, :occurred_at)}
  end

  defp normalize_event(%{type: type, payload: payload} = event) do
    %{type: type, payload: payload, occurred_at: Map.get(event, :occurred_at)}
  end

  # ── datetime helpers ───────────────────────────────────────────────────

  defp duration_ms(from, to) do
    from = coerce_datetime(from)
    to = coerce_datetime(to)

    cond do
      match?(%DateTime{}, from) && match?(%DateTime{}, to) ->
        DateTime.diff(to, from, :millisecond)

      match?(%NaiveDateTime{}, from) && match?(%NaiveDateTime{}, to) ->
        NaiveDateTime.diff(to, from, :millisecond)

      true ->
        0
    end
  end

  defp coerce_datetime(%DateTime{} = dt), do: dt

  defp coerce_datetime(%NaiveDateTime{} = ndt) do
    case DateTime.from_naive(ndt, "Etc/UTC") do
      {:ok, dt} -> dt
      _ -> ndt
    end
  end

  defp coerce_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} ->
        dt

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, ndt} -> coerce_datetime(ndt)
          _ -> nil
        end
    end
  end

  defp coerce_datetime(_), do: nil

  # ─── Board grouping ───────────────────────────────────────────────────────────

  @active_task_statuses MapSet.new([
                          "in_progress",
                          "in-progress",
                          "review",
                          "cooldown",
                          "running"
                        ])

  @blocked_task_statuses MapSet.new([
                           "failed",
                           "fail",
                           "stuck",
                           "conflict",
                           "blocked",
                           "review",
                           "test-failed"
                         ])

  # User directive: closed PR is a terminal state → Done. Reset
  # stays out of Done (PrReset is a cleanup signal that may need
  # attention; explicit user clarification). pr_state="reset"
  # continues to route to blocked via pr_state_to_board_status/1.
  @done_task_statuses MapSet.new([
                        "merged",
                        "completed",
                        "done",
                        "closed",
                        "pr_created"
                      ])

  # Narrower override used for the pre-PR-state precedence: only
  # truly unambiguous done statuses where the operator has confirmed
  # the task landed. `closed` is intentionally NOT here — a closed
  # PR can mean "closed-without-merge", and we don't want to preempt
  # the broader post-PR-fallback check (which does fire for closed
  # tasks). The task-level discriminator between Done and Blocked for
  # closed PRs is whether `task.close` was emitted (real close via
  # PrMonitor) or only `PrReset` (operator reset, task stays Blocked).
  @authoritative_done_task_statuses MapSet.new([
                                       "merged",
                                       "completed",
                                       "done"
                                     ])

  @active_run_statuses MapSet.new([
                         "running",
                         "queued",
                         "pending",
                         "in_progress",
                         "retrying",
                         "cooldown"
                       ])
  # (used when Postgres is the backing store and GenServer state may be cold)
  defp build_board_from_maps(tasks_map, runs_map, project_id) do
    tasks =
      tasks_map
      |> Map.values()
      |> Enum.filter(fn task ->
        Map.get(task, :project_id) == project_id
      end)

    task_ids = MapSet.new(Enum.map(tasks, & &1.task_id))

    runs =
      runs_map
      |> Map.values()
      |> Enum.filter(fn run ->
        task_id = Map.get(run, :task_id)
        MapSet.member?(task_ids, task_id)
      end)
      |> Enum.sort_by(&{Map.get(&1, :task_id), Map.get(&1, :run_id)})

    # Build task_id -> active run mapping
    run_by_task =
      Enum.reduce(runs, %{}, fn run, acc ->
        task_id = Map.get(run, :task_id)

        case Map.get(acc, task_id) do
          nil ->
            Map.put(acc, task_id, run)

          existing ->
            existing_updated = Map.get(existing, :updated_at, "") || ""
            run_updated = Map.get(run, :updated_at, "") || ""

            if run_updated > existing_updated,
              do: Map.put(acc, task_id, run),
              else: acc
        end
      end)

    # Group tasks. Precedence (the Query-side state machine):
    #   1. Authoritative done task.status (`@authoritative_done_task_statuses`
    #      = merged / completed / done) wins over PR state. Used for
    #      operator-confirmed landings via `task.update`. The narrower
    #      set excludes `closed` (a closed PR can mean
    #      "closed-without-merge") and `reset` (operator reset
    #      cleanup signal stays in Blocked for triage).
    #   2. Blocked task status (`@blocked_task_statuses`).
    #   3. PR terminal state (`run.pr_state`) for non-terminal tasks:
    #      merged → done, closed/reset → blocked. Catches stale
    #      task.status="in-progress" when GitHub already merged the PR.
    #   4. Post-PR fallback: broader `@done_task_statuses`
    #      (closed / pr_created — reset is intentionally NOT here)
    #      `task.close` was emitted (real close via the PrMonitor
    #      `:closed` handler, which also emits `task.close`).
    #   5. Active run + non-terminal task → in_progress (RUNNING).
    #   6. Non-terminal active task status → in_progress (RECENT).
    #   7. Ready/approved → ready.
    #   8. Default → backlog.
    # Phase (developer/qa/reviewer/...) is NEVER used to decide the
    # column; it is rendered as a separate `current_phase` field.
    {in_progress_tasks, blocked_tasks, done_tasks, backlog_tasks, ready_tasks} =
      Enum.reduce(tasks, {[], [], [], [], []}, fn task, acc ->
        {in_prog, blocked, done, backlog, ready} = acc
        task_id = Map.get(task, :task_id)
        status = Map.get(task, :status, "backlog") |> String.downcase() |> String.trim()
        run = Map.get(run_by_task, task_id)

        run_status =
          if run, do: Map.get(run, :status, "") |> String.downcase() |> String.trim(), else: ""

        pr_state = if run, do: Map.get(run, :pr_state, ""), else: ""
        pr_override = ForemanServer.BoardItemStateMachine.pr_state_to_board_status(pr_state)

        active_run = run && MapSet.member?(@active_run_statuses, run_status)

        cond do
          # Pre-PR override: only operator-confirmed done states
          # (merged/completed/done) win over PR state. `closed` /
          # `reset` / `pr_created` are NOT here — those can be set
          # without an actual merge (abandoned PR, re-target reset)
          # and would incorrectly turn genuinely closed-PR tasks
          # into done. They fall through to PR state + the post-PR
          # fallback below.
          MapSet.member?(@authoritative_done_task_statuses, status) ->
            {in_prog, blocked, [{task, run, "RECENT"} | done], backlog, ready}

          MapSet.member?(@blocked_task_statuses, status) ->
            {in_prog, [{task, run, "RECENT"} | blocked], done, backlog, ready}
          # Post-PR fallback: broader @done_task_statuses (closed /
          # pr_created; reset is intentionally NOT here — operator
          # resets stay in blocked so the run can be triaged). This
          # sits BEFORE the pr_override="blocked" arm so a real close
          # (PrMonitor `:closed` handler emits both `run.pr.reset` AND
          # `task.close` → `task.status="closed"`) routes to Done via
          # `task.status`, not via `pr_state="closed"` which would
          # otherwise go to blocked.
          MapSet.member?(@done_task_statuses, status) ->
            {in_prog, blocked, [{task, run, "RECENT"} | done], backlog, ready}

          pr_override == "done" ->
            {in_prog, blocked, [{task, run, "RECENT"} | done], backlog, ready}

          pr_override == "blocked" ->
            {in_prog, [{task, run, "RECENT"} | blocked], done, backlog, ready}

          active_run ->
            {[{task, run, "RUNNING"} | in_prog], blocked, done, backlog, ready}

          MapSet.member?(@active_task_statuses, status) ->
            {[{task, run, "RECENT"} | in_prog], blocked, done, backlog, ready}

          status in ["ready", "approved"] ->
            {in_prog, blocked, done, backlog, [{task, run, "RECENT"} | ready]}

          true ->
            {in_prog, blocked, done, [{task, run, "RECENT"} | backlog], ready}
        end
      end)

    %{
      in_progress: Enum.reverse(in_progress_tasks),
      blocked: Enum.reverse(blocked_tasks),
      done: Enum.reverse(done_tasks),
      backlog: Enum.reverse(backlog_tasks),
      ready: Enum.reverse(ready_tasks)
    }
  end

  defp build_board(projection, project_id) do
    # Filter tasks by project
    tasks =
      projection.tasks
      |> Map.values()
      |> Enum.filter(fn task ->
        Map.get(task, :project_id) == project_id
      end)

    task_ids = MapSet.new(Enum.map(tasks, & &1.task_id))

    # Filter runs to those belonging to project's tasks
    runs =
      projection.runs
      |> Map.values()
      |> Enum.filter(fn run ->
        task_id = Map.get(run, :task_id)
        MapSet.member?(task_ids, task_id)
      end)
      |> Enum.sort_by(&{Map.get(&1, :task_id), Map.get(&1, :run_id)})

    # Build task_id -> active run mapping
    run_by_task =
      Enum.reduce(runs, %{}, fn run, acc ->
        task_id = Map.get(run, :task_id)
        # Prefer the most recently updated run for each task
        case Map.get(acc, task_id) do
          nil ->
            Map.put(acc, task_id, run)

          existing ->
            existing_updated = Map.get(existing, :updated_at, "") || ""
            run_updated = Map.get(run, :updated_at, "") || ""

            if run_updated > existing_updated,
              do: Map.put(acc, task_id, run),
              else: acc
        end
      end)

    # Group tasks. Precedence (the Query-side state machine):
    #   1. Task terminal status (operator's intent, set via
    #      `task.update` / `task.close` / `task.approve`). When the
    #      operator marks a task merged/closed/etc., that is the
    #      authoritative outcome — even if a later run's pr_state
    #      disagrees (re-target, follow-up branch). PR state is a
    #      mirror of GitHub, not a source of truth. A narrower set
    #      (`@authoritative_done_task_statuses` = merged / completed /
    #      done) is checked first; the broader `@done_task_statuses`
    #      (closed / reset / pr_created) is the post-PR fallback for
    #      tasks with no PR override.
    #   2. Blocked task status (`@blocked_task_statuses`).
    #   3. PR terminal state (`run.pr_state`) for non-terminal tasks —
    #      merged → done, closed/reset → blocked. This catches the
    #      case where task.status is stale (still `in-progress`)
    #      but GitHub already merged the PR.
    #   4. Post-PR fallback: broader `@done_task_statuses` for tasks
    #      with no PR override (closed / reset / pr_created → done).
    #   5. Active run + non-terminal task → in_progress (RUNNING).
    #   6. Non-terminal active task status → in_progress (RECENT).
    #   7. Ready/approved → ready.
    #   8. Default → backlog.
    # Phase (developer/qa/reviewer/...) is NEVER used to decide the
    # column; it is rendered as a separate `current_phase` field.
    {in_progress_tasks, blocked_tasks, done_tasks, backlog_tasks, ready_tasks} =
      Enum.reduce(tasks, {[], [], [], [], []}, fn task, acc ->
        {in_prog, blocked, done, backlog, ready} = acc
        task_id = Map.get(task, :task_id)
        status = Map.get(task, :status, "backlog") |> String.downcase() |> String.trim()
        run = Map.get(run_by_task, task_id)

        run_status =
          if run, do: Map.get(run, :status, "") |> String.downcase() |> String.trim(), else: ""

        pr_state = if run, do: Map.get(run, :pr_state, ""), else: ""
        pr_override = ForemanServer.BoardItemStateMachine.pr_state_to_board_status(pr_state)

        active_run = run && MapSet.member?(@active_run_statuses, run_status)

        cond do
          # Pre-PR override: only operator-confirmed done states
          # (merged/completed/done) win over PR state. `closed` /
          # `reset` / `pr_created` are NOT here — those can be set
          # without an actual merge (abandoned PR, re-target reset)
          # and would incorrectly turn genuinely closed-PR tasks
          # into done. They fall through to PR state + the post-PR
          # fallback below.
          MapSet.member?(@authoritative_done_task_statuses, status) ->
            {in_prog, blocked, [{task, run, "RECENT"} | done], backlog, ready}

          MapSet.member?(@blocked_task_statuses, status) ->
            {in_prog, [{task, run, "RECENT"} | blocked], done, backlog, ready}
          # Post-PR fallback: broader @done_task_statuses (closed /
          # pr_created; reset is intentionally NOT here — operator
          # resets stay in blocked so the run can be triaged). This
          # sits BEFORE the pr_override="blocked" arm so a real
          # close (PrMonitor emits both run.pr.reset AND task.close →
          # task.status="closed") routes to Done via task.status,
          # not via pr_state="closed" which would otherwise go to
          # blocked.
          MapSet.member?(@done_task_statuses, status) ->
            {in_prog, blocked, [{task, run, "RECENT"} | done], backlog, ready}

          pr_override == "done" ->
            {in_prog, blocked, [{task, run, "RECENT"} | done], backlog, ready}

          pr_override == "blocked" ->
            {in_prog, [{task, run, "RECENT"} | blocked], done, backlog, ready}
          active_run ->
            {[{task, run, "RUNNING"} | in_prog], blocked, done, backlog, ready}
          MapSet.member?(@active_task_statuses, status) ->
            {[{task, run, "RECENT"} | in_prog], blocked, done, backlog, ready}

          status in ["ready", "approved"] ->
            {in_prog, blocked, done, backlog, [{task, run, "RECENT"} | ready]}

          true ->
            {in_prog, blocked, done, [{task, run, "RECENT"} | backlog], ready}
        end
      end)

    %{
      in_progress: Enum.reverse(in_progress_tasks),
      blocked: Enum.reverse(blocked_tasks),
      done: Enum.reverse(done_tasks),
      backlog: Enum.reverse(backlog_tasks),
      ready: Enum.reverse(ready_tasks)
    }
  end

  defp normalize_board_output(board) do
    sm = ForemanServer.BoardItemStateMachine

    # `transform` receives the column atom so the visible_status fallback
    # can use the column as the source of truth at render time. Without
    # this, an unknown task.status already bucketed into `done` (via PR
    # override) or `blocked` would fall back to `in-progress`/`backlog`
    # from the group, mislabeling the rendered item.
    transform = fn
      col, {task, nil, group} ->
        task_status = normalized_task_status(task)

        visible_status =
          sm.task_status_to_board_status(task_status) || column_to_lifecycle(col)

        task
        |> Map.take([:task_id, :title, :priority, :task_type, :updated_at])
        |> Map.merge(%{group: group, type: "task", status: visible_status})

      col, {task, run, group} ->
        run_status = Map.get(run, :status, "")

        run_attention =
          case {Map.get(run, :failure_reason, ""), Map.get(run, :attention, "")} do
            {fr, _} when fr != "" -> fr
            {"", att} -> att
            _ -> ""
          end

        task_status = normalized_task_status(task)

        # Precedence (mirrors `build_board/2` and `build_board_from_maps/3`):
        #   1. Operator-confirmed done status (merged/completed/done)
        #      wins over PR state. So `task.status="merged"` renders
        #      `done` even if a later re-target closed the PR.
        #   2. Blocked task status (failed/blocked/etc.) wins.
        #   3. PR terminal state (run.pr_state) for non-terminal tasks.
        #   4. task.status via the state machine.
        #   5. Column: the item is already bucketed correctly by
        #      `build_board/2`/`build_board_from_maps/3`; if the state
        #      machine cannot map the status, use the column as the
        #      lifecycle truth.
        # Phase names (developer/qa/reviewer/...) are NEVER used as a
        # visible status — they belong to a run, not a task.
        pr_state = Map.get(run, :pr_state, "")
        pr_override = sm.pr_state_to_board_status(pr_state)
        task_mapped = sm.task_status_to_board_status(task_status)

        authoritative_done =
          MapSet.member?(@authoritative_done_task_statuses, task_status)

        authoritative_blocked =
          MapSet.member?(@blocked_task_statuses, task_status)

        # Post-PR fallback (`@done_task_statuses` for non-authoritative
        # statuses like `closed`/`reset`/`pr_created`) is already covered
        # by `task_mapped` below: the state machine maps those to `done`.
        # (Reset is intentionally excluded — see
        # `task_status_to_board_status/1`.)
        # User directive: closed task.status is a terminal state and
        # must render `done` even when the run's pr_state is `closed`
        # (which the state machine maps to `blocked`). The operator-done
        # precedence wins: a real close via PrMonitor emits both
        # `run.pr.reset` AND `task.close`, so `task.status` ends up
        # `"closed"`. An operator reset does NOT emit `task.close`,
        # so its `task.status` keeps a pre-reset value (often `failed`)
        # and `authoritative_blocked` above or `pr_override` below
        # routes it to `blocked`.
        task_done =
          MapSet.member?(@done_task_statuses, task_status)

        visible_status =
          cond do
            authoritative_done -> "done"
            authoritative_blocked -> "blocked"
            task_done -> "done"
            pr_override -> pr_override
            task_mapped -> task_mapped
            true -> column_to_lifecycle(col)
          end

        # Needs attention: failed run status OR explicit attention flag,
        # unless the visible status is already terminal (`done` or
        # `blocked` per user directive: "merged or blocked isn't Needs
        # Attention"). Attention still fires for genuinely failing
        # active runs (`in_progress` lifecycle state).
        needs_attention =
          visible_status not in ["done", "blocked"] and
            (run_status in ["failed", "fail", "stuck", "conflict", "test-failed"] ||
               run_attention != "")
        base =
          task
          |> Map.take([:task_id, :title, :priority, :task_type, :updated_at])
          |> Map.merge(%{
            group: group,
            type: if(needs_attention, do: "attention", else: "run"),
            status: visible_status,
            run_id: Map.get(run, :run_id),
            current_phase: Map.get(run, :current_phase),
            pr_state: pr_state
          })

        if run_attention != "",
          do: Map.put(base, :attention, run_attention),
          else: base
    end

    columns =
      [:backlog, :ready, :in_progress, :blocked, :done]
      |> Enum.map(fn col ->
        items =
          (board[col] || [])
          |> Enum.map(fn item -> transform.(col, item) end)
          |> Enum.sort_by(&{Map.get(&1, :group) == "RUNNING", Map.get(&1, :updated_at)}, :desc)

        {col, items}
      end)
      |> Map.new()

    counts =
      columns
      |> Enum.map(fn {col, items} -> {col, length(items)} end)
      |> Map.new()

    Map.merge(columns, %{counts: counts})
  end

  defp normalized_task_status(task) do
    task
    |> Map.get(:status, "")
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  # terminal_task_status?/1 was removed — the state machine in
  # `BoardItemStateMachine` is now the source of truth for whether
  # a status is terminal.

  # Translate the API column atom (`:in_progress`) back to the
  # lifecycle form (`"in-progress"`) for the safe fallback in
  # `normalize_board_output/1`. Other column atoms are already in
  # lifecycle form.
  defp column_to_lifecycle(:in_progress), do: "in-progress"
  defp column_to_lifecycle(other) when is_atom(other), do: Atom.to_string(other)
  defp column_to_lifecycle(other) when is_binary(other), do: other
end
