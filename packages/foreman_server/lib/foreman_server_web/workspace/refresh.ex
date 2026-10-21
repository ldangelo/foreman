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

  defp relevant?(%{event_type: type} = event, project_id) when is_binary(type) do
    not Enum.any?(@ignored_prefixes, &String.starts_with?(type, &1)) and
      case event_project_id(event) do
        nil -> true
        id -> id == project_id
      end
  end

  defp relevant?(_event, _project_id), do: false

  # Projection events carry atom-keyed data when freshly appended and
  # string-keyed data when replayed from the log; read the project id once, here.
  defp event_project_id(%{data: data}) when is_map(data), do: project_id_of(data)
  defp event_project_id(%{payload: data}) when is_map(data), do: project_id_of(data)
  defp event_project_id(_event), do: nil

  defp project_id_of(%{project_id: id}), do: id
  defp project_id_of(%{"project_id" => id}), do: id
  defp project_id_of(_), do: nil

  defp coalesce_ms do
    :foreman_server
    |> Application.get_env(:workspace, [])
    |> Keyword.get(:coalesce_ms, @default_coalesce_ms)
  end
end
