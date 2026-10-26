defmodule ForemanServerWeb.Workspace.Refresh do
  @moduledoc """
  Coalesced, subscription-driven refresh shared by the workspace LiveViews.

  A connected view subscribes once to `ProjectionStore.subscribe/1` (live
  events only, no replay). Every projection event of THIS project (or without a
  project id, such as run events) marks the view dirty; the first dirty event
  arms a single `Process.send_after/3` timer and every later event inside the
  window only sets the flag, so N events cost one refresh. There is no
  periodic timer: an idle project causes no work at all. Worker output events
  never trigger a refresh (they carry no state the workspace shows).

  The events are the shapes `ProjectionStore` broadcasts (`%EventData{}`,
  `%RecordedEvent{}` and applied `%{event_type:, payload:}` maps, atom-keyed); any
  other shape raises instead of being guessed at.

  The window is `config :foreman_server, :workspace, coalesce_ms:` (default 250).
  Each refresh emits `[:foreman_server, :workspace, :refresh]` telemetry.
  """

  alias ForemanServer.ProjectionStore

  @default_coalesce_ms 250
  @ignored_prefixes ["Worker"]

  @doc "Subscribes the calling LiveView process and initialises the coalescing state."
  @spec init(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init(socket) do
    if Phoenix.LiveView.connected?(socket),
      do: :ok = ProjectionStore.subscribe(replay_existing: false)

    socket
    |> Phoenix.Component.assign(:refresh_pending?, false)
    |> Phoenix.Component.assign(:refresh_count, 0)
    |> Phoenix.Component.assign(
      :intent_base,
      Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    )
  end

  @doc """
  The idempotency intent for an action taken NOW: this view's random session
  base plus the refresh count. Two clicks before the projection moved on share
  it (so the command id dedupes them); once a refresh happened the page shows a
  new state and the next action gets a new intent.
  """
  @spec intent(Phoenix.LiveView.Socket.t()) :: String.t()
  def intent(socket), do: "#{socket.assigns.intent_base}-#{socket.assigns.refresh_count}"

  @doc """
  Handles a `{:projection_event, event}` message: returns the socket with the
  coalescing timer armed when the event concerns `project_id`.
  """
  @spec note_event(Phoenix.LiveView.Socket.t(), map(), String.t()) :: Phoenix.LiveView.Socket.t()
  def note_event(socket, event, project_id) do
    cond do
      not relevant?(event, project_id) ->
        socket

      socket.assigns.refresh_pending? ->
        socket

      true ->
        Process.send_after(self(), :workspace_refresh, coalesce_ms())
        Phoenix.Component.assign(socket, :refresh_pending?, true)
    end
  end

  @doc "Clears the pending flag and counts the refresh; call before re-reading."
  @spec begin_refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def begin_refresh(socket) do
    :telemetry.execute([:foreman_server, :workspace, :refresh], %{count: 1}, %{pid: self()})

    socket
    |> Phoenix.Component.assign(:refresh_pending?, false)
    |> Phoenix.Component.update(:refresh_count, &(&1 + 1))
  end

  # The one place an event's shape is read. `ProjectionStore` broadcasts what it applied:
  # `%EventData{}` and `%RecordedEvent{}` (their `data` is a typed event struct or an
  # atom-keyed map: the event store serializer writes terms, so keys keep their type) and the
  # `%{event_type:, payload:}` maps `ProjectionStore.apply_events/1` also accepts. The project
  # id is read under its one key, `:project_id`. Any other shape raises: ignoring it, or
  # refreshing for it, would hide the change.
  defp relevant?(event, project_id) do
    {type, payload} = parts(event)

    not Enum.any?(@ignored_prefixes, &String.starts_with?(type, &1)) and
      of_project?(payload, project_id)
  end

  defp parts(%{event_type: type, data: %{} = data}) when is_binary(type), do: {type, data}
  defp parts(%{event_type: type, payload: %{} = data}) when is_binary(type), do: {type, data}

  # An event that names no project (a run event, say) concerns every workspace. A project id
  # that is neither absent nor a string is a defect, not a reason to guess.
  defp of_project?(payload, project_id) do
    case Map.get(payload, :project_id) do
      nil -> true
      id when is_binary(id) -> id == project_id
    end
  end

  defp coalesce_ms do
    :foreman_server
    |> Application.get_env(:workspace, [])
    |> Keyword.get(:coalesce_ms, @default_coalesce_ms)
  end
end
