defmodule ForemanServerWeb.ProjectSettingsLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ForemanServer.TelemetryTest.Handler
  alias ForemanServer.{ProjectMemory, ProjectSettings, ProjectStore}
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

  test "clearing a field clears the stored setting", %{id: id} do
    {view, _} = mount_view(id)
    view |> form("#settings-form", settings: %{goal: "temp"}) |> render_submit()
    assert settings(id).goal == "temp"

    view |> form("#settings-form", settings: %{goal: ""}) |> render_submit()
    assert settings(id).goal == nil
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
                   coordinator_max_active_threads coordinator_propose_before_start coordinator_reuse_threads) do
      assert html =~ ~s(for="settings_#{name}")
      assert html =~ ~s(id="settings_#{name}")
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
end
