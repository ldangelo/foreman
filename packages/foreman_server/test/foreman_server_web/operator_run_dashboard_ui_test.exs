defmodule ForemanServerWeb.OperatorRunDashboardUITest do
  @moduledoc """
  UI/UX parity of the operator run dashboard (`/dashboard/runs`) with the project workspace
  (`/dashboard/projects/:id`).

  Both pages are rendered inside one root stylesheet (`ForemanServerWeb.Workspace.Layouts.root/1`),
  but the dashboard's markup used class names that stylesheet never defines
  (`.operator-run-dashboard`, `.dashboard-layout`, `.run-list`, `.run-detail`, `.focus-marker`,
  `dashboard-stale`, `dashboard-error`, `dashboard-detail-error`, `dashboard-action-result`).
  Those selectors matched nothing, so its shell, list rows, tabs, chips and buttons fell back to
  browser defaults while the workspace rendered its own. These tests pin the shared vocabulary
  instead: every class the page emits must be one the root stylesheet actually styles, plus the
  specific replacements the task asks for.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "operator-run-dashboard-ui-token"

  setup do
    previous_token = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)
    ProjectionStoreReset.reset!()

    on_exit(fn ->
      ProjectionStoreReset.reset!()

      if previous_token,
        do: Application.put_env(:foreman_server, :api_bearer_token, previous_token),
        else: Application.delete_env(:foreman_server, :api_bearer_token)
    end)

    seed_run("run-ui", "completed")
    seed_run("run-ui-failed", "failed")

    :ok
  end

  defp url(params), do: "/dashboard/runs?" <> URI.encode_query(params)

  describe "shared vocabulary with the project workspace" do
    test "every class name the page emits is styled by the shared root stylesheet" do
      emitted = emitted_classes()

      assert "ws-card" in emitted and "thread-row" in emitted

      styled = styled_classes()

      for name <- emitted do
        assert name in styled,
               "#{inspect(name)} is emitted by the dashboard but has no rule in " <>
                 "ForemanServerWeb.Workspace.Layouts.root/1"
      end
    end

    test "the page shell reuses the workspace landmarks" do
      {:ok, _view, html} = open(%{})

      assert html =~ ~s(<main id="main" class="ws-main")
      assert html =~ ~s(<header class="ws-header")
      assert html =~ ~s(<nav id="run-list" class="ws-threads")
      assert html =~ ~s(<div class="ws-layout ws-layout--runs")

      for name <-
            ~w(operator-run-dashboard dashboard-layout dashboard-detail-error dashboard-stale) do
        refute html =~ name, "#{inspect(name)} is a class the shared stylesheet never defined"
      end
    end

    test "run rows are workspace list rows: status dot and chip, no focus-marker glyph" do
      {:ok, _view, html} = open(run_id: "run-ui")

      assert html =~ ~s(<ul class="thread-rows")
      assert html =~ ~s(<span class="thread-dot thread-dot--muted" aria-hidden="true"></span>)
      assert html =~ ~s(<span class="chip chip--muted">completed</span>)
      refute html =~ "focus-marker"
    end

    test "the run detail tabs use the workspace tablist role" do
      {:ok, _view, html} = open(run_id: "run-ui")

      assert html =~ ~s(<div role="tablist" aria-label="Run detail tabs">)
      # Attribute order is the template's, so match the individual parts rather than a whole tag.
      assert html =~ ~s(role="tab")
      assert html =~ ~s(id="dash-tab-summary")
      assert html =~ ~s(aria-controls="dash-panel")
      assert html =~ ~s(id="dash-panel")
      assert html =~ ~s(aria-selected="true")
      assert html =~ ~s(aria-selected="false")

      {:ok, _view, logs} = open(run_id: "run-ui", tab: "logs")
      assert logs =~ ~s(id="dash-tab-logs")
      assert logs =~ ~s(aria-controls="dash-panel")
      assert logs =~ ~s(aria-selected="true")
    end

    test "detail sections are cards, and the empty state is muted like the workspace's" do
      {:ok, _view, html} = open(run_id: "run-ui")

      assert html =~ ~s(class="ws-card")
      assert html =~ "Run run-ui"

      {:ok, _view, no_selection} = open(status: "no-such-status")
      assert no_selection =~ ~s(<p class="ws-muted">No runs found.</p>)
    end

    test "status and failure text never render a bare atom or nil" do
      {:ok, _view, html} = open(run_id: "run-ui")

      assert html =~ ~s(<span class="chip chip--muted">completed</span>)
      assert html =~ "not available"
      refute html =~ ":absent"

      {:ok, _view, failed} = open(run_id: "run-ui-failed")
      assert failed =~ ~s(<span class="chip chip--err">failed</span>)
      assert failed =~ "agent exited with 1"
      refute failed =~ ":absent"
    end

    test "an error notice uses the shared error class" do
      {:ok, _view, html} = open(run_id: "run-does-not-exist")

      assert html =~ ~s(class="ws-error")
      assert html =~ "run-does-not-exist"
      assert html =~ "run_not_found"
    end
  end

  describe "run rows and status colours" do
    test "a run row shows its task label, so runs can be told apart in the list" do
      seed_run("run-ui-task", "in_progress", task_id: "task-find-me")

      {:ok, view, _html} = open(run_id: "run-ui")

      assert has_element?(view, "#run-list button[phx-value-run-id=run-ui-task]", "task-find-me")
      assert has_element?(view, "#run-list button[phx-value-run-id=run-ui]", "ad-hoc run")
    end

    test "the selected row carries aria-current, the others do not" do
      {:ok, view, _html} = open(run_id: "run-ui-failed")

      assert has_element?(
               view,
               ~s(#run-list button[phx-value-run-id=run-ui-failed][aria-current=page])
             )

      refute has_element?(view, ~s(#run-list button[phx-value-run-id=run-ui][aria-current]))
    end

    test "needs_recovery is an alarming status, not the muted colour of completed" do
      seed_run("run-ui-recover", "in_progress")

      assert :ok =
               ProjectionStore.apply_events([
                 %{
                   event_type: "WorkerUnresponsive",
                   payload: %{run_id: "run-ui-recover", worker_id: "worker-1", sequence: 3}
                 }
               ])

      {:ok, _view, html} = open(run_id: "run-ui-recover")

      assert html =~ ~s(<span class="chip chip--err">needs_recovery</span>)
      assert html =~ ~s(<span class="thread-dot thread-dot--err" aria-hidden="true"></span>)
      refute html =~ ~s(<span class="chip chip--muted">needs_recovery</span>)
    end

    test "stdout log entries read as agent output, stderr and system keep their own styles" do
      seed_run("run-ui-logs", "in_progress")

      assert :ok =
               ProjectionStore.apply_events([
                 %{
                   event_type: "WorkerStdout",
                   payload: %{
                     run_id: "run-ui-logs",
                     worker_id: "worker-1",
                     sequence: 1,
                     line: "an stdout line",
                     timestamp: "2026-09-23T00:00:00Z"
                   }
                 },
                 %{
                   event_type: "WorkerStderr",
                   payload: %{
                     run_id: "run-ui-logs",
                     worker_id: "worker-1",
                     sequence: 2,
                     line: "an stderr line",
                     timestamp: "2026-09-23T00:00:01Z"
                   }
                 }
               ])

      {:ok, view, _html} = open(run_id: "run-ui-logs", tab: "logs")

      assert has_element?(view, "#run-log article.msg--agent", "an stdout line")
      assert has_element?(view, "#run-log article.msg--stderr", "an stderr line")
      refute has_element?(view, "#run-log article.msg--system")
    end

    test "the logs tab has exactly one live region: the log, not the entry count" do
      seed_run("run-ui-logs", "in_progress")

      {:ok, view, _html} = open(run_id: "run-ui-logs", tab: "logs")

      assert has_element?(view, "#run-log[role=log][aria-live=polite]")
      refute has_element?(view, "#dash-panel .chip[role=status]")
      refute has_element?(view, "#dash-panel [role=status]")
    end
  end

  describe "event controls, driven through the rendered DOM" do
    setup do
      previous_gateway = Application.get_env(:foreman_server, :command_gateway_module)
      previous_pid = Application.get_env(:foreman_server, :operator_dashboard_ui_test_pid)

      Application.put_env(:foreman_server, :command_gateway_module, __MODULE__.Gateway)
      Application.put_env(:foreman_server, :operator_dashboard_ui_test_pid, self())

      on_exit(fn ->
        restore_env(:command_gateway_module, previous_gateway)
        restore_env(:operator_dashboard_ui_test_pid, previous_pid)
      end)

      :ok
    end

    test "the tab buttons switch the panel and each one controls the one panel that exists" do
      {:ok, view, _html} = open(run_id: "run-ui")

      assert has_element?(view, ~s(#dash-panel[role=tabpanel][aria-labelledby=dash-tab-summary]))
      assert has_element?(view, "#dash-panel h3", "Summary")

      for {tab, heading} <- [
            {"logs", "Durable worker logs"},
            {"changes", "Code changes and PR evidence"},
            {"actions", "Run controls"},
            {"summary", "Phases"}
          ] do
        view |> element("#dash-tab-#{tab}") |> render_click()

        assert has_element?(view, "#dash-tab-#{tab}[aria-selected=true]")
        assert has_element?(view, "#dash-panel[aria-labelledby=dash-tab-#{tab}] h3", heading)
        assert has_element?(view, "#dash-tab-#{tab}[aria-controls=dash-panel]")
        assert has_element?(view, "#dash-panel")
      end

      assert has_element?(view, "[role=tab][aria-selected=false]")
    end

    test "Refresh reloads the run list" do
      {:ok, view, _html} = open(run_id: "run-ui")
      refute has_element?(view, "#run-list button[phx-value-run-id=run-ui-later]")

      seed_run("run-ui-later", "completed")

      view |> element("button[phx-click=refresh]", "Refresh") |> render_click()

      assert has_element?(view, "#run-list button[phx-value-run-id=run-ui-later]")
    end

    test "the filter form narrows the run list" do
      {:ok, view, _html} = open(%{})
      assert has_element?(view, "#run-list button[phx-value-run-id=run-ui]")
      assert has_element?(view, "#run-list button[phx-value-run-id=run-ui-failed]")

      view |> form("#run-filters", %{"status" => "failed"}) |> render_submit()

      assert has_element?(view, "#run-list button[phx-value-run-id=run-ui-failed]")
      refute has_element?(view, "#run-list button[phx-value-run-id=run-ui]")
    end

    test "clicking a run row selects it and moves the marker" do
      {:ok, view, _html} = open(run_id: "run-ui")

      view |> element("#run-list button[phx-value-run-id=run-ui-failed]") |> render_click()

      assert has_element?(view, "h2", "Run run-ui-failed")

      assert has_element?(
               view,
               "#run-list button[phx-value-run-id=run-ui-failed][aria-current=page]"
             )

      refute has_element?(view, "#run-list button[phx-value-run-id=run-ui][aria-current]")

      view |> element("#run-list button[phx-value-run-id=run-ui]") |> render_click()

      assert has_element?(view, "h2", "Run run-ui")
      assert has_element?(view, "#run-list button[phx-value-run-id=run-ui][aria-current=page]")
    end

    test "the Stop control submits the run-action form and dispatches run.pause" do
      seed_run("run-ui-live", "in_progress")
      {:ok, view, _html} = open(run_id: "run-ui-live", tab: "actions")

      assert has_element?(view, "#dash-panel form[phx-submit=run-action]")

      html =
        view
        |> form("#dash-panel form[phx-submit=run-action]", %{"reason" => "from the test"})
        |> render_submit(%{"action" => "stop"})

      assert_receive {:dashboard_command, command}
      assert command.type == "run.pause"
      assert command.payload.run_id == "run-ui-live"
      assert command.payload.reason == "from the test"
      assert html =~ "Command accepted: run.pause"
      assert has_element?(view, "#notice", "Command accepted: run.pause")
    end
  end

  defmodule Gateway do
    @moduledoc false
    def dispatch_operator(envelope) do
      send(
        Application.fetch_env!(:foreman_server, :operator_dashboard_ui_test_pid),
        {:dashboard_command, envelope}
      )

      {:ok, %{accepted: true}}
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:foreman_server, key)
  defp restore_env(key, value), do: Application.put_env(:foreman_server, key, value)

  # `open/1` rather than `live/1`: the imported LiveViewTest macro is `live/2`, and a local
  # `live/1` would collide with it at compile time.
  defp open(params),
    do: live(build_conn(), url(Map.put(Map.new(params), :token, @token)))

  # Class literals as written in the dashboard's own HEEx template: the static `class="..."`
  # strings, plus the modifiers the template builds by concatenation (`"chip--" <> kind`,
  # `"thread-dot--" <> kind`), which are enumerated from every kind the source can produce rather
  # than only what the seeded runs happen to hit.
  defp emitted_classes do
    contents = File.read!("lib/foreman_server_web/operator_run_dashboard_live.ex")

    static =
      for [_ | [captures]] <-
            Regex.scan(~r/class="([a-z0-9][a-z0-9 .-]*)"/, contents) ++
              Regex.scan(~r/class=\{?\[?"([a-z0-9][a-z0-9 .-]*)"/, contents),
          name <- String.split(captures, [" ", "\n"], trim: true),
          do: name

    dynamic =
      for prefix <- ~w(chip-- thread-dot--),
          suffix <- ~w(ok info warn err muted),
          do: prefix <> suffix

    Enum.uniq(static ++ dynamic)
  end

  # The root stylesheet is a literal `~H` template: interpolations style nothing, and `class`
  # selectors are the only way a class name reaches CSS here (attribute selectors in this file
  # match on `role`, `href` etc., never on class), so bare `.name` occurrences are the rule set.
  defp styled_classes do
    {:ok, contents} = File.read("lib/foreman_server_web/workspace/layouts.ex")

    contents
    |> then(&Regex.scan(~r/\.([a-z][a-z0-9_-]*)/, &1))
    |> Enum.flat_map(fn [_ | captures] -> captures end)
    |> Enum.uniq()
  end

  # `"in_progress"` seeds a started run with an active phase and no terminal event.
  defp seed_run(run_id, status, opts \\ []) do
    started =
      %{run_id: run_id, project_id: "project-ui", workflow_name: "implement"}
      |> then(fn payload ->
        case Keyword.get(opts, :task_id) do
          nil -> payload
          task_id -> Map.put(payload, :task_id, task_id)
        end
      end)

    events =
      [
        %{event_type: "RunStarted", payload: started},
        %{
          event_type: "PhaseStarted",
          payload: %{
            phase_id: "#{run_id}-phase-1",
            run_id: run_id,
            index: 1,
            name: "implement",
            attempt: 1,
            artifact_template: "artifact.md"
          }
        }
      ] ++ terminal_events(run_id, status)

    assert :ok = ProjectionStore.apply_events(events)
  end

  defp terminal_events(_run_id, "in_progress"), do: []

  defp terminal_events(run_id, status),
    do: [%{event_type: terminal_event(status), payload: terminal_payload(run_id, status)}]

  # The projection derives a run's status from which terminal event was applied; there is no
  # `RunStatusChanged` for runs, so the seed speaks in the vocabulary the projector handles.
  defp terminal_event("failed"), do: "RunFailed"
  defp terminal_event("completed"), do: "RunCompleted"

  defp terminal_payload(run_id, "failed"),
    do: %{run_id: run_id, project_id: "project-ui", sequence: 2, reason: "agent exited with 1"}

  defp terminal_payload(run_id, "completed"),
    do: %{run_id: run_id, project_id: "project-ui", sequence: 2}
end
