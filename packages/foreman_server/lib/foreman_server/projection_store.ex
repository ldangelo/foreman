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

  alias EventStore.{EventData, Page, RecordedEvent}
  alias EventStore.Streams.StreamInfo
  alias ForemanServer.{EventCodec, EventStore}
  alias ForemanServer.Events.{WorkerStderr, WorkerStdout}

  @active_run_statuses ["awaiting_worker", "in_progress"]

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

  @doc """
  Canonical list of run statuses that count as "actively dispatching" —
  i.e. holding a project slot and not yet terminal. Reuse this for any
  check that wants to know whether a run is still in flight.

  Currently `"awaiting_worker"` (admitted but no worker attached yet)
  and `"in_progress"` (worker attached and acknowledged). Adding a new
  pre-terminal state? Add it here and only here.
  """
  @spec active_run_statuses() :: [String.t()]
  def active_run_statuses, do: @active_run_statuses

  @doc "Return active runs whose last activity is older than the threshold."
  @spec stuck_runs(non_neg_integer(), integer() | nil) :: [String.t()]
  def stuck_runs(threshold_ms, now_ms \\ nil)
      when is_integer(threshold_ms) and threshold_ms >= 0 do
    GenServer.call(__MODULE__, {:stuck_runs, threshold_ms, normalize_now_ms_fun(now_ms)})
  end

  @spec stall_candidates(integer() | nil) :: [map()]
  def stall_candidates(now_ms \\ nil) do
    GenServer.call(__MODULE__, {:stall_candidates, normalize_now_ms_fun(now_ms)})
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

  @doc """
  Return the projected state for a run, or nil if not found.

  `pr_url` is always present on a projected run: a string once a `PrAssociated`
  event has been applied, `nil` when Foreman has recorded no PR for the run. A
  `PrAssociated` event carrying no usable URL raises rather than projecting
  `nil`, so an explicit `nil` never stands in for a lost association.
  """
  @spec run(String.t()) :: map() | nil
  def run(run_id) when is_binary(run_id) and run_id != "" do
    GenServer.call(__MODULE__, {:run, run_id})
  end

  @doc """
  Return all events for a run as serializable maps.

  `{:ok, []}` for a run with no stream. `{:error, reason}` on a store failure —
  never an empty list standing in for an error.
  """
  @spec run_events(String.t()) :: {:ok, [map()]} | {:error, term()}
  def run_events(run_id) do
    GenServer.call(__MODULE__, {:run_events, run_id})
  end

  @doc """
  Return per-worker activity for a run, summarized from its
  `worker:<run_id>:<worker_id>` event streams.

  Worker liveness events are appended to those streams, never to
  `run:<run_id>`, so `run_events/1` does not surface them: a live run shows a
  single `RunStarted` event on its run stream while its worker stream grows a
  `WorkerHeartbeat` every few seconds. This read is therefore the only way to
  judge worker liveness without reading the server console.

  `{:ok, []}` for a known run whose workers have emitted nothing yet.
  `{:error, :run_not_found}` for an unknown run — never an empty list standing
  in for an absent run.
  """
  @spec run_activity(String.t()) :: {:ok, [map()]} | {:error, :run_not_found | term()}
  def run_activity(run_id) do
    GenServer.call(__MODULE__, {:run_activity, run_id})
  end

  @doc """
  Return projected durable stdout/stderr for a known run.

  Logs are materialized from `WorkerStdout` / `WorkerStderr` events on
  `worker:<run_id>:<worker_id>` streams. Unknown runs return
  `{:error, :run_not_found}`; known runs with no worker output return a
  successful empty result. The default read is a deterministic latest-500 tail.

  **Absent is not the same as dropped** (AGENTS.md 5.3). A run whose workers
  wrote nothing reads `count: 0, truncated: false, omitted_entries: 0`. A run
  whose output outgrew the resident caps reads `truncated: true` with non-zero
  `omitted_entries`/`omitted_bytes`, so a partial read can never be mistaken
  for a complete one. The events themselves stay in the event store either
  way; this is a bounded read model over them, not the system of record.

  There is no `:log_store_unavailable` / `:log_store_failed` failure: the
  projection is this GenServer's own state, so for a known run the read always
  succeeds. Declaring failures that cannot occur would misdescribe the
  contract.
  """
  @spec run_logs(String.t()) ::
          {:ok,
           %{
             run_id: String.t(),
             entries: [map()],
             count: non_neg_integer(),
             limit: pos_integer(),
             truncated: boolean(),
             omitted_entries: non_neg_integer(),
             omitted_bytes: non_neg_integer(),
             max_limit: pos_integer()
           }}
          | {:error, :run_not_found}
  def run_logs(run_id) do
    GenServer.call(__MODULE__, {:run_logs, run_id})
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

  @doc "Return every projected run, optionally filtered by status, project_id, and limit."
  @spec list_runs(keyword()) :: [map()]
  def list_runs(opts \\ []) when is_list(opts) do
    GenServer.call(__MODULE__, {:list_runs, opts})
  end

  @doc "Return every projected scheduler intent."
  @spec list_scheduler_intents() :: [map()]
  def list_scheduler_intents do
    GenServer.call(__MODULE__, :list_scheduler_intents)
  end

  @doc "Return the current run-slot queue status: capacity, running run ids, and waiting run ids in FIFO order."
  @spec queue_status() :: %{
          capacity: non_neg_integer(),
          running: [String.t()],
          waiting: [String.t()]
        }
  def queue_status do
    GenServer.call(__MODULE__, :queue_status)
  end

  @doc "Return the projected state for a work, or nil if not found."
  @spec work_projection(String.t()) :: map() | nil
  def work_projection(work_id) when is_binary(work_id) and work_id != "" do
    GenServer.call(__MODULE__, {:work_projection, work_id})
  end

  @doc "Return every projected work."
  @spec list_work() :: [map()]
  def list_work do
    GenServer.call(__MODULE__, :list_work)
  end

  @doc "Return the queue position for a submitted work, or {:error, :not_in_queue}."
  @spec queue_position(String.t()) :: {:ok, pos_integer()} | {:error, :not_in_queue}
  def queue_position(work_id) when is_binary(work_id) and work_id != "" do
    GenServer.call(__MODULE__, {:queue_position, work_id})
  end

  @doc "Return the inbox thread for a run_id, or nil if not found."
  @spec inbox_thread(String.t()) :: map() | nil
  def inbox_thread(run_id) when is_binary(run_id) and run_id != "" do
    GenServer.call(__MODULE__, {:inbox_thread, run_id})
  end

  @doc "Return every inbox thread."
  @spec list_inbox_threads() :: [map()]
  def list_inbox_threads do
    GenServer.call(__MODULE__, :list_inbox_threads)
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
  def handle_call({:run_events, run_id}, _from, state) do
    # `%EventStore.RecordedEvent{}` has no Jason.Encoder, so returning the
    # structs raised Protocol.UndefinedError as soon as a run actually had
    # events — the tool only ever looked correct because its test covered the
    # empty case. Project each event onto a serializable map.
    reply =
      case EventStore.read_stream_forward("run:#{run_id}", 0, 99_999_999) do
        {:ok, events} -> {:ok, Enum.map(events, &recorded_event_to_map/1)}
        {:error, :stream_not_found} -> {:ok, []}
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:run_activity, run_id}, _from, state) do
    reply =
      case Map.get(state.runs, run_id) do
        nil -> {:error, :run_not_found}
        _run -> worker_activity_for_run(run_id)
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:run_logs, run_id}, _from, state) do
    reply =
      case Map.get(state.runs, run_id) do
        nil -> {:error, :run_not_found}
        _run -> run_logs_result(state, run_id)
      end

    {:reply, reply, state}
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
  def handle_call({:stall_candidates, now_ms_fun}, _from, state) do
    now_ms = now_ms_fun.()
    {:reply, stall_candidates_from_state(state, now_ms), state}
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
  def handle_call(:queue_status, _from, state) do
    %{capacity: capacity, holders: holders, waiters: waiters} = state.run_slots

    reply = %{
      capacity: capacity,
      running: Map.keys(holders),
      waiting: Enum.map(waiters, & &1.run_id)
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:work_projection, work_id}, _from, state) do
    {:reply, Map.get(state.works, work_id), state}
  end

  @impl true
  def handle_call(:list_work, _from, state) do
    {:reply, Map.values(state.works), state}
  end

  @impl true
  def handle_call(:list_scheduler_intents, _from, state) do
    {:reply, Map.values(state.scheduler_intents), state}
  end

  def handle_call({:queue_position, work_id}, _from, state) do
    reply =
      case Map.get(state.works, work_id) do
        %{run_id: run_id} when is_binary(run_id) ->
          %{waiters: waiters} = state.run_slots
          waiting = Enum.map(waiters, & &1.run_id)

          if run_id in waiting do
            position = Enum.find_index(waiting, &(&1 == run_id)) + 1
            {:ok, position}
          else
            {:error, :not_in_queue}
          end

        _ ->
          {:error, :not_in_queue}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:pr_association, run_id}, _from, state) do
    case Map.get(state.pr_associations, run_id) do
      nil -> {:reply, {:error, :not_found}, state}
      assoc -> {:reply, {:ok, assoc}, state}
    end
  end

  @impl true
  def handle_call({:inbox_thread, run_id}, _from, state) do
    {:reply, Map.get(state.inbox_threads, run_id), state}
  end

  @impl true
  def handle_call(:list_inbox_threads, _from, state) do
    {:reply, Map.values(state.inbox_threads), state}
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
  def handle_call({:list_runs, opts}, _from, state) do
    runs =
      state.runs
      |> Map.values()
      |> filter_runs(opts)
      |> Enum.sort_by(
        fn run -> {get(run, :last_event_at_ms, 0), get(run, :run_id, "")} end,
        :desc
      )
      |> limit_runs(Keyword.get(opts, :limit))

    {:reply, runs, state}
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
      run_logs: %{},
      scheduler_intents: %{},
      subscribers: %{},
      project_active_runs: %{},
      worktrees: %{},
      worktree_create_orphans: %{},
      run_slots: %{capacity: 0, holders: %{}, waiters: []},
      works: %{},
      inbox_threads: %{}
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

  defp apply_event_by_type(state, "NotificationEnqueued", payload) do
    case decode_for_projection("NotificationEnqueued", payload) do
      %ForemanServer.Events.NotificationEnqueued{run_id: run_id} = event
      when is_binary(run_id) and run_id != "" ->
        project_notification_enqueued(state, payload, event)

      _ ->
        state
    end
  end

  defp apply_event_by_type(state, "NotificationSuppressed", payload) do
    case decode_for_projection("NotificationSuppressed", payload) do
      %ForemanServer.Events.NotificationSuppressed{run_id: run_id} = event
      when is_binary(run_id) and run_id != "" ->
        project_notification_outcome(state, payload, event, "suppressed", %{
          reason: event.reason
        })

      _ ->
        state
    end
  end

  defp apply_event_by_type(state, "NotificationDeliveryAttempted", payload) do
    case decode_for_projection("NotificationDeliveryAttempted", payload) do
      %ForemanServer.Events.NotificationDeliveryAttempted{run_id: run_id} = event
      when is_binary(run_id) and run_id != "" ->
        project_notification_outcome(state, payload, event, "attempted", %{})

      _ ->
        state
    end
  end

  defp apply_event_by_type(state, "NotificationDeliverySucceeded", payload) do
    case decode_for_projection("NotificationDeliverySucceeded", payload) do
      %ForemanServer.Events.NotificationDeliverySucceeded{run_id: run_id} = event
      when is_binary(run_id) and run_id != "" ->
        project_notification_outcome(state, payload, event, "succeeded", %{
          delivered_at: event.delivered_at
        })

      _ ->
        state
    end
  end

  defp apply_event_by_type(state, "NotificationDeliveryFailed", payload) do
    case decode_for_projection("NotificationDeliveryFailed", payload) do
      %ForemanServer.Events.NotificationDeliveryFailed{run_id: run_id} = event
      when is_binary(run_id) and run_id != "" ->
        project_notification_outcome(state, payload, event, "failed", %{
          reason: event.reason,
          retryable?: event.retryable?
        })

      _ ->
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
            status: "awaiting_worker",
            terminal?: false,
            started_at_ms: event_at_ms,
            last_event_at_ms: event_at_ms,
            failure_reason: nil,
            pr_url: nil,
            phase_prs: [],
            notifications: []
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

  defp apply_event_by_type(state, "RunReset", payload) do
    run_id = get(payload, :run_id)

    if valid_id?(run_id) do
      project_id = get(payload, :project_id)

      state
      |> Map.update(:project_active_runs, %{}, fn active_runs ->
        if valid_id?(project_id) do
          remove_project_run_id(active_runs, project_id, run_id)
        else
          active_runs
        end
      end)
      |> put_state(state.projects, Map.delete(state.runs, run_id))
    else
      state
    end
  end

  defp apply_event_by_type(state, "RunFlaggedStuck", payload) do
    apply_terminal_run_event(state, payload, "stuck")
  end

  defp apply_event_by_type(state, "RunStallReported", payload) do
    stall = latest_stall_from_payload(payload)
    run_id = get(payload, :run_id)
    phase_id = get(payload, :phase_id)
    task_id = get(payload, :task_id)
    status_effect = get(payload, :status_effect)

    state
    |> update_run_projection(run_id, payload_event_at_ms(payload), fn run ->
      run
      |> Map.put(:latest_stall, stall)
      |> maybe_put_status_effect(status_effect, stall.reason)
    end)
    |> Map.update!(:phases, fn phases ->
      Map.update(phases, phase_id, %{latest_stall: stall}, fn phase ->
        Map.put(phase, :latest_stall, stall)
      end)
    end)
    |> update_task_latest_stall(task_id, stall)
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
          last_event_at_ms: payload_event_at_ms(payload),
          output_activity_at_ms: payload_event_at_ms(payload),
          messaging_activity_at_ms: payload_event_at_ms(payload),
          stall_detection_kind: event.stall_detection_kind,
          stall_threshold_ms: event.stall_threshold_ms,
          stall_policy: event.stall_policy,
          latest_stall: nil
        }

        state
        |> touch_run_for_payload(payload)
        |> Map.update!(:phases, &Map.put(&1, phase_id, phase))
        |> append_phase_id_to_run(run_id, phase_id)

      _ ->
        touch_run_for_payload(state, payload)
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
          |> Map.put(:output_activity_at_ms, payload_event_at_ms(payload))

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
          |> Map.put(:output_activity_at_ms, payload_event_at_ms(payload))

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
          prompt: event.prompt,
          # Carried because `CommandGateway` gates `task.approve` on it. Until
          # this line existed the field was accepted by `task.create`, stored on
          # the aggregate, and written onto `TaskCreated` — then dropped here, so
          # no cross-task reader could see it and dependencies had no effect on
          # anything.
          #
          # `event.dependencies || []` was wrong and is exactly the shape
          # AGENTS.md §5.4b names: `false || []` returns `[]` just as `nil || []`
          # does, so a malformed value arrived here as "no dependencies" and the
          # approval guard waved it through. Verified before fixing — a
          # `task.create` carrying `dependencies: false` returned `{:ok, ...}`,
          # the event stored `false`, and this projection reported `[]`.
          # `task.create` now refuses a non-list, but historical events keep
          # theirs, so the malformed value is PRESERVED here rather than
          # flattened; the guard refuses that approval by its own clause. A read
          # model must not raise on replay (`ProjectionStore.init/1` rebuilds
          # from the event log), and must not launder bad data either.
          dependencies: normalize_dependencies(event.dependencies),
          provider_tracked: event.provider_tracked,
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
          |> Map.put(:failure_reason, nil)
          |> Map.put(:run_terminal_reason, nil)
          |> Map.put(:run_terminal_at, nil)
          |> Map.put(:last_event_at_ms, payload_event_at_ms(payload))

        %{state | tasks: Map.put(state.tasks, task_id, task)}
    end
  end

  defp apply_event_by_type(state, "WorkerStarted", payload) do
    state
    |> update_run_projection(get(payload, :run_id), payload_event_at_ms(payload), fn run ->
      case run do
        %{status: "awaiting_worker"} -> %{run | status: "in_progress"}
        run -> run
      end
    end)
    |> touch_active_phase_activity(get(payload, :run_id), :output, payload_event_at_ms(payload))
  end

  defp apply_event_by_type(state, "WorkerHeartbeat", payload) do
    touch_run_for_payload(state, payload)
  end

  defp apply_event_by_type(state, "WorkerExited", payload) do
    state
    |> touch_run_for_payload(payload)
    |> touch_active_phase_activity(get(payload, :run_id), :output, payload_event_at_ms(payload))
  end

  defp apply_event_by_type(state, "WorkerStdout", payload) do
    project_worker_log(state, decode_for_projection("WorkerStdout", payload), payload, "stdout")
  end

  defp apply_event_by_type(state, "WorkerStderr", payload) do
    project_worker_log(state, decode_for_projection("WorkerStderr", payload), payload, "stderr")
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

  # `PrAssociated` lands on BOTH the association map and the run projection.
  # It previously wrote only the association map, so `run/1` — and therefore
  # `GET /api/runs/:id` and `GET /api/runs` — carried no PR field at all: the
  # run that opened https://github.com/ldangelo/foreman/pull/420 read exactly
  # like a run that opened nothing.
  defp apply_event_by_type(state, "PrAssociated", payload) do
    case decode_for_projection("PrAssociated", payload) do
      %ForemanServer.Events.PrAssociated{run_id: run_id, pr_url: pr_url} = event
      when is_binary(run_id) and run_id != "" and is_binary(pr_url) and pr_url != "" ->
        association = %{
          run_id: run_id,
          pr_url: pr_url,
          pr_number: event.pr_number,
          associated_at: event.associated_at
        }

        state
        |> update_run_projection(run_id, payload_event_at_ms(payload), fn run ->
          Map.put(run, :pr_url, pr_url)
        end)
        |> Map.update!(:pr_associations, &Map.put(&1, run_id, association))

      # AGENTS.md 5.3: a blank run_id or pr_url is malformed, not absent.
      # Projecting it would leave `pr_url: nil` on the run, indistinguishable
      # from "this run opened no PR". `PrAssociation.handle_command/2` rejects
      # both on the write path, so reaching here means the aggregate was
      # bypassed.
      %ForemanServer.Events.PrAssociated{} = event ->
        raise ArgumentError,
              "ProjectionStore: PrAssociated with unusable run_id/pr_url: #{inspect(event)}"
    end
  end

  defp apply_event_by_type(state, "PhasePrRecorded", payload) do
    case decode_for_projection("PhasePrRecorded", payload) do
      %ForemanServer.Events.PhasePrRecorded{} = event ->
        record = %{
          run_id: event.run_id,
          phase_id: event.phase_id,
          phase_index: event.phase_index,
          phase_name: event.phase_name,
          status: event.status,
          pr_url: event.pr_url,
          pr_number: event.pr_number,
          base_branch: event.base_branch,
          head_branch: event.head_branch,
          provider: event.provider,
          reason: event.reason,
          recorded_at: event.recorded_at
        }

        validate_phase_pr_record!(record)

        state
        |> update_run_projection(event.run_id, payload_event_at_ms(payload), fn run ->
          phase_prs =
            run
            |> Map.get(:phase_prs, [])
            |> upsert_phase_pr(record)

          Map.put(run, :phase_prs, phase_prs)
        end)
        |> Map.update!(:phases, fn phases ->
          Map.update(phases, event.phase_id, %{phase_prs: [record]}, fn phase ->
            Map.put(phase, :phase_prs, upsert_phase_pr(Map.get(phase, :phase_prs, []), record))
          end)
        end)
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

  defp apply_event_by_type(state, "AssistantMessage", payload) do
    state
    |> touch_run_for_payload(payload)
    |> touch_active_phase_activity(get(payload, :run_id), :output, payload_event_at_ms(payload))
  end

  defp apply_event_by_type(state, "ToolCallFinished", payload) do
    state
    |> touch_run_for_payload(payload)
    |> touch_active_phase_activity(get(payload, :run_id), :output, payload_event_at_ms(payload))
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

  # -------------------------------------------------------------------------
  # InboxThread events — folded into state.inbox_threads
  # -------------------------------------------------------------------------

  defp apply_event_by_type(state, "InboxMessageAppended", payload) do
    run_id = get(payload, :run_id)

    if valid_id?(run_id) do
      thread =
        state.inbox_threads
        |> Map.get(run_id, %{run_id: run_id, messages: []})
        |> Map.update!(:messages, fn msgs ->
          msg = %{
            message_id: get(payload, :message_id),
            body: get(payload, :body),
            delivery_status: nil,
            metadata:
              Map.drop(payload, [:run_id, :message_id, :body, "run_id", "message_id", "body"]),
            event_at_ms: payload_event_at_ms(payload)
          }

          msgs ++ [msg]
        end)

      state
      |> Map.put(:inbox_threads, Map.put(state.inbox_threads, run_id, thread))
      |> touch_active_phase_activity(run_id, :messaging, payload_event_at_ms(payload))
    else
      state
    end
  end

  defp apply_event_by_type(state, "InboxDeliveryUpdated", payload) do
    run_id = get(payload, :run_id)
    message_id = get(payload, :message_id)

    if valid_id?(run_id) and valid_id?(message_id) do
      case Map.get(state.inbox_threads, run_id) do
        nil ->
          state

        thread ->
          updated_messages =
            Enum.map(thread.messages, fn msg ->
              if msg.message_id == message_id do
                Map.put(msg, :delivery_status, get(payload, :delivery_status))
              else
                msg
              end
            end)

          updated_thread = %{thread | messages: updated_messages}
          %{state | inbox_threads: Map.put(state.inbox_threads, run_id, updated_thread)}
      end
    else
      state
    end
  end

  # -------------------------------------------------------------------------
  # RunSlot events — folded into state.run_slots
  # -------------------------------------------------------------------------

  defp apply_event_by_type(state, "RunSlotAcquired", payload) do
    run_id = get(payload, :run_id)
    capacity = get(payload, :capacity)

    if valid_id?(run_id) do
      Map.update!(state, :run_slots, fn slots ->
        %{slots | capacity: capacity, holders: Map.put(slots.holders, run_id, :held)}
      end)
    else
      state
    end
  end

  defp apply_event_by_type(state, "RunSlotQueued", payload) do
    run_id = get(payload, :run_id)
    position = get(payload, :position)
    enqueued_at_ms = get(payload, :enqueued_at_ms)

    if valid_id?(run_id) do
      Map.update!(state, :run_slots, fn slots ->
        waiter = %{run_id: run_id, position: position, enqueued_at_ms: enqueued_at_ms}
        %{slots | waiters: slots.waiters ++ [waiter]}
      end)
    else
      state
    end
  end

  defp apply_event_by_type(state, "RunSlotReleased", payload) do
    run_id = get(payload, :run_id)

    if valid_id?(run_id) do
      Map.update!(state, :run_slots, fn slots ->
        %{slots | holders: Map.delete(slots.holders, run_id)}
      end)
    else
      state
    end
  end

  defp apply_event_by_type(state, "RunSlotTransferred", payload) do
    released_run_id = get(payload, :released_run_id)
    acquired_run_id = get(payload, :acquired_run_id)

    if valid_id?(released_run_id) and valid_id?(acquired_run_id) do
      Map.update!(state, :run_slots, fn slots ->
        new_holders =
          slots.holders
          |> Map.delete(released_run_id)
          |> Map.put(acquired_run_id, :held)

        # Remove the promoted waiter
        new_waiters = Enum.reject(slots.waiters, &(&1.run_id == acquired_run_id))

        %{slots | holders: new_holders, waiters: new_waiters}
      end)
    else
      state
    end
  end

  defp apply_event_by_type(state, "RunSlotWaiterRemoved", payload) do
    run_id = get(payload, :run_id)

    if valid_id?(run_id) do
      Map.update!(state, :run_slots, fn slots ->
        %{slots | waiters: Enum.reject(slots.waiters, &(&1.run_id == run_id))}
      end)
    else
      state
    end
  end

  defp apply_event_by_type(state, "WorkSubmitted", payload) do
    case decode_for_projection("WorkSubmitted", payload) do
      %ForemanServer.Events.WorkSubmitted{
        work_id: work_id,
        project_id: project_id,
        run_id: run_id,
        submission_id: submission_id,
        backend: backend
      }
      when not is_nil(work_id) and work_id != "" ->
        work = %{
          work_id: work_id,
          status: :submitted,
          project_id: project_id,
          run_id: run_id,
          submission_id: submission_id,
          queue_position: nil,
          backend: backend
        }

        Map.update!(state, :works, &Map.put(&1, work_id, work))

      _ ->
        state
    end
  end

  defp apply_event_by_type(state, "WorkCancelled", payload) do
    case decode_for_projection("WorkCancelled", payload) do
      %ForemanServer.Events.WorkCancelled{work_id: work_id}
      when not is_nil(work_id) and work_id != "" ->
        Map.update!(state, :works, fn works ->
          case Map.get(works, work_id) do
            nil -> works
            existing -> Map.put(works, work_id, %{existing | status: :cancelled})
          end
        end)

      _ ->
        state
    end
  end

  defp apply_event_by_type(state, "WorkExecutionCompleted", payload) do
    case decode_for_projection("WorkExecutionCompleted", payload) do
      %ForemanServer.Events.WorkExecutionCompleted{work_id: work_id}
      when not is_nil(work_id) and work_id != "" ->
        Map.update!(state, :works, fn works ->
          case Map.get(works, work_id) do
            nil -> works
            existing -> Map.put(works, work_id, %{existing | status: :succeeded})
          end
        end)

      _ ->
        state
    end
  end

  defp apply_event_by_type(state, "WorkExecutionFailed", payload) do
    case decode_for_projection("WorkExecutionFailed", payload) do
      %ForemanServer.Events.WorkExecutionFailed{work_id: work_id}
      when not is_nil(work_id) and work_id != "" ->
        Map.update!(state, :works, fn works ->
          case Map.get(works, work_id) do
            nil -> works
            existing -> Map.put(works, work_id, %{existing | status: :failed})
          end
        end)

      _ ->
        state
    end
  end

  defp apply_event_by_type(state, _type, _payload), do: state

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

  defp upsert_phase_pr(records, record) when is_list(records) and is_map(record) do
    records
    |> Enum.reject(&(Map.get(&1, :phase_id) == Map.get(record, :phase_id)))
    |> Kernel.++([record])
    |> Enum.sort_by(fn pr -> {Map.get(pr, :phase_index, 0), Map.get(pr, :recorded_at, "")} end)
  end

  defp validate_phase_pr_record!(%{status: status, pr_url: url} = record) do
    cond do
      status in ["created", "existing"] and not (is_binary(url) and url != "") ->
        raise ArgumentError,
              "ProjectionStore: PhasePrRecorded #{status} missing usable pr_url: #{inspect(record)}"

      status == "noop" ->
        :ok

      status in ["created", "existing"] ->
        :ok

      true ->
        raise ArgumentError,
              "ProjectionStore: PhasePrRecorded with unknown status: #{inspect(record)}"
    end
  end

  defp project_notification_enqueued(state, payload, event) do
    update_run_projection(state, event.run_id, payload_event_at_ms(payload), fn run ->
      notification = %{
        notification_id: event.notification_id,
        provider: event.provider,
        event_class: event.event_class,
        severity: event.severity,
        correlation_id: event.correlation_id,
        status: "enqueued",
        reason: nil,
        retryable?: nil,
        metadata: event.metadata || %{}
      }

      Map.update(run, :notifications, [notification], fn notifications ->
        notifications
        |> Enum.reject(&(get(&1, :notification_id) == notification.notification_id))
        |> Kernel.++([notification])
      end)
    end)
  end

  defp project_notification_outcome(state, payload, event, status, outcome_fields) do
    update_run_projection(state, event.run_id, payload_event_at_ms(payload), fn run ->
      Map.update(run, :notifications, [], fn notifications ->
        case Enum.split_with(notifications, &(get(&1, :notification_id) == event.notification_id)) do
          {[existing], rest} ->
            [existing |> Map.put(:status, status) |> Map.merge(outcome_fields) | rest]

          {[], rest} ->
            base = %{
              notification_id: event.notification_id,
              provider: event.provider,
              correlation_id: event.correlation_id,
              status: status,
              reason: nil,
              retryable?: nil,
              metadata: %{}
            }

            [Map.merge(base, outcome_fields) | rest]
        end
      end)
    end)
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

  defp stall_candidates_from_state(state, now_ms) do
    state.phases
    |> Map.values()
    |> Enum.filter(&(get(&1, :status) == "in_progress"))
    |> Enum.filter(
      &(get(&1, :stall_detection_kind) in ["agent_no_output", "messaging_no_progress"])
    )
    |> Enum.filter(fn phase ->
      case Map.get(state.runs, get(phase, :run_id)) do
        %{status: status} when status in @active_run_statuses -> true
        _ -> false
      end
    end)
    |> Enum.flat_map(fn phase ->
      kind = get(phase, :stall_detection_kind)
      threshold_ms = get(phase, :stall_threshold_ms)
      activity_at_ms = activity_at_ms_for_kind(phase, kind)

      if is_integer(threshold_ms) and threshold_ms > 0 and is_integer(activity_at_ms) and
           activity_at_ms + threshold_ms <= now_ms do
        idle_ms = max(now_ms - activity_at_ms, 0)

        [
          %{
            run_id: get(phase, :run_id),
            task_id: get(Map.get(state.runs, get(phase, :run_id)), :task_id),
            phase_id: get(phase, :phase_id),
            phase_index: get(phase, :index),
            phase_name: get(phase, :name),
            stall_kind: kind,
            policy: get(phase, :stall_policy) || "attention",
            threshold_ms: threshold_ms,
            idle_ms: idle_ms,
            activity_at_ms: activity_at_ms,
            detected_at_ms: now_ms,
            idempotency_key: stall_idempotency_key(phase, kind, activity_at_ms),
            reason: stall_reason(phase, kind, idle_ms, threshold_ms)
          }
        ]
      else
        []
      end
    end)
  end

  defp activity_at_ms_for_kind(phase, "agent_no_output"), do: get(phase, :output_activity_at_ms)

  defp activity_at_ms_for_kind(phase, "messaging_no_progress"),
    do: get(phase, :messaging_activity_at_ms)

  defp stall_idempotency_key(phase, kind, activity_at_ms) do
    [get(phase, :run_id), get(phase, :phase_id), kind, activity_at_ms]
    |> Enum.join(":")
  end

  defp stall_reason(phase, "agent_no_output", idle_ms, threshold_ms) do
    "phase #{get(phase, :index)} (#{get(phase, :name)}) produced no agent output for #{idle_ms}ms (threshold #{threshold_ms}ms)"
  end

  defp stall_reason(phase, "messaging_no_progress", idle_ms, threshold_ms) do
    "phase #{get(phase, :index)} (#{get(phase, :name)}) had no messaging progress for #{idle_ms}ms (threshold #{threshold_ms}ms)"
  end

  defp touch_active_phase_activity(state, run_id, kind, event_at_ms) do
    if valid_id?(run_id) do
      phase_ids = state.runs |> Map.get(run_id, %{}) |> Map.get(:phase_ids, [])

      Map.update!(state, :phases, fn phases ->
        Enum.reduce(phase_ids, phases, fn phase_id, acc ->
          case Map.fetch(acc, phase_id) do
            {:ok, phase} ->
              if get(phase, :status) == "in_progress" do
                key =
                  if kind == :messaging,
                    do: :messaging_activity_at_ms,
                    else: :output_activity_at_ms

                Map.put(acc, phase_id, Map.put(phase, key, event_at_ms))
              else
                acc
              end

            :error ->
              acc
          end
        end)
      end)
    else
      state
    end
  end

  defp latest_stall_from_payload(payload) do
    %{
      run_id: get(payload, :run_id),
      task_id: get(payload, :task_id),
      phase_id: get(payload, :phase_id),
      phase_index: get(payload, :phase_index),
      phase_name: get(payload, :phase_name),
      stall_kind: get(payload, :stall_kind),
      policy: get(payload, :policy),
      status_effect: get(payload, :status_effect),
      threshold_ms: get(payload, :threshold_ms),
      idle_ms: get(payload, :idle_ms),
      activity_at_ms: get(payload, :activity_at_ms),
      detected_at_ms: get(payload, :detected_at_ms),
      idempotency_key: get(payload, :idempotency_key),
      reason: get(payload, :reason)
    }
  end

  defp maybe_put_status_effect(run, nil, _reason), do: run

  defp maybe_put_status_effect(run, status, reason)
       when status in ["failed", "blocked", "stuck"] do
    run
    |> Map.put(:status, status)
    |> Map.put(:terminal?, status in ["failed", "blocked", "stuck"])
    |> Map.put(:failure_reason, reason)
  end

  # Unknown status_effect (a future/unrecognized value persisted by a newer
  # writer): record it as the latest stall without changing run status, so
  # replay does not crash on a value this reader does not recognize yet.
  defp maybe_put_status_effect(run, _status, _reason), do: run

  defp update_task_latest_stall(state, nil, _stall), do: state

  defp update_task_latest_stall(state, task_id, stall) do
    if valid_id?(task_id) do
      Map.update!(state, :tasks, fn tasks ->
        Map.update(
          tasks,
          task_id,
          %{task_id: task_id, latest_stall: stall, attention_reason: stall.reason},
          fn task ->
            task
            |> Map.put(:latest_stall, stall)
            |> Map.put(:attention_reason, stall.reason)
          end
        )
      end)
    else
      state
    end
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
      status: "awaiting_worker",
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
      failure_reason: nil,
      latest_stall: nil,
      pr_url: nil,
      phase_prs: [],
      notifications: []
    }
  end

  defp filter_runs(runs, opts) do
    status = Keyword.get(opts, :status)
    project_id = Keyword.get(opts, :project_id)

    Enum.filter(runs, fn run ->
      status_match? = is_nil(status) or status == "" or get(run, :status) == status

      project_match? =
        is_nil(project_id) or project_id == "" or get(run, :project_id) == project_id

      status_match? and project_match?
    end)
  end

  defp limit_runs(runs, nil), do: runs
  defp limit_runs(runs, limit) when is_integer(limit) and limit > 0, do: Enum.take(runs, limit)
  defp limit_runs(runs, _limit), do: runs

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

  @run_logs_default_limit 500
  @run_logs_max_limit 5_000
  @run_logs_max_bytes 1_048_576

  # Match the decoded event STRUCT, exactly as `PrAssociated` above does. The
  # bare `%{run_id: _, worker_id: _, sequence: _, line: _}` map pattern this
  # replaced matched by shape, so renaming a field on `Events.WorkerStdout`
  # would have stopped matching and fallen into a `_ -> state` catch-all that
  # silently discarded the log line — the precise failure mode AGENTS.md 5.1
  # and 5.5 exist to prevent.
  #
  # AGENTS.md 5.3: a blank run_id/worker_id is MALFORMED, not absent. It
  # cannot be projected (the entry would have no run to belong to and no
  # stream id), and silently dropping it is indistinguishable from "this
  # worker wrote nothing" — the same confusion the tool's old
  # `:no_log_store` reply created. `WorkerProtocol.emit/2` supplies both, so
  # reaching here means that boundary was bypassed: raise.
  defp project_worker_log(state, decoded, payload, channel)
       when channel in ["stdout", "stderr"] do
    case decoded do
      %{run_id: run_id, worker_id: worker_id} = event
      when is_struct(event, WorkerStdout) or is_struct(event, WorkerStderr) ->
        if is_binary(run_id) and run_id != "" and is_binary(worker_id) and worker_id != "" do
          project_worker_log_entry(state, event, payload, channel, run_id, worker_id)
        else
          raise ArgumentError,
                "ProjectionStore: #{channel} log event with unusable run_id/worker_id: " <>
                  inspect(event)
        end
    end
  end

  defp project_worker_log_entry(state, event, payload, channel, run_id, worker_id) do
    entry = %{
      worker_id: worker_id,
      channel: channel,
      sequence: event.sequence,
      timestamp: event.timestamp || get(payload, :_projection_recorded_at),
      content: event.line || "",
      stream_id: "worker:#{run_id}:#{worker_id}",
      event_number: get(payload, :_projection_event_number),
      stream_version: get(payload, :_projection_stream_version)
    }

    log_state =
      state
      |> Map.get(:run_logs, %{})
      |> Map.get(run_id, empty_run_log_state())
      |> put_log_entry(entry)

    state
    |> touch_run_for_payload(payload)
    |> touch_active_phase_activity(run_id, :output, payload_event_at_ms(payload))
    |> Map.update(:run_logs, %{run_id => log_state}, &Map.put(&1, run_id, log_state))
  end

  defp empty_run_log_state do
    %{entries: :queue.new(), count: 0, bytes: 0, omitted_entries: 0, omitted_bytes: 0}
  end

  # Append is O(1) and evicts at most as many entries as the caps require.
  #
  # The list version of this rebuilt a fresh @run_logs_max_limit-cons-cell
  # list on EVERY log line (`length/1` + `Enum.take/2` + `Enum.drop/2`), and
  # this runs inside the single-writer `ProjectionStore` GenServer that also
  # serves `run/1`, `list_runs/1` and the scheduler's `active_runs/0` — so a
  # chatty worker charged every other projection read for its output.
  #
  # Both caps are needed and they bound different things: `@run_logs_max_limit`
  # bounds entry count, `@run_logs_max_bytes` bounds RESIDENT MEMORY, which
  # entry count alone does not (a line has no intrinsic size limit, and a run
  # may have many workers). This is a memory bound on the read model, distinct
  # from `WorkerLogPolicy`'s bound on how many events are durably WRITTEN —
  # different resources, so not a duplicated boundary (AGENTS.md 5.7). Do not
  # delete one because the other exists. Evictions are always accounted in
  # `omitted_entries`/`omitted_bytes` so a truncated read can never look
  # complete.
  defp put_log_entry(log_state, entry) do
    log_state
    |> Map.update!(:entries, &:queue.in(entry, &1))
    |> Map.update!(:count, &(&1 + 1))
    |> Map.update!(:bytes, &(&1 + byte_size(entry.content)))
    |> evict_over_cap()
  end

  defp evict_over_cap(%{count: count, bytes: bytes} = log_state)
       when count > @run_logs_max_limit or bytes > @run_logs_max_bytes do
    {{:value, oldest}, entries} = :queue.out(log_state.entries)
    size = byte_size(oldest.content)

    evict_over_cap(%{
      log_state
      | entries: entries,
        count: log_state.count - 1,
        bytes: log_state.bytes - size,
        omitted_entries: log_state.omitted_entries + 1,
        omitted_bytes: log_state.omitted_bytes + size
    })
  end

  defp evict_over_cap(log_state), do: log_state

  defp run_logs_result(state, run_id) do
    log_state = state |> Map.get(:run_logs, %{}) |> Map.get(run_id, empty_run_log_state())

    # `:queue.to_list/1` is already oldest-first (the order events were
    # applied), and `Enum.sort_by/2` is stable, so this preserves arrival
    # order and only makes the cross-worker key explicit.
    entries =
      log_state.entries
      |> :queue.to_list()
      |> Enum.sort_by(&log_sort_key/1)

    total = log_state.count
    tail = Enum.take(entries, -@run_logs_default_limit)
    tail_omitted = max(total - length(tail), 0)

    {:ok,
     %{
       run_id: run_id,
       entries: tail,
       count: length(tail),
       limit: @run_logs_default_limit,
       truncated: tail_omitted > 0 or log_state.omitted_entries > 0,
       omitted_entries: log_state.omitted_entries + tail_omitted,
       omitted_bytes: log_state.omitted_bytes,
       max_limit: @run_logs_max_limit
     }}
  end

  defp log_sort_key(entry) do
    {entry.event_number || 0, entry.timestamp || "", entry.worker_id, entry.sequence || 0,
     entry.channel}
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
  #
  # `event_type` is stripped for the same reason and it is NOT cosmetic:
  # `Overwatch.Tracker.dispatch_lifecycle/3` folds `"event_type" => type`
  # into the payload it persists (`tracker.ex:314-324`), so every worker
  # lifecycle event on disk carries it, while no struct under
  # `ForemanServer.Events` declares such a field. `EventCodec.decode!/2`
  # rejects undeclared keys, so decoding a persisted `WorkerStdout` /
  # `WorkerStderr` raised `ArgumentError` inside
  # `rebuild_state_from_event_log/1` — that runs in `init/1`, so the
  # ProjectionStore failed to start and took the whole application down at
  # boot for any event store containing a single worker log event. The
  # handlers that predate this read those payloads with `get/2` instead of
  # decoding them, which is why nothing had hit it before.
  #
  # Strip it HERE, at the one decode boundary, rather than in the worker-log
  # handler: every future typed handler reading a Tracker-produced payload
  # would otherwise re-discover the same crash (AGENTS.md 5.7).
  defp decode_for_projection(event_type, payload)
       when is_binary(event_type) and is_map(payload) do
    EventCodec.decode!(event_type, drop_projection_meta(payload))
  end

  defp with_recorded_projection_metadata(payload, %RecordedEvent{} = recorded, now_ms_fun) do
    payload
    |> with_event_at_ms(recorded_event_at_ms(recorded, now_ms_fun))
    |> Map.put(:_projection_stream_version, recorded.stream_version)
    |> Map.put(:_projection_event_number, recorded.event_number)
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
    |> Map.delete(:_projection_event_number)
    |> Map.delete("_projection_event_number")
    |> Map.delete(:_projection_recorded_at)
    |> Map.delete("_projection_recorded_at")
    |> Map.delete(:event_type)
    |> Map.delete("event_type")
  end

  # `%EventStore.RecordedEvent{}` derives no Jason.Encoder, so it cannot cross
  # the MCP boundary. Project it onto the fields a caller inspecting a run
  # actually needs.
  defp recorded_event_to_map(%RecordedEvent{} = event) do
    %{
      event_number: event.event_number,
      event_id: event.event_id,
      stream_uuid: event.stream_uuid,
      stream_version: event.stream_version,
      event_type: event.event_type,
      created_at: encode_timestamp(event.created_at),
      data: event.data
    }
  end

  # Worker events live on one `worker:<run_id>:<worker_id>` stream per worker,
  # so the worker set for a run is discovered from the stream table: the run
  # projection only records a worker once it goes unresponsive, and the run
  # stream never carries worker events at all.
  defp worker_activity_for_run(run_id) do
    prefix = "worker:#{run_id}:"

    with {:ok, stream_uuids} <- worker_stream_uuids(prefix, 1, []) do
      stream_uuids
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn stream_uuid, {:ok, acc} ->
        case EventStore.read_stream_forward(stream_uuid, 0, 99_999_999) do
          {:ok, events} ->
            {:cont, {:ok, [worker_activity(stream_uuid, prefix, events) | acc]}}

          # A stream listed a moment ago can be hard-deleted before we read it.
          {:error, :stream_not_found} ->
            {:cont, {:ok, acc}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, activity} -> {:ok, Enum.reverse(activity)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # `paginate_streams(search: term)` matches `%term%`, so the prefix is
  # re-checked here: a substring hit elsewhere in a stream id is not a worker
  # stream for this run. Sorting by `stream_uuid` keeps paging stable.
  defp worker_stream_uuids(prefix, page_number, acc) do
    opts = [search: prefix, page_number: page_number, page_size: 100, sort_by: :stream_uuid]

    case EventStore.paginate_streams(opts) do
      {:ok, %Page{entries: entries, total_pages: total_pages}} ->
        acc =
          Enum.reduce(entries, acc, fn %StreamInfo{stream_uuid: stream_uuid}, uuids ->
            if String.starts_with?(stream_uuid, prefix), do: [stream_uuid | uuids], else: uuids
          end)

        if page_number >= total_pages do
          {:ok, acc}
        else
          worker_stream_uuids(prefix, page_number + 1, acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp worker_activity(stream_uuid, prefix, events) do
    heartbeats = Enum.filter(events, &(&1.event_type == "WorkerHeartbeat"))

    %{
      worker_id: String.replace_prefix(stream_uuid, prefix, ""),
      event_count: length(events),
      heartbeat_count: length(heartbeats),
      last_sequence: last_worker_sequence(events),
      last_event_type: last_worker_event_type(events),
      last_event_at: last_worker_event_at(events),
      last_heartbeat_at: last_worker_event_at(heartbeats)
    }
  end

  defp last_worker_event_type([]), do: nil
  defp last_worker_event_type(events), do: List.last(events).event_type

  defp last_worker_event_at([]), do: nil
  defp last_worker_event_at(events), do: encode_timestamp(List.last(events).created_at)

  # `Overwatch.Tracker` allocates a strictly increasing sequence per worker
  # event, so the last event on the stream carries the highest one.
  defp last_worker_sequence([]), do: nil
  defp last_worker_sequence(events), do: get(List.last(events).data, :sequence)

  defp encode_timestamp(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp encode_timestamp(at) when is_binary(at), do: at
  defp encode_timestamp(_), do: nil

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

  # An ABSENT declaration reads as the empty list, because "declared nothing"
  # and "declared an empty list" mean the same thing to the approval guard. A
  # non-list is passed through UNCHANGED so the guard can refuse it: collapsing
  # it to `[]` here is the bug this replaced, and it read as "no dependencies".
  defp normalize_dependencies(nil), do: []
  defp normalize_dependencies(dependency_ids) when is_list(dependency_ids), do: dependency_ids
  defp normalize_dependencies(malformed), do: malformed

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
