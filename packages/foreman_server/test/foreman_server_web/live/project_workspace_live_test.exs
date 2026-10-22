defmodule ForemanServerWeb.ProjectWorkspaceLiveTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ForemanServer.{CommandGateway, ProjectionStore, ProjectStore, Threads}
  alias ForemanServerWeb.Workspace.Actions
  alias ForemanServer.TelemetryTest.Handler
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "project-workspace-live-token"
  @xss "<script>alert('xss')</script>"

  setup do
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

    id = "ws-#{System.unique_integer([:positive])}"
    other = "other-#{System.unique_integer([:positive])}"

    for p <- [id, other] do
      assert {:ok, _} = ProjectStore.save(%{project_id: p, path: "/tmp/#{p}", name: "Demo #{p}"})
    end

    :ok =
      ProjectionStore.apply_events([
        task("t-ready", id, @xss),
        run("r-ready", "t-ready", id),
        %{event_type: "RunCompleted", payload: %{run_id: "r-ready", project_id: id}},
        %{event_type: "PrReady", payload: %{run_id: "r-ready", pr_url: "javascript:alert(1)"}},
        task("t-pr2", id, "Second PR"),
        run("r-pr2", "t-pr2", id),
        %{event_type: "RunCompleted", payload: %{run_id: "r-pr2", project_id: id}},
        %{
          event_type: "PrReady",
          payload: %{run_id: "r-pr2", pr_url: "https://github.com/a/b/pull/9"}
        },
        task("t-failed", id, "Broken thing"),
        run("r-failed", "t-failed", id),
        %{
          event_type: "RunFailed",
          payload: %{run_id: "r-failed", project_id: id, reason: "boom"}
        },
        task("t-work", id, "In flight"),
        run("r-work", "t-work", id),
        task("t-other", other, "Other project thread"),
        run("r-other", "t-other", other),
        %{event_type: "RunFailed", payload: %{run_id: "r-other", project_id: other, reason: "x"}}
      ])

    {:ok, id: id, other: other}
  end

  defp restore(key, nil), do: Application.delete_env(:foreman_server, key)
  defp restore(key, value), do: Application.put_env(:foreman_server, key, value)

  defp task(task_id, project_id, title),
    do: %{
      event_type: "TaskCreated",
      payload: %{
        task_id: task_id,
        project_id: project_id,
        title: title,
        status: "open",
        task_type: "implement"
      }
    }

  defp run(run_id, task_id, project_id),
    do: %{
      event_type: "RunStarted",
      payload: %{run_id: run_id, task_id: task_id, project_id: project_id}
    }

  defp path(id), do: "/dashboard/projects/#{id}?token=#{@token}"

  # Attaches the refresh telemetry handler BEFORE the view mounts, so no
  # refresh can happen unobserved between a trigger and a later attach.
  defp mount_view(id) do
    {handler, ref} =
      Handler.attach_event_handlers(self(), [[:foreman_server, :workspace, :refresh]])

    Process.put(:refresh_ref, ref)
    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, view, html} = live(build_conn(), path(id))
    Process.put(:view_pid, view.pid)
    {view, html}
  end

  # Re-checks `fun.(html)` after every refresh of the view (and once up front)
  # until it holds; flunks after 5s. No sleeps.
  defp await_until(view, fun) do
    ref = Process.get(:refresh_ref)
    pid = view.pid
    html = render(view)

    if fun.(html) do
      html
    else
      receive do
        {[:foreman_server, :workspace, :refresh], ^ref, _m, %{pid: ^pid}} ->
          await_until(view, fun)
      after
        5_000 ->
          flunk(
            "condition not reached after a refresh; last html:\n" <> String.slice(html, 0, 600)
          )
      end
    end
  end

  defp await_element(view, selector),
    do: await_until(view, fn _ -> has_element?(view, selector) end)

  describe "auth" do
    test "unauthenticated and wrong-token requests get 401, never the page", %{id: id} do
      assert build_conn() |> get("/dashboard/projects/#{id}") |> response(401) == "unauthorized"
      assert build_conn() |> get("/dashboard/projects/#{id}?token=nope") |> response(401)
      assert build_conn() |> get("/dashboard/projects/#{id}/settings") |> response(401)

      assert build_conn()
             |> put_req_header("authorization", "Bearer #{@token}")
             |> get("/dashboard/projects/#{id}")
             |> html_response(200) =~ "Overview"
    end

    test "an unknown project is a 404" do
      assert_error_sent(404, fn ->
        get(build_conn(), "/dashboard/projects/nope?token=#{@token}")
      end)
    end
  end

  describe "overview pane" do
    test "a failing-CI PR raises its thread out of Ready for review (foreman-c1i34)", %{id: id} do
      pr = "https://github.com/a/b/pull/9"

      {view, _html} = mount_view(id)
      assert has_element?(view, "#group-ready_for_review #thread-run\\:r-pr2")

      :ok =
        ProjectionStore.apply_events([
          %{event_type: "PrAssociated", payload: %{run_id: "r-pr2", pr_url: pr, pr_number: 9}},
          %{
            event_type: "PrChecksChanged",
            payload: %{
              run_id: "r-pr2",
              project_id: id,
              task_id: "t-pr2",
              pr_url: pr,
              head_sha: "h1",
              pr_status: "open",
              checks_state: "failing",
              failing: [%{name: "unit"}],
              digest: "d1",
              observation_seq: 1
            }
          }
        ])

      html =
        await_until(view, fn _ ->
          has_element?(view, "#group-waiting_on_you #thread-run\\:r-pr2")
        end)

      assert html =~ "CI failing"
      refute has_element?(view, "#group-ready_for_review #thread-run\\:r-pr2")

      {:ok, overview} = ForemanServer.Overview.build(id)
      assert :ci_failing in overview.attention.reasons
    end

    test "groups threads by state with counts, from the seeded projection", %{id: id} do
      {view, _html} = mount_view(id)

      assert view |> element("#group-ready_for_review") |> render() =~ "Ready for review"
      assert has_element?(view, "#group-ready_for_review article", "alert(")
      assert has_element?(view, "#group-waiting_on_you article", "Broken thing")
      assert has_element?(view, "#group-working article", "In flight")
      assert render(view) =~ "Landing"
      assert render(view) =~ "Idle"
      assert render(view) =~ "Resolved"
      refute has_element?(view, "#thread-run\\:r-other")
    end

    test "untrusted thread titles and PR urls are escaped, never rendered as markup", %{id: id} do
      {view, html} = mount_view(id)
      html = html <> render(view)

      assert html =~ "&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;"
      refute html =~ "<script>alert"
      refute html =~ ~s(href="javascript:)
    end

    test "resolve moves the card to Resolved via the projection event; reopen moves it back", %{
      id: id
    } do
      {view, _} = mount_view(id)

      view |> element("#thread-run\\:r-failed button", "Resolve") |> render_click()
      await_element(view, "#group-resolved #thread-run\\:r-failed")

      assert {:ok, %{resolved: true}} = Threads.get("run:r-failed")

      view |> element("#thread-run\\:r-failed button", "Reopen") |> render_click()
      await_element(view, "#group-waiting_on_you #thread-run\\:r-failed")
      refute has_element?(view, "#group-resolved #thread-run\\:r-failed")
    end

    test "a thread of another project is refused and nothing is dispatched", %{id: id} do
      {view, _} = mount_view(id)

      html =
        render_click(view, "thread_action", %{"action" => "resolve", "thread-id" => "run:r-other"})

      assert html =~ "That thread belongs to another project."
      assert {:ok, %{resolved: false}} = Threads.get("run:r-other")
    end

    test "steer rejects an empty message through Threads.Actions and shows the reason", %{id: id} do
      {view, _} = mount_view(id)

      html =
        render_submit(view, "steer", %{
          "thread_id" => "run:r-work",
          "text" => "  ",
          "message_id" => "m1"
        })

      assert html =~ "the message is empty"
    end

    test "stop needs a confirm step and reports a terminal thread as not stoppable", %{id: id} do
      {view, _} = mount_view(id)

      refute render(view) =~ "Confirm stop"
      html = render_click(view, "stop", %{"thread-id" => "run:r-failed"})
      assert html =~ "not_stoppable"
    end
  end

  describe "tabs" do
    test "library tab is served by the built-in provider (empty library: nothing to show)", %{
      id: id
    } do
      {view, _} = mount_view(id)

      html = view |> element("#tab-library") |> render_click()
      refute html =~ "Not available yet."
      assert html =~ "Nothing to show."
      refute has_element?(view, "#panel-library li")
    end

    test "pull requests list the project's PRs; unsafe urls are not links", %{id: id} do
      {view, _} = mount_view(id)

      view |> element("#tab-pull_requests") |> render_click()

      assert has_element?(view, "#panel-pull_requests li", "Second PR")
      assert has_element?(view, ~s(#panel-pull_requests a[href="https://github.com/a/b/pull/9"]))
      assert has_element?(view, "#panel-pull_requests li", "gate pending")
      # the other PR (a javascript: url) is listed but never linked
      assert has_element?(view, "#panel-pull_requests li", "alert(")
      refute render(view) =~ ~s(href="javascript:)
      refute has_element?(view, "#panel-library")
    end

    test "scheduled lists schedules and pause goes through schedule.pause", %{
      id: id,
      other: other
    } do
      for {project, sid, name} <- [{id, "s-1", "nightly"}, {other, "s-2", "foreign"}] do
        assert {:ok, _} =
                 CommandGateway.dispatch_operator(%{
                   command_id: "sched-#{sid}-#{id}",
                   type: "schedule.create",
                   aggregate_id: "schedule:#{project}:#{sid}",
                   payload: %{
                     project_id: project,
                     schedule_id: sid,
                     name: name,
                     spec: %{"every" => "1h", "anchor" => "2026-01-01T00:00:00Z"},
                     prompt: "p",
                     workflow: "implement"
                   }
                 })
      end

      {view, _} = mount_view(id)
      view |> element("#tab-scheduled") |> render_click()

      assert has_element?(view, "#panel-scheduled td", "nightly")
      refute has_element?(view, "#panel-scheduled td", "foreign")

      view |> element("#panel-scheduled button", "Pause nightly") |> render_click()

      await_until(view, fn _ ->
        has_element?(view, "#panel-scheduled button", "Resume nightly")
      end)

      assert [%{status: "paused"}] = ProjectionStore.schedules(id)

      # a schedule of another project is refused, not paused
      assert render_click(view, "schedule", %{"op" => "pause", "id" => "s-2"}) =~
               "Schedule not found in this project."

      assert [%{status: "active"}] = ProjectionStore.schedules(other)
    end
  end

  describe "conversation pane" do
    test "posting a message shows it, escaped, and an HTTP-posted one arrives via PubSub", %{
      id: id
    } do
      {view, _} = mount_view(id)
      bug = "pasted bug report <img src=x onerror=alert(1)>"

      html = view |> form("#composer", %{"text" => bug}) |> render_submit()
      assert html =~ "pasted bug report &lt;img src=x onerror=alert(1)&gt;"
      refute html =~ "<img src=x"

      assert {:ok, _} =
               ForemanServer.CoordinatorAPI.post_message(id, %{
                 text: "from the API",
                 source: "http"
               })

      assert await_until(view, &(&1 =~ "from the API")) =~ "from the API"
    end

    test "a blank message is refused client-side of the dispatch", %{id: id} do
      {view, _} = mount_view(id)

      assert view |> form("#composer", %{"text" => "   "}) |> render_submit() =~
               "Write a message first."
    end

    test "proposals render a Start button only for open tasks of this project", %{
      id: id,
      other: other
    } do
      assert {:ok, _} =
               CommandGateway.dispatch_system(%{
                 command_id: "prop-#{id}",
                 aggregate_id: "coordinator:" <> id,
                 type: "coordinator.message",
                 payload: %{project_id: id, message_id: "m-seed", text: "hi", source: "http"}
               })

      :ok =
        ProjectionStore.apply_events([
          task("t-prop", id, "Proposed work"),
          task("t-prop-other", other, "Foreign"),
          %{
            event_type: "CoordinatorActionRecorded",
            payload: %{
              project_id: id,
              action_id: "a1",
              turn_id: "turn1",
              kind: "propose_threads",
              status: "proposed",
              result_ref: %{"task_ids" => ["t-prop", "t-prop-other"]}
            }
          }
        ])

      {view, html} = mount_view(id)

      assert html =~ "Proposed work"
      assert has_element?(view, "#proposal-t-prop button", "Start")

      # another project's task was named in the proposal: no Start button, and a
      # forged click is refused with its own message, dispatching nothing
      refute has_element?(view, "#proposal-t-prop-other button")

      assert render_click(view, "start_proposed", %{"task-id" => "t-prop-other"}) =~
               "That task belongs to another project."

      assert %{status: "open"} = ProjectionStore.task_projection("t-prop-other")

      # a task the coordinator never proposed, and an unknown one, differ
      assert render_click(view, "start_proposed", %{"task-id" => "t-ready"}) =~
               "The coordinator did not propose that task."

      assert render_click(view, "start_proposed", %{"task-id" => "ghost"}) =~ "Task not found."
    end
  end

  describe "bounded updates" do
    test "a burst of events costs a bounded number of refreshes", %{id: id} do
      {view, _} = mount_view(id)
      before = :sys.get_state(view.pid).socket.assigns.refresh_count

      for n <- 1..200 do
        send(
          view.pid,
          {:projection_event,
           %{event_type: "RunStarted", data: %{project_id: id, run_id: "x#{n}"}}}
        )
      end

      # events for other projects and worker output never schedule anything
      send(
        view.pid,
        {:projection_event, %{event_type: "RunStarted", data: %{project_id: "elsewhere"}}}
      )

      send(view.pid, {:projection_event, %{event_type: "WorkerStdout", data: %{}}})

      await_until(view, fn _ -> :sys.get_state(view.pid).socket.assigns.refresh_count > before end)

      count = :sys.get_state(view.pid).socket.assigns.refresh_count - before
      assert count <= 2
    end

    test "an idle workspace does no work: no refresh without events", %{id: id} do
      {view, _} = mount_view(id)
      ref = Process.get(:refresh_ref)
      render(view)
      refute_receive {[:foreman_server, :workspace, :refresh], ^ref, _, _}, 100
    end
  end

  describe "idempotent actions" do
    test "the same intent dedupes a repeated action; a new intent is a new action", %{id: id} do
      assert {:ok, _} = Actions.set_resolved(id, "run:r-failed", :resolve, "i-1")
      assert {:ok, _} = Actions.set_resolved(id, "run:r-failed", :reopen, "i-2")
      # a double click: same intent, same command id, deduplicated by the router
      assert {:ok, _} = Actions.set_resolved(id, "run:r-failed", :reopen, "i-2")
      # a genuinely new reopen of a thread that is not resolved is rejected
      assert {:error, message} = Actions.set_resolved(id, "run:r-failed", :reopen, "i-3")
      assert message =~ "thread_not_resolved"
    end

    test "errors are distinct for a missing and a foreign thread", %{id: id} do
      assert {:error, "Thread not found."} = Actions.set_resolved(id, "run:ghost", :resolve, "i")

      assert {:error, "That thread belongs to another project."} =
               Actions.set_resolved(id, "run:r-other", :resolve, "i")
    end
  end

  describe "accessibility" do
    test "landmarks, live regions and labelled controls are present", %{id: id} do
      {_view, html} = mount_view(id)

      assert html =~ ~s(<main id="main")
      assert html =~ ~s(role="log" aria-live="polite")
      assert html =~ ~s(id="notice" role="status" aria-live="polite")
      assert html =~ ~s(role="tablist")
      assert html =~ ~s(aria-selected=)
      assert html =~ "Message the coordinator"
      assert html =~ ~s(<html lang="en")
    end
  end
end
