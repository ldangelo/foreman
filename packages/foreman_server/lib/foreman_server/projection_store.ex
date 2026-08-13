defmodule ForemanServer.ProjectionStore do
  @moduledoc """
  In-memory projection read model for domain queries.

  Maintains projected state for projects, runs, and PR associations
  by applying confirmed events synchronously after each successful
  append.

  ## Startup

  On `init/1`, rebuilds the entire read model by replaying all events from the
  event log via `read_all_streams_forward`. This ensures the projection is always
  consistent with the event store at startup.

  ## Command path

  After `CommandRouter.append_events` succeeds, it calls
  `ProjectionStore.apply_events(events)` before sending `append_ok` to the actor.
  This keeps the projection synchronous with the command path — no eventual consistency.

  ## Query

  `project/1` returns the projected state for a given project_id.
  `run/1` returns the projected state for a given run_id.
  `pr_association/1` returns the current PR association for a given run_id.
  """

  use GenServer

  alias EventStore.{EventData, RecordedEvent}
  alias ForemanServer.{EventCodec, EventStore}

  @active_run_statuses ["in_progress"]

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc "Return the projected state for a project, or nil if not found."
  @spec project(String.t()) :: map() | nil
  def project(project_id) do
    GenServer.call(__MODULE__, {:project, project_id})
  end

  @doc "Return the active run ids."
  @spec active_runs() :: [String.t()]
  def active_runs do
    GenServer.call(__MODULE__, :active_runs)
  end

  @doc "Return active runs whose last activity is older than the threshold."
  @spec stuck_runs(non_neg_integer(), integer() | nil) :: [String.t()]
  def stuck_runs(threshold_ms, now_ms \\ nil)
      when is_integer(threshold_ms) and threshold_ms >= 0 do
    GenServer.call(__MODULE__, {:stuck_runs, threshold_ms, normalize_now_ms_fun(now_ms)})
  end

  @doc """
  Apply a list of confirmed events to the projection.

  Called by CommandRouter after a successful append, before replying to the actor.
  """
  @spec apply_events([EventData.t() | RecordedEvent.t() | map()]) :: :ok
  def apply_events(events) do
    GenServer.call(__MODULE__, {:apply_events, events, resolve_now_ms_fun()})
  end

  @doc """
  Rebuild the entire projection from the committed event log.

  Leaves the current projection state untouched if the rebuild read fails.
  """
  @spec rebuild([EventData.t() | RecordedEvent.t() | map()]) :: :ok | {:error, term()}
  def rebuild(recovered_events) when is_list(recovered_events) do
    GenServer.call(__MODULE__, {:rebuild, recovered_events, resolve_now_ms_fun()})
  end

  @doc """
  Rebuild one project's projection from its committed aggregate stream.

  Leaves the current projection state untouched if the stream read fails.
  """
  @spec rebuild_project(String.t(), [EventData.t() | RecordedEvent.t() | map()]) ::
          :ok | {:error, term()}
  def rebuild_project(project_id, recovered_events)
      when is_binary(project_id) and project_id != "" and is_list(recovered_events) do
    GenServer.call(
      __MODULE__,
      {:rebuild_project, project_id, recovered_events, resolve_now_ms_fun()}
    )
  end

  @spec subscribe() :: :ok
  def subscribe do
    GenServer.call(__MODULE__, :subscribe)
  end

  @doc "Return the projected state for a task, or nil if not found."
  @spec task_projection(String.t()) :: map() | nil
  def task_projection(task_id) when is_binary(task_id) and task_id != "" do
    GenServer.call(__MODULE__, {:task_projection, task_id})
  end

  @doc """
  Return the projected task that owns the given bead id (`:external_id`), or nil.

  Used by the Beads watcher dedupe path: before dispatching
  `task.create`, the watcher looks up the existing task by its
  `external_id` to decide between `[:watcher, :reconciled]`
  (already imported) and `[:watcher, :imported]` (new).
  """
  @spec get_task(keyword()) :: map() | nil
  def get_task(opts) when is_list(opts) do
    case opts do
      [external_id: external_id] when is_binary(external_id) and external_id != "" ->
        GenServer.call(__MODULE__, {:get_task_by_external_id, external_id})

      _ ->
        raise ArgumentError,
              "ProjectionStore.get_task/1 expects [external_id: binary]; got #{inspect(opts)}"
    end
  end

  @doc """
  Return every task projection that is currently bound to `run_id`.

  Used by the run-cancellation fanout path so the dispatcher can
  emit a `task.run_terminated` for each affected task. Tasks whose
  previous run already had a terminal acknowledgement are filtered
  out — the operator path is idempotent and a stale re-fire MUST NOT
  rewrite `acknowledged_run_id` against the same run twice.
  """
  @spec tasks_by_run_id(String.t()) :: [map()]
  def tasks_by_run_id(run_id) when is_binary(run_id) and run_id != "" do
    GenServer.call(__MODULE__, {:tasks_by_run_id, run_id})
  end

  @doc "Return every projected task. Used by boot reconciliation to scan run orphans."
  @spec list_tasks() :: [map()]
  def list_tasks do
    GenServer.call(__MODULE__, :list_tasks)
  end

  @doc "Return the projected state for a run, or nil if not found."
  @spec run(String.t()) :: map() | nil
  def run(run_id) when is_binary(run_id) and run_id != "" do
    GenServer.call(__MODULE__, {:run, run_id})
  end

  @doc "Return the projected state for a phase, or nil if not found."
  @spec phase_projection(String.t()) :: map() | nil
  def phase_projection(phase_id) when is_binary(phase_id) and phase_id != "" do
    GenServer.call(__MODULE__, {:phase_projection, phase_id})
  end

  @doc "Return the ordered phase projections for a run."
  @spec phases_for_run(String.t()) :: [map()]
  def phases_for_run(run_id) when is_binary(run_id) and run_id != "" do
    GenServer.call(__MODULE__, {:phases_for_run, run_id})
  end

  @doc "Return workflow-eligible tasks (`ready` and `in_progress`) for dispatcher reconciliation."
  @spec list_workflow_tasks() :: [map()]
  def list_workflow_tasks do
    GenServer.call(__MODULE__, :list_workflow_tasks)
  end

  @doc "Return the PR association for a run_id, or :not_found."
  @spec pr_association(String.t()) :: {:ok, map()} | {:error, :not_found}
  def pr_association(run_id) when is_binary(run_id) do
    GenServer.call(__MODULE__, {:pr_association, run_id})
  end

  @doc "Return the projected state for a project, or nil if not found."
  @spec project_projection(String.t()) :: map() | nil
  def project_projection(project_id) when is_binary(project_id) do
    GenServer.call(__MODULE__, {:project_projection, project_id})
  end

  @doc "Return every projected project."
  @spec list_projects() :: [map()]
  def list_projects do
    GenServer.call(__MODULE__, :list_projects)
  end

  @doc "Return projects with reserved active run ids for reconciler enumeration only."
  @spec list_projects_with_active_runs() :: [{String.t(), [String.t()]}]
  def list_projects_with_active_runs do
    GenServer.call(__MODULE__, :list_projects_with_active_runs)
  end

  @doc "Return every projected run."
  @spec list_runs() :: [map()]
  def list_runs do
    GenServer.call(__MODULE__, :list_runs)
  end

  @doc "Return every projected scheduler intent."
  @spec list_scheduler_intents() :: [map()]
  def list_scheduler_intents do
    GenServer.call(__MODULE__, :list_scheduler_intents)
  end

  @doc """
  Return the projected worktree for an `operation_id` (the deterministic
  correlation id `"wt-<run_id>-<phase_id>"`), or nil if not found.
  """
  @spec worktree(String.t()) :: map() | nil
  def worktree(operation_id) when is_binary(operation_id) do
    GenServer.call(__MODULE__, {:worktree, operation_id})
  end

  @doc """
  Return every projected worktree for a given run, sorted by operation_id.
  """
  @spec worktrees_for_run(String.t()) :: [map()]
  def worktrees_for_run(run_id) when is_binary(run_id) do
    GenServer.call(__MODULE__, {:worktrees_for_run, run_id})
  end

  @doc """
  Return the projected worktree for a given `(project_id, run_id, phase_id)`
  tuple, or nil if not found. Mirrors the deterministic `operation_id`
  derivation used by the worktree aggregate.
  """
  @spec worktree_for_phase(String.t(), String.t(), String.t()) :: map() | nil
  def worktree_for_phase(project_id, run_id, phase_id)
      when is_binary(project_id) and is_binary(run_id) and is_binary(phase_id) do
    operation_id = "wt-" <> run_id <> "-" <> phase_id
    GenServer.call(__MODULE__, {:worktree, operation_id})
  end

  @doc """
  Return every projected worktree whose final status is `"created"` —
  i.e. a `WorktreeCreated` event was replayed but no matching
  `WorktreeCleaned` event followed. BootReconciliation uses this
  list to drive cleanup of orphans after a restart.
  """
  @spec list_unresolved_worktrees() :: [map()]
  def list_unresolved_worktrees do
    GenServer.call(__MODULE__, :list_unresolved_worktrees)
  end

  @doc """
  Return the projected worktree create orphan for an `operation_id`, or
  nil if not found. BootReconciliation surfaces these for operator
  recovery when in-process compensation failed.
  """
  @spec worktree_create_orphan(String.t()) :: map() | nil
  def worktree_create_orphan(operation_id) when is_binary(operation_id) do
    GenServer.call(__MODULE__, {:worktree_create_orphan, operation_id})
  end

  @doc """
  Return every projected worktree create orphan, sorted by operation_id.
  Used by `BootReconciliation` to surface durables whose create
  compensation failed.
  """
  @spec list_worktree_create_orphans() :: [map()]
  def list_worktree_create_orphans do
    GenServer.call(__MODULE__, :list_worktree_create_orphans)
  end

  # -------------------------------------------------------------------------

  @impl true
  def init(init_arg) do
    {:ok, rebuild_from_event_log(init_now_ms_fun(init_arg))}
  end

  @impl true
  def handle_call({:project, project_id}, _from, state) do
    {:reply, Map.get(state.projects, project_id), state}
  end

  @impl true
  def handle_call({:run, run_id}, _from, state) do
    {:reply, Map.get(state.runs, run_id), state}
  end

  @impl true
  def handle_call(:active_runs, _from, state) do
    {:reply, active_run_ids(state), state}
  end

  @impl true
  def handle_call({:stuck_runs, threshold_ms, now_ms_fun}, _from, state) do
    now_ms = now_ms_fun.()

    reply =
      state
      |> active_run_ids()
      |> Enum.filter(fn run_id ->
        case Map.get(state.runs, run_id) do
          %{last_event_at_ms: last_event_at_ms} when is_integer(last_event_at_ms) ->
            last_event_at_ms + threshold_ms <= now_ms

          _ ->
            false
        end
      end)

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:apply_events, events, now_ms_fun}, _from, state) do
    new_state =
      Enum.reduce(events, state, fn event, acc -> apply_event(acc, event, now_ms_fun) end)

    new_state = broadcast_events(new_state, events)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:rebuild, recovered_events, now_ms_fun}, _from, state) do
    case rebuild_state_from_event_log(now_ms_fun) do
      {:ok, rebuilt_state} ->
        new_state =
          rebuilt_state
          |> Map.put(:subscribers, state.subscribers)
          |> broadcast_events(recovered_events)

        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(
        {:rebuild_project, project_id, recovered_events, now_ms_fun},
        _from,
        state
      ) do
    case rebuild_project_state(project_id, now_ms_fun) do
      {:ok, rebuilt_project_state} ->
        projects =
          replace_project_entry(
            state.projects,
            rebuilt_project_state.projects,
            project_id
          )

        project_active_runs =
          replace_project_entry(
            state.project_active_runs,
            rebuilt_project_state.project_active_runs,
            project_id
          )

        new_state =
          state
          |> Map.put(:projects, projects)
          |> Map.put(:project_active_runs, project_active_runs)
          |> broadcast_events(recovered_events)

        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:subscribe, {pid, _ref}, state) do
    Process.put(:projection_subscribers, Map.put(state.subscribers, pid, true))
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, pid, true)}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  defp broadcast_events(state, events) do
    for event <- events,
        pid <- Map.keys(state.subscribers) do
      send(pid, {:projection_event, event})
    end

    state
  end

  @impl true
  def handle_call({:pr_association, run_id}, _from, state) do
    case Map.get(state.pr_associations, run_id) do
      nil -> {:reply, {:error, :not_found}, state}
      assoc -> {:reply, {:ok, assoc}, state}
    end
  end

  @impl true
  def handle_call({:project_projection, project_id}, _from, state) do
    {:reply, Map.get(state.projects, project_id), state}
  end

  @impl true
  def handle_call(:list_projects, _from, state) do
    {:reply, Map.values(state.projects), state}
  end

  @impl true
  def handle_call(:list_projects_with_active_runs, _from, state) do
    reply =
      state
      |> Map.get(:project_active_runs, %{})
      |> Enum.reduce([], fn
        {project_id, run_ids}, acc when is_binary(project_id) and run_ids != [] ->
          [{project_id, Enum.sort(run_ids)} | acc]

        _, acc ->
          acc
      end)
      |> Enum.sort_by(fn {project_id, _run_ids} -> project_id end)

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:list_runs, _from, state) do
    {:reply, Map.values(state.runs), state}
  end

  @impl true
  def handle_call({:get_task_by_external_id, external_id}, _from, state) do
    task =
      Enum.find_value(state.tasks, fn {_task_id, task} ->
        if get(task, :external_id) == external_id, do: task, else: nil
      end)

    {:reply, task, state}
  end

  @impl true
  def handle_call({:task_projection, task_id}, _from, state) do
    {:reply, Map.get(state.tasks, task_id), state}
  end

  @impl true
  def handle_call({:tasks_by_run_id, run_id}, _from, state) do
    tasks =
      state.tasks
      |> Map.values()
      |> Enum.filter(fn task ->
        get(task, :run_id) == run_id and
          get(task, :acknowledged_run_id) != run_id
      end)
      |> Enum.sort_by(fn task -> get(task, :task_id, "") end)

    {:reply, tasks, state}
  end

  @impl true
  def handle_call(:list_tasks, _from, state) do
    tasks =
      state.tasks
      |> Map.values()
      |> Enum.sort_by(fn task -> get(task, :task_id, "") end)

    {:reply, tasks, state}
  end

  @impl true
  def handle_call({:phase_projection, phase_id}, _from, state) do
    {:reply, Map.get(state.phases, phase_id), state}
  end

  @impl true
  def handle_call({:phases_for_run, run_id}, _from, state) do
    phases =
      state.phases
      |> Map.values()
      |> Enum.filter(fn phase -> get(phase, :run_id) == run_id end)
      |> Enum.sort_by(fn phase -> get(phase, :index, 0) end)

    {:reply, phases, state}
  end

  @impl true
  def handle_call(:list_workflow_tasks, _from, state) do
    tasks =
      state.tasks
      |> Map.values()
      |> Enum.filter(fn task -> get(task, :status) in ["ready", "in_progress"] end)
      |> Enum.sort_by(fn task -> get(task, :task_id, "") end)

    {:reply, tasks, state}
  end

  @impl true
  def handle_call(:list_scheduler_intents, _from, state) do
    {:reply, Map.values(state.scheduler_intents), state}
  end

  @impl true
  def handle_call({:worktree, operation_id}, _from, state) do
    {:reply, Map.get(state.worktrees, operation_id), state}
  end

  @impl true
  def handle_call({:worktrees_for_run, run_id}, _from, state) do
    worktrees =
      state.worktrees
      |> Map.values()
      |> Enum.filter(fn wt -> get(wt, :run_id) == run_id end)
      |> Enum.sort_by(fn wt -> get(wt, :operation_id, "") end)

    {:reply, worktrees, state}
  end

  @impl true
  def handle_call(:list_unresolved_worktrees, _from, state) do
    unresolved =
      state.worktrees
      |> Map.values()
      |> Enum.filter(fn wt -> get(wt, :status) == "created" end)
      |> Enum.sort_by(fn wt -> get(wt, :operation_id, "") end)

    {:reply, unresolved, state}
  end

  @impl true
  def handle_call({:worktree_create_orphan, operation_id}, _from, state) do
    {:reply, Map.get(state.worktree_create_orphans, operation_id), state}
  end

  @impl true
  def handle_call(:list_worktree_create_orphans, _from, state) do
    orphans =
      state.worktree_create_orphans
      |> Map.values()
      |> Enum.sort_by(fn wt -> get(wt, :operation_id, "") end)

    {:reply, orphans, state}
  end

  # -------------------------------------------------------------------------
  # Projection logic
  # -------------------------------------------------------------------------

  defp rebuild_from_event_log(now_ms_fun) when is_function(now_ms_fun, 0) do
    case rebuild_state_from_event_log(now_ms_fun) do
      {:ok, rebuilt_state} -> rebuilt_state
      {:error, _reason} -> initial_state()
    end
  end

  defp rebuild_state_from_event_log(now_ms_fun) when is_function(now_ms_fun, 0) do
    case EventStore.read_all_streams_forward(0, 99_999_999) do
      {:ok, events} ->
        {:ok,
         Enum.reduce(events, initial_state(), fn event, acc ->
           apply_event(acc, event, now_ms_fun)
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rebuild_project_state(project_id, now_ms_fun)
       when is_binary(project_id) and is_function(now_ms_fun, 0) do
    case EventStore.read_stream_forward("project:#{project_id}", 0, 99_999_999) do
      {:ok, events} ->
        {:ok,
         Enum.reduce(events, initial_state(), fn event, acc ->
           apply_event(acc, event, now_ms_fun)
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replace_project_entry(current, rebuilt, project_id) do
    case Map.fetch(rebuilt, project_id) do
      {:ok, value} -> Map.put(current, project_id, value)
      :error -> Map.delete(current, project_id)
    end
  end

  defp initial_state do
    %{
      projects: %{},
      runs: %{},
      tasks: %{},
      phases: %{},
      pr_associations: %{},
      scheduler_intents: %{},
      subscribers: %{},
      project_active_runs: %{},
      worktrees: %{},
      worktree_create_orphans: %{}
    }
  end

  defp apply_event(state, %RecordedEvent{} = recorded, now_ms_fun) do
    payload =
      recorded.data
      |> to_payload_map()
      |> with_recorded_projection_metadata(recorded, now_ms_fun)

    apply_event_by_type(state, recorded.event_type, payload)
  end

  defp apply_event(state, %EventData{} = event_data, now_ms_fun) do
    payload =
      event_data.data
      |> to_payload_map()
      |> with_event_at_ms(now_ms_fun.())

    apply_event_by_type(state, event_data.event_type, payload)
  end

  defp apply_event(state, %{event_type: type, payload: payload}, now_ms_fun) do
    apply_event_by_type(
      state,
      type,
      payload |> to_payload_map() |> with_event_at_ms(now_ms_fun.())
    )
  end

  defp apply_event(state, event, now_ms_fun) when is_map(event) do
    type = Map.get(event, :event_type) || Map.get(event, "event_type")

    payload =
      Map.get(event, :data) ||
        Map.get(event, "data") ||
        Map.get(event, :payload) ||
        Map.get(event, "payload") ||
        event

    apply_event_by_type(
      state,
      type,
      payload |> to_payload_map() |> with_event_at_ms(now_ms_fun.())
    )
  end

  defp apply_event_by_type(state, "ProjectRegistered", payload) do
    project_id = get(payload, :project_id)
    path = get(payload, :path)

    if valid_id?(project_id) do
      put_state(
        state,
        Map.put(state.projects, project_id, project_projection(payload, path)),
        state.runs
      )
    else
      state
    end
  end

  defp apply_event_by_type(state, "ProjectUpdated", payload) do
    project_id = get(payload, :project_id)

    if valid_id?(project_id) do
      project =
        state.projects
        |> Map.get(project_id, project_projection(payload, nil))
        |> maybe_put(:path, get(payload, :path))
        |> maybe_put(:status, get(payload, :status))
        |> maybe_put(:default_branch, get(payload, :default_branch))
        |> maybe_put(:health, get(payload, :health))
        |> maybe_put(:name, get(payload, :name))
        |> maybe_put(:task_provider, get(payload, :task_provider))
        |> put_project_config(get(payload, :config, %{}))
        |> put_project_projection_metadata(payload)

      put_state(state, Map.put(state.projects, project_id, project), state.runs)
    else
      state
    end
  end

  defp apply_event_by_type(state, "ProjectArchived", payload) do
    project_id = get(payload, :project_id)

    if valid_id?(project_id) do
      project =
        state.projects
        |> Map.get(project_id, %{status: "archived", archived?: true})
        |> Map.put(:status, "archived")
        |> Map.put(:archived?, true)
        |> put_project_projection_metadata(payload)

      put_state(state, Map.put(state.projects, project_id, project), state.runs)
    else
      state
    end
  end

  defp apply_event_by_type(state, "ProjectReactivated", payload) do
    project_id = get(payload, :project_id)

    if valid_id?(project_id) do
      project =
        state.projects
        |> Map.get(project_id, %{status: "active", archived?: false})
        |> Map.put(:status, "active")
        |> Map.put(:archived?, false)
        |> put_project_projection_metadata(payload)

      put_state(state, Map.put(state.projects, project_id, project), state.runs)
    else
      state
    end
  end

  defp apply_event_by_type(state, "ProjectRunReserved", payload) do
    project_id = get(payload, :project_id)
    run_id = get(payload, :run_id)

    if valid_id?(project_id) and valid_id?(run_id) do
      active_runs =
        state
        |> Map.get(:project_active_runs, %{})
        |> Map.update(project_id, [run_id], &add_project_run_id(&1, run_id))

      Map.put(state, :project_active_runs, active_runs)
    else
      state
    end
  end

  defp apply_event_by_type(state, "ProjectRunReservationReleased", payload) do
    project_id = get(payload, :project_id)
    run_id = get(payload, :run_id)

    if valid_id?(project_id) and valid_id?(run_id) do
      active_runs =
        state
        |> Map.get(:project_active_runs, %{})
        |> remove_project_run_id(project_id, run_id)

      Map.put(state, :project_active_runs, active_runs)
    else
      state
    end
  end

  defp apply_event_by_type(state, "RunStarted", payload) do
    case decode_for_projection("RunStarted", payload) do
      %ForemanServer.Events.RunStarted{run_id: run_id} = event ->
        if valid_id?(run_id) do
          event_at_ms = payload_event_at_ms(payload)

          run = %{
            run_id: run_id,
            task_id: event.task_id,
            project_id: event.project_id,
            workflow_name: event.workflow_name,
            workflow_digest: event.workflow_digest,
            workflow_snapshot: event.workflow_snapshot,
            phase_ids: [],
            last_sequence: event.sequence,
            status: "in_progress",
            terminal?: false,
            started_at_ms: event_at_ms,
            last_event_at_ms: event_at_ms,
            failure_reason: nil
          }

          put_state(state, state.projects, Map.put(state.runs, run_id, run))
        else
          state
        end
    end
  end

  defp apply_event_by_type(state, "RunUpdated", payload) do
    update_run_projection(state, get(payload, :run_id), payload_event_at_ms(payload), fn run ->
      maybe_put(run, :task_id, get(payload, :task_id))
    end)
  end

  defp apply_event_by_type(state, "RunCompleted", payload) do
    apply_terminal_run_event(state, payload, "completed")
  end

  defp apply_event_by_type(state, "RunFailed", payload) do
    apply_terminal_run_event(state, payload, "failed")
  end

  defp apply_event_by_type(state, "RunBlocked", payload) do
    apply_terminal_run_event(state, payload, "blocked")
  end

  defp apply_event_by_type(state, "RunDeleted", payload) do
    apply_terminal_run_event(state, payload, "deleted")
  end

  defp apply_event_by_type(state, "RunFlaggedStuck", payload) do
    apply_terminal_run_event(state, payload, "stuck")
  end

  defp apply_event_by_type(state, "RunCancelled", payload) do
    apply_terminal_run_event(state, payload, "cancelled")
  end

  defp apply_event_by_type(state, "PhaseStarted", payload) do
    case decode_for_projection("PhaseStarted", payload) do
      %ForemanServer.Events.PhaseStarted{phase_id: phase_id, run_id: run_id} = event
      when not is_nil(phase_id) and phase_id != "" and not is_nil(run_id) and run_id != "" ->
        phase = %{
          phase_id: phase_id,
          run_id: run_id,
          index: event.index,
          name: event.name,
          attempt: event.attempt,
          status: "in_progress",
          artifact_template: event.artifact_template,
          artifact: nil,
          failure_reason: nil,
          last_sequence: event.sequence,
          started_at_ms: payload_event_at_ms(payload),
          last_event_at_ms: payload_event_at_ms(payload)
        }

        state
        |> touch_run_for_payload(payload)
        |> Map.update!(:phases, &Map.put(&1, phase_id, phase))
        |> append_phase_id_to_run(run_id, phase_id)

      _ ->
        touch_run_for_payload(state, payload)
    end
  end

  defp append_phase_id_to_run(state, run_id, phase_id) do
    case Map.get(state.runs, run_id) do
      nil ->
        state

      run ->
        existing = Map.get(run, :phase_ids, [])

        if phase_id in existing do
          state
        else
          updated = %{run | phase_ids: existing ++ [phase_id]}
          %{state | runs: Map.put(state.runs, run_id, updated)}
        end
    end
  end

  defp apply_event_by_type(state, "PhaseCompleted", payload) do
    case decode_for_projection("PhaseCompleted", payload) do
      %ForemanServer.Events.PhaseCompleted{phase_id: phase_id} = event
      when not is_nil(phase_id) and phase_id != "" ->
        phase =
          state.phases
          |> Map.get(phase_id, %{})
          |> Map.put(:status, "completed")
          |> Map.put(:artifact, %{
            path: event.artifact_path,
            sha256: event.artifact_sha256,
            bytes: event.artifact_bytes
          })
          |> Map.put(:last_sequence, event.sequence)
          |> Map.put(:last_event_at_ms, payload_event_at_ms(payload))

        state
        |> touch_run_for_payload(payload)
        |> Map.update!(:phases, &Map.put(&1, phase_id, phase))

      _ ->
        touch_run_for_payload(state, payload)
    end
  end

  defp apply_event_by_type(state, "PhaseFailed", payload) do
    case decode_for_projection("PhaseFailed", payload) do
      %ForemanServer.Events.PhaseFailed{phase_id: phase_id} = event
      when not is_nil(phase_id) and phase_id != "" ->
        phase =
          state.phases
          |> Map.get(phase_id, %{})
          |> Map.put(:status, "failed")
          |> Map.put(:failure_reason, event.reason)
          |> Map.put(:last_sequence, event.sequence)
          |> Map.put(:last_event_at_ms, payload_event_at_ms(payload))

        state
        |> touch_run_for_payload(payload)
        |> Map.update!(:phases, &Map.put(&1, phase_id, phase))

      _ ->
        touch_run_for_payload(state, payload)
    end
  end

  defp apply_event_by_type(state, "PhaseTimedOut", payload) do
    touch_run_for_payload(state, payload)
  end

  defp apply_event_by_type(state, "PhaseRetried", payload) do
    touch_run_for_payload(state, payload)
  end

  defp apply_event_by_type(state, "TaskCreated", payload) do
    case decode_for_projection("TaskCreated", payload) do
      %ForemanServer.Events.TaskCreated{task_id: task_id} = event ->
        task = %{
          task_id: task_id,
          external_id: event.external_id,
          project_id: event.project_id,
          title: event.title,
          description: event.description,
          priority: event.priority,
          status: event.status,
          task_type: event.task_type,
          workflow_type: event.workflow_type,
          trd_path: event.trd_path,
          approval_id: nil,
          approved_by: nil,
          approved_at: nil,
          run_id: nil,
          workflow_snapshot: nil,
          failure_reason: nil,
          created_at_ms: payload_event_at_ms(payload),
          last_event_at_ms: payload_event_at_ms(payload)
        }

        %{state | tasks: Map.put(state.tasks, task_id, task)}
    end
  end

  defp apply_event_by_type(state, "TaskUpdated", payload) do
    case decode_for_projection("TaskUpdated", payload) do
      %ForemanServer.Events.TaskUpdated{task_id: task_id} = event ->
        task =
          state.tasks
          |> Map.get(task_id, %{})
          |> maybe_put(:status, event.status)
          |> maybe_put(:priority, event.priority)
          |> maybe_put(:title, event.title)
          |> maybe_put(:description, event.description)
          |> Map.put(:last_event_at_ms, payload_event_at_ms(payload))

        %{state | tasks: Map.put(state.tasks, task_id, task)}
    end
  end

  defp apply_event_by_type(state, "TaskApproved", payload) do
    case decode_for_projection("TaskApproved", payload) do
      %ForemanServer.Events.TaskApproved{task_id: task_id} = event ->
        task =
          state.tasks
          |> Map.get(task_id, %{})
          |> Map.put(:status, "ready")
          |> Map.put(:approval_id, event.approval_id)
          |> Map.put(:approved_by, event.approved_by)
          |> Map.put(:approved_at, event.approved_at)
          |> Map.put(:run_id, event.run_id)
          |> Map.put(:workflow_snapshot, event.workflow_snapshot)
          |> Map.put(:last_event_at_ms, payload_event_at_ms(payload))

        %{state | tasks: Map.put(state.tasks, task_id, task)}
    end
  end

  defp apply_event_by_type(state, "TaskDispatched", payload) do
    case decode_for_projection("TaskDispatched", payload) do
      %ForemanServer.Events.TaskDispatched{task_id: task_id} ->
        task =
          state.tasks
          |> Map.get(task_id, %{})
          |> Map.put(:status, "in_progress")
          |> Map.put(:last_event_at_ms, payload_event_at_ms(payload))

        %{state | tasks: Map.put(state.tasks, task_id, task)}
    end
  end

  defp apply_event_by_type(state, "TaskExecutionCompleted", payload) do
    case decode_for_projection("TaskExecutionCompleted", payload) do
      %ForemanServer.Events.TaskExecutionCompleted{task_id: task_id} ->
        task =
          state.tasks
          |> Map.get(task_id, %{})
          |> Map.put(:status, "closed")
          |> Map.put(:failure_reason, nil)
          |> Map.put(:last_event_at_ms, payload_event_at_ms(payload))

        %{state | tasks: Map.put(state.tasks, task_id, task)}
    end
  end

  defp apply_event_by_type(state, "TaskExecutionFailed", payload) do
    case decode_for_projection("TaskExecutionFailed", payload) do
      %ForemanServer.Events.TaskExecutionFailed{task_id: task_id} = event ->
        task =
          state.tasks
          |> Map.get(task_id, %{})
          |> Map.put(:status, "failed")
          |> Map.put(:failure_reason, event.reason)
          |> Map.put(:last_event_at_ms, payload_event_at_ms(payload))

        %{state | tasks: Map.put(state.tasks, task_id, task)}
    end
  end

  defp apply_event_by_type(state, "TaskRunTerminated", payload) do
    case decode_for_projection("TaskRunTerminated", payload) do
      %ForemanServer.Events.TaskRunTerminated{task_id: task_id, run_id: run_id} = event ->
        task =
          state.tasks
          |> Map.get(task_id, %{})
          |> Map.put(:acknowledged_run_id, run_id)
          |> Map.put(:run_terminal_reason, event.reason)
          |> Map.put(:run_terminal_at, event.acknowledged_at)
          |> Map.put(:last_event_at_ms, payload_event_at_ms(payload))

        %{state | tasks: Map.put(state.tasks, task_id, task)}
    end
  end

  defp apply_event_by_type(state, "TaskRetried", payload) do
    case decode_for_projection("TaskRetried", payload) do
      %ForemanServer.Events.TaskRetried{task_id: task_id} ->
        task =
          state.tasks
          |> Map.get(task_id, %{})
          |> Map.put(:status, "open")
          |> Map.put(:approval_id, nil)
          |> Map.put(:approved_by, nil)
          |> Map.put(:approved_at, nil)
          |> Map.put(:run_id, nil)
          |> Map.put(:workflow_snapshot, nil)
          |> Map.put(:acknowledged_run_id, nil)
          |> Map.put(:run_terminal_reason, nil)
          |> Map.put(:run_terminal_at, nil)
          |> Map.put(:last_event_at_ms, payload_event_at_ms(payload))

        %{state | tasks: Map.put(state.tasks, task_id, task)}
    end
  end

  defp apply_event_by_type(state, "WorkerStarted", payload) do
    touch_run_for_payload(state, payload)
  end

  defp apply_event_by_type(state, "WorkerHeartbeat", payload) do
    touch_run_for_payload(state, payload)
  end

  defp apply_event_by_type(state, "WorkerExited", payload) do
    touch_run_for_payload(state, payload)
  end

  defp apply_event_by_type(state, "WorkerUnresponsive", payload) do
    update_run_projection(state, get(payload, :run_id), payload_event_at_ms(payload), fn run ->
      worker_id = get(payload, :worker_id)
      sequence = get(payload, :sequence)

      workers =
        Map.put(
          Map.get(run, :workers, %{}),
          worker_id,
          %{status: "unresponsive", sequence: sequence}
        )

      run
      |> Map.put(:status, "needs_recovery")
      |> Map.put(:needs_recovery, true)
      |> Map.put(:workers, workers)
    end)
  end

  defp apply_event_by_type(state, "WorkerRecoveryRequired", payload) do
    update_run_projection(state, get(payload, :run_id), payload_event_at_ms(payload), fn run ->
      Map.put(run, :recovery_observation_at_ms, payload_event_at_ms(payload))
    end)
  end

  defp apply_event_by_type(state, "PrAssociated", payload) do
    run_id = get(payload, :run_id)

    if valid_id?(run_id) do
      association = %{
        run_id: run_id,
        pr_url: get(payload, :pr_url),
        pr_number: get(payload, :pr_number),
        associated_at: get(payload, :associated_at)
      }

      put_state(state, state.projects, state.runs)
      |> Map.put(:pr_associations, Map.put(state.pr_associations, run_id, association))
    else
      state
    end
  end

  defp apply_event_by_type(state, "ScheduledFireRecorded", payload) do
    intent_id = get(payload, :intent_id)

    if valid_id?(intent_id) do
      intent = %{
        intent_id: intent_id,
        status: "recorded",
        recorded_at: payload_event_at_ms(payload),
        run_id: get(payload, :run_id),
        task_id: get(payload, :task_id),
        scheduled_at: get(payload, :scheduled_at),
        scheduled_for: get(payload, :scheduled_for),
        payload: get(payload, :payload, %{})
      }

      put_state(state, state.projects, state.runs)
      |> Map.put(:scheduler_intents, Map.put(state.scheduler_intents, intent_id, intent))
    else
      state
    end
  end

  defp apply_event_by_type(state, "ScheduledFireConfirmed", payload) do
    update_intent(state, payload, "confirmed")
  end

  defp apply_event_by_type(state, "ScheduledFireSkipped", payload) do
    update_intent(state, payload, "skipped")
  end

  defp apply_event_by_type(state, "SchedulerIntentStale", payload) do
    update_intent(state, payload, "stale")
  end

  defp apply_event_by_type(state, "ToolCallFinished", payload) do
    touch_run_for_payload(state, payload)
  end

  defp apply_event_by_type(state, "WorktreeCreated", payload) do
    case decode_for_projection("WorktreeCreated", payload) do
      %ForemanServer.Events.WorktreeCreated{} = event
      when not is_nil(event.operation_id) and event.operation_id != "" ->
        entry = %{
          operation_id: event.operation_id,
          project_id: event.project_id,
          run_id: event.run_id,
          phase_id: event.phase_id,
          status: "created",
          repo_path: event.repo_path,
          worktree_path: event.worktree_path,
          branch: event.branch,
          base_ref: event.base_ref,
          cleanup: event.cleanup,
          last_event_at_ms: payload_event_at_ms(payload)
        }

        state
        |> Map.update!(:worktrees, &Map.put(&1, event.operation_id, entry))
        |> touch_run_for_payload(payload)

      _ ->
        touch_run_for_payload(state, payload)
    end
  end

  defp apply_event_by_type(state, "WorktreeCleaned", payload) do
    case decode_for_projection("WorktreeCleaned", payload) do
      %ForemanServer.Events.WorktreeCleaned{} = event
      when not is_nil(event.operation_id) and event.operation_id != "" ->
        existing = Map.get(state.worktrees, event.operation_id, %{})

        merged =
          Map.merge(existing, %{
            operation_id: event.operation_id,
            project_id: event.project_id || existing[:project_id],
            run_id: event.run_id || existing[:run_id],
            phase_id: event.phase_id || existing[:phase_id],
            status: "cleaned",
            repo_path: event.repo_path || existing[:repo_path],
            worktree_path: event.worktree_path || existing[:worktree_path],
            cleanup_observed: event.cleanup_observed,
            last_event_at_ms: payload_event_at_ms(payload)
          })

        state
        |> Map.update!(:worktrees, &Map.put(&1, event.operation_id, merged))
        |> touch_run_for_payload(payload)

      _ ->
        touch_run_for_payload(state, payload)
    end
  end

  defp apply_event_by_type(state, "WorktreeCreateOrphanRecorded", payload) do
    case decode_for_projection("WorktreeCreateOrphanRecorded", payload) do
      %ForemanServer.Events.WorktreeCreateOrphanRecorded{} = event
      when not is_nil(event.operation_id) and event.operation_id != "" ->
        entry = %{
          operation_id: event.operation_id,
          project_id: event.project_id,
          run_id: event.run_id,
          phase_id: event.phase_id,
          worktree_path: event.worktree_path,
          repo_path: event.repo_path,
          reason: event.reason,
          last_event_at_ms: payload_event_at_ms(payload)
        }

        state
        |> Map.update!(:worktree_create_orphans, &Map.put(&1, event.operation_id, entry))
        |> touch_run_for_payload(payload)

      _ ->
        touch_run_for_payload(state, payload)
    end
  end

  defp apply_event_by_type(state, "WorktreeCreateOrphanResolved", payload) do
    case decode_for_projection("WorktreeCreateOrphanResolved", payload) do
      %ForemanServer.Events.WorktreeCreateOrphanResolved{} = event
      when not is_nil(event.operation_id) and event.operation_id != "" ->
        state
        |> Map.update!(:worktree_create_orphans, &Map.delete(&1, event.operation_id))
        |> touch_run_for_payload(payload)

      _ ->
        touch_run_for_payload(state, payload)
    end
  end

  defp apply_event_by_type(state, _type, _payload), do: state

  defp update_intent(state, payload, status) do
    intent_id = get(payload, :intent_id)

    if valid_id?(intent_id) do
      existing = Map.get(state.scheduler_intents, intent_id, %{})
      merged = Map.merge(existing, %{status: status, intent_id: intent_id})

      put_state(state, state.projects, state.runs)
      |> Map.put(:scheduler_intents, Map.put(state.scheduler_intents, intent_id, merged))
    else
      state
    end
  end

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------

  defp project_projection(payload, path) do
    %{
      project_id: get(payload, :project_id),
      path: path,
      status: get(payload, :status, "active"),
      archived?: false,
      default_branch: get(payload, :default_branch, "main"),
      config: get(payload, :config, %{}),
      task_provider: get(payload, :task_provider),
      health: get(payload, :health, %{ok: true}),
      name: get(payload, :name)
    }
    |> put_project_projection_metadata(payload)
  end

  defp put_project_projection_metadata(project, payload)
       when is_map(project) and is_map(payload) do
    project
    |> maybe_put(:version, get(payload, :_projection_stream_version))
    |> put_registered_projection_timestamp(get(payload, :_projection_recorded_at))
  end

  defp put_registered_projection_timestamp(project, recorded_at) when is_binary(recorded_at) do
    if is_binary(Map.get(project, :registered_at)) do
      project
    else
      project
      |> Map.put(:registered, recorded_at)
      |> Map.put(:registered_at, recorded_at)
    end
  end

  defp put_registered_projection_timestamp(project, _recorded_at), do: project

  defp put_project_config(project, config) do
    Map.put(project, :config, shallow_merge(get(project, :config, %{}), config))
  end

  defp shallow_merge(left, right) when is_map(left) and is_map(right) do
    Enum.reduce(right, left, fn {key, value}, acc -> Map.put(acc, key, value) end)
  end

  defp shallow_merge(_left, right) when is_map(right), do: right
  defp shallow_merge(left, _right), do: left

  defp add_project_run_id(run_ids, run_id) when is_list(run_ids) do
    if run_id in run_ids, do: run_ids, else: [run_id | run_ids]
  end

  defp remove_project_run_id(active_runs, project_id, run_id) when is_map(active_runs) do
    case Map.get(active_runs, project_id, []) |> Enum.reject(&(&1 == run_id)) do
      [] -> Map.delete(active_runs, project_id)
      remaining -> Map.put(active_runs, project_id, remaining)
    end
  end

  defp apply_terminal_run_event(state, payload, status) do
    update_run_projection(state, get(payload, :run_id), payload_event_at_ms(payload), fn run ->
      run
      |> maybe_put(:task_id, get(payload, :task_id))
      |> maybe_put(:failure_reason, get(payload, :reason))
      |> Map.update(:last_sequence, get(payload, :sequence), & &1)
      |> Map.put(:status, status)
      |> Map.put(:terminal?, true)
    end)
  end

  defp touch_run_for_payload(state, payload) do
    update_run_projection(state, get(payload, :run_id), payload_event_at_ms(payload), fn run ->
      run
    end)
  end

  defp update_run_projection(state, run_id, event_at_ms, updater) when is_function(updater, 1) do
    if valid_id?(run_id) do
      run =
        state.runs
        |> Map.get(run_id, base_run_projection(run_id, event_at_ms))
        |> updater.()
        |> Map.put(:run_id, run_id)
        |> Map.put(:last_event_at_ms, event_at_ms)

      put_state(state, state.projects, Map.put(state.runs, run_id, run))
    else
      state
    end
  end

  defp base_run_projection(run_id, now_ms) do
    %{
      run_id: run_id,
      status: "in_progress",
      task_id: nil,
      project_id: nil,
      workflow_name: nil,
      workflow_digest: nil,
      workflow_snapshot: nil,
      phase_ids: [],
      last_sequence: nil,
      started_at_ms: now_ms,
      last_event_at_ms: now_ms,
      terminal?: false,
      failure_reason: nil
    }
  end

  defp active_run_ids(state) do
    state.runs
    |> Enum.reduce([], fn
      {run_id, %{status: status}}, acc when status in @active_run_statuses -> [run_id | acc]
      _, acc -> acc
    end)
    |> Enum.sort()
  end

  defp put_state(state, projects, runs) do
    %{
      state
      | projects: projects,
        runs: runs
    }
  end

  defp recorded_event_at_ms(%RecordedEvent{created_at: %DateTime{} = created_at}, _now_ms_fun) do
    DateTime.to_unix(created_at, :millisecond)
  end

  defp recorded_event_at_ms(_recorded, now_ms_fun) do
    now_ms_fun.()
  end

  defp payload_event_at_ms(payload) do
    get(payload, :_projection_event_at_ms, resolve_now_ms_fun().())
  end

  defp with_event_at_ms(payload, event_at_ms) when is_map(payload) do
    Map.put(payload, :_projection_event_at_ms, event_at_ms)
  end

  # The EventCodec enforces a closed set of fields per typed event struct.
  # `_projection_event_at_ms` is a projection-private timestamp we attach
  # in `with_event_at_ms/2` so `payload_event_at_ms/1` can read it without
  # coupling handlers to metadata storage. Strip it before decoding so
  # typed-event validation does not reject the private key.
  defp decode_for_projection(event_type, payload)
       when is_binary(event_type) and is_map(payload) do
    EventCodec.decode!(event_type, drop_projection_meta(payload))
  end

  defp with_recorded_projection_metadata(payload, %RecordedEvent{} = recorded, now_ms_fun) do
    payload
    |> with_event_at_ms(recorded_event_at_ms(recorded, now_ms_fun))
    |> Map.put(:_projection_stream_version, recorded.stream_version)
    |> maybe_put(:_projection_recorded_at, recorded_event_timestamp(recorded))
  end

  defp recorded_event_timestamp(%RecordedEvent{created_at: %DateTime{} = created_at}) do
    DateTime.to_iso8601(created_at)
  end

  defp recorded_event_timestamp(%RecordedEvent{created_at: created_at})
       when is_binary(created_at) do
    created_at
  end

  defp recorded_event_timestamp(_recorded), do: nil

  defp drop_projection_meta(payload) do
    payload
    |> Map.delete(:_projection_event_at_ms)
    |> Map.delete("_projection_event_at_ms")
    |> Map.delete(:_projection_stream_version)
    |> Map.delete("_projection_stream_version")
    |> Map.delete(:_projection_recorded_at)
    |> Map.delete("_projection_recorded_at")
  end

  defp to_payload_map(%{} = payload) do
    if Map.has_key?(payload, :__struct__) do
      Map.from_struct(payload)
    else
      payload
    end
  end

  defp init_now_ms_fun(init_arg) when is_list(init_arg) do
    case Keyword.get(init_arg, :now_ms) do
      now_ms_fun when is_function(now_ms_fun, 0) -> now_ms_fun
      _ -> resolve_now_ms_fun()
    end
  end

  defp init_now_ms_fun(_init_arg), do: resolve_now_ms_fun()

  defp normalize_now_ms_fun(nil), do: resolve_now_ms_fun()

  defp normalize_now_ms_fun(now_ms) when is_integer(now_ms), do: fn -> now_ms end
  defp normalize_now_ms_fun(now_ms_fun) when is_function(now_ms_fun, 0), do: now_ms_fun

  defp resolve_now_ms_fun do
    case Process.get(:projection_store_now_ms) do
      now_ms_fun when is_function(now_ms_fun, 0) ->
        now_ms_fun

      _ ->
        case Application.get_env(:foreman_server, :projection_store_now_ms) do
          now_ms_fun when is_function(now_ms_fun, 0) -> now_ms_fun
          _ -> fn -> System.system_time(:millisecond) end
        end
    end
  end

  defp valid_id?(value) when is_binary(value), do: value != ""
  defp valid_id?(_value), do: false

  defp maybe_put(project, _key, nil), do: project
  defp maybe_put(project, key, value), do: Map.put(project, key, value)

  defp get(%{} = m, k), do: get(m, k, nil)

  defp get(%{} = m, k, default) when is_atom(k) do
    Map.get(m, k, Map.get(m, Atom.to_string(k), default))
  end

  defp get(%{} = m, k, default), do: Map.get(m, k, default)
end
