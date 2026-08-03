defmodule ForemanServer.ProjectionStore do
  @moduledoc """
  In-memory projection read model for domain queries.

  Maintains projected state for projects (and eventually other entities) by applying
  confirmed events synchronously after each successful append.

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
  """

  use GenServer
  alias EventStore.{EventData, RecordedEvent}
  alias ForemanServer.EventStore

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc "Return the projected state for a project, or nil if not found."
  @spec project(String.t()) :: map() | nil
  def project(project_id) do
    GenServer.call(__MODULE__, {:project, project_id})
  end

  @doc """
  Apply a list of confirmed events to the projection.

  Called by CommandRouter after a successful append, before replying to the actor.
  """
  @spec apply_events([EventData.t()]) :: :ok
  def apply_events(events) do
    GenServer.call(__MODULE__, {:apply_events, events})
  end

  # -------------------------------------------------------------------------
  # GenServer callbacks
  # -------------------------------------------------------------------------

  @impl true
  def init(_init_arg) do
    state = rebuild_from_event_log()
    {:ok, state}
  end

  @impl true
  def handle_call({:project, project_id}, _from, state) do
    {:reply, Map.get(state, project_id), state}
  end

  @impl true
  def handle_call({:apply_events, events}, _from, state) do
    new_state = Enum.reduce(events, state, fn event, acc -> apply_event(acc, event) end)
    {:reply, :ok, new_state}
  end

  # -------------------------------------------------------------------------
  # Projection logic
  # -------------------------------------------------------------------------

  defp rebuild_from_event_log do
    case EventStore.read_all_streams_forward(0, 99_999_999) do
      {:ok, events} -> Enum.reduce(events, %{}, fn event, acc -> apply_event(acc, event) end)
      {:error, _} -> %{}
    end
  end

  # RecordedEvent from stream replay
  defp apply_event(state, %RecordedEvent{} = recorded) do
    type = recorded.event_type
    payload = recorded.data
    apply_event_by_type(state, type, payload)
  end

  # EventData from CommandRouter's append (already-normalized)
  defp apply_event(state, %EventData{} = event_data) do
    apply_event_by_type(state, event_data.event_type, event_data.data)
  end

  # Plain map (e.g., from tests)
  defp apply_event(state, %{event_type: type, payload: payload}) do
    apply_event_by_type(state, type, payload)
  end

  defp apply_event(state, event) when is_map(event) do
    type = Map.get(event, :event_type) || Map.get(event, "event_type")
    payload = Map.get(event, :data) || Map.get(event, "data") || Map.get(event, :payload) || Map.get(event, "payload") || event
    apply_event_by_type(state, type, payload)
  end

  defp apply_event_by_type(state, "ProjectRegistered", payload) do
    project_id = get(payload, :project_id)
    path = get(payload, :path)

    if project_id do
      Map.put(state, project_id, project_projection(payload, path))
    else
      state
    end
  end

  defp apply_event_by_type(state, "ProjectUpdated", payload) do
    project_id = get(payload, :project_id)

    if project_id do
      Map.update(state, project_id, project_projection(payload, nil), fn project ->
        project
        |> maybe_put(:path, get(payload, :path))
        |> maybe_put(:status, get(payload, :status))
        |> maybe_put(:default_branch, get(payload, :default_branch))
        |> maybe_put(:health, get(payload, :health))
        |> maybe_put(:name, get(payload, :name))
        |> put_project_config(get(payload, :config, %{}))
      end)
    else
      state
    end
  end

  defp apply_event_by_type(state, "ProjectArchived", payload) do
    project_id = get(payload, :project_id)

    if project_id do
      Map.update(state, project_id, %{status: "archived", archived?: true}, fn project ->
        project
        |> Map.put(:status, "archived")
        |> Map.put(:archived?, true)
      end)
    else
      state
    end
  end

  defp apply_event_by_type(state, "ProjectReactivated", payload) do
    project_id = get(payload, :project_id)

    if project_id do
      Map.update(state, project_id, %{status: "active", archived?: false}, fn project ->
        project
        |> Map.put(:status, "active")
        |> Map.put(:archived?, false)
      end)
    else
      state
    end
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

  defp maybe_put(project, _key, nil), do: project
  defp maybe_put(project, key, value), do: Map.put(project, key, value)

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------

  defp get(%{} = m, k), do: get(m, k, nil)
  defp get(%{} = m, k, default) when is_atom(k) do
    Map.get(m, k, Map.get(m, Atom.to_string(k), default))
  end

  defp get(%{} = m, k, default), do: Map.get(m, k, default)
end
