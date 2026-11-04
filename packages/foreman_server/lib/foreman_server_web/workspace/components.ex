defmodule ForemanServerWeb.Workspace.Components do
  @moduledoc """
  Function components of the project workspace: the thread sidebar (`thread_sidebar/1`), the
  open thread's pane with its conversation and controls (`thread_pane/1`), the coordinator
  conversation, the operator questions, the project-knowledge panels and the Library / Pull
  requests / Scheduled tabs. Everything user- or agent-authored (thread titles, branches,
  reports, conversation text, memory content) is interpolated through HEEx, which escapes it;
  no component calls `raw/1` or `Phoenix.HTML.raw/1`. URLs coming from projections are only
  turned into links when they are `http(s)` URLs (`safe_url/1`).

  Every link to the workspace or to one of its threads is built by `project_path/1` and
  `thread_path/2`.
  """

  use Phoenix.Component

  alias ForemanServer.Aggregates.OperatorQuestion
  alias ForemanServer.Library
  alias ForemanServer.Overview.{Group, ThreadCard}
  alias ForemanServerWeb.Workspace.{LibraryUpload, ThreadView}
  alias ForemanServerWeb.Workspace.ThreadView.Log
  alias Phoenix.LiveView.JS
  alias Phoenix.LiveView.UploadConfig

  # A system message is collapsed behind a <details> when it is this long or longer, or
  # when it spans more than this many lines; the client preserves the toggle across
  # re-renders (JS.ignore_attributes("open") on phx-mounted).
  @system_collapse_chars 280
  @system_collapse_lines 4

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

  # The sidebar lists the Overview's groups in THIS order (what needs the operator first, not
  # `Group.all/0`'s), and folds the `:earlier` ones into one "Earlier" disclosure. The one table
  # of the order and of which groups fold; the titles are `@group_titles`. It must name every
  # group the Overview has, so a group added there cannot silently go unlisted.
  @sidebar_groups [
    waiting_on_you: :listed,
    working: :listed,
    landing: :listed,
    ready_for_review: :listed,
    idle: :earlier,
    resolved: :earlier
  ]

  if Enum.sort(Keyword.keys(@sidebar_groups)) != Enum.sort(Group.all()) do
    raise ArgumentError,
          "@sidebar_groups must name exactly the groups of Overview.Group.all/0: " <>
            inspect(Group.all())
  end

  @doc """
  Path of the project workspace (the coordinator conversation). `token` is the dashboard token
  the page was opened with, or nil: the dashboard takes it only as a header or as `?token=` (no
  cookie), so an in-page link has to carry it for a reload of the page it leads to to be
  answered. Every link of the page is built by `project_path/2`, `thread_path/3` and
  `settings_path/2`.
  """
  @spec project_path(String.t(), String.t() | nil) :: String.t()
  def project_path(project_id, token \\ nil), do: base_path(project_id) <> query(token)

  @doc """
  Path of one thread's conversation. Thread ids hold a colon (`run:<id>`, `jobsite:<id>`), so the
  id is percent-encoded; every link to a thread, in the page and in tests, is built here.
  """
  @spec thread_path(String.t(), String.t(), String.t() | nil) :: String.t()
  def thread_path(project_id, thread_id, token \\ nil) do
    base_path(project_id) <>
      "/threads/" <> URI.encode(thread_id, &URI.char_unreserved?/1) <> query(token)
  end

  @doc "Path of the project's settings page (see `project_path/2` for `token`)."
  @spec settings_path(String.t(), String.t() | nil) :: String.t()
  def settings_path(project_id, token \\ nil),
    do: base_path(project_id) <> "/settings" <> query(token)

  defp base_path(project_id), do: "/dashboard/projects/#{project_id}"

  defp query(nil), do: ""
  defp query(token) when is_binary(token), do: "?token=" <> URI.encode_www_form(token)

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

  attr(:instructions, :string, default: nil)
  attr(:settings_path, :string, required: true)
  attr(:memory_topics, :any, required: true)
  attr(:library_entries, :any, required: true)
  attr(:upload, UploadConfig, required: true)
  attr(:folder_upload, UploadConfig, required: true)
  attr(:library_name, :string, default: "")
  attr(:library_folder_name, :string, default: "")
  attr(:library_limits, :map, required: true)

  @doc """
  The "project knowledge" cards: the project's instructions (clamped, with a
  Show-all reveal whose open state the client preserves), its memory topics
  (`ProjectMemory.Topic`, name and description) and its library entries
  (`Library.Entry`, name and file count) with the add-files/add-folder upload
  forms. `memory_topics`/`library_entries` are the entry lists, or `:error`
  when the read failed, which renders an unavailable state distinct from an
  empty list. The threads are in the sidebar (`thread_sidebar/1`), not here.
  """
  def info_panels(assigns) do
    ~H"""
    <section class="ws-panel" aria-labelledby="panel-instructions-title">
      <div class="ws-panel-head">
        <h2 id="panel-instructions-title">Instructions</h2>
        <.link navigate={@settings_path} class="btn--link">Edit</.link>
      </div>
      <%= if @instructions do %>
        <p class="ws-msg ws-clamp-8">{@instructions}</p>
        <details class="ws-showall" phx-mounted={JS.ignore_attributes("open")}>
          <summary class="btn--link">Show all</summary>
          <p class="ws-msg">{@instructions}</p>
        </details>
      <% else %>
        <p class="ws-muted">No instructions yet.</p>
        <.link navigate={@settings_path} class="btn--link">Add instructions</.link>
      <% end %>
    </section>
    <section class="ws-panel" aria-labelledby="panel-memory-title">
      <div class="ws-panel-head">
        <h2 id="panel-memory-title">Memory</h2>
        <span :if={is_list(@memory_topics)} class="ws-count">{length(@memory_topics)}</span>
      </div>
      <p :if={@memory_topics == :error} class="ws-error">Memory unavailable.</p>
      <p :if={@memory_topics == []} class="ws-muted">No memory yet. Agents save durable facts here.</p>
      <ul :if={is_list(@memory_topics) and @memory_topics != []} class="ws-panel-list">
        <li :for={topic <- @memory_topics}>
          <strong>{topic.name}</strong>
          <span :if={topic.description != ""} class="ws-muted ws-clamp-1">{topic.description}</span>
        </li>
      </ul>
    </section>
    <section class="ws-panel" aria-labelledby="panel-files-title">
      <div class="ws-panel-head">
        <h2 id="panel-files-title">Files</h2>
        <span :if={is_list(@library_entries)} class="ws-count">{length(@library_entries)}</span>
      </div>
      <p :if={@library_entries == :error} class="ws-error">Files unavailable.</p>
      <p :if={@library_entries == []} class="ws-muted">No files yet.</p>
      <ul :if={is_list(@library_entries) and @library_entries != []} class="ws-panel-list">
        <li :for={entry <- @library_entries} class="ws-ellipsis">
          <strong>{entry.name}</strong>
          <span class="ws-muted"> · {entry.file_count} {file_word(entry.file_count)}</span>
        </li>
      </ul>
      <details class="ws-add-files" phx-mounted={JS.ignore_attributes("open")}>
        <summary class="btn ws-btn">Add files</summary>
        <.library_upload upload={@upload} library_name={@library_name} library_limits={@library_limits} />
        <.library_folder_upload upload={@folder_upload} folder_name={@library_folder_name} library_limits={@library_limits} />
      </details>
    </section>
    """
  end

  defp file_word(1), do: "file"
  defp file_word(_), do: "files"

  attr(:project_id, :string, required: true)
  attr(:token, :string, default: nil)
  attr(:overview, :map, required: true)
  attr(:selected_id, :string, default: nil)
  attr(:status, :map, default: nil)

  @doc """
  The thread sidebar, `<nav id="thread-list">`: "Project chat" first (the coordinator, selected
  while no thread is open, with its health chip), then the project's threads by Overview group in
  the order of `@sidebar_groups`, empty groups left out. Idle and resolved threads fold into one
  "Earlier" disclosure that starts open only when the selected thread is inside it. Every row
  links by patch (`thread_path/3`) to the thread's conversation; the attention dot sits on the
  heading while `overview.attention.needed`. `selected_id` is the open thread's id, nil for the
  project chat; `token` rides every link (see `project_path/2`).
  """
  def thread_sidebar(assigns) do
    groups = assigns.overview.groups

    sections =
      for {group, placement} <- @sidebar_groups,
          cards = Map.get(groups, group, []),
          cards != [],
          do: {placement, group, cards}

    listed = for {:listed, group, cards} <- sections, do: {group, cards}
    earlier = for {:earlier, group, cards} <- sections, do: {group, cards}

    {chat_label, chat_kind} =
      if assigns.status, do: coordinator_chip(assigns.status), else: {nil, nil}

    assigns =
      assigns
      |> assign(:listed, listed)
      |> assign(:earlier, earlier)
      |> assign(:earlier_count, Enum.sum_by(earlier, fn {_group, cards} -> length(cards) end))
      |> assign(:earlier_open?, selected_in?(earlier, assigns.selected_id))
      |> assign(:chat_label, chat_label)
      |> assign(:chat_kind, chat_kind)
      |> assign(:now, System.system_time(:millisecond))

    ~H"""
    <nav id="thread-list" class="ws-threads" aria-label="Threads">
      <.link
        id="thread-list-chat"
        patch={project_path(@project_id, @token)}
        class="thread-row thread-row--chat"
        aria-current={if(is_nil(@selected_id), do: "page")}
      >
        <span class="thread-row-title">Project chat</span>
        <span :if={@chat_label} class={["chip", "chip--" <> @chat_kind]}>{@chat_label}</span>
      </.link>
      <h2 id="threads-heading" class="ws-group-title">
        Threads
        <span :if={@overview.attention.needed} class="ws-dot" role="img" aria-label={"#{@overview.attention.count} threads need attention"}></span>
      </h2>
      <p :if={@listed == [] and @earlier == []} class="ws-muted">No threads yet.</p>
      <section :for={{group, cards} <- @listed} id={"group-#{group}"} aria-labelledby={"group-#{group}-title"}>
        <h3 id={"group-#{group}-title"} class="ws-group-title">{group_title(group)} <span class="ws-count">({length(cards)})</span></h3>
        <ul class="thread-rows" role="list">
          <li :for={card <- cards}>
            <.thread_row card={card} project_id={@project_id} token={@token} selected_id={@selected_id} now={@now} />
          </li>
        </ul>
      </section>
      <details :if={@earlier != []} id="threads-earlier" class="thread-earlier" open={@earlier_open?} phx-mounted={JS.ignore_attributes("open")}>
        <summary class="ws-group-title">Earlier ({@earlier_count})</summary>
        <ul :for={{group, cards} <- @earlier} id={"group-#{group}"} class="thread-rows" role="list">
          <li :for={card <- cards}>
            <.thread_row card={card} project_id={@project_id} token={@token} selected_id={@selected_id} now={@now} />
          </li>
        </ul>
      </details>
    </nav>
    """
  end

  defp selected_in?(sections, selected_id),
    do:
      Enum.any?(sections, fn {_group, cards} ->
        Enum.any?(cards, &(&1.thread_id == selected_id))
      end)

  attr(:card, ThreadCard, required: true)
  attr(:project_id, :string, required: true)
  attr(:token, :string, default: nil)
  attr(:selected_id, :string, default: nil)
  attr(:now, :integer, required: true)

  # One sidebar row: the title on one line (ellipsis, the whole title on hover), then the status
  # label in the chip's colour and how long ago the thread last moved (its full time on hover).
  defp thread_row(assigns) do
    {label, kind} = thread_chip(assigns.card)
    {_display, updated_title} = message_time(assigns.card.updated_at)

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:kind, kind)
      |> assign(:age, ThreadView.age(assigns.card.updated_at, assigns.now))
      |> assign(:age_title, updated_title)

    ~H"""
    <.link
      id={"thread-#{@card.thread_id}"}
      patch={thread_path(@project_id, @card.thread_id, @token)}
      class="thread-row"
      aria-current={if(@card.thread_id == @selected_id, do: "page")}
    >
      <span class="thread-row-title" title={@card.title}>{@card.title}</span>
      <span class="thread-row-meta">
        <span class={["thread-dot", "thread-dot--" <> @kind]} aria-hidden="true"></span>
        <span>{@label}</span>
        <span :if={@age} title={@age_title}>· {@age}</span>
      </span>
    </.link>
    """
  end

  attr(:card, ThreadCard, required: true)

  attr(:log, :any,
    required: true,
    doc: "a `ThreadView.Log`, or `:unavailable` when the conversation could not be read"
  )

  attr(:project_id, :string, required: true)
  attr(:token, :string, default: nil)
  attr(:confirm_stop, :string, default: nil)
  attr(:steer_nonce, :string, required: true)

  @doc """
  One thread's conversation in the main column: a light header (the way back, the title and
  status chip, one line of branch / PR state / PR link, the failure lines and the card's hint),
  its controls, in one collapsed `Actions` disclosure (the `action_control/1` buttons and the PR
  actions, enabled ones first with a disabled one's reason on hover and for assistive technology;
  both are reachable once it is open) and the pending tool approvals below it (they send the
  same events the thread cards sent), the log of what the agent, the operator and
  Foreman said, and the steer composer while the thread takes steering.
  """
  def thread_pane(assigns) do
    {chip_label, chip_kind} = thread_chip(assigns.card)

    assigns =
      assigns
      |> assign(:chip_label, chip_label)
      |> assign(:chip_kind, chip_kind)
      |> assign(:buttons, Enum.reject(assigns.card.actions, &(&1 == "thread.steer")))
      |> assign(:pr_actions, Enum.sort_by(assigns.card.pr_actions, &(not &1.enabled)))
      |> assign(:steerable?, "thread.steer" in assigns.card.actions)

    ~H"""
    <section id="thread-pane" class="ws-card thread-pane" aria-label={"Thread: " <> @card.title}>
      <header class="thread-pane-head">
        <.link patch={project_path(@project_id, @token)} class="btn--link thread-back"><span aria-hidden="true">←</span> Project chat</.link>
        <div class="thread-pane-titlerow">
          <h2 class="thread-pane-title" title={@card.title}>{@card.title}</h2>
          <span class={["chip", "chip--" <> @chip_kind]}>{@chip_label}</span>
        </div>
        <p :if={@card.branch || @card.pr_state || safe_url(@card.pr_url)} class="thread-meta ws-muted">
          <code :if={@card.branch} class="thread-branch" title={@card.branch}>{@card.branch}</code>
          <span :if={@card.branch && @card.pr_state} aria-hidden="true">·</span>
          <span :if={@card.pr_state}>PR {@card.pr_state}</span>
          <span :if={(@card.branch || @card.pr_state) && safe_url(@card.pr_url)} aria-hidden="true">·</span>
          <a :if={safe_url(@card.pr_url)} href={safe_url(@card.pr_url)} class="btn--link" rel="noopener noreferrer" target="_blank">Open PR</a>
        </p>
        <p :if={@card.failure_reason} class="ws-error">Failure: {@card.failure_reason}</p>
        <p :if={@card.reason == :ci_failing} class="ws-error">CI failing: the PR's checks are red.</p>
        <p :if={@card.reason == :changes_requested} class="ws-error">Changes requested: a reviewer asked for changes on the PR.</p>
        <p :if={@card.reason == :review_threads} class="ws-error">Review threads unresolved: the PR has open review comments.</p>
        <p :if={@card.hint} class="thread-hint ws-muted">{@card.hint}</p>
      </header>
      <details
        :if={@buttons != [] or @card.pr_actions != []}
        id={"thread-controls-#{@card.thread_id}"}
        class="thread-controls-details"
        phx-mounted={JS.ignore_attributes("open")}
      >
        <summary>Actions</summary>
        <div class="thread-controls">
          <div :if={@buttons != []} class="thread-actions" role="group" aria-label={"Actions for " <> @card.title}>
            <%= for action <- @buttons do %>
              <.action_control action={action} card={@card} confirm_stop={@confirm_stop} steer_nonce={@steer_nonce} />
            <% end %>
          </div>
          <div
            :if={@card.pr_actions != []}
            class="thread-pr-actions"
            role="group"
            aria-label={"Pull request actions for " <> @card.title}
          >
            <span :for={a <- @pr_actions} class="ws-pr-action">
              <button
                type="button"
                id={"pr-action-#{@card.thread_id}-#{a.kind}"}
                phx-click="pr_action"
                phx-value-kind={a.kind}
                phx-value-thread-id={@card.thread_id}
                phx-value-pr-url={a.pr_url}
                disabled={not a.enabled}
                title={a.reason}
                aria-describedby={if(a.reason, do: "pr-action-#{@card.thread_id}-#{a.kind}-reason")}
              >
                {a.label}
              </button>
              <span
                :if={a.reason}
                id={"pr-action-#{@card.thread_id}-#{a.kind}-reason"}
                class="ws-vh"
              >
                {a.reason}
              </span>
            </span>
          </div>
        </div>
      </details>
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
      <.thread_log log={@log} />
      <.action_control :if={@steerable?} action="thread.steer" card={@card} confirm_stop={@confirm_stop} steer_nonce={@steer_nonce} />
      <p :if={not @steerable?} class="ws-muted thread-note">{steer_note(@log)}</p>
    </section>
    """
  end

  # Why there is no composer: the thread is over, or it does not take steering in its state.
  defp steer_note(%Log{terminal?: true}), do: "This thread is finished."
  defp steer_note(%Log{terminal?: false}), do: "This thread is not taking steering right now."
  defp steer_note(:unavailable), do: "Steering is not available for this thread right now."

  attr(:log, :any, required: true)

  # The conversation, newest at the bottom and pinned there (the same `column-reverse` box as
  # the coordinator's `#conversation-log`).
  defp thread_log(%{log: :unavailable} = assigns) do
    ~H"""
    <div id="thread-log" class="conv-transcript" role="log" aria-live="polite" aria-label="Thread conversation">
      <div class="conv-inner">
        <p class="ws-muted">The conversation cannot be read right now.</p>
      </div>
    </div>
    """
  end

  defp thread_log(%{log: %Log{}} = assigns) do
    ~H"""
    <div id="thread-log" class="conv-transcript" role="log" aria-live="polite" aria-label="Thread conversation">
      <div class="conv-inner">
        <p :if={@log.omitted_entries > 0} id="thread-log-omitted" class="ws-muted">{omitted_note(@log.omitted_entries)}</p>
        <p :if={@log.dropped_turns > 0} class="ws-muted">{@log.dropped_turns} earlier {if @log.dropped_turns == 1, do: "turn", else: "turns"} not shown.</p>
        <p :if={@log.blocks == []} class="ws-muted">No output recorded yet.</p>
        <p :if={@log.blocks == [] and not @log.terminal?} class="ws-muted">Output appears here as the agent works.</p>
        <.turn :for={block <- @log.blocks} block={block} />
      </div>
    </div>
    """
  end

  defp omitted_note(1), do: "The first output entry is no longer stored."
  defp omitted_note(count), do: "The first #{count} output entries are no longer stored."

  attr(:block, ThreadView.Block, required: true)

  # One block of the conversation: the sender, a human time (its full ISO time on hover) and the
  # text, which HEEx escapes.
  defp turn(assigns) do
    {variant, label} = turn_style(assigns.block)
    {time, time_title} = message_time(assigns.block.at)

    assigns =
      assigns
      |> assign(:variant, variant)
      |> assign(:label, label)
      |> assign(:time, time)
      |> assign(:time_title, time_title)

    ~H"""
    <article id={"turn-#{@block.seq}"} class={["msg", "msg--" <> @variant]}>
      <p class="msg-meta">
        <span class="msg-sender">{@label}</span>
        <span :if={@time != ""} title={@time_title}>{@time}</span>
      </p>
      <div class="msg-text">{@block.text}</div>
    </article>
    """
  end

  # The CSS variant and the sender label of a block. The vocabulary is closed to what
  # `Transcript` produces; an unknown role or kind raises rather than render a wrong attribution.
  defp turn_style(%{role: :agent, kind: :text, source: "stderr"}), do: {"stderr", "stderr"}
  defp turn_style(%{role: :agent, kind: :text}), do: {"agent", "Agent"}
  defp turn_style(%{role: :operator, kind: :steer}), do: {"operator", "You"}
  defp turn_style(%{role: :system, kind: :status}), do: {"system", "Foreman"}
  defp turn_style(%{role: :system, kind: :verdict}), do: {"verdict", "Review"}

  attr(:project_id, :string, required: true)
  attr(:token, :string, default: nil)

  @doc "The calm card for a thread id that is not one of this project's threads."
  def thread_missing(assigns) do
    ~H"""
    <section id="thread-not-found" class="ws-card" aria-labelledby="thread-not-found-title">
      <h2 id="thread-not-found-title" class="thread-pane-title">Thread not found</h2>
      <p class="ws-muted">This project has no thread with that id.</p>
      <.link patch={project_path(@project_id, @token)} class="btn ws-btn">Project chat</.link>
    </section>
    """
  end

  defp approval_note(%{approval_delivery: "inflight"}), do: "the agent is waiting on this call"
  defp approval_note(_approval), do: "approving resumes the paused run"

  # A thread's status chip: a failed thread reads as an error, a completed one is quiet,
  # otherwise the chip takes the Overview group's colour and title.
  @group_chip_kind %{
    ready_for_review: "ok",
    waiting_on_you: "warn",
    working: "info",
    landing: "info",
    idle: "muted",
    resolved: "muted"
  }

  defp thread_chip(%{status: "failed"}), do: {"failed", "err"}
  defp thread_chip(%{status: "completed"}), do: {"completed", "muted"}

  defp thread_chip(%{group: group}),
    do: {String.downcase(group_title(group)), Map.fetch!(@group_chip_kind, group)}

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

  # The steer form is the thread pane's composer: the same event and the same hidden inputs the
  # card's inline form had, laid out like the coordinator's `.composer`.
  defp action_control(%{action: "thread.steer"} = assigns) do
    ~H"""
    <form phx-submit="steer" id={"steer-#{@card.thread_id}"} class="composer thread-composer">
      <input type="hidden" name="thread_id" value={@card.thread_id} />
      <input type="hidden" name="message_id" value={@steer_nonce <> ":" <> @card.thread_id} />
      <%!-- phx-update="ignore": LiveView rewrites an input the browser does not have focused from the
           server's markup, and this pane re-renders every time the agent writes output, so a steer
           the operator is still typing would be wiped by a click on the log or the sidebar. The text
           belongs to the browser until it is sent. The field's id carries the send nonce: a
           successful send changes the nonce, which replaces the element and so clears it, while a
           refused one keeps what was typed. --%>
      <label>
        <span class="ws-vh">Steer {@card.title}</span>
        <textarea id={"steer-text-#{@card.thread_id}-#{@steer_nonce}"} name="text" rows="2" maxlength="8000" autocomplete="off" placeholder="Steer this thread..." phx-update="ignore"></textarea>
      </label>
      <div class="composer-row">
        <button type="submit" class="btn ws-btn ws-btn--primary">Send</button>
      </div>
    </form>
    """
  end

  attr(:messages, :list, required: true)
  attr(:status, :map, default: nil)
  attr(:proposals, :list, default: [])
  attr(:has_earlier, :boolean, default: false)
  attr(:truncated_before_seq, :integer, default: nil)
  attr(:draft_id, :string, required: true)

  @doc """
  The coordinator conversation pane: log, the proposed threads that can still be started
  (Start / Decline; a proposal that was started, declined or closed is not shown, and with none
  the section is absent), health and composer.
  """
  def conversation_pane(assigns) do
    assigns = assign(assigns, :startable, Enum.filter(assigns.proposals, & &1.startable?))

    ~H"""
    <section id="conversation-pane" class="ws-card conv-card" aria-labelledby="conversation-heading">
      <div class="conv-head">
        <h2 id="conversation-heading">Coordinator</h2>
        <span :if={@status} id="coordinator-health">
          <% {label, kind} = coordinator_chip(@status) %>
          <span class={["chip", "chip--" <> kind]}>{label}</span>
          <span :if={@status["consecutive_failures"] > 0} class="ws-muted"> · {@status["consecutive_failures"]} consecutive failures</span>
          <span :if={@status["last_error"]} class="ws-error"> · last error: {@status["last_error"]["message"]}</span>

          <button :if={@status["status"] == "unhealthy"} type="button" class="btn ws-btn" phx-click="restart_coordinator">Restart coordinator</button>
        </span>
      </div>
      <button :if={@has_earlier} type="button" class="btn--link" phx-click="load_earlier">Load earlier messages</button>
      <p :if={@truncated_before_seq} class="ws-muted">Older messages were trimmed (before {@truncated_before_seq}).</p>
      <div id="conversation-log" class="conv-transcript" role="log" aria-live="polite" aria-label="Coordinator conversation">
        <div class="conv-inner">
          <p :if={@messages == []} class="ws-muted">No messages yet. Tell the coordinator what you want done.</p>
          <.message :for={m <- @messages} message={m} />
        </div>
      </div>
      <div :if={@startable != []} id="proposals" aria-label="Proposed threads">
        <h3 class="ws-group-title">Proposed threads</h3>
        <article :for={p <- @startable} class="ws-card" id={"proposal-#{p.task_id}"} aria-label={"Proposal: " <> p.title}>
          <span>{p.title}</span>
          <button type="button" class="btn ws-btn ws-btn--primary" phx-click="start_proposed" phx-value-task-id={p.task_id}>Start</button>
          <button type="button" class="btn ws-btn" phx-click="decline_proposed" phx-value-task-id={p.task_id}>Decline</button>
        </article>
      </div>
      <form id="composer" class="composer" phx-submit="post_message">
        <input type="hidden" name="message_id" value={@draft_id} />
        <label>
          <span class="ws-vh">Message the coordinator</span>
          <textarea name="text" rows="3" placeholder="Message the coordinator…" required></textarea>
        </label>
        <div class="composer-row">
          <button type="submit" class="btn ws-btn ws-btn--primary">Send</button>
        </div>
      </form>
    </section>
    """
  end

  attr(:message, :map, required: true)

  # One conversation message, formatted (no raw role/source/ISO headers): the sender
  # label, a human time (full ISO in the title), and the text. Operator messages sit
  # right, the coordinator left; a system ("Foreman") message is quiet, and a long one is
  # collapsed behind a <details> whose open state the client preserves.
  defp message(assigns) do
    m = assigns.message
    {time, title} = message_time(m["at"])

    assigns =
      assigns
      |> assign(:role, m["role"])
      |> assign(:sender, sender_label(m["role"]))
      |> assign(:time, time)
      |> assign(:time_title, title)
      |> assign(:text, m["text"] || "")
      |> assign(:seq, m["seq"])

    ~H"""
    <article id={"msg-#{@seq}"} class={["msg", "msg--" <> message_variant(@role)]}>
      <p class="msg-meta">
        <span class="msg-sender">{@sender}</span>
        <span :if={@time != ""} title={@time_title}>{@time}</span>
      </p>
      <%= if @role == "system" and collapse_system?(@text) do %>
        <details phx-mounted={JS.ignore_attributes("open")}>
          <summary class="msg-text">{first_line(@text)}</summary>
          <div class="msg-text">{@text}</div>
        </details>
      <% else %>
        <div class="msg-text">{@text}</div>
      <% end %>
    </article>
    """
  end

  @doc "Sender label shown on a message: operator -> You, coordinator -> Coordinator, system -> Foreman."
  @spec sender_label(String.t()) :: String.t()
  def sender_label("operator"), do: "You"
  def sender_label("coordinator"), do: "Coordinator"
  def sender_label("system"), do: "Foreman"

  # The CSS variant suffix for a message's role. The role vocabulary is closed to the
  # three above; an unknown role raises rather than rendering a wrong attribution.
  defp message_variant("operator"), do: "operator"
  defp message_variant("coordinator"), do: "coordinator"
  defp message_variant("system"), do: "system"

  @doc """
  A message's time as `{display, title}` from an ISO 8601 string or unix milliseconds:
  display like `Nov 2, 4:22 PM` (UTC) and the title the full ISO time to the second plus
  `UTC` (never the raw microsecond stamp). An unparseable or absent time yields `{"", nil}`.
  """
  @spec message_time(term()) :: {String.t(), String.t() | nil}
  def message_time(unix_ms) when is_integer(unix_ms),
    do: unix_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601() |> message_time()

  def message_time(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _offset} ->
        dt = DateTime.truncate(dt, :second)
        {Calendar.strftime(dt, "%b %-d, %-I:%M %p"), DateTime.to_iso8601(dt) <> " UTC"}

      _ ->
        {"", nil}
    end
  end

  def message_time(_), do: {"", nil}

  defp collapse_system?(text) when is_binary(text),
    do: String.length(text) > @system_collapse_chars or line_count(text) > @system_collapse_lines

  defp collapse_system?(_), do: false

  defp line_count(text), do: text |> String.split("\n") |> length()

  defp first_line(text) do
    case String.split(text, "\n", parts: 2) do
      [first | _] -> first
      _ -> text
    end
  end

  # The coordinator's health chip. The status vocabulary is closed (`:idle | :turn_open |
  # :unhealthy`, `ForemanServer.Coordinator.Conversation.status/1`): idle is quiet, an open turn
  # reads "working" and is informational, unhealthy is an error. A status outside it raises.
  defp coordinator_chip(%{"status" => "idle"}), do: {"idle", "muted"}
  defp coordinator_chip(%{"status" => "turn_open"}), do: {"working", "info"}
  defp coordinator_chip(%{"status" => "unhealthy"}), do: {"unhealthy", "err"}

  attr(:tab, :atom, required: true)
  attr(:tabs, :map, required: true)
  attr(:schedules, :list, required: true)
  attr(:replace_upload, UploadConfig, required: true)
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
          replace_upload={@replace_upload}
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
