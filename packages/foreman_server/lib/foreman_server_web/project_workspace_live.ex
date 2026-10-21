defmodule ForemanServerWeb.ProjectWorkspaceLive do
  @moduledoc """
  The project workspace: `GET /dashboard/projects/:id` (authenticated).

  Left, the coordinator conversation (E15 via `ForemanServer.CoordinatorAPI`);
  right, the Overview (E7: threads grouped by state with the E6 thread cards and
  their existing actions) and the Library / Pull requests / Scheduled tabs.

  Reads and writes go through the same Elixir functions the HTTP API uses (see
  `ForemanServerWeb.Workspace.Actions`); there is no HTTP-to-self call and no
  new mutation path. Updates arrive through one `ProjectionStore` subscription
  with a coalescing window (`ForemanServerWeb.Workspace.Refresh`): no periodic
  polling. A tab or conversation that is not shown costs nothing on refresh.
  """

  use ForemanServerWeb, :live_view

  require Logger

  alias ForemanServer.{CoordinatorAPI, Overview, ProjectionStore, ProjectStore}
  alias ForemanServer.Schedule.DTO, as: ScheduleDTO
  alias ForemanServerWeb.Workspace.{Actions, Components, ProjectNotFound, ProjectView, Refresh}

  @tail 50
  @page 200
  @max_kept 400
  @tabs %{"library" => :library, "pull_requests" => :pull_requests, "scheduled" => :scheduled}
  @thread_actions ~w(pause resume resolve reopen)
  @schedule_ops %{"pause" => :pause, "resume" => :resume}

  @impl true
  def mount(%{"id" => project_id}, _session, socket) do
    case ProjectStore.get(project_id) do
      nil ->
        raise ProjectNotFound, project_id: project_id

      project ->
        socket =
          socket
          |> Refresh.init()
          |> assign(
            page_title: "Project #{project_id}",
            project_id: project_id,
            project_view: ProjectView.build(project, project_id),
            tab: :library,
            notice: nil,
            notice_kind: :ok,
            confirm_stop: nil,
            steer_nonce: nonce(),
            draft_id: draft_id(),
            messages: [],
            cursor: 0,
            first_seq: nil,
            has_earlier: false,
            truncated_before_seq: nil,
            status: nil,
            proposals: [],
            schedules: []
          )
          |> load_conversation_tail()
          |> load_state()

        {:ok, socket}
    end
  end

  @impl true
  def handle_info({:projection_event, event}, socket),
    do: {:noreply, Refresh.note_event(socket, event, socket.assigns.project_id)}

  def handle_info(:workspace_refresh, socket) do
    {:noreply, socket |> Refresh.begin_refresh() |> refresh_conversation() |> load_state()}
  end

  def handle_info(other, socket) do
    Logger.warning("workspace received an unexpected message: #{inspect(other, limit: 5)}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket) when is_map_key(@tabs, tab) do
    {:noreply, socket |> assign(:tab, Map.fetch!(@tabs, tab)) |> load_state()}
  end

  def handle_event("confirm_stop", %{"thread-id" => id}, socket),
    do: {:noreply, assign(socket, :confirm_stop, id)}

  def handle_event("cancel_stop", _params, socket),
    do: {:noreply, assign(socket, :confirm_stop, nil)}

  def handle_event("stop", %{"thread-id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:confirm_stop, nil)
     |> notify(Actions.stop_thread(socket.assigns.project_id, id, Refresh.intent(socket)))}
  end

  def handle_event("thread_action", %{"action" => action, "thread-id" => id}, socket)
      when action in @thread_actions do
    project_id = socket.assigns.project_id
    intent = Refresh.intent(socket)

    result =
      case action do
        "pause" -> Actions.run_control(project_id, id, :pause, intent)
        "resume" -> Actions.run_control(project_id, id, :resume, intent)
        "resolve" -> Actions.set_resolved(project_id, id, :resolve, intent)
        "reopen" -> Actions.set_resolved(project_id, id, :reopen, intent)
      end

    {:noreply, notify(socket, result)}
  end

  def handle_event(
        "steer",
        %{"thread_id" => id, "text" => text, "message_id" => message_id},
        socket
      ) do
    result = Actions.steer_thread(socket.assigns.project_id, id, text, message_id)
    socket = if match?({:ok, _}, result), do: assign(socket, :steer_nonce, nonce()), else: socket
    {:noreply, notify(socket, result)}
  end

  def handle_event("post_message", %{"text" => text, "message_id" => message_id}, socket) do
    case String.trim(text) do
      "" ->
        {:noreply, notify(socket, {:error, "Write a message first."})}

      _ ->
        result = Actions.post_coordinator_message(socket.assigns.project_id, text, message_id)

        socket =
          if match?({:ok, _}, result), do: assign(socket, :draft_id, draft_id()), else: socket

        {:noreply, socket |> notify(result) |> refresh_conversation() |> load_state()}
    end
  end

  def handle_event("load_earlier", _params, socket), do: {:noreply, load_earlier(socket)}

  def handle_event("restart_coordinator", _params, socket) do
    {:noreply,
     socket |> notify(Actions.restart_coordinator(socket.assigns.project_id)) |> load_state()}
  end

  def handle_event("start_proposed", %{"task-id" => task_id}, socket) do
    {:noreply,
     notify(
       socket,
       Actions.start_proposed(socket.assigns.project_id, task_id, Refresh.intent(socket))
     )}
  end

  def handle_event("schedule", %{"op" => op, "id" => id}, socket)
      when is_map_key(@schedule_ops, op) do
    {:noreply,
     notify(
       socket,
       Actions.schedule_control(
         socket.assigns.project_id,
         id,
         Map.fetch!(@schedule_ops, op),
         Refresh.intent(socket)
       )
     )}
  end

  # -- state -----------------------------------------------------------------

  defp notify(socket, {kind, message}), do: assign(socket, notice: message, notice_kind: kind)

  # Overview, project row, coordinator health and proposals on every refresh;
  # the schedules only while their tab is shown.
  defp load_state(socket) do
    project_id = socket.assigns.project_id
    {:ok, overview} = Overview.build(project_id, include_resolved: true)
    status = status(project_id)

    socket
    |> assign(
      project_view: project_view(project_id, socket),
      overview: overview,
      status: status,
      proposals: proposals(project_id)
    )
    |> assign(:schedules, schedules(socket))
  end

  defp project_view(project_id, socket) do
    case ProjectStore.get(project_id) do
      %{} = project -> ProjectView.build(project, project_id)
      nil -> socket.assigns.project_view
    end
  end

  defp status(project_id) do
    case CoordinatorAPI.status_view(project_id) do
      {:ok, status} -> status
      {:error, _} -> nil
    end
  end

  defp schedules(%{assigns: %{tab: :scheduled, project_id: project_id}}),
    do: ScheduleDTO.list(project_id)

  defp schedules(_socket), do: []

  defp proposals(project_id) do
    case ProjectionStore.coordinator_state(project_id) do
      {:ok, conv} ->
        for task_id <- conv |> Actions.proposed_task_ids() |> Enum.uniq() do
          task = ProjectionStore.task_projection(task_id) || %{}
          status = Map.get(task, :status) || "unknown"

          %{
            task_id: task_id,
            title: Map.get(task, :title) || task_id,
            status: status,
            startable?: status == "open" and Map.get(task, :project_id) == project_id
          }
        end

      {:error, _} ->
        []
    end
  end

  defp load_conversation_tail(socket) do
    project_id = socket.assigns.project_id

    with {:ok, conv} <- ProjectionStore.coordinator_state(project_id),
         after_seq = max(conv.next_seq - 1 - @tail, 0),
         {:ok, page} <- CoordinatorAPI.read_page(project_id, after: after_seq, limit: @page) do
      socket
      |> assign(messages: page["messages"], cursor: cursor(page, after_seq))
      |> assign(truncated_before_seq: page["truncated_before_seq"])
      |> track_first()
    else
      _ -> socket
    end
  end

  defp refresh_conversation(socket) do
    case CoordinatorAPI.read_page(socket.assigns.project_id,
           after: socket.assigns.cursor,
           limit: @page
         ) do
      {:ok, %{"messages" => []}} ->
        socket

      {:ok, page} ->
        messages = Enum.take(socket.assigns.messages ++ page["messages"], -@max_kept)

        socket
        |> assign(messages: messages, cursor: cursor(page, socket.assigns.cursor))
        |> track_first()

      {:error, _} ->
        socket
    end
  end

  defp load_earlier(socket) do
    %{project_id: project_id, first_seq: first_seq} = socket.assigns
    after_seq = max(first_seq - 1 - @tail, 0)

    case CoordinatorAPI.read_page(project_id, after: after_seq, limit: @tail) do
      {:ok, page} ->
        older = Enum.filter(page["messages"], &(&1["seq"] < first_seq))

        socket
        |> assign(:messages, older ++ socket.assigns.messages)
        |> track_first()

      {:error, _} ->
        socket
    end
  end

  defp track_first(socket) do
    first = socket.assigns.messages |> List.first() |> then(&(&1 && &1["seq"]))
    trunc = socket.assigns.truncated_before_seq

    assign(socket,
      first_seq: first,
      has_earlier: is_integer(first) and first > max(trunc || 1, 1)
    )
  end

  defp cursor(%{"messages" => [], "next_cursor" => next}, fallback), do: next || fallback

  defp cursor(%{"messages" => messages, "next_cursor" => next}, _fallback),
    do: next || List.last(messages)["seq"]

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
  defp draft_id, do: "dash-" <> nonce()

  # -- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main" class="ws-main">
      <header>
        <h1>{@project_view.name}</h1>
        <nav aria-label="Project">
          <.link navigate={"/dashboard/projects/#{@project_id}/settings"}>Settings</.link>
        </nav>
        <p :if={@project_view.status == "paused"} class="ws-error" role="status">This project is paused.</p>
        <div id="notice" role="status" aria-live="polite" class={@notice_kind == :error && "ws-error"}>{@notice}</div>
      </header>
      <div class="ws-layout">
        <Components.conversation_pane
          messages={@messages}
          status={@status}
          proposals={@proposals}
          has_earlier={@has_earlier}
          truncated_before_seq={@truncated_before_seq}
          draft_id={@draft_id}
        />
        <div>
          <div id="overview-live" aria-live="polite" aria-relevant="additions text">
            <Components.overview_pane overview={@overview} confirm_stop={@confirm_stop} steer_nonce={@steer_nonce} />
          </div>
          <Components.tabs_pane tab={@tab} tabs={@overview.tabs} schedules={@schedules} />
        </div>
      </div>
    </main>
    """
  end
end
