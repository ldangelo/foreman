defmodule ForemanServerWeb.ProjectSettingsLiveTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ForemanServer.Aggregates.Project.Environment
  alias ForemanServer.TelemetryTest.Handler

  alias ForemanServer.{
    CommandGateway,
    EventStore,
    ProjectEnvironment,
    ProjectionStore,
    ProjectMemory,
    ProjectSettings,
    ProjectStore,
    SecretStore
  }

  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "project-settings-live-token"

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    previous_ws = Application.get_env(:foreman_server, :workspace)
    Application.put_env(:foreman_server, :api_bearer_token, @token)
    Application.put_env(:foreman_server, :workspace, coalesce_ms: 20)
    ProjectionStoreReset.reset!()

    on_exit(fn ->
      ProjectionStoreReset.reset!()
      restore(:api_bearer_token, previous)
      restore(:workspace, previous_ws)
    end)

    id = "set-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             ProjectStore.save(%{
               project_id: id,
               path: dir,
               name: "Settings Demo",
               config: %{"env" => %{"API_TOKEN" => "s3cr3t-value-123"}}
             })

    {:ok, id: id}
  end

  defp restore(key, nil), do: Application.delete_env(:foreman_server, key)
  defp restore(key, value), do: Application.put_env(:foreman_server, key, value)

  defp mount_view(id) do
    {:ok, view, html} = live(build_conn(), "/dashboard/projects/#{id}/settings?token=#{@token}")
    {view, html}
  end

  defp settings(id), do: ProjectSettings.from_config(ProjectStore.get(id).config)

  defp environment(id), do: ProjectEnvironment.from_config(ProjectStore.get(id).config)

  # The fixture's legacy flat `env` names `API_TOKEN`, a secret-looking variable the
  # environment record refuses, so a script-only save would fail on it. Put the project on
  # the record form with valid variables first, as `foreman project env set` does.
  defp seed_environment(id, record) do
    assert {:ok, _} =
             CommandGateway.dispatch_operator(%{
               command_id: "seed-environment-#{id}",
               type: "project.environment.set",
               aggregate_id: "project:#{id}",
               payload: Map.put(record, :project_id, id)
             })

    :ok
  end

  defp git_checkout(dir, name) do
    path = Path.join(dir, name)
    File.mkdir_p!(path)
    {_output, 0} = System.cmd("git", ["init", "-q", path])
    path
  end

  # What the server stores for a path: macOS tmp dirs are symlinks.
  defp realpath(path) do
    {out, 0} = System.cmd("sh", ["-c", "cd \"$1\" && pwd -P", "sh", path])
    String.trim(out)
  end

  defp add_repo(view, id, path, branch \\ "") do
    view
    |> form("#repo-form", repo: %{id: id, path: path, default_branch: branch})
    |> render_submit()
  end

  # Sends every operator and system command envelope this test's views dispatch to the test
  # process as `{:dispatched, :dispatch_operator | :dispatch_system, envelope}` and lets it
  # through unchanged (other processes' dispatches arrive too: match on the type).
  defp capture_dispatches! do
    test = self()
    {:ok, _} = Application.ensure_all_started(:meck)
    :meck.new(CommandGateway, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(CommandGateway) end)

    for fun <- [:dispatch_operator, :dispatch_system] do
      :meck.expect(CommandGateway, fun, fn envelope ->
        send(test, {:dispatched, fun, envelope})
        :meck.passthrough([envelope])
      end)
    end

    :ok
  end

  # True when ANY recorded event, of any stream, mentions `text`.
  defp event_log_mentions?(text) do
    EventStore.stream_all_forward()
    |> Enum.any?(&(inspect(&1, limit: :infinity, printable_limit: :infinity) =~ text))
  end

  # Runs `fun` (it returns the page's HTML) with debug logging captured: `{html, log}`.
  defp html_and_log(fun) do
    test = self()
    log = capture_log([level: :debug], fn -> send(test, {:html, fun.()}) end)
    assert_received {:html, html}
    {html, log}
  end

  test "requires authentication", %{id: id} do
    assert build_conn()
           |> Plug.Conn.put_req_header("accept", "text/html")
           |> get("/dashboard/projects/#{id}/settings")
           |> response(401)
  end

  test "secrets are never rendered, only variable names", %{id: id} do
    {_view, html} = mount_view(id)

    assert html =~ "API_TOKEN"
    refute html =~ "s3cr3t-value-123"
  end

  test "saving writes through project.update; the instructions counter is live", %{id: id} do
    {view, _} = mount_view(id)

    html = view |> form("#settings-form", settings: %{instructions: "abc"}) |> render_change()
    assert html =~ "3 / 16000 characters"

    view
    |> form("#settings-form",
      settings: %{
        goal: "Ship v2",
        max_concurrent_runs: "2",
        thread_effort: "high",
        instructions: "Be terse"
      }
    )
    |> render_submit()

    assert %{
             goal: "Ship v2",
             max_concurrent_runs: 2,
             thread_effort: "high",
             instructions: "Be terse"
           } = settings(id)

    assert render(view) =~ "Settings saved."
  end

  test "server-side errors are shown against their field and nothing is written", %{id: id} do
    {view, _} = mount_view(id)
    too_long = String.duplicate("x", 16_001)

    html = view |> form("#settings-form", settings: %{instructions: too_long}) |> render_submit()

    assert html =~ ~s(id="instructions-error")
    assert html =~ "instructions_too_long"
    assert html =~ "16001 / 16000 characters"
    assert settings(id).instructions == nil

    html =
      view
      |> form("#settings-form", settings: %{instructions: "ok", max_concurrent_runs: "abc"})
      |> render_submit()

    assert html =~ ~s(id="max_concurrent_runs-error")
    assert settings(id).instructions == nil
  end

  test "save sends only the fields the operator changed: a concurrent change survives", %{id: id} do
    {view, _} = mount_view(id)

    # someone else (CLI, coordinator) sets the goal after this page loaded
    assert {:ok, _} =
             CommandGateway.dispatch_operator(%{
               command_id: "elsewhere-#{id}",
               type: "project.update",
               aggregate_id: "project:#{id}",
               payload: %{project_id: id, goal: "Changed elsewhere", daily_thread_cap: 7}
             })

    # the operator only touches max_concurrent_runs; goal/daily cap fields still
    # hold their stale mount-time (empty) values in the form
    view |> form("#settings-form", settings: %{max_concurrent_runs: "3"}) |> render_submit()

    assert %{goal: "Changed elsewhere", daily_thread_cap: 7, max_concurrent_runs: 3} =
             settings(id)
  end

  test "saving with nothing changed dispatches nothing", %{id: id} do
    {view, _} = mount_view(id)
    assert view |> form("#settings-form") |> render_submit() =~ "No changes to save."
  end

  test "a failed usage/limits read shows an error, not an empty pane", %{id: id} do
    {view, html} = mount_view(id)
    assert html =~ ~s(id="usage-pane")
    refute html =~ ~s(id="usage-error")

    # the project vanishes from the projection while the page is open
    ProjectionStoreReset.reset!()

    {handler, ref} =
      Handler.attach_event_handlers(self(), [[:foreman_server, :workspace, :refresh]])

    send(view.pid, {:projection_event, %{event_type: "RunStarted", data: %{project_id: id}}})
    assert_receive {[:foreman_server, :workspace, :refresh], ^ref, _, _}, 5_000
    :telemetry.detach(handler)

    html = render(view)
    assert html =~ ~s(id="usage-error")
    assert html =~ "Usage unavailable"
    assert html =~ ~s(id="limits-error")
    assert html =~ "This project no longer exists."
  end

  test "clearing a field clears the stored setting", %{id: id} do
    {view, _} = mount_view(id)
    view |> form("#settings-form", settings: %{goal: "temp"}) |> render_submit()
    assert settings(id).goal == "temp"

    view |> form("#settings-form", settings: %{goal: ""}) |> render_submit()
    assert settings(id).goal == nil
  end

  test "the notification preference saves and (default) clears it", %{id: id} do
    {view, _} = mount_view(id)

    html =
      view
      |> form("#settings-form", settings: %{notification_preference: "off"})
      |> render_submit()

    assert html =~ "Settings saved."
    refute html =~ ~s(id="notification_preference-error")
    assert settings(id).notification_preference == "off"

    view
    |> form("#settings-form", settings: %{notification_preference: ""})
    |> render_submit()

    assert settings(id).notification_preference == nil
  end

  test "an invalid notification preference is refused at its field", %{id: id} do
    {view, _} = mount_view(id)

    # the select cannot offer this value, a forged event can
    html = render_submit(view, "save", %{"settings" => %{"notification_preference" => "loud"}})

    assert html =~ ~s(id="notification_preference-error")
    assert html =~ "notification_preference_invalid"
    assert settings(id).notification_preference == nil
  end

  test "the repository allowlist and the per-run cap save as typed", %{id: id} do
    {view, _} = mount_view(id)

    # an entry that is not an absolute path is refused by the server, at its field
    html =
      view
      |> form("#settings-form", settings: %{repo_allowlist: "/srv/ok\nrelative/dir"})
      |> render_submit()

    assert html =~ ~s(id="repo_allowlist-error")
    assert html =~ "invalid_repo_allowlist"
    assert settings(id).repo_allowlist == nil

    # one entry per non-blank line, trimmed; the cap is an integer
    allowlist = "/srv/repos\r\n  /opt/work/  \r\n\r\n"

    html =
      view
      |> form("#settings-form", settings: %{repo_allowlist: allowlist, max_repos_per_run: "2"})
      |> render_submit()

    assert html =~ "Settings saved."
    refute html =~ ~s(id="repo_allowlist-error")
    assert %{repo_allowlist: ["/srv/repos", "/opt/work"], max_repos_per_run: 2} = settings(id)

    # an empty box clears the allowlist and nothing else
    view |> form("#settings-form", settings: %{repo_allowlist: ""}) |> render_submit()
    assert %{repo_allowlist: nil, max_repos_per_run: 2} = settings(id)

    # a cap the server refuses is shown at its field; the stored one stays
    html =
      view
      |> form("#settings-form", settings: %{max_repos_per_run: "0"})
      |> render_submit()

    assert html =~ ~s(id="max_repos_per_run-error")
    assert settings(id).max_repos_per_run == 2
  end

  test "browser newlines (CRLF) are neither a change nor stored", %{id: id} do
    {view, _} = mount_view(id)

    html =
      view
      |> form("#settings-form", settings: %{instructions: "a\r\nb"})
      |> render_change()

    assert html =~ "3 / 16000 characters"

    typed = %{instructions: "line one\r\nline two", repo_allowlist: "/srv/a\r\n/srv/b"}
    view |> form("#settings-form", settings: typed) |> render_submit()

    assert settings(id).instructions == "line one\nline two"
    assert settings(id).repo_allowlist == ["/srv/a", "/srv/b"]

    # a fresh page starts from the stored text; the browser sends it back with CRLF
    {fresh, html} = mount_view(id)
    assert html =~ "/srv/a\n/srv/b"

    html = fresh |> form("#settings-form", settings: typed) |> render_submit()

    assert html =~ "No changes to save."
  end

  test "a concurrent notification preference survives an unrelated save", %{id: id} do
    {view, _} = mount_view(id)

    assert {:ok, _} =
             CommandGateway.dispatch_operator(%{
               command_id: "elsewhere-pref-#{id}",
               type: "project.update",
               aggregate_id: "project:#{id}",
               payload: %{project_id: id, notification_preference: "every_turn"}
             })

    view |> form("#settings-form", settings: %{max_repos_per_run: "2"}) |> render_submit()

    assert %{notification_preference: "every_turn", max_repos_per_run: 2} = settings(id)
  end

  test "the operator-only warnings are rendered and tied to their controls", %{id: id} do
    {view, _} = mount_view(id)

    assert has_element?(view, "#repo_allowlist-warning", ~r/\AWarning:/)
    assert has_element?(view, "textarea[aria-describedby~=repo_allowlist-warning]")
    assert has_element?(view, "#setup-script-warning", ~r/\AWarning:/)
    assert has_element?(view, "textarea[aria-describedby~=setup-script-warning]")
    assert has_element?(view, "#notification_preference-help", "blocked_only")
    assert has_element?(view, "#max_repos_per_run-help", "default 4")
  end

  test "a refusal about the stored variables is shown at the script field", %{id: id} do
    {view, _} = mount_view(id)

    # the fixture's legacy `API_TOKEN` variable is ported into the record, which refuses it
    html =
      view
      |> form("#setup-script-form", setup_script: %{script: "make deps"})
      |> render_submit()

    assert html =~ ~s(id="setup-script-error")
    assert html =~ "Fix the highlighted field."
    assert environment(id)["setup_script"] == nil
  end

  test "pause and resume need a confirm step and update the status", %{id: id} do
    {view, _} = mount_view(id)

    view |> element("button", "Pause") |> render_click()
    assert ProjectStore.get(id).status == "active"
    assert render(view) =~ "Confirm Pause"

    view |> element("button", "Confirm Pause") |> render_click()
    assert ProjectStore.get(id).status == "paused"
    assert render(view) =~ "Resume"

    view |> element("button", "Resume") |> render_click()
    view |> element("button", "Confirm Resume") |> render_click()
    assert ProjectStore.get(id).status == "active"
  end

  test "memory topics can be written, read back escaped, and forgotten", %{id: id} do
    {view, _} = mount_view(id)
    evil = "</textarea><script>alert(1)</script>"

    view |> element("button", "New topic") |> render_click()

    html =
      view
      |> form("#memory-form", memory: %{name: "facts", description: "d", content: evil})
      |> render_submit()

    assert {:ok, _topic, ^evil} = ProjectMemory.read(id, "facts")
    refute html =~ "<script>alert(1)"
    assert html =~ "facts"

    view |> element("button", "facts") |> render_click()
    html = render(view)
    assert html =~ "&lt;/textarea&gt;&lt;script&gt;"
    refute html =~ "<script>alert(1)"

    view |> element("button", "Forget topic") |> render_click()
    view |> element("button", "Confirm forget") |> render_click()
    assert {:error, %{code: :not_found}} = ProjectMemory.read(id, "facts")
  end

  test "a bad memory name surfaces the server's error", %{id: id} do
    {view, _} = mount_view(id)
    view |> element("button", "New topic") |> render_click()

    html =
      view |> form("#memory-form", memory: %{name: "Bad Name!", content: "x"}) |> render_submit()

    assert html =~ ~s(role="alert")
  end

  test "usage and limits panes render", %{id: id} do
    {_view, html} = mount_view(id)
    assert html =~ "Total tokens"
    assert html =~ "Active runs"
  end

  test "labelled controls: every settings field has a label bound by for/id", %{id: id} do
    {_view, html} = mount_view(id)

    for name <-
          ~w(goal instructions thread_model thread_effort coordinator_provider coordinator_model
                   coordinator_effort max_concurrent_runs daily_thread_cap
                   coordinator_max_active_threads coordinator_propose_before_start coordinator_reuse_threads
                   notification_preference repo_allowlist max_repos_per_run) do
      assert html =~ ~s(for="settings_#{name}")
      assert html =~ ~s(id="settings_#{name}")
    end

    # the repository and setup-script forms do not use `settings[...]` names
    for control <- ~w(repo_id repo_path repo_default_branch setup_script) do
      assert html =~ ~s(for="#{control}")
      assert html =~ ~s(id="#{control}")
    end
  end

  test "an event burst costs one refresh of the read-only panes, however many events arrive", %{
    id: id
  } do
    {view, _} = mount_view(id)
    pid = view.pid
    before = :sys.get_state(pid).socket.assigns.refresh_count

    # Attached BEFORE anything is sent, so no refresh can fire unobserved (and it is
    # detached even when the test fails).
    {handler, ref} =
      Handler.attach_event_handlers(self(), [[:foreman_server, :workspace, :refresh]])

    on_exit(fn -> :telemetry.detach(handler) end)

    # The view is held while the burst is queued, so every event is already in its mailbox
    # when it handles the first: the coalescing window cannot be straddled, the burst is
    # exactly one refresh, and nothing here depends on how fast the test process sends.
    :ok = :sys.suspend(pid)

    for n <- 1..100 do
      send(
        pid,
        {:projection_event, %{event_type: "RunStarted", data: %{project_id: id, run_id: "x#{n}"}}}
      )
    end

    :ok = :sys.resume(pid)

    assert_receive {[:foreman_server, :workspace, :refresh], ^ref, _, %{pid: ^pid}}, 5_000
    assert :sys.get_state(pid).socket.assigns.refresh_count - before == 1
  end

  # No catch-all `handle_event/3`: a renamed form key or an unknown operation is a defect
  # that must show (the view restarts), not a dead control.
  test "an event the page does not know raises instead of doing nothing" do
    socket = %Phoenix.LiveView.Socket{}

    for {event, params} <- [
          {"no_such_event", %{}},
          {"save", %{}},
          {"validate", %{"goal" => "renamed key"}},
          {"confirm_lifecycle", %{"op" => "explode"}},
          {"env_save", %{"env" => %{"name" => 1, "value" => "v"}}}
        ] do
      assert_raise FunctionClauseError, fn ->
        ForemanServerWeb.ProjectSettingsLive.handle_event(event, params, socket)
      end
    end
  end

  describe "setup script" do
    setup %{id: id} do
      seed_environment(id, %{vars: %{"LOG_LEVEL" => "debug"}, network: %{"mode" => "none"}})
    end

    test "saves LF text and leaves the variables and network alone", %{id: id} do
      {view, _} = mount_view(id)

      html =
        view
        |> form("#setup-script-form", setup_script: %{script: "set -e\r\nmake deps\r\n"})
        |> render_submit()

      assert html =~ "Setup script saved."
      refute html =~ ~s(id="setup-script-error")

      assert %{"setup_script" => script, "vars" => vars, "network" => network} = environment(id)
      assert script == "set -e\nmake deps\n"
      refute script =~ "\r"
      assert vars == %{"LOG_LEVEL" => "debug"}
      assert network == %{"mode" => "none", "hosts" => []}
    end

    test "the same text again is no change, with or without CRLF", %{id: id} do
      {view, _} = mount_view(id)
      typed = %{script: "set -e\r\nmake deps\r\n"}

      view |> form("#setup-script-form", setup_script: typed) |> render_submit()
      assert environment(id)["setup_script"] == "set -e\nmake deps\n"

      html = view |> form("#setup-script-form", setup_script: typed) |> render_submit()
      assert html =~ "No changes to the setup script."

      # a fresh page starts from the stored text, which the browser sends back with CRLF
      {fresh, _} = mount_view(id)
      html = fresh |> form("#setup-script-form", setup_script: typed) |> render_submit()
      assert html =~ "No changes to the setup script."
    end

    test "whitespace only removes the script; blank on blank is no change", %{id: id} do
      {view, _} = mount_view(id)

      view
      |> form("#setup-script-form", setup_script: %{script: "make deps"})
      |> render_submit()

      assert environment(id)["setup_script"] == "make deps"

      html =
        view
        |> form("#setup-script-form", setup_script: %{script: " \r\n\t"})
        |> render_submit()

      assert html =~ "Setup script removed."
      refute html =~ "make deps"
      assert environment(id)["setup_script"] == nil
      assert environment(id)["vars"] == %{"LOG_LEVEL" => "debug"}

      html =
        view
        |> form("#setup-script-form", setup_script: %{script: "  "})
        |> render_submit()

      assert html =~ "No changes to the setup script."
    end

    test "a script over the size limit is refused at its field", %{id: id} do
      {view, _} = mount_view(id)
      limit = Environment.max_script_bytes()
      too_long = String.duplicate("x", limit + 1)

      html =
        view
        |> form("#setup-script-form", setup_script: %{script: too_long})
        |> render_submit()

      assert html =~ ~s(id="setup-script-error")
      assert html =~ "the script is #{limit + 1} bytes; at most #{limit} are accepted"
      assert html =~ "Fix the highlighted field."
      assert has_element?(view, "#setup_script", too_long)
      assert environment(id)["setup_script"] == nil
    end

    test "a NUL byte is refused at its field", %{id: id} do
      {view, _} = mount_view(id)
      params = %{"setup_script" => %{"script" => "ls\0"}}

      html = render_submit(view, "save_setup_script", params)

      assert html =~ ~s(id="setup-script-error")
      assert html =~ "the script contains a NUL byte"
      assert environment(id)["setup_script"] == nil
    end

    test "a refresh keeps the text typed into the box", %{id: id} do
      {view, _} = mount_view(id)

      view
      |> form("#setup-script-form", setup_script: %{script: "make deps"})
      |> render_change()

      {handler, ref} =
        Handler.attach_event_handlers(self(), [[:foreman_server, :workspace, :refresh]])

      pid = view.pid
      send(pid, {:projection_event, %{event_type: "RunStarted", data: %{project_id: id}}})
      assert_receive {[:foreman_server, :workspace, :refresh], ^ref, _, %{pid: ^pid}}, 5_000
      :telemetry.detach(handler)

      assert %{script_form: "make deps", script_baseline: ""} = :sys.get_state(pid).socket.assigns
      assert render(view) =~ "make deps"
    end
  end

  describe "repositories" do
    test "lists the primary, which has no Remove button", %{id: id, tmp_dir: dir} do
      {view, html} = mount_view(id)

      assert has_element?(view, "#repo-list #repository-main code", "main")
      assert has_element?(view, "#repository-main", "primary")
      assert has_element?(view, "#repository-main", dir)
      assert has_element?(view, "#repository-main", "current branch")
      refute has_element?(view, "#repository-main button")
      refute html =~ "Remove main"
    end

    test "adds a git checkout; it is listed and projected", %{id: id, tmp_dir: dir} do
      checkout = git_checkout(dir, "api")
      {view, _} = mount_view(id)

      html = add_repo(view, "api", checkout, "develop")

      assert html =~ "Added repository api."
      assert has_element?(view, "#repository-api code", "api")
      assert has_element?(view, "#repository-api", realpath(checkout))
      assert has_element?(view, "#repository-api", "develop")
      assert has_element?(view, ~s(input#repo_id[value=""]))

      assert [%{id: "main", primary: true}, api] = ProjectionStore.project_repositories(id)
      assert %{id: "api", path: path, default_branch: "develop", primary: false} = api
      assert path == realpath(checkout)
    end

    test "path errors show at the path field and keep what was typed", %{id: id, tmp_dir: dir} do
      plain = Path.join(dir, "plain")
      File.mkdir_p!(plain)
      {view, _} = mount_view(id)

      # a directory that is not the root of a git work tree
      html = add_repo(view, "plain", plain)

      assert has_element?(view, "#repo-path-error", "is not the root of a git work tree")
      assert html =~ "Fix the highlighted field."
      refute html =~ ~s(id="repo-id-error")
      assert html =~ ~s(value="plain")
      assert html =~ ~s(value="#{plain}")

      add_repo(view, "rel", "relative/checkout")
      assert has_element?(view, "#repo-path-error", "the path must be absolute")

      add_repo(view, "gone", Path.join(dir, "missing"))
      assert has_element?(view, "#repo-path-error", "does not exist on the server host")

      # the same checkout twice, under another id
      checkout = git_checkout(dir, "api")
      assert add_repo(view, "api", checkout) =~ "Added repository api."
      add_repo(view, "again", checkout)
      assert has_element?(view, "#repo-path-error", "is already attached to this project")
      assert [_main, %{id: "api"}] = ProjectionStore.project_repositories(id)
    end

    test "id errors show at the id field and keep what was typed", %{id: id, tmp_dir: dir} do
      checkout = git_checkout(dir, "api")
      other = git_checkout(dir, "web")
      {view, _} = mount_view(id)

      # an id the server refuses; the path is fine
      html = add_repo(view, "Bad Id", checkout)

      assert has_element?(view, "#repo-id-error", "the id must be 1-32 lowercase letters")
      refute html =~ ~s(id="repo-path-error")
      assert html =~ ~s(value="Bad Id")

      # a taken id: attach api, then ask for api again with another checkout
      assert add_repo(view, "api", checkout) =~ "Added repository api."
      add_repo(view, "api", other)
      assert has_element?(view, "#repo-id-error", "the id api is already used in this project")

      # the primary's id is taken too
      add_repo(view, "main", other)
      assert has_element?(view, "#repo-id-error", "the id main is already used in this project")
      assert [_main, %{id: "api"}] = ProjectionStore.project_repositories(id)
    end

    test "removal needs the confirm step; Cancel backs out", %{id: id, tmp_dir: dir} do
      {view, _} = mount_view(id)
      add_repo(view, "api", git_checkout(dir, "api"))

      view |> element("#repository-api button", "Remove api") |> render_click()
      assert has_element?(view, "#repository-api button", "Confirm remove api")
      assert [_main, %{id: "api"}] = ProjectionStore.project_repositories(id)

      view |> element("#repository-api button", "Cancel") |> render_click()
      assert has_element?(view, "#repository-api button", "Remove api")
      refute has_element?(view, "#repository-api button", "Confirm remove api")

      view |> element("#repository-api button", "Remove api") |> render_click()
      html = view |> element("#repository-api button", "Confirm remove api") |> render_click()

      assert html =~ "Removed repository api."
      refute has_element?(view, "#repository-api")
      assert [%{id: "main"}] = ProjectionStore.project_repositories(id)
    end

    test "a resent removal in the same intent is not an error", %{id: id, tmp_dir: dir} do
      # no refresh in between, so both requests carry the same intent (and command id)
      Application.put_env(:foreman_server, :workspace, coalesce_ms: 60_000)
      {view, _} = mount_view(id)
      add_repo(view, "api", git_checkout(dir, "api"))

      assert render_click(view, "repo_remove", %{"id" => "api"}) =~ "Removed repository api."
      assert render_click(view, "repo_remove", %{"id" => "api"}) =~ "Removed repository api."
      assert [%{id: "main"}] = ProjectionStore.project_repositories(id)
    end

    test "a forged removal of the primary is refused", %{id: id} do
      {view, _} = mount_view(id)

      html = render_click(view, "repo_remove", %{"id" => "main"})

      assert html =~ "Could not remove main: the primary repository cannot be removed"
      assert has_element?(view, "#repository-main")
      assert [%{id: "main", primary: true}] = ProjectionStore.project_repositories(id)
    end

    test "an error no field owns is shown as the notice", %{id: id, tmp_dir: dir} do
      checkout = git_checkout(dir, "api")
      {view, _} = mount_view(id)
      assert {:ok, _} = ProjectStore.archive(id)

      html = add_repo(view, "api", checkout)

      assert html =~ "Could not add: project #{id} is archived"
      refute html =~ ~s(id="repo-id-error")
      refute html =~ ~s(id="repo-path-error")
    end
  end

  describe "environment variables" do
    setup %{id: id} do
      # The fixture's legacy `API_TOKEN` is a secret-looking variable the record refuses (the
      # legacy tests below drive it); start from the record form with plain variables, as
      # `foreman project env set` leaves it. The script and the network policy must survive.
      seed_environment(id, %{
        vars: %{"LOG_LEVEL" => "debug"},
        setup_script: "make deps",
        network: %{"mode" => "none"}
      })
    end

    test "lists each variable with its value, in a box labelled by its name", %{id: id} do
      {view, html} = mount_view(id)

      assert has_element?(
               view,
               ~s(#env-var-LOG_LEVEL label[for="env_value_LOG_LEVEL"]),
               "LOG_LEVEL"
             )

      assert has_element?(view, ~s(#env-form-LOG_LEVEL input#env_value_LOG_LEVEL[value="debug"]))
      assert has_element?(view, "#env-form-LOG_LEVEL button", "Save LOG_LEVEL")
      refute html =~ "value hidden"
      refute has_element?(view, "#env-legacy-note")
    end

    test "setting a variable sends project.environment.set with the stored set plus the new one",
         %{id: id} do
      capture_dispatches!()
      {view, _} = mount_view(id)

      html =
        view
        |> form("#env-add-form", env: %{name: "CACHE_DIR", value: "/var/cache/x"})
        |> render_submit()

      assert html =~ "Set CACHE_DIR."

      assert_received {:dispatched, :dispatch_operator,
                       %{type: "project.environment.set"} = envelope}

      assert envelope.aggregate_id == "project:" <> id

      # the payload names the variables and nothing else: the script and the network keep theirs
      assert envelope.payload == %{
               project_id: id,
               vars: %{"LOG_LEVEL" => "debug", "CACHE_DIR" => "/var/cache/x"}
             }

      assert %{
               "vars" => %{"LOG_LEVEL" => "debug", "CACHE_DIR" => "/var/cache/x"},
               "setup_script" => "make deps",
               "network" => %{"mode" => "none", "hosts" => []}
             } = environment(id)

      # the new value is listed, the add form is empty and its value box was replaced
      assert has_element?(view, ~s(#env-form-CACHE_DIR input[value="/var/cache/x"]))
      assert has_element?(view, ~s(#env_name[value=""]))
      assert html =~ ~s(id="env-value-box-1")
    end

    test "editing a listed variable replaces only its value", %{id: id} do
      {view, _} = mount_view(id)

      html = view |> form("#env-form-LOG_LEVEL", env: %{value: "info"}) |> render_submit()

      assert html =~ "Set LOG_LEVEL."
      assert environment(id)["vars"] == %{"LOG_LEVEL" => "info"}
      assert has_element?(view, ~s(#env-form-LOG_LEVEL input[value="info"]))
    end

    test "a variable changed elsewhere after the page loaded survives a save", %{id: id} do
      {view, _} = mount_view(id)

      # another writer (the CLI) adds a variable while this page is open
      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: "elsewhere-#{id}",
                 type: "project.environment.set",
                 aggregate_id: "project:#{id}",
                 payload: %{project_id: id, vars: %{"LOG_LEVEL" => "debug", "FROM_CLI" => "1"}}
               })

      view |> form("#env-form-LOG_LEVEL", env: %{value: "info"}) |> render_submit()

      assert environment(id)["vars"] == %{"LOG_LEVEL" => "info", "FROM_CLI" => "1"}
    end

    test "a secret-looking name is refused at its field and its value goes nowhere", %{id: id} do
      value = "sk-live-NEVER-STORED-8675309"
      {view, _} = mount_view(id)

      {html, log} =
        html_and_log(fn ->
          view
          |> form("#env-add-form", env: %{name: "STRIPE_API_KEY", value: value})
          |> render_submit()
        end)

      assert html =~ ~s(id="env-name-error")
      assert html =~ "STRIPE_API_KEY looks like a secret"
      assert html =~ "Set it under Secrets instead."

      # nothing was stored, rendered, logged or written to any event
      assert environment(id)["vars"] == %{"LOG_LEVEL" => "debug"}
      refute html =~ value
      refute render(view) =~ value

      # the log capture saw the event, with the value filtered by `config :phoenix, :filter_parameters`
      assert log =~ ~s(HANDLE EVENT "env_add")
      assert log =~ ~s("value" => "[FILTERED]")
      refute log =~ value
      refute event_log_mentions?(value)

      # the name stays typed for a correction, the value box is replaced (empty)
      assert has_element?(view, ~s(#env_name[value="STRIPE_API_KEY"]))
      assert html =~ ~s(id="env-value-box-1")
    end

    test "reserved, malformed and blank names are refused at the name field", %{id: id} do
      {view, _} = mount_view(id)

      for {name, words} <- [
            {"FOREMAN_TOKEN_X", "reserved for Foreman"},
            {"1ST", "is not a valid name"},
            {"a-b", "is not a valid name"},
            {"  ", "enter a variable name"}
          ] do
        html = view |> form("#env-add-form", env: %{name: name, value: "v"}) |> render_submit()

        assert html =~ ~s(id="env-name-error"), "no error for #{inspect(name)}"
        assert html =~ words, "wrong words for #{inspect(name)}"
      end

      assert environment(id)["vars"] == %{"LOG_LEVEL" => "debug"}
    end

    test "a value over the limit is refused at its own field", %{id: id} do
      big = String.duplicate("x", Environment.max_value_bytes() + 1)
      {view, _} = mount_view(id)

      html = view |> form("#env-add-form", env: %{name: "BIG", value: big}) |> render_submit()
      assert html =~ ~s(id="env-value-error")
      assert html =~ "the value of BIG is over #{Environment.max_value_bytes()} bytes"

      html = view |> form("#env-form-LOG_LEVEL", env: %{value: big}) |> render_submit()
      assert html =~ ~s(id="env-error-LOG_LEVEL")
      assert environment(id)["vars"] == %{"LOG_LEVEL" => "debug"}
    end

    test "removal needs a confirm step; the script and the network survive it", %{id: id} do
      {view, _} = mount_view(id)

      view |> element("#env-var-LOG_LEVEL button", "Remove LOG_LEVEL") |> render_click()
      assert has_element?(view, "#env-var-LOG_LEVEL button", "Confirm remove LOG_LEVEL")
      assert environment(id)["vars"] == %{"LOG_LEVEL" => "debug"}

      view |> element("#env-var-LOG_LEVEL button", "Cancel") |> render_click()
      refute has_element?(view, "#env-var-LOG_LEVEL button", "Confirm remove LOG_LEVEL")
      assert environment(id)["vars"] == %{"LOG_LEVEL" => "debug"}

      view |> element("#env-var-LOG_LEVEL button", "Remove LOG_LEVEL") |> render_click()

      html =
        view |> element("#env-var-LOG_LEVEL button", "Confirm remove LOG_LEVEL") |> render_click()

      assert html =~ "Removed LOG_LEVEL."
      assert html =~ "No environment variables."
      refute has_element?(view, "#env-var-LOG_LEVEL")

      assert %{
               "vars" => vars,
               "setup_script" => "make deps",
               "network" => %{"mode" => "none", "hosts" => []}
             } = environment(id)

      assert vars == %{}
    end

    test "a stale or resent removal is already the requested end state", %{id: id} do
      {view, _} = mount_view(id)

      assert render_click(view, "env_remove", %{"name" => "LOG_LEVEL"}) =~ "Removed LOG_LEVEL."
      assert render_click(view, "env_remove", %{"name" => "LOG_LEVEL"}) =~ "Removed LOG_LEVEL."
      assert environment(id)["vars"] == %{}
    end

    test "an archived project refuses a set with the aggregate's words", %{id: id} do
      {view, _} = mount_view(id)
      assert {:ok, _} = ProjectStore.archive(id)

      html = view |> form("#env-add-form", env: %{name: "LATE", value: "1"}) |> render_submit()

      assert html =~ "Could not set LATE: project #{id} is archived"
      assert environment(id)["vars"] == %{"LOG_LEVEL" => "debug"}
    end

    test "every control is labelled and the secrets pointer is in the help text", %{id: id} do
      {_view, html} = mount_view(id)

      for control <- ~w(env_name env_value env_value_LOG_LEVEL secret_name secret_value) do
        assert html =~ ~s(for="#{control}"), "no label for #{control}"
        assert html =~ ~s(id="#{control}"), "no control #{control}"
      end

      assert html =~ "put a password or token under Secrets instead"
    end
  end

  describe "legacy variables" do
    test "values stay hidden; setting a variable moves them into the record and shows them", %{
      tmp_dir: dir
    } do
      id = "legacy-#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               ProjectStore.save(%{
                 project_id: id,
                 path: dir,
                 name: "Legacy Demo",
                 config: %{"env" => %{"NPM_REGISTRY" => "https://r.example", "RETRIES" => "3"}}
               })

      {view, html} = mount_view(id)

      assert html =~ "NPM_REGISTRY"
      assert has_element?(view, "#env-legacy-note")
      assert has_element?(view, "#env-var-RETRIES", "value hidden")
      refute html =~ "https://r.example"
      refute has_element?(view, "#env-form-RETRIES")

      html =
        view
        |> form("#env-add-form", env: %{name: "LOG_LEVEL", value: "debug"})
        |> render_submit()

      assert html =~ "Set LOG_LEVEL."
      refute has_element?(view, "#env-legacy-note")
      assert has_element?(view, ~s(#env-form-NPM_REGISTRY input[value="https://r.example"]))
      assert has_element?(view, ~s(#env-form-RETRIES input[value="3"]))

      assert environment(id)["vars"] ==
               %{"NPM_REGISTRY" => "https://r.example", "RETRIES" => "3", "LOG_LEVEL" => "debug"}
    end

    test "a stored variable that looks like a secret refuses a set; removing it unblocks", %{
      id: id
    } do
      {view, _} = mount_view(id)
      assert has_element?(view, "#env-var-API_TOKEN", "value hidden")

      html = view |> form("#env-add-form", env: %{name: "FOO", value: "bar"}) |> render_submit()

      assert html =~ "the stored variable API_TOKEN looks like a secret"
      refute html =~ "s3cr3t-value-123"
      refute ProjectEnvironment.record_form?(ProjectStore.get(id).config)

      view |> element("#env-var-API_TOKEN button", "Remove API_TOKEN") |> render_click()

      html =
        view |> element("#env-var-API_TOKEN button", "Confirm remove API_TOKEN") |> render_click()

      assert html =~ "Removed API_TOKEN."
      assert environment(id)["vars"] == %{}

      view |> form("#env-add-form", env: %{name: "FOO", value: "bar"}) |> render_submit()
      assert environment(id)["vars"] == %{"FOO" => "bar"}
      assert has_element?(view, ~s(#env-form-FOO input[value="bar"]))
    end
  end

  describe "secrets" do
    @secret "hunter2-NOT-IN-EVENTS-5551234"

    setup %{tmp_dir: dir} do
      store = Application.get_env(:foreman_server, :secret_store)

      Application.put_env(
        :foreman_server,
        :secret_store,
        Keyword.put(store, :dir, Path.join(dir, "secret-store"))
      )

      on_exit(fn -> Application.put_env(:foreman_server, :secret_store, store) end)
      :ok
    end

    test "a secret is write-only: the value reaches the store and nowhere else", %{id: id} do
      capture_dispatches!()
      {view, _} = mount_view(id)

      {html, log} =
        html_and_log(fn ->
          view
          |> form("#secret-form", secret: %{name: "DEPLOY_TOKEN", value: @secret})
          |> render_submit()
        end)

      assert html =~ "Saved secret DEPLOY_TOKEN (version 1)."
      assert has_element?(view, "#secret-DEPLOY_TOKEN", "version 1")

      # the value reached the secret store ...
      assert {:ok, @secret} = SecretStore.get(id, "DEPLOY_TOKEN")

      # ... and nothing else: not the page, the process state, the log or any event
      refute html =~ @secret
      refute render(view) =~ @secret
      assert log =~ ~s(HANDLE EVENT "secret_set")
      assert log =~ ~s("value" => "[FILTERED]")
      refute log =~ @secret

      # (the positive controls prove the inspected state and event log are not empty ones)
      assigns =
        inspect(:sys.get_state(view.pid).socket.assigns,
          limit: :infinity,
          printable_limit: :infinity
        )

      assert assigns =~ id
      refute assigns =~ @secret

      assert event_log_mentions?("DEPLOY_TOKEN")
      refute event_log_mentions?(@secret)

      assert [%{event_type: "ProjectSecretSet"}] = secret_events(id)

      # the only command is the system one that records name and author, never the value
      assert_received {:dispatched, :dispatch_system, %{type: "project.secret.set"} = envelope}
      assert envelope.payload == %{project_id: id, name: "DEPLOY_TOKEN", author_ref: "dashboard"}
      refute_received {:dispatched, :dispatch_operator, %{type: "project.secret.set"}}

      # the form was reset: a fresh, empty password box; the name is empty again
      assert html =~ ~s(id="secret-value-box-1")
      assert has_element?(view, ~s(#secret_name[value=""]))
    end

    test "the value box is a password input without any value attribute; the form never syncs",
         %{id: id} do
      {view, html} = mount_view(id)

      [tag] = Regex.run(~r/<input[^>]*id="secret_value"[^>]*>/, html)
      assert tag =~ ~s(type="password")
      assert tag =~ ~s(autocomplete="new-password")
      refute tag =~ ~r/\svalue=/

      [form_tag] = Regex.run(~r/<form[^>]*id="secret-form"[^>]*>/, html)
      assert form_tag =~ ~s(phx-submit="secret_set")
      refute form_tag =~ "phx-change"
      assert has_element?(view, ~s(#secret-form #secret_value[type="password"]))
    end

    test "setting a name again rotates it; the list shows the version, never a value", %{id: id} do
      {view, _} = mount_view(id)

      view
      |> form("#secret-form", secret: %{name: "DEPLOY_TOKEN", value: "first-value-1"})
      |> render_submit()

      html =
        view
        |> form("#secret-form", secret: %{name: "DEPLOY_TOKEN", value: "second-value-2"})
        |> render_submit()

      assert html =~ "Saved secret DEPLOY_TOKEN (version 2)."
      assert {:ok, "second-value-2"} = SecretStore.get(id, "DEPLOY_TOKEN")
      assert has_element?(view, "#secret-list li#secret-DEPLOY_TOKEN", "version 2")

      # a second page load lists name and version only
      {_view2, html2} = mount_view(id)
      assert html2 =~ "DEPLOY_TOKEN"
      refute html2 =~ "first-value-1"
      refute html2 =~ "second-value-2"
    end

    test "a bad name or value is refused at its field and nothing is stored", %{id: id} do
      {view, _} = mount_view(id)

      html =
        view
        |> form("#secret-form", secret: %{name: "lower_case", value: @secret})
        |> render_submit()

      assert html =~ ~s(id="secret-name-error")
      assert html =~ "secret name must match"
      refute html =~ @secret
      # the name stays typed, the value box was replaced
      assert has_element?(view, ~s(#secret_name[value="lower_case"]))
      assert html =~ ~s(id="secret-value-box-1")

      html =
        view
        |> form("#secret-form", secret: %{name: "FOREMAN_X", value: @secret})
        |> render_submit()

      assert html =~ ~s(id="secret-name-error")

      html =
        view |> form("#secret-form", secret: %{name: "EMPTY_ONE", value: ""}) |> render_submit()

      assert html =~ ~s(id="secret-value-error")
      assert html =~ "secret value must be 1.."

      assert {:ok, []} = SecretStore.names(id)
      assert secret_events(id) == []
    end

    test "removal needs a confirm step, deletes the value and records the name only", %{id: id} do
      capture_dispatches!()
      {view, _} = mount_view(id)

      view
      |> form("#secret-form", secret: %{name: "DEPLOY_TOKEN", value: @secret})
      |> render_submit()

      view
      |> element("#secret-DEPLOY_TOKEN button", "Remove secret DEPLOY_TOKEN")
      |> render_click()

      assert has_element?(
               view,
               "#secret-DEPLOY_TOKEN button",
               "Confirm remove secret DEPLOY_TOKEN"
             )

      assert {:ok, @secret} = SecretStore.get(id, "DEPLOY_TOKEN")

      view |> element("#secret-DEPLOY_TOKEN button", "Cancel") |> render_click()
      assert {:ok, @secret} = SecretStore.get(id, "DEPLOY_TOKEN")

      view
      |> element("#secret-DEPLOY_TOKEN button", "Remove secret DEPLOY_TOKEN")
      |> render_click()

      html =
        view
        |> element("#secret-DEPLOY_TOKEN button", "Confirm remove secret DEPLOY_TOKEN")
        |> render_click()

      assert html =~ "Removed secret DEPLOY_TOKEN."
      assert html =~ "No secrets."
      assert {:error, %{code: :secret_not_found}} = SecretStore.get(id, "DEPLOY_TOKEN")

      assert_received {:dispatched, :dispatch_system, %{type: "project.secret.unset"} = envelope}
      assert envelope.payload == %{project_id: id, name: "DEPLOY_TOKEN", author_ref: "dashboard"}
      refute event_log_mentions?(@secret)
    end

    test "removing a secret that is already gone is an error notice, not a crash", %{id: id} do
      {view, _} = mount_view(id)

      html = render_click(view, "secret_unset", %{"name" => "NEVER_SET"})

      assert html =~ "Could not remove secret NEVER_SET: no such secret"
      assert Process.alive?(view.pid)
    end
  end

  defp secret_events(id) do
    case EventStore.read_stream_forward("project_secret:#{id}", 0, 100) do
      {:ok, events} -> events
      {:error, :stream_not_found} -> []
    end
  end
end
