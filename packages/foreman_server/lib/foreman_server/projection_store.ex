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
  `run_projection/1` returns the projected state for a given run_id.
  `pr_association/1` returns the current PR association for a given run_id.
  """

  use GenServer

  alias EventStore.{EventData, RecordedEvent}
  alias ForemanServer.EventStore

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
  @spec apply_events([EventData.t() | map()]) :: :ok
  def apply_events(events) do
    GenServer.call(__MODULE__, {:apply_events, events, resolve_now_ms_fun()})
  end

  @doc "Return the projected state for a run, or nil if not found."
  @spec run_projection(String.t()) :: map() | nil
  def run_projection(run_id) when is_binary(run_id) do
    GenServer.call(__MODULE__, {:run_projection, run_id})
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

  @doc "Return every projected run."
  @spec list_runs() :: [map()]
  def list_runs do
    GenServer.call(__MODULE__, :list_runs)
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

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:run_projection, run_id}, _from, state) do
    {:reply, Map.get(state.runs, run_id), state}
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
  def handle_call(:list_runs, _from, state) do
    {:reply, Map.values(state.runs), state}
  end

  # -------------------------------------------------------------------------
  # Projection logic
  # -------------------------------------------------------------------------

  defp rebuild_from_event_log(now_ms_fun) when is_function(now_ms_fun, 0) do
    case EventStore.read_all_streams_forward(0, 99_999_999) do
      {:ok, events} ->
        Enum.reduce(events, initial_state(), fn event, acc ->
          apply_event(acc, event, now_ms_fun)
        end)

      {:error, _} ->
        initial_state()
    end
  end

  defp initial_state do
    %{projects: %{}, runs: %{}, pr_associations: %{}}
  end

  defp apply_event(state, %RecordedEvent{} = recorded, now_ms_fun) do
    payload =
      recorded.data
      |> to_payload_map()
      |> with_event_at_ms(recorded_event_at_ms(recorded, now_ms_fun))

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
      put_state(state, Map.put(state.projects, project_id, project_projection(payload, path)), state.runs)
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
        |> put_project_config(get(payload, :config, %{}))

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

      put_state(state, Map.put(state.projects, project_id, project), state.runs)
    else
      state
    end
  end

  defp apply_event_by_type(state, "RunStarted", payload) do
    run_id = get(payload, :run_id)

    if valid_id?(run_id) do
      event_at_ms = payload_event_at_ms(payload)

      run =
        base_run_projection(run_id, event_at_ms)
        |> Map.put(:status, "in_progress")
        |> Map.put(:task_id, get(payload, :task_id))
        |> Map.put(:started_at_ms, event_at_ms)
        |> Map.put(:last_event_at_ms, event_at_ms)
        |> Map.put(:terminal?, false)

      put_state(state, state.projects, Map.put(state.runs, run_id, run))
    else
      state
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

  defp apply_event_by_type(state, "PhaseStarted", payload) do
    touch_run_for_payload(state, payload)
  end

  defp apply_event_by_type(state, "PhaseCompleted", payload) do
    touch_run_for_payload(state, payload)
  end

  defp apply_event_by_type(state, "PhaseFailed", payload) do
    touch_run_for_payload(state, payload)
  end

  defp apply_event_by_type(state, "PhaseTimedOut", payload) do
    touch_run_for_payload(state, payload)
  end

  defp apply_event_by_type(state, "PhaseRetried", payload) do
    touch_run_for_payload(state, payload)
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

  defp apply_event_by_type(state, "ToolCallFinished", payload) do
    touch_run_for_payload(state, payload)
  end

  defp apply_event_by_type(state, _type, _payload), do: state

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
      health: get(payload, :health, %{ok: true}),
      name: get(payload, :name)
    }
  end

  defp put_project_config(project, config) do
    Map.put(project, :config, shallow_merge(get(project, :config, %{}), config))
  end

  defp shallow_merge(left, right) when is_map(left) and is_map(right) do
    Enum.reduce(right, left, fn {key, value}, acc -> Map.put(acc, key, value) end)
  end

  defp shallow_merge(_left, right) when is_map(right), do: right
  defp shallow_merge(left, _right), do: left

  defp apply_terminal_run_event(state, payload, status) do
    update_run_projection(state, get(payload, :run_id), payload_event_at_ms(payload), fn run ->
      run
      |> maybe_put(:task_id, get(payload, :task_id))
      |> Map.put(:status, status)
      |> Map.put(:terminal?, true)
    end)
  end

  defp touch_run_for_payload(state, payload) do
    update_run_projection(state, get(payload, :run_id), payload_event_at_ms(payload), fn run -> run end)
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
      started_at_ms: now_ms,
      last_event_at_ms: now_ms,
      terminal?: false
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
    pr_associations = Map.get(state, :pr_associations, %{})
    %{projects: projects, runs: runs, pr_associations: pr_associations}
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
