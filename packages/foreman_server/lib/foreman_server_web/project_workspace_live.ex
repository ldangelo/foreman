defmodule ForemanServerWeb.ProjectWorkspaceLive do
  @moduledoc """
  The project workspace: `GET /dashboard/projects/:id` and
  `GET /dashboard/projects/:id/threads/:thread_id` (authenticated).

  Left, the thread sidebar (`Components.thread_sidebar/1`): "Project chat" and the project's
  threads grouped by Overview state (E7), each row a patch link. In the main column,
  `/projects/:id` is the coordinator conversation (E15 via `ForemanServer.CoordinatorAPI`) with
  its proposed threads (Start / Decline), and a thread's own URL is that thread's conversation
  (`Components.thread_pane/1`): its header, its controls (the E6 thread actions, the PR actions,
  the tool approvals), what `ForemanServer.Threads.Transcript` has for it and a steer composer.
  The open thread must be one of THIS project's Overview cards: any other id (unknown, another
  project's, malformed) is a "Thread not found" card, and nothing is read for it. Right, the
  project's open operator questions (the rows `GET /api/projects/:id/questions` lists, each with
  an answer form), the project's knowledge (instructions, memory, files) and the Library (add
  files or a folder, replace, download and remove, `ForemanServer.Library`) / Pull requests /
  Scheduled tabs. Moving between the chat and threads is a `patch`: one process, nothing
  remounts.

  Reads and writes go through the same Elixir functions the HTTP API uses (see
  `ForemanServerWeb.Workspace.Actions`); there is no HTTP-to-self call and no
  new mutation path. Updates arrive through one `ProjectionStore` subscription with a
  coalescing window (`ForemanServerWeb.Workspace.Refresh`): no periodic polling. The worker
  output of the open thread, which that refresh ignores, arms a second coalesced trigger that
  re-reads only its transcript. A tab or conversation that is not shown costs nothing on
  refresh.

  Library files travel over the LiveView socket (`allow_upload/3`: files, a folder with
  its relative paths, or the files that replace an entry) with the library's own limits
  (`Library.Ingest.limits/0`: files per add, bytes per file). LiveView has no cumulative
  cap, so the whole-add cap `upload_max_bytes` (the HTTP routes' request cap) is enforced
  here (`ForemanServerWeb.Workspace.LibraryUpload`); `Library.add/4` and
  `Library.replace/5` stay authoritative for names, paths and sizes. A file is
  downloaded over the same socket (`push_event/3`, `library-download`), because a link
  to the HTTP route could not authenticate in a browser.
  """

  use ForemanServerWeb, :live_view

  require Logger

  alias ForemanServer.{
    CoordinatorAPI,
    Library,
    Overview,
    ProjectionStore,
    ProjectMemory,
    ProjectStore
  }

  alias ForemanServer.Coordinator.Redact
  alias ForemanServer.Library.Ingest
  alias ForemanServer.Overview.ThreadCard
  alias ForemanServer.Questions.DTO, as: QuestionDTO
  alias ForemanServer.Schedule.DTO, as: ScheduleDTO
  alias ForemanServer.Threads.Transcript
  alias ForemanServer.Threads.Transcript.Full

  alias ForemanServerWeb.Workspace.{
    Actions,
    Components,
    LibraryUpload,
    ProjectNotFound,
    ProjectView,
    Refresh,
    ThreadView
  }

  @tail 50
  @page 200
  @max_kept 400
  @tabs %{"library" => :library, "pull_requests" => :pull_requests, "scheduled" => :scheduled}
  # The values the thread controls send: derived from the pane's own table, never a second list.
  @thread_actions Components.thread_actions()
  @schedule_ops %{"pause" => :pause, "resume" => :resume}

  # What the three upload forms say when a submit finds nothing to add or an upload that
  # is not (or cannot be) finished.
  @files_selection %{
    empty: "Choose at least one file to add.",
    not_ready: "Wait for the uploads to finish and cancel the files marked with an error."
  }
  @folder_selection %{
    empty: "Choose a folder to add.",
    not_ready:
      "Wait for the upload to finish. If it is marked with an error, clear the selection and choose again."
  }
  @replace_not_ready "Wait for the upload to finish. If it is marked with an error, cancel and choose again."
  @replace_selection %{
    file: %{empty: "Choose the files that replace it.", not_ready: @replace_not_ready},
    folder: %{empty: "Choose the folder that replaces it.", not_ready: @replace_not_ready}
  }

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
            schedules: [],
            confirm_remove: nil,
            confirm_delete: nil,
            library_name: "",
            library_folder_name: "",
            replace_entry: nil,
            open_entry: nil,
            token: nil,
            thread_id: nil,
            thread_card: nil,
            thread_log: nil
          )
          |> allow_library_uploads()
          |> load_conversation_tail()
          |> load_state()

        {:ok, socket}
    end
  end

  # The open thread follows the URL (nil: the project chat). A pending stop confirmation belongs
  # to the thread it was asked on, so it does not follow the operator to another one.
  @impl true
  def handle_params(
        %{"thread_id" => thread_id} = params,
        _uri,
        %{assigns: %{live_action: :thread}} = socket
      ),
      do: {:noreply, socket |> keep_token(params) |> open_thread(thread_id)}

  def handle_params(params, _uri, %{assigns: %{live_action: :show}} = socket),
    do: {:noreply, socket |> keep_token(params) |> open_thread(nil)}

  # The dashboard takes its token only as a header or as `?token=` (no cookie), so every link of
  # the page carries the token the page was opened with (`Components.thread_path/3`): a reload of
  # a page the operator reached by clicking is answered, not a 401. A URL without one leaves
  # what was kept.
  defp keep_token(socket, %{"token" => token}) when is_binary(token) and token != "",
    do: assign(socket, :token, token)

  defp keep_token(socket, _params), do: socket

  defp open_thread(socket, thread_id) do
    if socket.assigns.thread_id == thread_id do
      select_card(socket)
    else
      socket
      |> assign(thread_id: thread_id, thread_log: nil, confirm_stop: nil)
      |> select_card()
    end
  end

  @impl true
  def handle_info({:projection_event, event}, socket) do
    {:noreply,
     socket
     |> Refresh.note_event(event, socket.assigns.project_id)
     |> Refresh.note_output(event, open_thread_id(socket))}
  end

  def handle_info(:workspace_refresh, socket) do
    {:noreply,
     socket
     |> Refresh.begin_refresh()
     |> refresh_conversation()
     |> assign(:thread_log, nil)
     |> load_state()}
  end

  def handle_info(:thread_refresh, socket),
    do: {:noreply, socket |> Refresh.begin_thread_refresh() |> load_log()}

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
        "decide_approval",
        %{
          "thread-id" => id,
          "run-id" => run_id,
          "tool-call-id" => tool_call_id,
          "decision" => decision
        },
        socket
      )
      when decision in ["approve", "deny"] do
    result =
      Actions.decide_approval(
        socket.assigns.project_id,
        id,
        run_id,
        tool_call_id,
        String.to_existing_atom(decision),
        Refresh.intent(socket)
      )

    {:noreply, notify(socket, result)}
  end

  # The operator's answer to an agent's question (`question.answer`). The questions are
  # re-read at once, so the answered one is gone without waiting for the projection event.
  def handle_event(
        "answer_question",
        %{"run_id" => run_id, "question_id" => question_id, "text" => text},
        socket
      ) do
    result =
      Actions.answer_question(
        socket.assigns.project_id,
        run_id,
        question_id,
        text,
        Refresh.intent(socket)
      )

    {:noreply, socket |> notify(result) |> load_state()}
  end

  def handle_event("pr_action", %{"kind" => kind, "thread-id" => id} = params, socket) do
    result =
      Actions.pr_action(
        socket.assigns.project_id,
        id,
        kind,
        params["pr-url"],
        Refresh.intent(socket)
      )

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

  def handle_event("decline_proposed", %{"task-id" => task_id}, socket) do
    {:noreply,
     notify(
       socket,
       Actions.decline_proposed(socket.assigns.project_id, task_id, Refresh.intent(socket))
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

  def handle_event("schedule_confirm_delete", %{"id" => id}, socket) when is_binary(id),
    do: {:noreply, assign(socket, :confirm_delete, id)}

  def handle_event("schedule_cancel_delete", _params, socket),
    do: {:noreply, assign(socket, :confirm_delete, nil)}

  def handle_event("schedule_delete", %{"id" => id}, socket) when is_binary(id) do
    result =
      Actions.schedule_control(socket.assigns.project_id, id, :delete, Refresh.intent(socket))

    {:noreply, socket |> assign(:confirm_delete, nil) |> notify(result) |> load_state()}
  end

  def handle_event("library_validate", %{"name" => name}, socket) when is_binary(name),
    do: {:noreply, assign(socket, :library_name, name)}

  # A stale click (the entry was already added or cancelled) is a no-op, not a crash.
  def handle_event("library_cancel_upload", %{"ref" => ref}, socket) do
    if Enum.any?(socket.assigns.uploads.library.entries, &(&1.ref == ref)),
      do: {:noreply, cancel_upload(socket, :library, ref)},
      else: {:noreply, socket}
  end

  def handle_event("library_add", %{"name" => name}, socket) when is_binary(name),
    do: {:noreply, socket |> assign(:library_name, name) |> add_library_files(name)}

  def handle_event("library_folder_validate", %{"name" => name}, socket) when is_binary(name),
    do: {:noreply, assign(socket, :library_folder_name, name)}

  def handle_event("library_folder_clear", _params, socket),
    do: {:noreply, cancel_all(socket, :library_folder)}

  def handle_event("library_folder_add", %{"name" => name}, socket) when is_binary(name),
    do: {:noreply, socket |> assign(:library_folder_name, name) |> add_library_folder(name)}

  # The replace form belongs to one entry at a time. The entry, and so the kind of upload
  # it takes (files or a folder), comes from the library, never from the browser.
  def handle_event("library_replace_open", %{"entry-id" => id}, socket) do
    case Actions.library_replace_kind(socket.assigns.project_id, id) do
      {:ok, kind} -> {:noreply, open_replace(socket, id, kind)}
      {:error, _message} = refused -> {:noreply, notify(socket, refused)}
    end
  end

  def handle_event("library_replace_validate", _params, socket), do: {:noreply, socket}

  def handle_event("library_replace_cancel", _params, socket),
    do: {:noreply, close_replace(socket)}

  def handle_event("library_replace", _params, socket),
    do: {:noreply, replace_library_entry(socket)}

  def handle_event("library_files", %{"entry-id" => id}, socket),
    do: {:noreply, toggle_files(socket, id)}

  # The file's bytes go to the browser over this socket (`Library.read/3`, at most
  # `Library.read_max_bytes/0`, path validated by the library); the layout's
  # `phx:library-download` handler saves them.
  def handle_event("library_download", %{"entry-id" => id, "path" => path}, socket) do
    case Actions.library_file(socket.assigns.project_id, id, path) do
      {:ok, bytes} ->
        name = Path.basename(path)

        {:noreply,
         socket
         |> push_event("library-download", %{name: name, data: Base.encode64(bytes)})
         |> notify({:ok, "Downloading #{name}."})}

      {:error, _message} = refused ->
        {:noreply, notify(socket, refused)}
    end
  end

  def handle_event("library_confirm_remove", %{"entry-id" => id}, socket),
    do: {:noreply, assign(socket, :confirm_remove, id)}

  def handle_event("library_cancel_remove", _params, socket),
    do: {:noreply, assign(socket, :confirm_remove, nil)}

  def handle_event("library_remove", %{"entry-id" => id}, socket) do
    result = Actions.library_remove(socket.assigns.project_id, id)
    {:noreply, socket |> assign(:confirm_remove, nil) |> notify(result) |> load_state()}
  end

  # -- state -----------------------------------------------------------------

  defp notify(socket, {kind, message}), do: assign(socket, notice: message, notice_kind: kind)

  defp project_chip_kind("paused"), do: "chip--warn"
  defp project_chip_kind("active"), do: "chip--ok"
  defp project_chip_kind(_status), do: "chip--muted"

  # The three upload forms share the library's count and per-file limits
  # (`Library.Ingest.limits/0`; the library checks them again server-side) and the cap on
  # the whole add (`LibraryUpload`). The replace form serves file and folder entries
  # alike, so it takes the larger count.
  defp allow_library_uploads(socket) do
    limits = Ingest.limits()

    socket
    |> assign(:library_limits, limits)
    |> allow_upload(:library, LibraryUpload.upload_opts(:files, limits))
    |> allow_upload(:library_folder, LibraryUpload.upload_opts(:folder, limits))
    |> allow_upload(:library_replace, LibraryUpload.upload_opts(:replace, limits))
  end

  defp add_library_files(socket, name) do
    project_id = socket.assigns.project_id
    add = &Actions.library_add(project_id, LibraryUpload.flat_files(&1), name)

    case submit_upload(socket, :library, @files_selection, add) do
      {:ok, _message} = added ->
        socket |> assign(:library_name, "") |> notify(added) |> load_state()

      {:error, _message} = refused ->
        notify(socket, refused)
    end
  end

  defp add_library_folder(socket, name) do
    project_id = socket.assigns.project_id

    add = fn selected ->
      {suggested, files} = LibraryUpload.folder_files(selected)
      Actions.library_add_folder(project_id, files, folder_entry_name(name, suggested))
    end

    case submit_upload(socket, :library_folder, @folder_selection, add) do
      {:ok, _message} = added ->
        socket |> assign(:library_folder_name, "") |> notify(added) |> load_state()

      {:error, _message} = refused ->
        notify(socket, refused)
    end
  end

  # A typed name wins; else the folder's own name when it is a valid entry name; else
  # the library derives one.
  defp folder_entry_name(typed, suggested),
    do: if(String.trim(typed) == "", do: suggested || "", else: typed)

  defp replace_library_entry(%{assigns: %{replace_entry: nil}} = socket),
    do: notify(socket, {:error, "Choose an entry to replace first."})

  defp replace_library_entry(
         %{assigns: %{replace_entry: %{entry_id: entry_id, kind: kind}}} = socket
       ) do
    project_id = socket.assigns.project_id

    replace = fn selected ->
      Actions.library_replace(project_id, entry_id, replacement_files(kind, selected))
    end

    case submit_upload(socket, :library_replace, Map.fetch!(@replace_selection, kind), replace) do
      {:ok, _message} = replaced ->
        socket |> assign(:replace_entry, nil) |> notify(replaced) |> load_state()

      {:error, _message} = refused ->
        notify(socket, refused)
    end
  end

  # A folder entry takes the folder's files (its own name dropped), a file entry plain files.
  defp replacement_files(:folder, selected),
    do: selected |> LibraryUpload.folder_files() |> elem(1)

  defp replacement_files(:file, selected), do: LibraryUpload.flat_files(selected)

  defp open_replace(socket, entry_id, kind),
    do: socket |> close_replace() |> assign(:replace_entry, %{entry_id: entry_id, kind: kind})

  defp close_replace(socket),
    do: socket |> cancel_all(:library_replace) |> assign(:replace_entry, nil)

  defp cancel_all(socket, name) do
    socket.assigns.uploads
    |> Map.fetch!(name)
    |> Map.fetch!(:entries)
    |> Enum.reject(& &1.cancelled?)
    |> Enum.reduce(socket, fn entry, acc -> cancel_upload(acc, name, entry.ref) end)
  end

  # Uploaded files are consumed in two steps. `{:postpone, _}` hands out the temp
  # paths without freeing them while `add` (an `Actions` function) copies the files into
  # the library; only a successful add consumes them for good (which frees the temp
  # files and clears the form). A refused add (a taken name, say) therefore keeps the
  # selection, uploaded already, for another try. Before anything reaches the library
  # the bytes that really arrived are held to the whole-add cap (`LibraryUpload`),
  # against the CURRENT config: it does not matter what the page showed or the
  # browser claimed.
  defp submit_upload(socket, name, messages, add) do
    upload = Map.fetch!(socket.assigns.uploads, name)

    cond do
      upload.entries == [] ->
        {:error, messages.empty}

      upload.errors != [] or not Enum.all?(upload.entries, &(&1.valid? and &1.done?)) ->
        {:error, messages.not_ready}

      true ->
        selected =
          consume_uploaded_entries(socket, name, fn %{path: path}, entry ->
            {:postpone, {entry, path}}
          end)

        max = Ingest.limits().upload_max_bytes

        case LibraryUpload.actual_bytes(selected) do
          bytes when bytes > max ->
            {:error, Components.cap_message(bytes, max)}

          _within_cap ->
            with {:ok, _message} = added <- add.(selected) do
              consume_uploaded_entries(socket, name, fn _meta, _entry -> {:ok, :added} end)
              added
            end
        end
    end
  end

  defp toggle_files(%{assigns: %{open_entry: %{entry_id: id}}} = socket, id),
    do: assign(socket, :open_entry, nil)

  defp toggle_files(socket, id) do
    case Actions.library_entry_files(socket.assigns.project_id, id) do
      {:ok, files} -> assign(socket, :open_entry, %{entry_id: id, files: files})
      {:error, _message} = refused -> socket |> assign(:open_entry, nil) |> notify(refused)
    end
  end

  # The open file list and the replace form each belong to one entry and follow it: a
  # replaced entry shows its new files, a removed one closes both.
  defp sync_library_panels(socket), do: socket |> sync_open_entry() |> sync_replace_entry()

  defp sync_open_entry(%{assigns: %{open_entry: nil}} = socket), do: socket

  defp sync_open_entry(%{assigns: %{open_entry: %{entry_id: id}}} = socket) do
    case Actions.library_entry_files(socket.assigns.project_id, id) do
      {:ok, files} -> assign(socket, :open_entry, %{entry_id: id, files: files})
      {:error, _gone} -> assign(socket, :open_entry, nil)
    end
  end

  defp sync_replace_entry(%{assigns: %{replace_entry: nil}} = socket), do: socket

  defp sync_replace_entry(%{assigns: %{replace_entry: %{entry_id: id}}} = socket) do
    case Actions.library_replace_kind(socket.assigns.project_id, id) do
      {:ok, _kind} -> socket
      {:error, _gone} -> close_replace(socket)
    end
  end

  # Overview, project row, coordinator health, proposals and the open operator questions
  # on every refresh; the schedules only while their tab is shown.
  defp load_state(socket) do
    project_id = socket.assigns.project_id
    {:ok, overview} = Overview.build(project_id, include_resolved: true)
    status = status(project_id)

    socket
    |> assign(
      project_view: project_view(project_id, socket),
      overview: overview,
      status: status,
      proposals: proposals(project_id),
      questions: project_id |> ProjectionStore.open_questions() |> QuestionDTO.list(),
      memory_topics: memory_topics(project_id),
      library_entries: library_entries(project_id)
    )
    |> assign(:schedules, schedules(socket))
    |> sync_library_panels()
    |> select_card()
  end

  # The open thread's card, found among THIS project's Overview cards: another project's
  # thread, an unknown id and a malformed one find nothing. The pane renders a log wherever it
  # renders a card, so a card never stands without one: a thread whose events arrive after the
  # page was opened gets its log read here, and one that leaves the Overview drops its log.
  defp select_card(%{assigns: %{thread_id: nil}} = socket),
    do: assign(socket, thread_card: nil, thread_log: nil)

  defp select_card(%{assigns: %{thread_id: thread_id, overview: overview}} = socket) do
    case ThreadView.find_card(overview, thread_id) do
      nil -> assign(socket, thread_card: nil, thread_log: nil)
      %ThreadCard{} = card -> socket |> assign(:thread_card, card) |> ensure_log()
    end
  end

  defp ensure_log(%{assigns: %{thread_log: nil}} = socket), do: load_log(socket)
  defp ensure_log(socket), do: socket

  # The open thread's conversation. Nothing is read without a card: no thread is open, or its id
  # is not one of this project's (that never reaches `Transcript`). The pane re-reads the whole
  # transcript and holds no cursor, so it asks for one turn per stored output chunk
  # (`chunks: true`): nothing is grouped, so nothing is withheld and no grouping gap applies, and
  # `ThreadView.log/3` assembles the chunks into the conversation. A streamed message is one
  # stored entry per delta, so it reads everything the store keeps (`log_limit`), not the API's
  # 500-entry tail, and `ThreadView.log/3` says how many entries are gone when the store dropped
  # any.
  defp load_log(%{assigns: %{thread_card: nil}} = socket), do: assign(socket, :thread_log, nil)

  defp load_log(%{assigns: %{thread_card: %ThreadCard{thread_id: thread_id}}} = socket) do
    opts = [chunks: true, log_limit: ProjectionStore.run_logs_max_limit()]

    log =
      case Transcript.full(thread_id, opts) do
        {:ok, %Full{turns: turns, terminal: terminal?, omitted_entries: omitted}} ->
          turns
          |> ThreadView.log(terminal?, omitted_entries: omitted)
          |> redact_blocks(socket.assigns.project_id)

        {:error, :thread_not_found} ->
          :unavailable

        {:error, reason} ->
          Logger.warning("workspace: transcript of #{thread_id} unavailable: #{inspect(reason)}")
          :unavailable
      end

    assign(socket, :thread_log, log)
  end

  # Redaction runs per stored chunk, so a secret that straddles two chunks survives it. Once
  # `ThreadView.log/3` has joined the chunks, the redactor `Transcript` uses (the built-in
  # patterns and the project's secrets) runs again over each block's text: a split secret is gone
  # as soon as its last chunk is in. Limits: a secret's PREFIX can show until then, and a message
  # whose deltas hide a split secret is shown twice (its deltas no longer equal the redacted
  # final), both redacted. The stored chunks stay redacted per chunk until the worker stores one
  # entry per message (foreman-l30ao.5).
  defp redact_blocks(%{blocks: blocks} = log, project_id) do
    redact = Redact.redactor(project_id)
    %{log | blocks: Enum.map(blocks, &%{&1 | text: redact.(&1.text)})}
  end

  # The thread whose worker output `Refresh.note_output/3` listens for: the open one, once it is
  # known to be this project's.
  defp open_thread_id(%{assigns: %{thread_card: %ThreadCard{thread_id: thread_id}}}),
    do: thread_id

  defp open_thread_id(_socket), do: nil

  # Read-only side-panel data: the project's memory topics and library entries. A missing
  # on-disk directory is already an empty list; a genuine read failure (unknown project,
  # absent path, IO error) returns `:error` so the panel can render an unavailable state
  # distinct from an empty collection, instead of masking the failure as "nothing here".
  defp memory_topics(project_id) do
    case ProjectMemory.list(project_id) do
      {:ok, topics} -> topics
      {:error, _} -> :error
    end
  end

  defp library_entries(project_id) do
    case Library.list(project_id) do
      {:ok, entries} -> entries
      {:error, _} -> :error
    end
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
      <header class="ws-header">
        <div class="ws-header-title">
          <h1>{@project_view.name}</h1>
          <p :if={@project_view.goal} class="ws-goal" title={@project_view.goal}>{@project_view.goal}</p>
        </div>
        <nav class="ws-header-actions" aria-label="Project">
          <span :if={@project_view.status} class={["chip", project_chip_kind(@project_view.status)]} role="status">{@project_view.status}</span>
          <.link navigate={Components.settings_path(@project_id, @token)} class="btn ws-btn">Settings</.link>
        </nav>
        <div id="notice" role="status" aria-live="polite" class={@notice_kind == :error && "ws-error"}>{@notice}</div>
      </header>
      <div class="ws-layout">
        <Components.thread_sidebar
          project_id={@project_id}
          token={@token}
          overview={@overview}
          selected_id={@thread_id}
          status={@status}
        />
        <div class="ws-main-col">
          <Components.conversation_pane
            :if={@live_action == :show}
            messages={@messages}
            status={@status}
            proposals={@proposals}
            has_earlier={@has_earlier}
            truncated_before_seq={@truncated_before_seq}
            draft_id={@draft_id}
          />
          <Components.thread_pane
            :if={@live_action == :thread and @thread_card}
            card={@thread_card}
            log={@thread_log}
            project_id={@project_id}
            token={@token}
            confirm_stop={@confirm_stop}
            steer_nonce={@steer_nonce}
          />
          <Components.thread_missing :if={@live_action == :thread and is_nil(@thread_card)} project_id={@project_id} token={@token} />
        </div>
        <aside class="ws-side" aria-label="Project panels">
          <div id="questions-live" aria-live="polite" aria-relevant="additions text">
            <Components.questions_pane questions={@questions} />
          </div>
          <section class="ws-panels" aria-label="Project knowledge">
            <Components.info_panels
              instructions={@project_view.instructions}
              settings_path={Components.settings_path(@project_id, @token)}
              memory_topics={@memory_topics}
              library_entries={@library_entries}
              upload={@uploads.library}
              folder_upload={@uploads.library_folder}
              library_name={@library_name}
              library_folder_name={@library_folder_name}
              library_limits={@library_limits}
            />
          </section>
          <Components.tabs_pane
            tab={@tab}
            tabs={@overview.tabs}
            schedules={@schedules}
            replace_upload={@uploads.library_replace}
            confirm_remove={@confirm_remove}
            confirm_delete={@confirm_delete}
            replace_entry={@replace_entry}
            open_entry={@open_entry}
            library_limits={@library_limits}
          />
        </aside>
      </div>
    </main>
    """
  end
end
