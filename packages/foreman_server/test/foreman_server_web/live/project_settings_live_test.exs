defmodule ForemanServerWeb.ProjectSettingsLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ForemanServer.Aggregates.Project.Environment
  alias ForemanServer.TelemetryTest.Handler

  alias ForemanServer.{
    CommandGateway,
    ProjectEnvironment,
    ProjectionStore,
    ProjectMemory,
    ProjectSettings,
    ProjectStore
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

  test "an event burst refreshes the read-only panes a bounded number of times", %{id: id} do
    {view, _} = mount_view(id)
    before = :sys.get_state(view.pid).socket.assigns.refresh_count

    for n <- 1..100,
        do:
          send(
            view.pid,
            {:projection_event,
             %{event_type: "RunStarted", data: %{project_id: id, run_id: "x#{n}"}}}
          )

    {handler, ref} =
      Handler.attach_event_handlers(self(), [[:foreman_server, :workspace, :refresh]])

    pid = view.pid
    assert_receive {[:foreman_server, :workspace, :refresh], ^ref, _, %{pid: ^pid}}, 5_000
    :telemetry.detach(handler)

    assert :sys.get_state(view.pid).socket.assigns.refresh_count - before <= 2
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
end
