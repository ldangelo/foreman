defmodule ForemanServerWeb.OperatorRunDashboardLive do
  @moduledoc """
  Authenticated operator run-management dashboard.
  """

  use ForemanServerWeb, :live_view

  alias ForemanServerWeb.OperatorDashboard

  @refresh_ms 2_000

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    {:ok,
     socket
     |> assign(:page_title, "Operator Run Dashboard")
     |> assign(:selected_run_id, params["run_id"])
     |> assign(:status_filter, params["status"] || "")
     |> assign(:project_filter, params["project_id"] || "")
     |> assign(:limit, params["limit"] || "100")
     |> assign(:runs, [])
     |> assign(:detail, nil)
     |> assign(:detail_error, nil)
     |> assign(:active_tab, "summary")
     |> assign(:last_refresh_at, nil)
     |> assign(:stale?, false)
     |> assign(:error, nil)
     |> assign(:action_result, nil)
     |> refresh()}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, refresh(socket)}

  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:status_filter, params["status"] || "")
     |> assign(:project_filter, params["project_id"] || "")
     |> assign(:limit, params["limit"] || "100")
     |> refresh()}
  end

  def handle_event("select-run", %{"run-id" => run_id}, socket) do
    {:noreply, socket |> assign(:selected_run_id, run_id) |> refresh()}
  end

  def handle_event("tab", %{"tab" => tab}, socket)
      when tab in ["summary", "logs", "changes", "actions"] do
    socket = assign(socket, :active_tab, tab)

    socket =
      if tab == "changes" and socket.assigns.detail do
        detail = socket.assigns.detail
        changes = load_changes_bounded(detail.run.run_id)
        assign(socket, :detail, %{detail | changes: changes})
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("run-action", %{"action" => action, "run-id" => run_id} = params, socket) do
    reason = params["reason"]

    result =
      case action do
        "stop" -> OperatorDashboard.pause_run(run_id, reason)
        "resume" -> OperatorDashboard.resume_run(run_id, reason)
        "abandon" -> OperatorDashboard.remove_run(run_id, reason)
        "reset" -> OperatorDashboard.reset_run(run_id, reason)
        _ -> {:error, :unknown_action}
      end

    message = action_message(result)

    {:noreply,
     socket
     |> assign(:action_result, message)
     |> refresh()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, refresh(socket, reload_changes?: false)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="operator-run-dashboard" class="operator-run-dashboard">
      <header>
        <h1>{@page_title}</h1>
        <p>Run management dashboard. Existing Jido dashboard remains at <a href="/dashboard">/dashboard</a>.</p>
        <p :if={@last_refresh_at}>Last refresh: {@last_refresh_at}</p>
        <p :if={@stale?} class="dashboard-stale">Stale: refresh failed; showing last known state.</p>
        <p :if={@error} class="dashboard-error">Error: {inspect(@error)}</p>
        <p :if={@action_result} class="dashboard-action-result">{@action_result}</p>
      </header>

      <form phx-submit="filter" id="run-filters">
        <label>Status <input name="status" value={@status_filter} /></label>
        <label>Project <input name="project_id" value={@project_filter} /></label>
        <label>Limit <input name="limit" value={@limit} /></label>
        <button type="submit">Apply filters</button>
        <button type="button" phx-click="refresh">Refresh</button>
      </form>

      <section class="dashboard-layout">
        <aside class="run-list" aria-label="Runs">
          <h2>Runs</h2>
          <p :if={@runs == []}>No runs found.</p>
          <ul :if={@runs != []}>
            <li :for={run <- @runs}>
              <button type="button" phx-click="select-run" phx-value-run-id={run.run_id}>
                <span class="focus-marker">▶</span>
                <strong>{run.run_id}</strong>
                <span>[{run.status}]</span>
                <span>{run.workflow}</span>
                <span>{run.task_label}</span>
                <span>{run.current_phase_name}</span>
                <span>{run.pr_marker}</span>
              </button>
            </li>
          </ul>
        </aside>

        <section class="run-detail" aria-label="Run detail">
          <%= if @detail do %>
            <h2>Run {@detail.run.run_id}</h2>
            <nav aria-label="Run detail tabs">
              <button phx-click="tab" phx-value-tab="summary">Summary</button>
              <button phx-click="tab" phx-value-tab="logs">Logs</button>
              <button phx-click="tab" phx-value-tab="changes">Changes</button>
              <button phx-click="tab" phx-value-tab="actions">Actions</button>
            </nav>

            <section :if={@active_tab == "summary"}>
              <h3>Summary</h3>
              <dl>
                <dt>Status</dt><dd>{@detail.run.status}</dd>
                <dt>Project</dt><dd>{@detail.run.project_id}</dd>
                <dt>Task</dt><dd>{@detail.run.task_label}</dd>
                <dt>Latest stall</dt><dd>{inspect(@detail.run.latest_stall)}</dd>
                <dt>Failure</dt><dd>{inspect(@detail.run.failure_reason)}</dd>
                <dt>PR</dt><dd>{inspect(@detail.run.pr_url)}</dd>
              </dl>

              <h3>Phases</h3>
              <ol>
                <li :for={phase <- @detail.phases}>
                  <strong>{phase.name}</strong> [{phase.status}] artifact={inspect(phase.artifact)} stall={inspect(phase.latest_stall)} failure={inspect(phase.failure_reason)}
                </li>
              </ol>
            </section>

            <section :if={@active_tab == "logs"}>
              <h3>Durable worker logs</h3>
              {render_logs(@detail.logs)}
            </section>

            <section :if={@active_tab == "changes"}>
              <h3>Code changes and PR evidence</h3>
              {render_changes(@detail.changes)}
            </section>

            <section :if={@active_tab == "actions"}>
              <h3>Run controls</h3>
              <p>Stop pauses the run with reason <code>operator_pause</code>. Cancel is not Stop.</p>
              <form phx-submit="run-action">
                <input type="hidden" name="run-id" value={@detail.run.run_id} />
                <label>Reason <input name="reason" placeholder="operator reason" /></label>
                <button name="action" value="stop" disabled={!@detail.run.actions.stop.enabled}>Stop / pause</button>
                <button name="action" value="resume" disabled={!@detail.run.actions.resume.enabled}>Resume</button>
                <button name="action" value="reset" disabled={!@detail.run.actions.reset.enabled}>Restart / reset</button>
                <button name="action" value="abandon" disabled={!@detail.run.actions.abandon.enabled}>Abandon / remove</button>
              </form>
            </section>
          <% else %>
            <%= if @detail_error do %>
              <h2>Run detail unavailable</h2>
              <p class="dashboard-detail-error">
                Could not load run <code>{elem(@detail_error, 0)}</code>: {inspect(elem(@detail_error, 1))}
              </p>
            <% else %>
              <h2>No run selected</h2>
              <p>Select a run to inspect phases, logs, changes, and safe actions.</p>
            <% end %>
          <% end %>
        </section>
      </section>
    </main>
    """
  end

  # `reload_changes?: false` (the periodic 2s timer tick) reuses whatever
  # changes evidence is already assigned instead of re-running the
  # git-backed evidence read on every poll; an explicit operator action
  # (select-run, tab switch, filter, manual refresh, run-action) always
  # reloads it. Either way the read itself is bounded (`load_changes_bounded/1`).
  defp refresh(socket, opts \\ []) do
    reload_changes? = Keyword.get(opts, :reload_changes?, true)

    params = %{
      status: socket.assigns.status_filter,
      project_id: socket.assigns.project_filter,
      limit: socket.assigns.limit
    }

    with {:ok, runs} <- OperatorDashboard.list_runs(params) do
      selected_run_id = socket.assigns.selected_run_id || first_run_id(runs)
      previous_changes = previous_changes(socket, selected_run_id)

      {detail, detail_error} =
        case selected_run_id do
          nil ->
            {nil, nil}

          :absent ->
            {nil, nil}

          run_id ->
            case detail_result(
                   run_id,
                   socket.assigns.active_tab,
                   reload_changes?,
                   previous_changes
                 ) do
              {:ok, detail} -> {detail, nil}
              {:error, reason} -> {nil, {run_id, reason}}
            end
        end

      socket
      |> assign(:runs, runs)
      |> assign(:selected_run_id, selected_run_id)
      |> assign(:detail, detail)
      |> assign(:detail_error, detail_error)
      |> assign(:last_refresh_at, DateTime.utc_now() |> DateTime.to_iso8601())
      |> assign(:stale?, false)
      |> assign(:error, nil)
    else
      {:error, reason} ->
        socket
        |> assign(:stale?, true)
        |> assign(:error, reason)
    end
  end

  # Only reuse the previously loaded evidence when it belongs to the SAME
  # selected run -- switching runs must never show the prior run's changes.
  defp previous_changes(socket, run_id) do
    case socket.assigns[:detail] do
      %{run: %{run_id: ^run_id}, changes: changes} -> changes
      _ -> nil
    end
  end

  defp detail_result(run_id, active_tab, reload_changes?, previous_changes) do
    case OperatorDashboard.run_detail(run_id) do
      {:ok, detail} ->
        changes =
          cond do
            active_tab != "changes" -> :absent
            reload_changes? or is_nil(previous_changes) -> load_changes_bounded(run_id)
            true -> previous_changes
          end

        {:ok, %{detail | changes: changes}}

      {:error, _reason} = error ->
        error
    end
  end

  @evidence_timeout_ms 3_000

  # Change evidence shells out to git (`ChangeEvidence.for_run/1`). Run it in
  # a bounded task so a slow/hung git command cannot block this LiveView
  # process -- including its filters and run controls -- for longer than
  # @evidence_timeout_ms.
  defp load_changes_bounded(run_id) do
    task = Task.async(fn -> OperatorDashboard.change_evidence(run_id) end)

    case Task.yield(task, @evidence_timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :evidence_timeout}
    end
  end

  defp first_run_id([run | _]), do: run.run_id
  defp first_run_id([]), do: nil

  defp action_message({:ok, %{command: command}}), do: "Command accepted: #{command.type}"
  defp action_message({:error, reason, _command}), do: "Command rejected: #{inspect(reason)}"
  defp action_message({:error, reason}), do: "Command rejected: #{inspect(reason)}"

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_ms)
  end

  defp render_logs({:ok, logs}) do
    assigns = %{logs: logs}

    ~H"""
    <p>count={@logs.count} limit={@logs.limit} truncated={inspect(@logs.truncated)}</p>
    <p :if={@logs.truncated}>Tail shown; omitted entries={@logs.omitted_entries}, omitted bytes={@logs.omitted_bytes}.</p>
    <ol>
      <li :for={entry <- @logs.entries}>
        <span>[{entry.channel}]</span>
        <span>seq={entry.sequence}</span>
        <code>{entry.content}</code>
      </li>
    </ol>
    """
  end

  defp render_logs({:error, :run_not_found}) do
    assigns = %{}

    ~H"""
    <p>run_not_found</p>
    """
  end

  defp render_changes({:ok, %{state: :available} = changes}) do
    assigns = %{changes: changes}

    ~H"""
    <p>source={@changes.source} truncated={inspect(@changes.truncated?)}</p>
    <ul>
      <li :for={file <- @changes.files}>{file.status} {file.path}</li>
    </ul>
    """
  end

  defp render_changes({:ok, %{state: state} = changes}) do
    assigns = %{state: state, changes: changes}

    ~H"""
    <p>Change evidence unavailable: {inspect(@state)} {inspect(Map.get(@changes, :meta, %{}))}</p>
    """
  end

  defp render_changes({:error, reason}) do
    assigns = %{reason: reason}

    ~H"""
    <p>Change evidence unavailable: {inspect(@reason)}</p>
    """
  end

  defp render_changes(:absent) do
    assigns = %{}

    ~H"""
    <p>Open the Changes tab to load evidence.</p>
    """
  end
end
