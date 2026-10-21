defmodule ForemanServerWeb.ProjectSettingsLive do
  @moduledoc """
  Project settings: `GET /dashboard/projects/:id/settings` (authenticated).

  Edits what E1 stores through `project.update` (goal, instructions with a live
  character counter against the server's 16000 limit, thread and coordinator
  model/effort, limits, tuning), the project lifecycle (`project.pause|resume|
  archive|reactivate`, each behind a confirm step), the project memory (E2:
  list, edit, delete via `ForemanServer.ProjectMemory`, the same functions the
  HTTP controller calls) and shows the usage rollup (E14, `UsageDTO`).

  Validation is the server's: the form sends what was typed and renders the
  aggregate's distinct error tuple next to the field it belongs to; nothing is
  checked client-side only. Environment values and secrets are never rendered
  (variable NAMES only; they are edited through `project.environment.set`).
  """

  use ForemanServerWeb, :live_view

  alias ForemanServer.Aggregates.Project.Settings
  alias ForemanServer.{ProjectMemory, ProjectSettings, ProjectStore, UsageDTO}
  alias ForemanServer.AgentRuntime.JidoHarness
  alias ForemanServer.ProjectMemory.Error, as: MemoryError
  alias ForemanServerWeb.Workspace.{Actions, ProjectNotFound, Refresh}

  @text_fields ~w(goal instructions thread_model thread_effort coordinator_provider coordinator_model
                  coordinator_effort)a
  @int_fields ~w(max_concurrent_runs daily_thread_cap coordinator_max_active_threads)a
  @bool_fields ~w(coordinator_propose_before_start coordinator_reuse_threads)a
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
            memory_error: nil
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

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("validate", %{"settings" => params}, socket) do
    {:noreply, socket |> assign(:form, Map.merge(socket.assigns.form, params)) |> sync_counter()}
  end

  def handle_event("save", %{"settings" => params}, socket) do
    form = Map.merge(socket.assigns.form, params)
    socket = socket |> assign(:form, form) |> sync_counter()

    case Actions.update_settings(socket.assigns.project_id, to_settings(form)) do
      :ok ->
        {:noreply,
         socket |> assign(errors: %{}, notice: "Settings saved.", notice_kind: :ok) |> load()}

      {:error, reason} ->
        {:noreply, assign_error(socket, reason)}
    end
  end

  def handle_event("confirm_lifecycle", %{"op" => op}, socket) when is_map_key(@lifecycle, op),
    do: {:noreply, assign(socket, :confirm_lifecycle, op)}

  def handle_event("cancel_lifecycle", _params, socket),
    do: {:noreply, assign(socket, :confirm_lifecycle, nil)}

  def handle_event("lifecycle", %{"op" => op}, socket) when is_map_key(@lifecycle, op) do
    {kind, message} =
      Actions.project_lifecycle(socket.assigns.project_id, Map.fetch!(@lifecycle, op))

    {:noreply,
     socket |> assign(confirm_lifecycle: nil, notice: message, notice_kind: kind) |> load()}
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

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # -- state -----------------------------------------------------------------

  defp load(socket) do
    project_id = socket.assigns.project_id
    project = ProjectStore.get(project_id)

    assign(socket,
      project: project,
      status: Map.get(project, :status),
      env_names: env_names(project),
      usage: usage(project_id),
      limits: limits(project_id),
      memory: memory(project_id)
    )
  end

  defp load_form(socket) do
    settings = ProjectSettings.from_config(Map.get(socket.assigns.project, :config))

    form =
      Map.new(@text_fields ++ @int_fields ++ @bool_fields, fn key ->
        {Atom.to_string(key), form_value(Map.get(settings, key))}
      end)

    assign(socket, :form, form)
  end

  defp form_value(nil), do: ""
  defp form_value(value), do: to_string(value)

  defp sync_counter(socket),
    do:
      assign(
        socket,
        :instructions_length,
        String.length(socket.assigns.form["instructions"] || "")
      )

  defp usage(project_id) do
    with {:ok, params} <- UsageDTO.parse_params(%{}),
         {:ok, dto} <- UsageDTO.build(project_id, params, DateTime.utc_now()) do
      dto
    else
      _ -> nil
    end
  end

  defp limits(project_id), do: ForemanServer.ProjectionStore.project_limits(project_id)

  defp memory(project_id) do
    case ProjectMemory.list(project_id) do
      {:ok, topics} -> {:ok, topics}
      {:error, %MemoryError{message: message}} -> {:error, message}
    end
  end

  # Names only, from either the legacy flat `env` map or the environment record.
  defp env_names(project) do
    config = Map.get(project, :config) || %{}
    environment = fetch(config, :environment)
    vars = if is_map(environment), do: fetch(environment, :vars), else: nil

    [fetch(config, :env), vars]
    |> Enum.flat_map(fn m -> if is_map(m), do: Map.keys(m), else: [] end)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  # -- form -> command -------------------------------------------------------

  defp to_settings(form) do
    text = Map.new(@text_fields, &{&1, blank_to_nil(form[Atom.to_string(&1)])})
    ints = Map.new(@int_fields, &{&1, int_or_raw(form[Atom.to_string(&1)])})
    bools = Map.new(@bool_fields, &{&1, bool(form[Atom.to_string(&1)])})
    text |> Map.merge(ints) |> Map.merge(bools)
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

  defp error_field(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    tag = elem(reason, 0)

    if is_atom(tag) do
      Enum.find(Settings.keys(), fn key ->
        String.starts_with?(Atom.to_string(tag), Atom.to_string(key) <> "_")
      end)
    end
  end

  defp error_field(_), do: nil

  # -- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        efforts: Settings.efforts(),
        providers: Enum.map(JidoHarness.providers(), &Atom.to_string/1),
        max_instructions: Settings.max_instructions_chars()
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
        <button type="submit">Save settings</button>
      </form>

      <section aria-labelledby="env-h">
        <h2 id="env-h">Environment</h2>
        <p :if={@env_names == []} class="ws-muted">No environment variables.</p>
        <ul :if={@env_names != []}>
          <li :for={name <- @env_names}>{name} = <span aria-label="value hidden">••••••</span></li>
        </ul>
        <p class="ws-muted">Values and secrets are never shown here.</p>
      </section>

      <section aria-labelledby="limits-h">
        <h2 id="limits-h">Limits and usage</h2>
        <dl :if={@limits}>
          <dt>Active runs</dt><dd>{@limits.active_runs} / {@limits.max_concurrent_runs}</dd>
          <dt>Threads started today</dt><dd>{@limits.threads_started_today}<span :if={@limits.daily_thread_cap}> / {@limits.daily_thread_cap}</span></dd>
          <dt>Deferred tasks</dt><dd>{@limits.deferred_tasks}</dd>
        </dl>
        <dl :if={@usage}>
          <dt>Total tokens</dt><dd>{@usage["totals"]["total_tokens"]}</dd>
          <dt>Cost (USD)</dt><dd>{@usage["totals"]["cost_usd"] || "unknown"}</dd>
          <dt>Threads with usage</dt><dd>{@usage["thread_count"]}</dd>
        </dl>
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

  defp field(assigns) do
    assigns = assign(assigns, :key, String.to_existing_atom(assigns.name))

    ~H"""
    <div>
      <label for={"settings_#{@name}"}>{@label}</label>
      <%= cond do %>
        <% @options -> %>
          <select id={"settings_#{@name}"} name={"settings[#{@name}]"} aria-describedby={"#{@name}-error"}>
            <option value="" selected={@form[@name] == ""}>(default)</option>
            <option :for={o <- @options} value={o} selected={@form[@name] == o}>{o}</option>
          </select>
        <% @kind == "textarea" -> %>
          <textarea id={"settings_#{@name}"} name={"settings[#{@name}]"} rows="3" aria-describedby={"#{@name}-error"}>{@form[@name]}</textarea>
        <% true -> %>
          <input id={"settings_#{@name}"} type={@kind} name={"settings[#{@name}]"} value={@form[@name]} aria-describedby={"#{@name}-error"} aria-invalid={to_string(@errors[@key] != nil)} />
      <% end %>
      <p id={"#{@name}-error"} :if={@errors[@key]} class="ws-error" role="alert">{@errors[@key]}</p>
    </div>
    """
  end
end
