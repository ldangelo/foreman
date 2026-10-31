defmodule ForemanServerWeb.Workspace.Components do
  @moduledoc """
  Function components of the project workspace. Everything user- or
  agent-authored (thread titles, branches, reports, conversation text, memory
  content) is interpolated through HEEx, which escapes it; no component calls
  `raw/1` or `Phoenix.HTML.raw/1`. URLs coming from projections are only turned
  into links when they are `http(s)` URLs (`safe_url/1`).
  """

  use Phoenix.Component

  alias ForemanServer.Aggregates.OperatorQuestion
  alias ForemanServer.Library
  alias ForemanServer.Overview.{Group, ThreadCard}
  alias ForemanServerWeb.Workspace.LibraryUpload
  alias Phoenix.LiveView.UploadConfig

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
      <p :if={@card.reason == :changes_requested} class="ws-error">Changes requested: a reviewer asked for changes on the PR.</p>
      <p :if={@card.reason == :review_threads} class="ws-error">Review threads unresolved: the PR has open review comments.</p>
      <p :if={@card.hint} class="ws-muted">{@card.hint}</p>
      <div class="thread-actions" role="group" aria-label={"Actions for " <> @card.title}>
        <%= for action <- @card.actions do %>
          <.action_control action={action} card={@card} confirm_stop={@confirm_stop} steer_nonce={@steer_nonce} />
        <% end %>
      </div>
      <div
        :if={@card.approvals != []}
        class="thread-approvals"
        role="group"
        aria-label={"Tool approvals for " <> @card.title}
      >
        <div
          :for={a <- @card.approvals}
          class="ws-approval"
          id={"approval-#{@card.thread_id}-#{a.tool_call_id}"}
        >
          <span>
            <strong>{a.tool_name}</strong> <code :if={a.input_summary}>{a.input_summary}</code>
          </span>
          <span class="ws-muted">{approval_note(a)}</span>
          <button
            type="button"
            phx-click="decide_approval"
            phx-value-decision="approve"
            phx-value-thread-id={@card.thread_id}
            phx-value-run-id={a.run_id}
            phx-value-tool-call-id={a.tool_call_id}
          >
            Approve
          </button>
          <button
            type="button"
            phx-click="decide_approval"
            phx-value-decision="deny"
            phx-value-thread-id={@card.thread_id}
            phx-value-run-id={a.run_id}
            phx-value-tool-call-id={a.tool_call_id}
          >
            Deny
          </button>
        </div>
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

  defp approval_note(%{approval_delivery: "inflight"}), do: "the agent is waiting on this call"
  defp approval_note(_approval), do: "approving resumes the paused run"

  attr(:questions, :list, required: true)

  @doc """
  The project's open operator questions (`Questions.DTO`, oldest first), each with the
  form that answers it. Nothing is rendered when none is open. Question text and the
  asker are agent-authored: HEEx escapes them.
  """
  def questions_pane(assigns) do
    ~H"""
    <section :if={@questions != []} id="questions-pane" aria-labelledby="questions-heading">
      <h2 id="questions-heading">
        Questions for you <span class="ws-muted">({length(@questions)})</span>
      </h2>
      <article
        :for={q <- @questions}
        class="ws-card"
        id={question_dom_id(q)}
        aria-labelledby={question_dom_id(q) <> "-text"}
      >
        <p class="ws-msg" id={question_dom_id(q) <> "-text"}>{q.text || "The agent asked without a question text."}</p>
        <p class="ws-muted">{question_meta(q)}</p>
        <form id={question_dom_id(q) <> "-form"} phx-submit="answer_question">
          <input type="hidden" name="run_id" value={q.run_id} />
          <input type="hidden" name="question_id" value={q.question_id} />
          <%!-- phx-update="ignore": LiveView rewrites an input the browser does not have focused from the
               server's markup, which would wipe a typed answer at the next refresh. The text belongs to
               the browser until it is submitted or the question leaves the pane. --%>
          <label>
            <span>Your answer</span>
            <textarea id={question_dom_id(q) <> "-answer"} name="text" rows="3" maxlength={OperatorQuestion.max_answer_chars(q.question_id)} required phx-update="ignore" aria-describedby={question_dom_id(q) <> "-text"}></textarea>
          </label>
          <button type="submit">Answer</button>
        </form>
      </article>
    </section>
    """
  end

  defp question_dom_id(q), do: "question-#{q.run_id}-#{q.question_id}"

  # Who asked, in which run (a question outside any run says nothing) and when.
  defp question_meta(q) do
    [
      q.agent_id && "asked by #{q.agent_id}",
      q.run_id != ForemanServer.Aggregates.OperatorQuestion.global_run() && "run #{q.run_id}",
      q.opened_at
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  # The plain buttons of a thread card: `ThreadCard` action id => {the `thread_action` event
  # value it sends, its label}. The values the page accepts (`thread_actions/0`) come from this
  # table, so a card cannot offer a button the page would refuse. An action id with no
  # control at all (not here, not `run.cancel`, not `thread.steer`) raises when rendered.
  @thread_buttons %{
    "run.pause" => {"pause", "Pause"},
    "run.resume" => {"resume", "Resume"},
    "thread.resolve" => {"resolve", "Resolve"},
    "thread.reopen" => {"reopen", "Reopen"}
  }

  @doc "The `thread_action` event values the thread cards send."
  @spec thread_actions() :: [String.t()]
  def thread_actions, do: for({value, _label} <- Map.values(@thread_buttons), do: value)

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

  defp action_control(%{action: action} = assigns) when is_map_key(@thread_buttons, action) do
    {value, label} = Map.fetch!(@thread_buttons, action)
    assigns = assign(assigns, value: value, label: label)

    ~H"""
    <button type="button" phx-click="thread_action" phx-value-action={@value} phx-value-thread-id={@card.thread_id}>{@label}</button>
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
        <article :for={p <- @proposals} class="ws-card" id={"proposal-#{p.task_id}"} aria-label={"Proposal: " <> p.title}>
          <span>{p.title}</span>
          <button :if={p.startable?} type="button" phx-click="start_proposed" phx-value-task-id={p.task_id}>Start</button>
          <button :if={p.startable?} type="button" phx-click="decline_proposed" phx-value-task-id={p.task_id}>Decline</button>
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
  attr(:upload, UploadConfig, required: true)
  attr(:folder_upload, UploadConfig, required: true)
  attr(:replace_upload, UploadConfig, required: true)
  attr(:library_name, :string, default: "")
  attr(:library_folder_name, :string, default: "")
  attr(:confirm_remove, :string, default: nil)
  attr(:confirm_delete, :string, default: nil)
  attr(:replace_entry, :map, default: nil)
  attr(:open_entry, :map, default: nil)
  attr(:library_limits, :map, required: true)

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
        <.tab_body
          tab={@tab}
          tabs={@tabs}
          schedules={@schedules}
          upload={@upload}
          folder_upload={@folder_upload}
          replace_upload={@replace_upload}
          library_name={@library_name}
          library_folder_name={@library_folder_name}
          confirm_remove={@confirm_remove}
          confirm_delete={@confirm_delete}
          replace_entry={@replace_entry}
          open_entry={@open_entry}
          library_limits={@library_limits}
        />
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
            <%= if @confirm_delete == s.schedule_id do %>
              <button type="button" phx-click="schedule_delete" phx-value-id={s.schedule_id}>Confirm delete {s.name}</button>
              <button type="button" phx-click="schedule_cancel_delete">Cancel</button>
            <% else %>
              <button type="button" phx-click="schedule_confirm_delete" phx-value-id={s.schedule_id}>Delete {s.name}</button>
            <% end %>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp tab_body(%{tab: :library, tabs: tabs} = assigns) do
    assigns = assign(assigns, :data, Map.get(tabs, :library, %{available: false, rows: []}))

    ~H"""
    <p :if={not @data.available} class="ws-muted">Not available yet.</p>
    <p :if={@data[:error]} class="ws-error">This tab failed to load.</p>
    <p :if={@data.available and @data.rows == []} class="ws-muted">Nothing to show.</p>
    <ul :if={@data.available and @data.rows != []} id="library-list">
      <li :for={row <- @data.rows} id={"library-entry-#{row["entry_id"]}"}>
        <strong>{row["name"]}</strong>
        <span class="ws-muted"> · {row["kind"]} · {files_label(row["file_count"])} · {format_bytes(row["bytes"])}</span>
        <button type="button" phx-click="library_files" phx-value-entry-id={row["entry_id"]} aria-expanded={to_string(for_row?(@open_entry, row))}>Files of {row["name"]}</button>
        <button :if={row["kind"] in ["file", "folder"]} type="button" phx-click="library_replace_open" phx-value-entry-id={row["entry_id"]}>Replace {row["name"]}</button>
        <%= if @confirm_remove == row["entry_id"] do %>
          <button type="button" phx-click="library_remove" phx-value-entry-id={row["entry_id"]}>Confirm remove {row["name"]}</button>
          <button type="button" phx-click="library_cancel_remove">Cancel</button>
        <% else %>
          <button type="button" phx-click="library_confirm_remove" phx-value-entry-id={row["entry_id"]}>Remove {row["name"]}</button>
        <% end %>
        <.entry_files :if={for_row?(@open_entry, row)} entry={@open_entry} name={row["name"]} />
        <.replace_form :if={for_row?(@replace_entry, row)} entry={@replace_entry} name={row["name"]} upload={@replace_upload} library_limits={@library_limits} />
      </li>
    </ul>
    <.library_upload upload={@upload} library_name={@library_name} library_limits={@library_limits} />
    <.library_folder_upload upload={@folder_upload} folder_name={@library_folder_name} library_limits={@library_limits} />
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
        <span class="ws-muted"> · {row["pr_state"]} · gate {row["merge_gate"]}<span :if={row["repo_id"]}> · repo {row["repo_id"]}</span><span :if={row["review_verdict"]}> · review {row["review_verdict"]}</span></span>
        <a :if={safe_url(row["pr_url"])} href={safe_url(row["pr_url"])} rel="noopener noreferrer" target="_blank">open</a>
      </li>
    </ul>
    """
  end

  # True when `state` (`%{entry_id: ...}`: the open file list or the replace form) belongs to the row.
  defp for_row?(%{entry_id: id}, %{"entry_id" => id}), do: true
  defp for_row?(_state, _row), do: false

  attr(:entry, :map, required: true)
  attr(:name, :string, required: true)

  # The files of one entry, each with a Download button that asks the server for its bytes
  # (`Library.read/3`: at most `Library.read_max_bytes/0`; bigger files are listed without one).
  defp entry_files(assigns) do
    assigns = assign(assigns, :read_max, Library.read_max_bytes())

    ~H"""
    <ul id={"library-files-#{@entry.entry_id}"} aria-label={"Files of " <> @name}>
      <li :for={file <- @entry.files}>
        <span>{file.path}</span>
        <span class="ws-muted">({format_bytes(file.bytes)})</span>
        <button :if={file.bytes <= @read_max} type="button" phx-click="library_download" phx-value-entry-id={@entry.entry_id} phx-value-path={file.path}>Download {file.path}</button>
        <span :if={file.bytes > @read_max} class="ws-muted">over the {format_bytes(@read_max)} read limit</span>
      </li>
    </ul>
    """
  end

  attr(:upload, UploadConfig, required: true)
  attr(:library_name, :string, required: true)
  attr(:library_limits, :map, required: true)

  # Files are uploaded over the LiveView socket (`allow_upload/3`, same count and size
  # limits as `POST /api/projects/:id/library`, plus the cap on the whole add:
  # `LibraryUpload`) and added in ONE entry.
  defp library_upload(assigns) do
    assigns = assign(assigns, :over_cap, over_cap(assigns.upload, assigns.library_limits))

    ~H"""
    <form id="library-form" phx-submit="library_add" phx-change="library_validate">
      <fieldset>
        <legend>Add files</legend>
        <p id="library-limits" class="ws-muted">
          {files_limits(@library_limits)}
          Agents read them, read-only, from $FOREMAN_LIBRARY_PATH.
        </p>
        <div>
          <label for="library_name">Name (optional)</label>
          <input id="library_name" type="text" name="name" value={@library_name} maxlength="128" autocomplete="off" aria-describedby="library-name-help" />
          <p id="library-name-help" class="ws-muted">Letters, digits, spaces, dashes and underscores. Left blank, the entry is named after the file.</p>
        </div>
        <div>
          <label for={@upload.ref}>Files</label>
          <.live_file_input upload={@upload} aria-describedby="library-limits" />
        </div>
        <ul :if={@upload.entries != []} id="library-selected" aria-label="Selected files">
          <li :for={entry <- @upload.entries} id={"library-selected-#{entry.ref}"}>
            <span>{entry.client_name}</span>
            <span class="ws-muted">({format_bytes(entry.client_size)})</span>
            <progress :if={entry.progress > 0} value={entry.progress} max="100" aria-label={"Upload progress of " <> entry.client_name}>{entry.progress}%</progress>
            <button type="button" phx-click="library_cancel_upload" phx-value-ref={entry.ref} aria-label={"Cancel upload of " <> entry.client_name}>Cancel upload</button>
            <span :for={error <- upload_errors(@upload, entry)} class="ws-error" role="alert">{upload_error_text(error, :files, @upload.max_entries)}</span>
          </li>
        </ul>
        <p :for={error <- upload_errors(@upload)} class="ws-error" role="alert">{upload_error_text(error, :files, @upload.max_entries)}</p>
        <p :if={@over_cap} class="ws-error" role="alert">{cap_message(@over_cap, @library_limits.upload_max_bytes)}</p>
        <button type="submit" disabled={@over_cap != nil}>Add to library</button>
      </fieldset>
    </form>
    """
  end

  attr(:upload, UploadConfig, required: true)
  attr(:folder_name, :string, required: true)
  attr(:library_limits, :map, required: true)

  # A folder (`webkitdirectory`): the browser sends every file with its path below the
  # chosen folder, and the library applies its folder rules (`Library.Ingest`) to them.
  defp library_folder_upload(assigns) do
    assigns = assign(assigns, :over_cap, over_cap(assigns.upload, assigns.library_limits))

    ~H"""
    <form id="library-folder-form" phx-submit="library_folder_add" phx-change="library_folder_validate">
      <fieldset>
        <legend>Add a folder</legend>
        <p id="library-folder-limits" class="ws-muted">
          {folder_limits(@library_limits)}
          Agents read it, read-only, from $FOREMAN_LIBRARY_PATH.
        </p>
        <div>
          <label for="library_folder_name">Name (optional)</label>
          <input id="library_folder_name" type="text" name="name" value={@folder_name} maxlength="128" autocomplete="off" aria-describedby="library-folder-name-help" />
          <p id="library-folder-name-help" class="ws-muted">Letters, digits, spaces, dashes and underscores. Left blank, the entry is named after the folder; when that is not a valid name, it is named folder.</p>
        </div>
        <div>
          <label for={@upload.ref}>Folder</label>
          <.live_file_input upload={@upload} webkitdirectory aria-describedby="library-folder-limits" />
        </div>
        <.selection id="library-folder-selected" upload={@upload} form={:folder} library_limits={@library_limits} />
        <p :if={@over_cap} class="ws-error" role="alert">{cap_message(@over_cap, @library_limits.upload_max_bytes)}</p>
        <button :if={@upload.entries != []} type="button" phx-click="library_folder_clear">Clear selection</button>
        <button type="submit" disabled={@over_cap != nil}>Add folder</button>
      </fieldset>
    </form>
    """
  end

  attr(:entry, :map, required: true)
  attr(:name, :string, required: true)
  attr(:upload, UploadConfig, required: true)
  attr(:library_limits, :map, required: true)

  # Replaces the files of ONE entry in place (`Library.replace/5`: id, name and kind stay):
  # a folder entry takes a folder (`webkitdirectory`), a file entry takes files.
  defp replace_form(assigns) do
    assigns =
      assigns
      |> assign(:folder?, assigns.entry.kind == :folder)
      |> assign(:over_cap, over_cap(assigns.upload, assigns.library_limits))

    ~H"""
    <form id="library-replace-form" phx-submit="library_replace" phx-change="library_replace_validate">
      <fieldset>
        <legend>Replace {@name}</legend>
        <p id="library-replace-limits" class="ws-muted">
          {if @folder?, do: folder_limits(@library_limits), else: files_limits(@library_limits)}
          The entry keeps its name; its current files are removed.
        </p>
        <div>
          <label for={@upload.ref}>{if @folder?, do: "Folder that replaces", else: "Files that replace"} {@name}</label>
          <.live_file_input upload={@upload} webkitdirectory={@folder?} aria-describedby="library-replace-limits" />
        </div>
        <.selection id="library-replace-selected" upload={@upload} form={if @folder?, do: :folder, else: :replace_files} library_limits={@library_limits} />
        <p :if={@over_cap} class="ws-error" role="alert">{cap_message(@over_cap, @library_limits.upload_max_bytes)}</p>
        <button type="submit" disabled={@over_cap != nil}>Replace files</button>
        <button type="button" phx-click="library_replace_cancel">Cancel replacing {@name}</button>
      </fieldset>
    </form>
    """
  end

  attr(:id, :string, required: true)
  attr(:upload, UploadConfig, required: true)
  attr(:form, :atom, required: true)
  attr(:library_limits, :map, required: true)

  # What a folder or a replacement upload holds so far: the paths, sizes, progress and
  # errors. The selection is dropped as a whole (the form's own button), not file by file.
  defp selection(assigns) do
    ~H"""
    <ul :if={@upload.entries != []} id={@id} aria-label="Selected files">
      <li :for={entry <- @upload.entries} id={"#{@id}-#{entry.ref}"}>
        <span>{entry_path(entry)}</span>
        <span class="ws-muted">({format_bytes(entry.client_size)})</span>
        <progress :if={entry.progress > 0} value={entry.progress} max="100" aria-label={"Upload progress of " <> entry_path(entry)}>{entry.progress}%</progress>
        <span :for={error <- upload_errors(@upload, entry)} class="ws-error" role="alert">{upload_error_text(error, @form, @upload.max_entries)}</span>
      </li>
    </ul>
    <p :for={error <- upload_errors(@upload)} class="ws-error" role="alert">{upload_error_text(error, @form, @upload.max_entries)}</p>
    """
  end

  # `webkitRelativePath` is "" for a file that was not picked as part of a folder.
  defp entry_path(%{client_relative_path: rel, client_name: name}) when rel in [nil, ""], do: name
  defp entry_path(%{client_relative_path: rel}), do: rel

  defp over_cap(upload, limits),
    do: LibraryUpload.declared_over_cap(upload, limits.upload_max_bytes)

  defp files_limits(limits) do
    "Up to #{limits.max_files_per_add} files per add, " <>
      "#{format_bytes(LibraryUpload.max_file_size(limits))} each. " <>
      "At most #{format_bytes(limits.upload_max_bytes)} in all."
  end

  defp folder_limits(limits) do
    "Up to #{limits.folder_max_files} files and #{format_bytes(limits.folder_max_bytes)} per folder; " <>
      "hidden files, node_modules and files over #{format_bytes(limits.folder_skip_file_bytes)} " <>
      "are left out. At most #{format_bytes(limits.upload_max_bytes)} in all."
  end

  @doc "The refusal of an upload over `upload_max_bytes`, naming both sizes."
  @spec cap_message(non_neg_integer(), pos_integer()) :: String.t()
  def cap_message(bytes, max) do
    "These files add up to #{format_bytes(bytes)}; at most #{format_bytes(max)} can be added at once."
  end

  defp upload_error_text(:too_large, _form, _max_entries),
    do: "This file is over the per-file limit."

  defp upload_error_text(:too_many_files, :folder, max_entries) do
    "More than #{max_entries} files are selected, hidden files and node_modules included. " <>
      "Add this folder with foreman project library add: it leaves those out before uploading."
  end

  defp upload_error_text(:too_many_files, :replace_files, max_entries),
    do: "Too many files: choose at most #{max_entries}."

  defp upload_error_text(:too_many_files, :files, _max_entries),
    do: "Too many files: cancel some of them."

  defp upload_error_text(:not_accepted, _form, _max_entries),
    do: "This kind of file is not accepted."

  defp upload_error_text(_other, _form, _max_entries), do: "This file could not be uploaded."

  defp files_label(1), do: "1 file"
  defp files_label(count), do: "#{count} files"

  @doc "Binary-unit size for display: `480 MiB`, `1.5 KiB`, `12 B`."
  @spec format_bytes(non_neg_integer()) :: String.t()
  def format_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    cond do
      bytes < 1024 -> "#{bytes} B"
      bytes < 1024 * 1024 -> "#{unit(bytes / 1024)} KiB"
      bytes < 1024 * 1024 * 1024 -> "#{unit(bytes / (1024 * 1024))} MiB"
      true -> "#{unit(bytes / (1024 * 1024 * 1024))} GiB"
    end
  end

  defp unit(value) do
    if value == Float.round(value, 0),
      do: value |> trunc() |> Integer.to_string(),
      else: :erlang.float_to_binary(value, decimals: 1)
  end
end
