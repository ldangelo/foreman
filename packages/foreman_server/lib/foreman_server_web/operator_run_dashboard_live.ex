defmodule ForemanServerWeb.OperatorRunDashboardLive do
  @moduledoc """
  Authenticated operator run-management dashboard.

  Deep links: `/dashboard/runs?run_id=R[&tab=summary|logs|changes|actions][&file=PATH][&token=T]`.
  `run_id` alone opens run R's detail; an unknown or missing `tab` is `summary`. With
  `tab=changes&file=PATH` the Changes tab shows the `git diff` patch of that changed file (a diff,
  not the file; cut at a byte limit with a visible notice). `tab`/`file` are applied in `mount/3`
  before the first refresh and again by `handle_params/3` on `patch` navigation (a no-op when
  already applied). Git evidence and the preview are only read once the socket is connected: the
  dead (HTTP) render runs no git, and the periodic refresh tick never re-reads the preview.
  Links keep `token` only when the page was opened with one.
  """

  use ForemanServerWeb, :live_view

  alias ForemanServerWeb.OperatorDashboard
  alias ForemanServerWeb.Workspace.Components

  @tabs ~w(summary logs changes actions)

  # Maps the run/phase status strings the projections produce onto a colour modifier of the
  # workspace's shared `.chip--*` / `.thread-dot--*` classes. `Workspace.Components.thread_chip/1`
  # is the same idea for threads (there `completed` is deliberately muted, and the `ok` colour is
  # reserved for review groups that no run status maps to).
  @chip_kinds %{
    # run statuses
    "completed" => "muted",
    "in_progress" => "info",
    "awaiting_worker" => "info",
    "failed" => "err",
    "blocked" => "warn",
    "stuck" => "err",
    "paused" => "warn",
    "cancelled" => "warn",
    "deleted" => "muted",
    # phase statuses
    "pending" => "muted",
    "timed_out" => "err"
  }

  @refresh_ms 2_000

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    {:ok,
     socket
     |> assign(:page_title, "Operator Run Dashboard")
     |> assign(:token, param_string(params["token"]))
     |> assign(:selected_run_id, params["run_id"])
     |> assign(:status_filter, params["status"] || "")
     |> assign(:project_filter, params["project_id"] || "")
     |> assign(:limit, params["limit"] || "100")
     |> assign(:runs, [])
     |> assign(:detail, nil)
     |> assign(:detail_error, nil)
     |> assign(:active_tab, normalize_tab(params["tab"]))
     |> assign(:selected_file, param_string(params["file"]))
     |> assign(:file_preview, :absent)
     |> assign(:last_refresh_at, nil)
     |> assign(:stale?, false)
     |> assign(:error, nil)
     |> assign(:action_result, nil)
     |> assign(:action_intent_key, new_action_intent_key())
     |> refresh()
     |> load_preview()}
  end

  @impl true
  def handle_params(params, _uri, socket), do: {:noreply, apply_nav(socket, params)}

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
    {:noreply,
     socket
     |> assign(:selected_run_id, run_id)
     |> clear_file()
     |> refresh()}
  end

  def handle_event("tab", %{"tab" => tab}, socket)
      when tab in ["summary", "logs", "changes", "actions"] do
    socket = socket |> assign(:active_tab, tab) |> clear_file()

    socket =
      if tab == "changes" and socket.assigns.detail do
        detail = socket.assigns.detail
        changes = OperatorDashboard.change_evidence_bounded(detail.run.run_id)
        assign(socket, :detail, %{detail | changes: changes})
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("run-action", %{"action" => action, "run-id" => run_id} = params, socket) do
    reason = params["reason"]
    intent_key = params["intent-key"]

    result =
      case action do
        "stop" -> OperatorDashboard.pause_run(run_id, reason, intent_key)
        "resume" -> OperatorDashboard.resume_run(run_id, reason, intent_key)
        "abandon" -> OperatorDashboard.remove_run(run_id, reason, intent_key)
        "reset" -> OperatorDashboard.reset_run(run_id, reason, intent_key)
        _ -> {:error, :unknown_action}
      end

    message = action_message(result)

    {:noreply,
     socket
     |> assign(:action_result, message)
     |> assign(:action_intent_key, intent_key_after(result, intent_key))
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
    <main id="main" class="ws-main">
      <header class="ws-header">
        <div class="ws-header-title">
          <h1>{@page_title}</h1>
          <p class="ws-muted">Run management dashboard. Existing Jido dashboard remains at <a href="/dashboard">/dashboard</a>.</p>
          <p :if={@last_refresh_at} class="ws-muted">Last refresh: {@last_refresh_at}</p>
        </div>
        <nav class="ws-header-actions" aria-label="Dashboard">
          <button type="button" class="btn ws-btn" phx-click="refresh">Refresh</button>
        </nav>
        <div id="notice" role="status" aria-live="polite" class={(@stale? || @error != nil) && "ws-error"}>
          <p :if={@stale?}>Stale: refresh failed; showing last known state.</p>
          <p :if={@error}>Error: {describe(@error)}</p>
          <p :if={@action_result}>{@action_result}</p>
        </div>
      </header>

      <form class="ws-card" phx-submit="filter" id="run-filters">
        <label>Status <input name="status" value={@status_filter} /></label>
        <label>Project <input name="project_id" value={@project_filter} /></label>
        <label>Limit <input name="limit" value={@limit} /></label>
        <button type="submit" class="btn ws-btn">Apply filters</button>
      </form>

      <div class="ws-layout ws-layout--runs">
        <nav id="run-list" class="ws-threads" aria-label="Runs">
          <h2 id="runs-heading" class="ws-group-title">
            Runs <span class="ws-count">({length(@runs)})</span>
          </h2>
          <p :if={@runs == []} class="ws-muted">No runs found.</p>
          <ul class="thread-rows" :if={@runs != []}>
            <li :for={run <- @runs}>
              <.run_row run={run} selected_id={@selected_run_id} />
            </li>
          </ul>
        </nav>

        <section class="ws-main-col" aria-label="Run detail">
          <%= if @detail do %>
            <header class="ws-header">
              <div class="ws-header-title"><h2>Run {@detail.run.run_id}</h2></div>
              <nav class="ws-header-actions" aria-label="Run status">
                <span class={["chip", "chip--" <> chip_kind(@detail.run.status)]} role="status">{@detail.run.status}</span>
                <span :if={@detail.run.completed_with_errors} class="chip chip--warn" role="status">completed with errors</span>
              </nav>
            </header>
            <div role="tablist" aria-label="Run detail tabs">
              <button type="button" role="tab" class="btn ws-btn" phx-click="tab" phx-value-tab="summary"
                id="dash-tab-summary" aria-controls="dash-panel-summary"
                aria-selected={to_string(@active_tab == "summary")}>Summary</button>
              <button type="button" role="tab" class="btn ws-btn" phx-click="tab" phx-value-tab="logs"
                id="dash-tab-logs" aria-controls="dash-panel-logs"
                aria-selected={to_string(@active_tab == "logs")}>Logs</button>
              <button type="button" role="tab" class="btn ws-btn" phx-click="tab" phx-value-tab="changes"
                id="dash-tab-changes" aria-controls="dash-panel-changes"
                aria-selected={to_string(@active_tab == "changes")}>Changes</button>
              <button type="button" role="tab" class="btn ws-btn" phx-click="tab" phx-value-tab="actions"
                id="dash-tab-actions" aria-controls="dash-panel-actions"
                aria-selected={to_string(@active_tab == "actions")}>Actions</button>
            </div>

            <section :if={@active_tab == "summary"} id="dash-panel-summary" role="tabpanel" aria-labelledby="dash-tab-summary" tabindex="0" class="ws-card">
              <h3>Summary</h3>
              <dl>
                <dt>Status</dt><dd><span class={["chip", "chip--" <> chip_kind(@detail.run.status)]}>{@detail.run.status}</span></dd>
                <dt>Project</dt><dd>{describe(@detail.run.project_id)}</dd>
                <dt>Task</dt><dd>{describe(@detail.run.task_label)}</dd>
                <dt>Current phase</dt><dd>{describe(@detail.run.current_phase_name)}</dd>
                <dt>Workflow</dt><dd>{describe(@detail.run.workflow)}</dd>
                <dt>Latest stall</dt><dd>{describe(@detail.run.latest_stall)}</dd>
                <dt>Failure</dt><dd>{describe(@detail.run.failure_reason)}</dd>
                <dt>PR</dt><dd>{describe(@detail.run.pr_url)}</dd>
              </dl>

              <h3>Phases</h3>
              <ul :if={@detail.phases != []} class="ws-panel-list">
                <li :for={phase <- @detail.phases}>
                  <span class={["chip", "chip--" <> chip_kind(phase.status)]}>{phase.status}</span>
                  <span>{phase.name}</span>
                  <span class="ws-ellipsis" title={describe(phase.artifact)}>artifact={describe(phase.artifact)}</span>
                  <span>stall={describe(phase.latest_stall)}</span>
                  <span>failure={describe(phase.failure_reason)}</span>
                </li>
              </ul>
              <p :if={@detail.phases == []} class="ws-muted">No phases recorded.</p>
            </section>

            <section :if={@active_tab == "logs"} id="dash-panel-logs" role="tabpanel" aria-labelledby="dash-tab-logs" tabindex="0" class="ws-card">
              <h3>Durable worker logs</h3>
              {render_logs(@detail.logs)}
            </section>

            <section :if={@active_tab == "changes"} id="dash-panel-changes" role="tabpanel" aria-labelledby="dash-tab-changes" tabindex="0" class="ws-card">
              <h3>Code changes and PR evidence</h3>
              {render_changes(@detail.changes, %{
                run_id: @detail.run.run_id,
                token: @token,
                selected_file: @selected_file,
                preview: @file_preview
              })}
            </section>

            <section :if={@active_tab == "actions"} id="dash-panel-actions" role="tabpanel" aria-labelledby="dash-tab-actions" tabindex="0" class="ws-card">
              <h3>Run controls</h3>
              <p>Stop pauses the run with reason <code>operator_pause</code>. Cancel is not Stop.</p>
              <form phx-submit="run-action">
                <input type="hidden" name="run-id" value={@detail.run.run_id} />
                <input type="hidden" name="intent-key" value={@action_intent_key} />
                <label>Reason <input name="reason" placeholder="operator reason" /></label>
                <button type="submit" class="btn ws-btn" name="action" value="stop" disabled={!@detail.run.actions.stop.enabled}>Stop / pause</button>
                <button type="submit" class="btn ws-btn" name="action" value="resume" disabled={!@detail.run.actions.resume.enabled}>Resume</button>
                <button type="submit" class="btn ws-btn" name="action" value="reset" disabled={!@detail.run.actions.reset.enabled}>Restart / reset</button>
                <button type="submit" class="btn ws-btn" name="action" value="abandon" disabled={!@detail.run.actions.abandon.enabled}>Abandon / remove</button>
              </form>
            </section>
          <% else %>
            <%= if @detail_error do %>
              <section class="ws-card">
                <h2>Run detail unavailable</h2>
                <p class="ws-error">
                  Could not load run <code>{elem(@detail_error, 0)}</code>: {describe(elem(@detail_error, 1))}
                </p>
              </section>
            <% else %>
              <section class="ws-card">
                <h2>No run selected</h2>
                <p class="ws-muted">Select a run to inspect phases, logs, changes, and safe actions.</p>
              </section>
            <% end %>
          <% end %>
        </section>
      </div>
    </main>
    """
  end

  # `reload_changes?: false` (the periodic 2s timer tick) reuses whatever
  # changes evidence is already assigned instead of re-running the
  # git-backed evidence read on every poll; an explicit operator action
  # (select-run, tab switch, filter, manual refresh, run-action) always
  # reloads it. Either way the read itself is bounded (`OperatorDashboard.change_evidence_bounded/1`).
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
                   connected?(socket),
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

  defp detail_result(run_id, active_tab, connected?, reload_changes?, previous_changes) do
    case OperatorDashboard.run_detail(run_id) do
      {:ok, detail} ->
        changes =
          cond do
            active_tab != "changes" or not connected? ->
              :absent

            reload_changes? or is_nil(previous_changes) ->
              OperatorDashboard.change_evidence_bounded(run_id)

            true ->
              previous_changes
          end

        {:ok, %{detail | changes: changes}}

      {:error, _reason} = error ->
        error
    end
  end

  defp param_string(value) when is_binary(value) and value != "", do: value
  defp param_string(_), do: nil

  defp normalize_tab(tab) when tab in @tabs, do: tab
  defp normalize_tab(_), do: "summary"

  defp clear_file(socket),
    do: socket |> assign(:selected_file, nil) |> assign(:file_preview, :absent)

  # Applies `run_id`/`tab`/`file` from the URL. Idempotent: state that already matches (as right
  # after `mount/3`) loads nothing. A file-only change reuses the loaded changes evidence.
  defp apply_nav(socket, params) do
    run_id = param_string(params["run_id"])
    tab = normalize_tab(params["tab"])
    file = param_string(params["file"])
    assigns = socket.assigns

    run_changed? = run_id != nil and run_id != assigns.selected_run_id
    tab_changed? = tab != assigns.active_tab

    cond do
      run_changed? or tab_changed? ->
        socket
        |> assign(:selected_run_id, run_id || assigns.selected_run_id)
        |> assign(:active_tab, tab)
        |> assign(:selected_file, file)
        |> assign(:file_preview, :absent)
        |> refresh()
        |> load_preview()

      file != assigns.selected_file ->
        socket
        |> assign(:selected_file, file)
        |> assign(:file_preview, :absent)
        |> load_preview()

      true ->
        socket
    end
  end

  # The diff of the selected file, read only on a connected socket, on the Changes tab and for a
  # loaded run. Never called from the periodic tick.
  defp load_preview(socket) do
    case socket.assigns do
      %{active_tab: "changes", selected_file: file, detail: %{run: %{run_id: run_id}}}
      when is_binary(file) ->
        if connected?(socket),
          do: assign(socket, :file_preview, OperatorDashboard.preview_bounded(run_id, file)),
          else: socket

      _ ->
        socket
    end
  end

  defp first_run_id([run | _]), do: run.run_id
  defp first_run_id([]), do: nil

  defp action_message({:ok, %{command: command}}), do: "Command accepted: #{command.type}"

  defp action_message({:error, :dispatch_timeout, command}) do
    "Command result unknown (dispatch timed out): #{command.type} may still be processing. Retrying reuses the same intent key."
  end

  defp action_message({:error, reason, _command}), do: "Command rejected: #{inspect(reason)}"
  defp action_message({:error, reason}), do: "Command rejected: #{inspect(reason)}"

  # A timeout means the outcome is UNKNOWN, not failed -- the append may
  # have already committed on the gateway side. Keep the same intent key so
  # an operator retry of the same confirmed action is deduplicated by
  # CommandGateway/CommandRouter instead of minting a second command_id for
  # what is really one intent. Every definitive outcome (accepted or a real
  # rejection) gets a fresh key for the next, genuinely new action.
  defp intent_key_after({:error, :dispatch_timeout, _command}, current_key), do: current_key
  defp intent_key_after(_result, _current_key), do: new_action_intent_key()

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_ms)
  end

  # Stable per-form-render intent key so a client-side retry of the SAME
  # confirmed run-action (e.g. a LiveView reconnect resending an
  # unacknowledged submit) reuses the same command_id and is deduplicated
  # by CommandGateway/CommandRouter, while a genuinely new action gets a
  # fresh one after each result.
  defp new_action_intent_key do
    Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  defp render_logs({:ok, logs}) do
    assigns = %{logs: logs}

    ~H"""
    <p class="ws-muted">
      <span class="chip chip--muted" role="status">{@logs.count} entries</span>
      <span> · showing up to limit {@logs.limit}</span>
      <span :if={@logs.truncated}> · tail shown, {@logs.omitted_entries} entries ({@logs.omitted_bytes} bytes) omitted</span>
    </p>
    <div id="run-log" class="conv-transcript" role="log" aria-live="polite" aria-label="Run worker logs">
      <div class="conv-inner">
      <article :for={entry <- @logs.entries} id={"log-entry-#{entry.sequence}"} class={["msg", entry_kind(entry.channel)]}>
        <p class="msg-meta">
          <span class="msg-sender">{describe(entry.channel)}</span>
          <span>#{entry.sequence}</span>
        </p>
        <div class="msg-text">{entry.content}</div>
      </article>
      </div>
    </div>
    """
  end

  defp render_logs({:error, :run_not_found}) do
    assigns = %{}

    ~H"""
    <p class="ws-error">run_not_found</p>
    """
  end

  # Worker log channels onto the workspace's message variants (`layouts.ex` styles
  # `.msg--agent`/`.msg--stderr`/`.msg--system`/...); an unrecognised channel reads as system.
  defp entry_kind("stderr"), do: "msg--stderr"
  defp entry_kind("system"), do: "msg--system"
  defp entry_kind("operator"), do: "msg--operator"
  defp entry_kind("agent"), do: "msg--agent"
  defp entry_kind(_), do: "msg--system"

  # The selected file's diff is shown beside any list state: the diff read is independent of the
  # list (and may fail the same way, e.g. git unavailable), so its typed message still appears.
  defp render_changes(changes, ctx) do
    assigns = %{changes: changes, ctx: ctx}

    ~H"""
    {render_change_list(@changes, @ctx)}
    <section :if={@ctx.selected_file} id="change-preview" class="ws-card" aria-live="polite">
      <h4>Diff of {@ctx.selected_file}</h4>
      <p class="ws-muted">This is the <code>git diff</code> patch of the file against the run's base, not the file itself.</p>
      {render_preview(@ctx.preview)}
    </section>
    """
  end

  defp render_change_list({:ok, %{state: :available} = changes}, ctx) do
    assigns = %{changes: changes, ctx: ctx}

    ~H"""
    <p class="ws-muted">
      <span class="chip chip--info" role="status">{length(@changes.files)} files</span>
      <span> · source {describe(@changes.source)}</span>
      <span :if={@changes.truncated?}> · truncated</span>
    </p>
    <ul class="ws-panel-list">
      <li :for={file <- @changes.files}>
        <span class={["chip", change_kind(file.status)]}>{file.status}</span>
        <.link patch={Components.run_detail_path(@ctx.run_id, @ctx.token, tab: "changes", file: file.path)} class="btn--link ws-ellipsis">
          {file.path}
        </.link>
      </li>
    </ul>
    """
  end

  defp render_change_list({:ok, %{state: state} = changes}, _ctx) do
    assigns = %{state: state, meta: Map.get(changes, :meta, %{})}

    ~H"""
    <p class="ws-error">Change evidence unavailable: {describe(@state)}</p>
    {render_meta(@meta)}
    """
  end

  defp render_change_list({:error, reason}, _ctx) do
    assigns = %{reason: reason}

    ~H"""
    <p class="ws-error">Change evidence unavailable: {describe(@reason)}</p>
    """
  end

  defp render_change_list(:absent, _ctx) do
    assigns = %{}

    ~H"""
    <p class="ws-muted">Open the Changes tab to load evidence.</p>
    """
  end

  # `git status --porcelain` letters onto the shared chip modifiers.
  defp change_kind("A"), do: "chip--ok"
  defp change_kind("M"), do: "chip--info"
  defp change_kind("D"), do: "chip--err"
  defp change_kind("R"), do: "chip--info"
  defp change_kind("?"), do: "chip--warn"
  defp change_kind(_), do: "chip--muted"

  # Evidence metadata is an open map; it reads as a list, and never as an inspected struct.
  defp render_meta(meta) when map_size(meta) == 0, do: nil

  defp render_meta(meta) when is_map(meta) do
    assigns = %{meta: meta}

    ~H"""
    <ul class="ws-panel-list">
      <li :for={{key, value} <- @meta}>
        <span>{to_string(key)}</span>
        <span>{describe(value)}</span>
      </li>
    </ul>
    """
  end

  defp render_meta(other) do
    assigns = %{other: other}

    ~H"""
    <p class="ws-muted">{describe(@other)}</p>
    """
  end

  defp render_preview({:ok, %{diff: diff, truncated?: truncated?, bytes: bytes}}) do
    assigns = %{diff: diff, truncated?: truncated?, bytes: bytes}

    ~H"""
    <pre class="ws-msg">{@diff}</pre>
    <p :if={@truncated?} class="ws-muted">Diff truncated: showing {byte_size(@diff)} of {@bytes} bytes</p>
    """
  end

  defp render_preview({:error, reason}) do
    assigns = %{message: preview_error(reason)}

    ~H"""
    <p class="ws-error">{@message}</p>
    """
  end

  defp render_preview(:absent) do
    assigns = %{}

    ~H"""
    <p class="ws-muted">Loading diff…</p>
    """
  end

  defp preview_error(:malformed_path),
    do: "Diff unavailable: the file path is not a safe path inside the repository."

  defp preview_error(:unavailable),
    do:
      "Diff unavailable: this file is not among the run's changed files, or its diff could not be read."

  defp preview_error(:git_unavailable),
    do: "Diff unavailable: git is not available on the server."

  defp preview_error(:evidence_timeout), do: "Diff unavailable: reading the diff timed out."

  # Run/phase fields are `:absent` when the projection has no value, and `nil` in a few others.
  # `inspect/1` leaked those as `:absent` / `nil` / `[status]` brackets on the page; the workspace
  # instead says "not available". Anything unrenderable reads as its inspected term so no value is
  # ever silently dropped.
  defp describe(nil), do: "not available"
  defp describe(:absent), do: "not available"
  defp describe(value) when is_binary(value), do: value
  defp describe(value) when is_boolean(value), do: to_string(value)
  defp describe(value) when is_atom(value), do: Atom.to_string(value)
  defp describe(value), do: inspect(value)

  # The run row mirrors `Workspace.Components.thread_row/1`. It stays a `button` + `phx-click`
  # (not the workspace's `<.link patch=...>`): there is no per-run route to patch to, the detail
  # is loaded by server-side selection.
  attr(:run, ForemanServerWeb.OperatorDashboard.RunDTO, required: true)
  attr(:selected_id, :string, default: nil)

  defp run_row(assigns) do
    ~H"""
    <button type="button" class="thread-row" phx-click="select-run" phx-value-run-id={@run.run_id}
      aria-current={if @run.run_id == @selected_id, do: "page"}>
      <span class="thread-row-title" title={@run.run_id}>{@run.run_id}</span>
      <span class="thread-row-meta">
        <span class={["thread-dot", "thread-dot--" <> chip_kind(@run.status)]} aria-hidden="true"></span>
        <span class={["chip", "chip--" <> chip_kind(@run.status)]}>{@run.status}</span>
        <span>{describe(@run.workflow)}</span>
        <span>{describe(@run.current_phase_name)}</span>
        <span>{describe(@run.pr_marker)}</span>
      </span>
    </button>
    """
  end

  defp chip_kind(status) when is_binary(status), do: Map.get(@chip_kinds, status, "muted")
  defp chip_kind(_status), do: "muted"
end
