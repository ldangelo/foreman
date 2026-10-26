defmodule ForemanServerWeb.ProjectSettingsLive do
  @moduledoc """
  Project settings: `GET /dashboard/projects/:id/settings` (authenticated).

  Edits what E1 stores through `project.update` (goal, instructions with a live
  character counter against the server's 16000 limit, thread and coordinator
  model/effort, limits, tuning, the notification preference, the repository
  allowlist and the per-run repository cap), the setup script through the
  operator-only `project.environment.set` (arbitrary shell code the server runs
  in every new run worktree, so it has its own form and warning), the extra
  repositories through `project.repo.add|remove` (the commands behind
  `foreman project repo`), the project lifecycle (`project.pause|resume|
  archive|reactivate`, each behind a confirm step), the project memory (E2:
  list, edit, delete via `ForemanServer.ProjectMemory`, the same functions the
  HTTP controller calls) and shows the usage rollup (E14, `UsageDTO`). None of
  it adds a command or an HTTP route: every action calls the existing operator
  path.

  Validation is the server's: the form sends what was typed and renders the
  aggregate's distinct error tuple next to the field it belongs to; nothing is
  checked client-side only. A save sends only the fields the operator changed.

  The environment has forms of its own. Plain variables are set and removed one at a
  time through `project.environment.set` (the command behind `foreman project env`).
  That command replaces the variable set, so the new set is built from what the server
  stores at that moment and a variable changed elsewhere survives; the aggregate refuses
  a name that looks like a secret, as on the CLI. Secrets are WRITE-ONLY: the value goes
  straight to `ForemanServer.SecretStore` through `ForemanServer.ProjectSecrets` (the
  path behind `foreman project secret` and `PUT /api/projects/:id/secrets/:name`), the
  page lists only name, version and time, its form has no `phx-change` (nothing typed
  reaches the server before the submit) and no assign, log line, event or rendered
  attribute ever holds a value. The listing is `ProjectEnvironmentDTO`, the read the
  HTTP and MCP surfaces share, so the values of a legacy `config.env` stay hidden.
  """

  use ForemanServerWeb, :live_view

  require Logger

  alias ForemanServer.Aggregates.Project.{Environment, Settings}

  alias ForemanServer.{
    ProjectEnvironment,
    ProjectEnvironmentDTO,
    ProjectMemory,
    ProjectionStore,
    ProjectSettings,
    ProjectStore,
    UsageDTO
  }

  alias ForemanServer.AgentRuntime.JidoHarness
  alias ForemanServer.ProjectMemory.Error, as: MemoryError
  alias ForemanServer.SecretStore.Error, as: SecretError
  alias ForemanServerWeb.Workspace.{Actions, ProjectNotFound, ProjectView, Refresh}

  @text_fields ~w(goal instructions thread_model thread_effort coordinator_provider coordinator_model
                  coordinator_effort notification_preference)a
  @int_fields ~w(max_concurrent_runs daily_thread_cap coordinator_max_active_threads
                 max_repos_per_run)a
  @bool_fields ~w(coordinator_propose_before_start coordinator_reuse_threads)a
  # A textarea with one entry per line, stored as a list of strings.
  @list_fields ~w(repo_allowlist)a
  @blank_repo_form %{"id" => "", "path" => "", "default_branch" => ""}
  @blank_env_form %{"name" => ""}
  @blank_secret_form %{"name" => ""}
  # The aggregate's repository errors, by the field of the add form that owns them.
  @repo_id_errors ~w(invalid_repo_id repo_id_taken)a
  @repo_path_errors ~w(repo_path_not_absolute repo_path_not_found repo_not_git_work_tree
                       repo_path_duplicate repo_remote_duplicate)a
  @lifecycle %{
    "pause" => :pause,
    "resume" => :resume,
    "archive" => :archive,
    "reactivate" => :reactivate
  }

  @impl true
  def mount(%{"id" => project_id}, _session, socket) do
    case ProjectStore.get(project_id) do
      nil ->
        raise ProjectNotFound, project_id: project_id

      _project ->
        socket =
          socket
          |> Refresh.init()
          |> assign(
            page_title: "Settings: #{project_id}",
            project_id: project_id,
            notice: nil,
            notice_kind: :ok,
            errors: %{},
            confirm_lifecycle: nil,
            selected_memory: nil,
            memory_confirm_delete: false,
            memory_error: nil,
            confirm_repo_remove: nil,
            repo_form: @blank_repo_form,
            repo_errors: %{},
            env_add_form: @blank_env_form,
            env_add_errors: %{},
            env_errors: %{},
            env_nonce: 0,
            confirm_env_remove: nil,
            secret_form: @blank_secret_form,
            secret_errors: %{},
            secret_nonce: 0,
            confirm_secret_unset: nil
          )
          |> load()
          |> load_form()
          |> assign(:instructions_length, 0)
          |> sync_counter()

        {:ok, socket}
    end
  end

  @impl true
  def handle_info({:projection_event, event}, socket),
    do: {:noreply, Refresh.note_event(socket, event, socket.assigns.project_id)}

  # A refresh re-reads the read-only panes (status, limits, usage, memory) but
  # never overwrites the form the operator may be typing in.
  def handle_info(:workspace_refresh, socket),
    do: {:noreply, socket |> Refresh.begin_refresh() |> load()}

  def handle_info(other, socket) do
    Logger.warning("settings page received an unexpected message: #{inspect(other, limit: 5)}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("validate", %{"settings" => params}, socket) do
    form = Map.merge(socket.assigns.form, normalize_newlines(params))
    {:noreply, socket |> assign(:form, form) |> sync_counter()}
  end

  def handle_event("save", %{"settings" => params}, socket) do
    form = Map.merge(socket.assigns.form, normalize_newlines(params))
    socket = socket |> assign(:form, form) |> sync_counter()

    # Only what the operator changed since the page (or the last save) loaded:
    # a setting changed elsewhere in the meantime is never written back.
    case changed_settings(form, socket.assigns.baseline) do
      changed when map_size(changed) == 0 ->
        {:noreply, assign(socket, errors: %{}, notice: "No changes to save.", notice_kind: :ok)}

      changed ->
        case Actions.update_settings(
               socket.assigns.project_id,
               to_settings(changed),
               Refresh.intent(socket)
             ) do
          :ok ->
            baseline = Map.merge(socket.assigns.baseline, Map.take(form, Map.keys(changed)))

            {:noreply,
             socket
             |> assign(
               baseline: baseline,
               errors: %{},
               notice: "Settings saved.",
               notice_kind: :ok
             )
             |> load()}

          {:error, reason} ->
            {:noreply, assign_error(socket, reason)}
        end
    end
  end

  def handle_event("confirm_lifecycle", %{"op" => op}, socket) when is_map_key(@lifecycle, op),
    do: {:noreply, assign(socket, :confirm_lifecycle, op)}

  def handle_event("cancel_lifecycle", _params, socket),
    do: {:noreply, assign(socket, :confirm_lifecycle, nil)}

  def handle_event("lifecycle", %{"op" => op}, socket) when is_map_key(@lifecycle, op) do
    {kind, message} =
      Actions.project_lifecycle(
        socket.assigns.project_id,
        Map.fetch!(@lifecycle, op),
        Refresh.intent(socket)
      )

    {:noreply,
     socket |> assign(confirm_lifecycle: nil, notice: message, notice_kind: kind) |> load()}
  end

  # The setup script has its own form and baseline: another command writes it
  # (`project.environment.set`, operator-only) than the one behind the settings.
  def handle_event("validate_setup_script", %{"setup_script" => %{"script" => raw}}, socket)
      when is_binary(raw) do
    {:noreply, assign(socket, :script_form, unix_newlines(raw))}
  end

  def handle_event("save_setup_script", %{"setup_script" => %{"script" => raw}}, socket)
      when is_binary(raw) do
    text = unix_newlines(raw)
    script = blank_to_nil(text)
    socket = assign(socket, :script_form, text)

    # Whitespace only is "no script" on both sides: only a real change is sent.
    if script == blank_to_nil(socket.assigns.script_baseline) do
      notice = "No changes to the setup script."
      {:noreply, assign(socket, script_error: nil, notice: notice, notice_kind: :ok)}
    else
      {:noreply, write_setup_script(socket, script)}
    end
  end

  def handle_event("repo_confirm_remove", %{"id" => id}, socket) when is_binary(id),
    do: {:noreply, assign(socket, :confirm_repo_remove, id)}

  def handle_event("repo_cancel_remove", _params, socket),
    do: {:noreply, assign(socket, :confirm_repo_remove, nil)}

  def handle_event("repo_remove", %{"id" => id}, socket) when is_binary(id) do
    case Actions.remove_repository(socket.assigns.project_id, id, Refresh.intent(socket)) do
      :ok ->
        notice = "Removed repository #{id}."

        {:noreply,
         socket
         |> assign(confirm_repo_remove: nil, notice: notice, notice_kind: :ok)
         |> load()}

      {:error, reason} ->
        notice = "Could not remove #{id}: " <> Actions.describe(reason)
        {:noreply, assign(socket, confirm_repo_remove: nil, notice: notice, notice_kind: :error)}
    end
  end

  def handle_event("repo_add", %{"repo" => params}, socket) do
    id = repo_param(params, "id")
    path = repo_param(params, "path")
    branch = repo_param(params, "default_branch")
    form = %{"id" => id, "path" => path, "default_branch" => branch}
    repo = %{id: id, path: path, default_branch: blank_to_nil(branch)}

    case Actions.add_repository(socket.assigns.project_id, repo, Refresh.intent(socket)) do
      :ok ->
        notice = "Added repository #{id}."
        socket = assign(socket, repo_form: @blank_repo_form, repo_errors: %{})
        {:noreply, socket |> assign(notice: notice, notice_kind: :ok) |> load()}

      {:error, reason} ->
        {:noreply, assign_repo_error(socket, form, reason)}
    end
  end

  # -- environment variables and secrets ---------------------------------------
  # A plain variable goes through `project.environment.set`, one per submit. A secret value
  # is write-only (moduledoc): neither form has a `phx-change`, and the value is passed on and
  # forgotten, never assigned.

  def handle_event("env_save", %{"env" => %{"name" => name, "value" => value}}, socket)
      when is_binary(name) and is_binary(value),
      do: {:noreply, write_env_var(socket, name, value, :row)}

  def handle_event("env_add", %{"env" => %{"name" => name, "value" => value}}, socket)
      when is_binary(name) and is_binary(value),
      do: {:noreply, write_env_var(socket, String.trim(name), value, :add)}

  def handle_event("env_confirm_remove", %{"name" => name}, socket) when is_binary(name),
    do: {:noreply, assign(socket, :confirm_env_remove, name)}

  def handle_event("env_cancel_remove", _params, socket),
    do: {:noreply, assign(socket, :confirm_env_remove, nil)}

  def handle_event("env_remove", %{"name" => name}, socket) when is_binary(name) do
    socket = assign(socket, :confirm_env_remove, nil)

    case Actions.unset_env_var(socket.assigns.project_id, name, Refresh.intent(socket)) do
      :ok ->
        {:noreply,
         socket
         |> assign(env_errors: %{}, notice: "Removed #{name}.", notice_kind: :ok)
         |> load()}

      {:error, reason} ->
        notice = "Could not remove #{name}: " <> Actions.describe(reason)
        {:noreply, socket |> assign(notice: notice, notice_kind: :error) |> load()}
    end
  end

  def handle_event("secret_set", %{"secret" => %{"name" => name, "value" => value}}, socket)
      when is_binary(name) and is_binary(value),
      do: {:noreply, write_secret(socket, String.trim(name), value)}

  def handle_event("secret_confirm_unset", %{"name" => name}, socket) when is_binary(name),
    do: {:noreply, assign(socket, :confirm_secret_unset, name)}

  def handle_event("secret_cancel_unset", _params, socket),
    do: {:noreply, assign(socket, :confirm_secret_unset, nil)}

  def handle_event("secret_unset", %{"name" => name}, socket) when is_binary(name) do
    socket = assign(socket, :confirm_secret_unset, nil)

    case Actions.unset_secret(socket.assigns.project_id, name) do
      {:ok, _result} ->
        {:noreply,
         socket |> assign(notice: "Removed secret #{name}.", notice_kind: :ok) |> load()}

      {:error, reason} ->
        notice = "Could not remove secret #{name}: " <> Actions.describe(reason)
        {:noreply, socket |> assign(notice: notice, notice_kind: :error) |> load()}
    end
  end

  def handle_event("memory_select", %{"name" => name}, socket) do
    case ProjectMemory.read(socket.assigns.project_id, name) do
      {:ok, topic, content} ->
        {:noreply,
         assign(socket,
           selected_memory: %{
             name: topic.name,
             description: topic.description || "",
             content: content
           },
           memory_confirm_delete: false,
           memory_error: nil
         )}

      {:error, %MemoryError{message: message}} ->
        {:noreply, assign(socket, :memory_error, message)}
    end
  end

  def handle_event("memory_save", %{"memory" => params}, socket) do
    attrs = %{
      name: params["name"],
      description: blank_to_nil(params["description"]),
      content: params["content"] || ""
    }

    case ProjectMemory.write(socket.assigns.project_id, attrs, %{
           kind: :operator,
           ref: "dashboard"
         }) do
      {:ok, topic} ->
        {:noreply,
         socket
         |> assign(
           selected_memory: Map.put(attrs, :description, attrs.description || ""),
           memory_error: nil
         )
         |> assign(notice: "Saved memory #{topic.name}.", notice_kind: :ok)
         |> load()}

      {:error, %MemoryError{message: message}} ->
        {:noreply, assign(socket, :memory_error, message)}
    end
  end

  def handle_event("memory_new", _params, socket),
    do:
      {:noreply,
       assign(socket,
         selected_memory: %{name: "", description: "", content: ""},
         memory_error: nil
       )}

  def handle_event("memory_confirm_delete", _params, socket),
    do: {:noreply, assign(socket, :memory_confirm_delete, true)}

  def handle_event(
        "memory_delete",
        _params,
        %{assigns: %{selected_memory: %{name: name}}} = socket
      ) do
    case ProjectMemory.forget(socket.assigns.project_id, name, %{
           kind: :operator,
           ref: "dashboard"
         }) do
      {:ok, _topic} ->
        {:noreply,
         socket
         |> assign(selected_memory: nil, memory_confirm_delete: false, memory_error: nil)
         |> assign(notice: "Forgot memory #{name}.", notice_kind: :ok)
         |> load()}

      {:error, %MemoryError{message: message}} ->
        {:noreply, assign(socket, memory_confirm_delete: false, memory_error: message)}
    end
  end

  def handle_event("memory_delete", _params, socket),
    do:
      {:noreply,
       assign(socket, memory_confirm_delete: false, memory_error: "No topic is selected.")}

  # -- state -----------------------------------------------------------------

  defp load(socket) do
    project_id = socket.assigns.project_id

    case ProjectStore.get(project_id) do
      %{} = project ->
        view = ProjectView.build(project, project_id)

        assign(socket,
          project: project,
          status: view.status,
          env: environment(project_id),
          repos: ProjectionStore.project_repositories(project_id) || [],
          usage: usage(project_id),
          limits: limits(project_id),
          memory: memory(project_id)
        )

      nil ->
        # The project vanished while the page was open (for example the
        # projection was rebuilt): say so, and show the reads as failed.
        assign(socket,
          repos: [],
          usage: usage(project_id),
          limits: limits(project_id),
          notice: "This project no longer exists.",
          notice_kind: :error
        )
    end
  end

  defp load_form(socket) do
    config = Map.get(socket.assigns.project, :config)
    settings = ProjectSettings.from_config(config)
    script = ProjectEnvironment.from_config(config)["setup_script"] || ""

    form =
      Map.new(@text_fields ++ @int_fields ++ @bool_fields ++ @list_fields, fn key ->
        {Atom.to_string(key), form_value(Map.get(settings, key))}
      end)

    assign(socket,
      form: form,
      baseline: form,
      script_form: script,
      script_baseline: script,
      script_error: nil
    )
  end

  defp form_value(nil), do: ""
  defp form_value(list) when is_list(list), do: Enum.join(list, "\n")
  defp form_value(value), do: to_string(value)

  defp sync_counter(socket),
    do:
      assign(
        socket,
        :instructions_length,
        String.length(socket.assigns.form["instructions"] || "")
      )

  # `{:ok, dto}` or `{:error, message}`: a failed read renders as an error, not
  # as an absent pane.
  defp usage(project_id) do
    with {:ok, params} <- UsageDTO.parse_params(%{}),
         {:ok, dto} <- UsageDTO.build(project_id, params, DateTime.utc_now()) do
      {:ok, dto}
    else
      :not_found ->
        {:error, "Usage unavailable: project not found."}

      {:error, {code, message}} ->
        Logger.warning("usage read failed: #{code}: #{message}")
        {:error, "Usage unavailable: #{message}"}
    end
  end

  defp limits(project_id) do
    case ProjectionStore.project_limits(project_id) do
      %{} = limits -> {:ok, limits}
      nil -> {:error, "Limits unavailable: project not found."}
    end
  end

  defp memory(project_id) do
    case ProjectMemory.list(project_id) do
      {:ok, topics} -> {:ok, topics}
      {:error, %MemoryError{message: message}} -> {:error, message}
    end
  end

  # -- form -> command -------------------------------------------------------

  # Form fields whose value differs from the baseline (string key => raw value).
  defp changed_settings(form, baseline) do
    for {key, base} <- baseline, Map.get(form, key, base) != base, into: %{}, do: {key, form[key]}
  end

  # Typed command payload for the changed fields only (atom key => typed value).
  defp to_settings(changed) do
    Map.new(changed, fn {key, raw} ->
      atom = String.to_existing_atom(key)

      cond do
        atom in @text_fields -> {atom, blank_to_nil(raw)}
        atom in @int_fields -> {atom, int_or_raw(raw)}
        atom in @bool_fields -> {atom, bool(raw)}
        atom in @list_fields -> {atom, lines_or_nil(raw)}
      end
    end)
  end

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(_), do: nil

  defp int_or_raw(value) do
    case blank_to_nil(value) do
      nil ->
        nil

      text ->
        case Integer.parse(String.trim(text)) do
          {n, ""} -> n
          _ -> text
        end
    end
  end

  defp bool("true"), do: true
  defp bool("false"), do: false
  defp bool(_), do: nil

  # One entry per non-blank line; no lines at all clears the setting.
  defp lines_or_nil(text) when is_binary(text) do
    lines =
      text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if lines == [], do: nil, else: lines
  end

  # Browsers submit textarea newlines as CRLF while the stored text (and so the
  # baseline) has LF only. Normalised once here, an untouched multi-line field is
  # not a change, the instructions counter counts a newline once and no stored
  # text carries a `\r`.
  defp normalize_newlines(params) do
    Map.new(params, fn
      {key, value} when is_binary(value) -> {key, unix_newlines(value)}
      other -> other
    end)
  end

  defp unix_newlines(text), do: String.replace(text, "\r\n", "\n")

  # The aggregate's distinct error tuples name their setting in the first
  # element (`{:goal_too_long, n, max}`, `{:invalid_setting, :coordinator_provider, _}`).
  defp assign_error(socket, reason) do
    case error_field(reason) do
      nil ->
        assign(socket,
          errors: %{},
          notice: "Could not save: " <> Actions.describe(reason),
          notice_kind: :error
        )

      field ->
        assign(socket,
          errors: %{field => Actions.describe(reason)},
          notice: "Fix the highlighted field.",
          notice_kind: :error
        )
    end
  end

  defp error_field({:invalid_setting, key, _}) when is_atom(key), do: key
  defp error_field({:setting_set_and_cleared, key}) when is_atom(key), do: key
  # Its tag does not start with the name of its setting: the prefix rule below misses it.
  defp error_field({:invalid_repo_allowlist, _entry}), do: :repo_allowlist

  defp error_field(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    tag = elem(reason, 0)

    if is_atom(tag) do
      Enum.find(Settings.keys(), fn key ->
        String.starts_with?(Atom.to_string(tag), Atom.to_string(key) <> "_")
      end)
    end
  end

  defp error_field(_), do: nil

  # Installs `script` (nil removes it); the form's baseline moves to what was written.
  defp write_setup_script(socket, script) do
    project_id = socket.assigns.project_id
    intent = Refresh.intent(socket)

    case Actions.update_setup_script(project_id, script, intent) do
      :ok ->
        text = script || ""
        notice = if script, do: "Setup script saved.", else: "Setup script removed."

        socket
        |> assign(
          script_form: text,
          script_baseline: text,
          script_error: nil,
          notice: notice,
          notice_kind: :ok
        )
        |> load()

      {:error, reason} ->
        assign(socket,
          script_error: Actions.describe(reason),
          notice: "Fix the highlighted field.",
          notice_kind: :error
        )
    end
  end

  # An absent field of the add form is blank: the server then names what is wrong.
  defp repo_param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) -> String.trim(value)
      :error -> ""
    end
  end

  defp assign_repo_error(socket, form, reason) do
    message = Actions.describe(reason)

    case repo_error_field(reason) do
      nil ->
        assign(socket,
          repo_form: form,
          repo_errors: %{},
          notice: "Could not add: " <> message,
          notice_kind: :error
        )

      field ->
        assign(socket,
          repo_form: form,
          repo_errors: %{field => message},
          notice: "Fix the highlighted field.",
          notice_kind: :error
        )
    end
  end

  # The field of the add form that owns an aggregate error (nil: it belongs to none).
  defp repo_error_field({tag, _detail}) when tag in @repo_id_errors, do: :id
  defp repo_error_field({tag, _detail}) when tag in @repo_path_errors, do: :path
  defp repo_error_field({:invalid_default_branch, _branch}), do: :default_branch
  defp repo_error_field(_reason), do: nil

  # -- environment: plain variables and write-only secrets ---------------------

  # What the page lists. One read, the one the HTTP and MCP surfaces share
  # (`ProjectEnvironmentDTO`): the values of a legacy `config.env` come back redacted
  # there, so they are never rendered (a project without any variable is not "legacy"
  # here), and a secret is only ever a name, a version and a time.
  defp environment(project_id) do
    case ProjectEnvironmentDTO.fetch(project_id) do
      {:ok, %{"vars" => vars, "legacy_env" => legacy?, "secrets" => secrets}} ->
        hidden? = legacy? and map_size(vars) > 0

        %{
          vars: Enum.map(Enum.sort(vars), &listed_var(&1, hidden?)),
          legacy?: hidden?,
          secrets: Enum.map(secrets, &listed_secret/1)
        }

      :not_found ->
        %{vars: [], legacy?: false, secrets: []}
    end
  end

  defp listed_var({name, _redacted}, true), do: {name, :hidden}
  defp listed_var({name, value}, false), do: {name, value}

  defp listed_secret(%{"name" => name, "version" => version, "updated_at" => updated_at}),
    do: %{name: name, version: version, updated_at: updated_at}

  # `source` is the form the variable came from, the `:row` of a listed variable or the
  # `:add` form: it decides where a refusal shows. After an add, the box is emptied (its
  # wrapper gets a new id, so the browser drops what was typed); a refused add keeps the
  # NAME but never the value, which may be the secret the operator typed into the wrong form.
  defp write_env_var(socket, name, value, source) do
    case Actions.set_env_var(socket.assigns.project_id, name, value, Refresh.intent(socket)) do
      :ok ->
        socket
        |> reset_env_add_form(source)
        |> assign(env_errors: %{}, notice: "Set #{name}.", notice_kind: :ok)
        |> load()

      {:error, reason} ->
        {field, message} = env_error(reason, name)
        assign_env_error(socket, name, source, field, message)
    end
  end

  defp reset_env_add_form(socket, :add),
    do:
      socket
      |> assign(env_add_form: @blank_env_form, env_add_errors: %{})
      |> update(:env_nonce, &(&1 + 1))

  defp reset_env_add_form(socket, :row), do: socket

  defp assign_env_error(socket, name, :row, nil, message),
    do: assign(socket, notice: "Could not set #{name}: " <> message, notice_kind: :error)

  defp assign_env_error(socket, name, :row, _field, message),
    do:
      assign(socket,
        env_errors: %{name => message},
        notice: "Fix the highlighted field.",
        notice_kind: :error
      )

  defp assign_env_error(socket, name, :add, field, message) do
    socket = socket |> assign(:env_add_form, %{"name" => name}) |> update(:env_nonce, &(&1 + 1))

    if field do
      assign(socket,
        env_add_errors: %{field => message},
        notice: "Fix the highlighted field.",
        notice_kind: :error
      )
    else
      assign(socket,
        env_add_errors: %{},
        notice: "Could not set #{name}: " <> message,
        notice_kind: :error
      )
    end
  end

  # The field that owns the aggregate's refusal of the variable just typed, with its words;
  # `nil` for a refusal about another variable or the project (a stored variable that looks
  # like a secret, a full set, an archived project): the notice carries those.
  defp env_error({:secret_in_vars, name}, name),
    do:
      {:name,
       "#{name} looks like a secret, so it cannot be a plain variable (plain values are " <>
         "stored in the event log). Set it under Secrets instead."}

  defp env_error({:reserved_env_name, name}, name),
    do: {:name, "Names starting with FOREMAN_ are reserved for Foreman."}

  defp env_error({:invalid_env_name, name} = reason, name),
    do: {:name, Actions.describe(reason)}

  defp env_error({tag, name} = reason, name)
       when tag in [:env_value_invalid, :env_value_too_long],
       do: {:value, Actions.describe(reason)}

  defp env_error(reason, _typed), do: {nil, Actions.describe(reason)}

  # The value is handed to the secret store and forgotten here. A refusal keeps the NAME
  # typed, empties the value box (new wrapper id) and says what is wrong with the name or the
  # value (the store never echoes the value); anything else is not about a field.
  defp write_secret(socket, name, value) do
    case Actions.set_secret(socket.assigns.project_id, name, value) do
      {:ok, %{version: version}} ->
        socket
        |> assign(
          secret_form: @blank_secret_form,
          secret_errors: %{},
          notice: "Saved secret #{name} (version #{version}).",
          notice_kind: :ok
        )
        |> update(:secret_nonce, &(&1 + 1))
        |> load()

      {:error, reason} ->
        socket
        |> assign(:secret_form, %{"name" => name})
        |> update(:secret_nonce, &(&1 + 1))
        |> assign_secret_error(reason)
    end
  end

  defp assign_secret_error(socket, reason) do
    message = Actions.describe(reason)

    case secret_error_field(reason) do
      nil ->
        assign(socket,
          secret_errors: %{},
          notice: "Could not save the secret: " <> message,
          notice_kind: :error
        )

      field ->
        assign(socket,
          secret_errors: %{field => message},
          notice: "Fix the highlighted field.",
          notice_kind: :error
        )
    end
  end

  defp secret_error_field(%SecretError{code: :invalid_secret_name}), do: :name
  defp secret_error_field(%SecretError{code: :invalid_secret_value}), do: :value
  defp secret_error_field(_reason), do: nil

  # -- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        efforts: Settings.efforts(),
        providers: Enum.map(JidoHarness.providers(), &Atom.to_string/1),
        notification_preferences: Settings.notification_preferences(),
        default_max_repos: Settings.default_max_repos_per_run(),
        max_instructions: Settings.max_instructions_chars(),
        max_script_bytes: Environment.max_script_bytes(),
        max_env_value_bytes: Environment.max_value_bytes()
      )

    ~H"""
    <main id="main">
      <header>
        <h1>Settings: {@project_id}</h1>
        <nav aria-label="Project"><.link navigate={"/dashboard/projects/#{@project_id}"}>Back to workspace</.link></nav>
        <div id="notice" role="status" aria-live="polite" class={@notice_kind == :error && "ws-error"}>{@notice}</div>
      </header>

      <section aria-labelledby="lifecycle-h">
        <h2 id="lifecycle-h">Lifecycle</h2>
        <p>Status: <strong>{@status}</strong></p>
        <%= for {op, label} <- lifecycle_buttons(@status) do %>
          <%= if @confirm_lifecycle == op do %>
            <button type="button" phx-click="lifecycle" phx-value-op={op}>Confirm {label}</button>
            <button type="button" phx-click="cancel_lifecycle">Cancel</button>
          <% else %>
            <button type="button" phx-click="confirm_lifecycle" phx-value-op={op}>{label}</button>
          <% end %>
        <% end %>
      </section>

      <form id="settings-form" phx-change="validate" phx-submit="save" aria-labelledby="settings-h">
        <h2 id="settings-h">Settings</h2>
        <.field name="goal" label="Goal" errors={@errors} form={@form} kind="textarea" />
        <div>
          <label for="settings_instructions">Instructions</label>
          <textarea id="settings_instructions" name="settings[instructions]" rows="8" aria-describedby="instructions-counter instructions-error">{@form["instructions"]}</textarea>
          <p id="instructions-counter" aria-live="polite" class={@instructions_length > @max_instructions && "ws-error"}>{@instructions_length} / {@max_instructions} characters</p>
          <p id="instructions-error" :if={@errors[:instructions]} class="ws-error" role="alert">{@errors[:instructions]}</p>
        </div>
        <.field name="thread_model" label="Thread model" errors={@errors} form={@form} />
        <.field name="thread_effort" label="Thread effort" errors={@errors} form={@form} options={@efforts} />
        <.field name="coordinator_provider" label="Coordinator provider" errors={@errors} form={@form} options={@providers} />
        <.field name="coordinator_model" label="Coordinator model" errors={@errors} form={@form} />
        <.field name="coordinator_effort" label="Coordinator effort" errors={@errors} form={@form} options={@efforts} />
        <.field name="max_concurrent_runs" label="Max concurrent runs" errors={@errors} form={@form} kind="number" />
        <.field name="daily_thread_cap" label="Daily thread cap" errors={@errors} form={@form} kind="number" />
        <.field name="coordinator_max_active_threads" label="Coordinator max active threads" errors={@errors} form={@form} kind="number" />
        <.field name="coordinator_propose_before_start" label="Propose before starting" errors={@errors} form={@form} options={["true", "false"]} />
        <.field name="coordinator_reuse_threads" label="Reuse threads" errors={@errors} form={@form} options={["true", "false"]} />
        <.field name="notification_preference" label="Notifications" errors={@errors} form={@form} options={@notification_preferences} help="Which updates reach the project's notification channel. (default) is blocked_only: failures, stalls and requests that need you." />
        <fieldset>
          <legend>Repository requests by agents</legend>
          <p id="repo_allowlist-warning" class="ws-error">Warning: only an operator can change this. Agents of this project may attach any repository under these path prefixes to a run. Leave the list empty to forbid that. The coordinator and agents cannot change it.</p>
          <.field name="repo_allowlist" label="Repository allowlist" errors={@errors} form={@form} kind="textarea" help="One absolute path prefix per line." described_by={["repo_allowlist-warning"]} />
          <.field name="max_repos_per_run" label="Max repositories per run" errors={@errors} form={@form} kind="number" help={"Counting the primary repository (default #{@default_max_repos})."} />
        </fieldset>
        <button type="submit">Save settings</button>
      </form>

      <section aria-labelledby="repos-h">
        <h2 id="repos-h">Repositories</h2>
        <ul id="repo-list">
          <li :for={repo <- @repos} id={"repository-" <> repo.id}>
            <code>{repo.id}</code>
            <strong :if={repo.primary}>primary</strong>
            <span>{repo.path}</span>
            <span class="ws-muted">branch: {repo.default_branch || "current branch"}</span>
            <%= if not repo.primary do %>
              <%= if @confirm_repo_remove == repo.id do %>
                <button type="button" phx-click="repo_remove" phx-value-id={repo.id}>Confirm remove {repo.id}</button>
                <button type="button" phx-click="repo_cancel_remove">Cancel</button>
              <% else %>
                <button type="button" phx-click="repo_confirm_remove" phx-value-id={repo.id}>Remove {repo.id}</button>
              <% end %>
            <% end %>
          </li>
        </ul>
        <form id="repo-form" phx-submit="repo_add" aria-labelledby="repo-add-h">
          <h3 id="repo-add-h">Add a repository</h3>
          <div>
            <label for="repo_id">Repository id</label>
            <p id="repo-id-help" class="ws-muted">1-32 lowercase letters, digits or dashes</p>
            <input id="repo_id" type="text" name="repo[id]" value={@repo_form["id"]} aria-describedby="repo-id-help repo-id-error" aria-invalid={to_string(@repo_errors[:id] != nil)} />
            <p id="repo-id-error" :if={@repo_errors[:id]} class="ws-error" role="alert">{@repo_errors[:id]}</p>
          </div>
          <div>
            <label for="repo_path">Path on the server host</label>
            <p id="repo-path-help" class="ws-muted">Absolute path of an existing git checkout</p>
            <input id="repo_path" type="text" name="repo[path]" value={@repo_form["path"]} aria-describedby="repo-path-help repo-path-error" aria-invalid={to_string(@repo_errors[:path] != nil)} />
            <p id="repo-path-error" :if={@repo_errors[:path]} class="ws-error" role="alert">{@repo_errors[:path]}</p>
          </div>
          <div>
            <label for="repo_default_branch">Default branch (optional)</label>
            <p id="repo-default-branch-help" class="ws-muted">The branch worktrees are cut from; empty uses the checked-out branch</p>
            <input id="repo_default_branch" type="text" name="repo[default_branch]" value={@repo_form["default_branch"]} aria-describedby="repo-default-branch-help repo-default-branch-error" aria-invalid={to_string(@repo_errors[:default_branch] != nil)} />
            <p id="repo-default-branch-error" :if={@repo_errors[:default_branch]} class="ws-error" role="alert">{@repo_errors[:default_branch]}</p>
          </div>
          <button type="submit">Add repository</button>
        </form>
      </section>

      <section aria-labelledby="env-h">
        <h2 id="env-h">Environment</h2>
        <p id="env-help" class="ws-muted">Plain variables every agent of this project starts with. They are stored in the event log and shown here as typed (at most {@max_env_value_bytes} bytes each): put a password or token under Secrets instead.</p>
        <p :if={@env.legacy?} id="env-legacy-note">This project still keeps its variables in the legacy <code>config.env</code>, so their values are hidden here. Setting or removing any variable moves all of them into the environment record, which shows its values.</p>
        <p :if={@env.vars == []} class="ws-muted">No environment variables.</p>
        <ul :if={@env.vars != []} id="env-list">
          <li :for={{name, value} <- @env.vars} id={"env-var-" <> name}>
            <%= if value == :hidden do %>
              <code>{name}</code> <span class="ws-muted">value hidden</span>
            <% else %>
              <form id={"env-form-" <> name} phx-submit="env_save">
                <input type="hidden" name="env[name]" value={name} />
                <label for={"env_value_" <> name}>{name}</label>
                <input id={"env_value_" <> name} type="text" name="env[value]" value={value} autocomplete="off" spellcheck="false" aria-describedby={"env-error-" <> name} aria-invalid={to_string(@env_errors[name] != nil)} />
                <button type="submit">Save {name}</button>
              </form>
            <% end %>
            <%= if @confirm_env_remove == name do %>
              <button type="button" phx-click="env_remove" phx-value-name={name}>Confirm remove {name}</button>
              <button type="button" phx-click="env_cancel_remove">Cancel</button>
            <% else %>
              <button type="button" phx-click="env_confirm_remove" phx-value-name={name}>Remove {name}</button>
            <% end %>
            <p id={"env-error-" <> name} :if={@env_errors[name]} class="ws-error" role="alert">{@env_errors[name]}</p>
          </li>
        </ul>
        <form id="env-add-form" phx-submit="env_add" aria-labelledby="env-add-h">
          <h3 id="env-add-h">Set a variable</h3>
          <div>
            <label for="env_name">Name</label>
            <p id="env-name-help" class="ws-muted">Letters, digits and underscores, starting with a letter. An existing name gets the new value.</p>
            <input id="env_name" type="text" name="env[name]" value={@env_add_form["name"]} autocomplete="off" spellcheck="false" aria-describedby="env-name-help env-name-error" aria-invalid={to_string(@env_add_errors[:name] != nil)} />
            <p id="env-name-error" :if={@env_add_errors[:name]} class="ws-error" role="alert">{@env_add_errors[:name]}</p>
          </div>
          <div id={"env-value-box-#{@env_nonce}"}>
            <label for="env_value">Value</label>
            <input id="env_value" type="text" name="env[value]" autocomplete="off" spellcheck="false" aria-describedby="env-value-error" aria-invalid={to_string(@env_add_errors[:value] != nil)} />
            <p id="env-value-error" :if={@env_add_errors[:value]} class="ws-error" role="alert">{@env_add_errors[:value]}</p>
          </div>
          <button type="submit">Set variable</button>
        </form>
      </section>

      <section aria-labelledby="secrets-h">
        <h2 id="secrets-h">Secrets</h2>
        <p id="secrets-help" class="ws-muted">Write-only. A secret's value is kept on the server host, never in the event log, and never shown again, not even here; agents get it as an environment variable of that name. Setting an existing name replaces its value.</p>
        <p :if={@env.secrets == []} class="ws-muted">No secrets.</p>
        <ul :if={@env.secrets != []} id="secret-list">
          <li :for={secret <- @env.secrets} id={"secret-" <> secret.name}>
            <code>{secret.name}</code>
            <span class="ws-muted">version {secret.version}<span :if={secret.updated_at}>, set {secret.updated_at}</span></span>
            <%= if @confirm_secret_unset == secret.name do %>
              <button type="button" phx-click="secret_unset" phx-value-name={secret.name}>Confirm remove secret {secret.name}</button>
              <button type="button" phx-click="secret_cancel_unset">Cancel</button>
            <% else %>
              <button type="button" phx-click="secret_confirm_unset" phx-value-name={secret.name}>Remove secret {secret.name}</button>
            <% end %>
          </li>
        </ul>
        <form id="secret-form" phx-submit="secret_set" autocomplete="off" aria-labelledby="secret-add-h">
          <h3 id="secret-add-h">Set a secret</h3>
          <div>
            <label for="secret_name">Name</label>
            <p id="secret-name-help" class="ws-muted">Capital letters, digits and underscores, starting with a letter (for example DEPLOY_TOKEN); not FOREMAN_.</p>
            <input id="secret_name" type="text" name="secret[name]" value={@secret_form["name"]} autocomplete="off" spellcheck="false" aria-describedby="secret-name-help secret-name-error" aria-invalid={to_string(@secret_errors[:name] != nil)} />
            <p id="secret-name-error" :if={@secret_errors[:name]} class="ws-error" role="alert">{@secret_errors[:name]}</p>
          </div>
          <div id={"secret-value-box-#{@secret_nonce}"}>
            <label for="secret_value">Value</label>
            <input id="secret_value" type="password" name="secret[value]" autocomplete="new-password" aria-describedby="secrets-help secret-value-error" aria-invalid={to_string(@secret_errors[:value] != nil)} />
            <p id="secret-value-error" :if={@secret_errors[:value]} class="ws-error" role="alert">{@secret_errors[:value]}</p>
          </div>
          <button type="submit">Set secret</button>
        </form>
      </section>

      <section aria-labelledby="setup-script-h">
        <h2 id="setup-script-h">Setup script</h2>
        <p id="setup-script-warning" class="ws-error">Warning: the setup script is arbitrary shell code. It runs on the server host, as the server's user, in every new run worktree before any agent starts, with the project's environment variables and secrets. Only an operator can change it: not the coordinator, not agents.</p>
        <form id="setup-script-form" phx-change="validate_setup_script" phx-submit="save_setup_script">
          <label for="setup_script">Setup script</label>
          <p id="setup-script-help" class="ws-muted">Runs once per new worktree as sh -c. At most {@max_script_bytes} bytes. Leave empty to remove the script.</p>
          <textarea id="setup_script" name="setup_script[script]" rows="10" spellcheck="false" autocomplete="off" aria-describedby="setup-script-warning setup-script-help setup-script-error" aria-invalid={to_string(@script_error != nil)}>{Phoenix.HTML.Form.normalize_value("textarea", @script_form)}</textarea>
          <p id="setup-script-error" :if={@script_error} class="ws-error" role="alert">{@script_error}</p>
          <button type="submit">Save setup script</button>
        </form>
      </section>

      <section aria-labelledby="limits-h">
        <h2 id="limits-h">Limits and usage</h2>
        <%= case @limits do %>
          <% {:ok, limits} -> %>
            <dl id="limits-pane">
              <dt>Active runs</dt><dd>{limits.active_runs} / {limits.max_concurrent_runs}</dd>
              <dt>Threads started today</dt><dd>{limits.threads_started_today}<span :if={limits.daily_thread_cap}> / {limits.daily_thread_cap}</span></dd>
              <dt>Deferred tasks</dt><dd>{limits.deferred_tasks}</dd>
            </dl>
          <% {:error, message} -> %>
            <p id="limits-error" class="ws-error" role="alert">{message}</p>
        <% end %>
        <%= case @usage do %>
          <% {:ok, usage} -> %>
            <dl id="usage-pane">
              <dt>Total tokens</dt><dd>{usage["totals"]["total_tokens"]}</dd>
              <dt>Cost (USD)</dt><dd>{usage["totals"]["cost_usd"] || "unknown"}</dd>
              <dt>Threads with usage</dt><dd>{usage["thread_count"]}</dd>
            </dl>
          <% {:error, message} -> %>
            <p id="usage-error" class="ws-error" role="alert">{message}</p>
        <% end %>
      </section>

      <section aria-labelledby="memory-h">
        <h2 id="memory-h">Memory</h2>
        <p :if={@memory_error} class="ws-error" role="alert">{@memory_error}</p>
        <%= case @memory do %>
          <% {:error, message} -> %><p class="ws-error">{message}</p>
          <% {:ok, []} -> %><p class="ws-muted">No memory topics.</p>
          <% {:ok, topics} -> %>
            <ul>
              <li :for={t <- topics}>
                <button type="button" phx-click="memory_select" phx-value-name={t.name}>{t.name}</button>
                <span class="ws-muted"> {t.description} · {t.bytes} bytes</span>
              </li>
            </ul>
        <% end %>
        <button type="button" phx-click="memory_new">New topic</button>
        <form :if={@selected_memory} id="memory-form" phx-submit="memory_save">
          <label>Name <input type="text" name="memory[name]" value={@selected_memory.name} maxlength="64" /></label>
          <label>Description <input type="text" name="memory[description]" value={@selected_memory.description} maxlength="200" /></label>
          <label for="memory_content">Content</label>
          <textarea id="memory_content" name="memory[content]" rows="10">{@selected_memory.content}</textarea>
          <button type="submit">Save topic</button>
          <%= if @memory_confirm_delete do %>
            <button type="button" phx-click="memory_delete">Confirm forget</button>
          <% else %>
            <button type="button" phx-click="memory_confirm_delete">Forget topic</button>
          <% end %>
        </form>
      </section>
    </main>
    """
  end

  defp lifecycle_buttons("paused"), do: [{"resume", "Resume"}, {"archive", "Archive"}]
  defp lifecycle_buttons("archived"), do: [{"reactivate", "Reactivate"}]
  defp lifecycle_buttons(_), do: [{"pause", "Pause"}, {"archive", "Archive"}]

  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:form, :map, required: true)
  attr(:errors, :map, required: true)
  attr(:kind, :string, default: "text")
  attr(:options, :list, default: nil)
  attr(:help, :string, default: nil)
  attr(:described_by, :list, default: [])

  defp field(assigns) do
    assigns =
      assign(assigns,
        key: String.to_existing_atom(assigns.name),
        describedby: describedby(assigns)
      )

    ~H"""
    <div>
      <label for={"settings_#{@name}"}>{@label}</label>
      <p :if={@help} id={"#{@name}-help"} class="ws-muted">{@help}</p>
      <%= cond do %>
        <% @options -> %>
          <select id={"settings_#{@name}"} name={"settings[#{@name}]"} aria-describedby={@describedby}>
            <option value="" selected={@form[@name] == ""}>(default)</option>
            <option :for={o <- @options} value={o} selected={@form[@name] == o}>{o}</option>
          </select>
        <% @kind == "textarea" -> %>
          <textarea id={"settings_#{@name}"} name={"settings[#{@name}]"} rows="3" aria-describedby={@describedby} aria-invalid={to_string(@errors[@key] != nil)}>{@form[@name]}</textarea>
        <% true -> %>
          <input id={"settings_#{@name}"} type={@kind} name={"settings[#{@name}]"} value={@form[@name]} aria-describedby={@describedby} aria-invalid={to_string(@errors[@key] != nil)} />
      <% end %>
      <p id={"#{@name}-error"} :if={@errors[@key]} class="ws-error" role="alert">{@errors[@key]}</p>
    </div>
    """
  end

  # The ids that describe a control, in reading order: the caller's own (a warning), then
  # its help text and its error message.
  defp describedby(%{name: name, help: help, described_by: extra}) do
    help_ids = if help, do: ["#{name}-help"], else: []
    Enum.join(extra ++ help_ids ++ ["#{name}-error"], " ")
  end
end
