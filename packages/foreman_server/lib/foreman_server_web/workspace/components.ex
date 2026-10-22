defmodule ForemanServerWeb.Workspace.Components do
  @moduledoc """
  Function components of the project workspace. Everything user- or
  agent-authored (thread titles, branches, reports, conversation text, memory
  content) is interpolated through HEEx, which escapes it; no component calls
  `raw/1` or `Phoenix.HTML.raw/1`. URLs coming from projections are only turned
  into links when they are `http(s)` URLs (`safe_url/1`).
  """

  use Phoenix.Component

  alias ForemanServer.Overview.{Group, ThreadCard}

  @group_titles %{
    ready_for_review: "Ready for review",
    waiting_on_you: "Waiting on you",
    working: "Working",
    landing: "Landing",
    idle: "Idle",
    resolved: "Resolved"
  }

  @doc "Display title of an Overview group."
  @spec group_title(Group.group()) :: String.t()
  def group_title(group), do: Map.fetch!(@group_titles, group)

  @doc "`url` when it is an http(s) URL, else nil (blocks `javascript:` links)."
  @spec safe_url(term()) :: String.t() | nil
  def safe_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  def safe_url(_), do: nil

  attr(:overview, :map, required: true)
  attr(:confirm_stop, :string, default: nil)
  attr(:steer_nonce, :string, required: true)

  @doc "The Overview pane: one labelled section per state group."
  def overview_pane(assigns) do
    assigns = assign(assigns, :groups, Group.all())

    ~H"""
    <section id="overview-pane" aria-labelledby="overview-heading">
      <h2 id="overview-heading">
        Overview
        <span :if={@overview.attention.needed} class="ws-dot" role="img" aria-label={"#{@overview.attention.count} threads need attention"}></span>
      </h2>
      <section :for={group <- @groups} id={"group-#{group}"} aria-labelledby={"group-#{group}-title"}>
        <h3 id={"group-#{group}-title"}>{group_title(group)} <span class="ws-muted">({Map.get(@overview.counts, group, 0)})</span></h3>
        <p :if={Map.get(@overview.groups, group, []) == []} class="ws-muted">Nothing here.</p>
        <.thread_card
          :for={card <- Map.get(@overview.groups, group, [])}
          card={card}
          confirm_stop={@confirm_stop}
          steer_nonce={@steer_nonce}
        />
      </section>
    </section>
    """
  end

  attr(:card, ThreadCard, required: true)
  attr(:confirm_stop, :string, default: nil)
  attr(:steer_nonce, :string, required: true)

  @doc "One thread card with its actions."
  def thread_card(assigns) do
    ~H"""
    <article class="ws-card" id={"thread-#{@card.thread_id}"} aria-label={"Thread: " <> @card.title}>
      <h4>{@card.title}</h4>
      <p class="ws-muted">
        <span>{@card.status}</span>
        <span :if={@card.branch}> · branch {@card.branch}</span>
        <span :if={@card.pr_state}> · PR {@card.pr_state}</span>
      </p>
      <p :if={safe_url(@card.pr_url)}><a href={safe_url(@card.pr_url)} rel="noopener noreferrer" target="_blank">Pull request</a></p>
      <p :if={@card.last_report}>
        Last report: <strong>{@card.last_report.verdict}</strong>
        <span :if={@card.last_report.summary}> - {@card.last_report.summary}</span>
      </p>
      <p :if={@card.failure_reason} class="ws-error">Failure: {@card.failure_reason}</p>
      <p :if={@card.reason == :ci_failing} class="ws-error">CI failing: the PR's checks are red.</p>
      <p :if={@card.hint} class="ws-muted">{@card.hint}</p>
      <div class="thread-actions" role="group" aria-label={"Actions for " <> @card.title}>
        <%= for action <- @card.actions do %>
          <.action_control action={action} card={@card} confirm_stop={@confirm_stop} steer_nonce={@steer_nonce} />
        <% end %>
      </div>
      <div
        :if={@card.pr_actions != []}
        class="thread-pr-actions"
        role="group"
        aria-label={"Pull request actions for " <> @card.title}
      >
        <span :for={a <- @card.pr_actions} class="ws-pr-action">
          <button
            type="button"
            id={"pr-action-#{@card.thread_id}-#{a.kind}"}
            phx-click="pr_action"
            phx-value-kind={a.kind}
            phx-value-thread-id={@card.thread_id}
            phx-value-pr-url={a.pr_url}
            disabled={not a.enabled}
            aria-describedby={if(a.reason, do: "pr-action-#{@card.thread_id}-#{a.kind}-reason")}
          >
            {a.label}
          </button>
          <span
            :if={a.reason}
            id={"pr-action-#{@card.thread_id}-#{a.kind}-reason"}
            class="ws-muted"
          >
            {a.reason}
          </span>
        </span>
      </div>
    </article>
    """
  end

  attr(:action, :string, required: true)
  attr(:card, ThreadCard, required: true)
  attr(:confirm_stop, :string, default: nil)
  attr(:steer_nonce, :string, required: true)

  defp action_control(%{action: "run.cancel"} = assigns) do
    ~H"""
    <%= if @confirm_stop == @card.thread_id do %>
      <button type="button" phx-click="stop" phx-value-thread-id={@card.thread_id}>Confirm stop</button>
      <button type="button" phx-click="cancel_stop">Cancel</button>
    <% else %>
      <button type="button" phx-click="confirm_stop" phx-value-thread-id={@card.thread_id}>Stop</button>
    <% end %>
    """
  end

  defp action_control(%{action: "run.pause"} = assigns) do
    ~H"""
    <button type="button" phx-click="thread_action" phx-value-action="pause" phx-value-thread-id={@card.thread_id}>Pause</button>
    """
  end

  defp action_control(%{action: "run.resume"} = assigns) do
    ~H"""
    <button type="button" phx-click="thread_action" phx-value-action="resume" phx-value-thread-id={@card.thread_id}>Resume</button>
    """
  end

  defp action_control(%{action: "thread.resolve"} = assigns) do
    ~H"""
    <button type="button" phx-click="thread_action" phx-value-action="resolve" phx-value-thread-id={@card.thread_id}>Resolve</button>
    """
  end

  defp action_control(%{action: "thread.reopen"} = assigns) do
    ~H"""
    <button type="button" phx-click="thread_action" phx-value-action="reopen" phx-value-thread-id={@card.thread_id}>Reopen</button>
    """
  end

  defp action_control(%{action: "thread.steer"} = assigns) do
    ~H"""
    <form phx-submit="steer" id={"steer-#{@card.thread_id}"}>
      <input type="hidden" name="thread_id" value={@card.thread_id} />
      <input type="hidden" name="message_id" value={@steer_nonce <> ":" <> @card.thread_id} />
      <label>
        <span>Steer {@card.title}</span>
        <input type="text" name="text" autocomplete="off" maxlength="8000" />
      </label>
      <button type="submit">Send</button>
    </form>
    """
  end

  attr(:messages, :list, required: true)
  attr(:status, :map, default: nil)
  attr(:proposals, :list, default: [])
  attr(:has_earlier, :boolean, default: false)
  attr(:truncated_before_seq, :integer, default: nil)
  attr(:draft_id, :string, required: true)

  @doc "The coordinator conversation pane: log, proposals, health and composer."
  def conversation_pane(assigns) do
    ~H"""
    <section id="conversation-pane" aria-labelledby="conversation-heading">
      <h2 id="conversation-heading">Coordinator</h2>
      <p :if={@status} id="coordinator-health">
        Status: <strong>{@status["status"]}</strong>
        <span :if={@status["consecutive_failures"] > 0}> · {@status["consecutive_failures"]} consecutive failures</span>
        <span :if={@status["last_error"]} class="ws-error"> · last error: {@status["last_error"]["message"]}</span>
        <button :if={@status["status"] == "unhealthy"} type="button" phx-click="restart_coordinator">Restart coordinator</button>
      </p>
      <button :if={@has_earlier} type="button" phx-click="load_earlier">Load earlier messages</button>
      <p :if={@truncated_before_seq} class="ws-muted">Older messages were trimmed (before {@truncated_before_seq}).</p>
      <div id="conversation-log" role="log" aria-live="polite" aria-label="Coordinator conversation">
        <p :if={@messages == []} class="ws-muted">No messages yet. Tell the coordinator what you want done.</p>
        <article :for={m <- @messages} id={"msg-#{m["seq"]}"} class={["ws-card", m["role"] == "operator" && "ws-msg-operator"]}>
          <p class="ws-muted">{m["role"]}<span :if={m["source"]}> via {m["source"]}</span> · {m["at"]}</p>
          <div class="ws-msg">{m["text"]}</div>
        </article>
      </div>
      <div :if={@proposals != []} id="proposals" aria-label="Proposed threads">
        <h3>Proposed threads</h3>
        <article :for={p <- @proposals} class="ws-card" id={"proposal-#{p.task_id}"}>
          <span>{p.title}</span>
          <button :if={p.startable?} type="button" phx-click="start_proposed" phx-value-task-id={p.task_id}>Start</button>
          <span :if={not p.startable?} class="ws-muted">({p.status})</span>
        </article>
      </div>
      <form id="composer" phx-submit="post_message">
        <input type="hidden" name="message_id" value={@draft_id} />
        <label>
          <span>Message the coordinator</span>
          <textarea name="text" rows="3" required></textarea>
        </label>
        <button type="submit">Send</button>
      </form>
    </section>
    """
  end

  attr(:tab, :atom, required: true)
  attr(:tabs, :map, required: true)
  attr(:schedules, :list, required: true)

  @doc "Library / Pull requests / Scheduled tabs."
  def tabs_pane(assigns) do
    ~H"""
    <section id="tabs-pane" aria-label="Project tabs">
      <div role="tablist" aria-label="Project data">
        <button :for={{name, label} <- [library: "Library", pull_requests: "Pull requests", scheduled: "Scheduled"]}
          type="button" role="tab" id={"tab-#{name}"} aria-controls={"panel-#{name}"}
          aria-selected={to_string(@tab == name)} phx-click="tab" phx-value-tab={name}>{label}</button>
      </div>
      <div role="tabpanel" id={"panel-#{@tab}"} aria-labelledby={"tab-#{@tab}"} tabindex="0">
        <.tab_body tab={@tab} tabs={@tabs} schedules={@schedules} />
      </div>
    </section>
    """
  end

  defp tab_body(%{tab: :scheduled} = assigns) do
    ~H"""
    <p :if={@schedules == []} class="ws-muted">No schedules.</p>
    <table :if={@schedules != []}>
      <caption class="ws-muted">Schedules</caption>
      <thead><tr><th scope="col">Name</th><th scope="col">Status</th><th scope="col">Next fire</th><th scope="col">Actions</th></tr></thead>
      <tbody>
        <tr :for={s <- @schedules}>
          <td>{s.name}</td>
          <td>{s.status}</td>
          <td>{s.next_fire_at || "-"}</td>
          <td>
            <button :if={s.status == "active"} type="button" phx-click="schedule" phx-value-op="pause" phx-value-id={s.schedule_id}>Pause {s.name}</button>
            <button :if={s.status == "paused"} type="button" phx-click="schedule" phx-value-op="resume" phx-value-id={s.schedule_id}>Resume {s.name}</button>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp tab_body(%{tab: tab, tabs: tabs} = assigns) do
    assigns = assign(assigns, :data, Map.get(tabs, tab, %{available: false, rows: []}))

    ~H"""
    <p :if={not @data.available} class="ws-muted">Not available yet.</p>
    <p :if={@data[:error]} class="ws-error">This tab failed to load.</p>
    <p :if={@data.available and @data.rows == []} class="ws-muted">Nothing to show.</p>
    <ul :if={@data.available and @tab == :pull_requests}>
      <li :for={row <- @data.rows}>
        <span>{row["title"] || row["run_id"]}</span>
        <span class="ws-muted"> · {row["pr_state"]} · gate {row["merge_gate"]}<span :if={row["review_verdict"]}> · review {row["review_verdict"]}</span></span>
        <a :if={safe_url(row["pr_url"])} href={safe_url(row["pr_url"])} rel="noopener noreferrer" target="_blank">open</a>
      </li>
    </ul>
    <ul :if={@data.available and @tab == :library}>
      <li :for={row <- @data.rows}>{row["name"] || row["path"] || inspect(row)}</li>
    </ul>
    """
  end
end
