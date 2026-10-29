defmodule ForemanServerWeb.ProjectWorkspaceLiveTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ForemanServer.{CommandGateway, ProjectionStore, ProjectStore, Threads}
  alias ForemanServer.Overview.{Group, ThreadCard}
  alias ForemanServer.Threads.Thread
  alias ForemanServerWeb.Workspace.{Actions, Components}
  alias ForemanServer.TelemetryTest.Handler
  alias ForemanServer.TestSupport.{PrWatchSupport, ProjectionStoreReset}

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
        run("r-failed-#{id}", "t-failed", id),
        %{
          event_type: "RunFailed",
          payload: %{run_id: "r-failed-#{id}", project_id: id, reason: "boom"}
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

  # The exit reason of the view when `fun` (a render_* call) crashes it. LiveViewTest links
  # the test process to the view's proxy, so exits are trapped for the call; the crash is
  # the view's own and its error log is not noise for the rest of the run.
  defp view_crash(fun) do
    Process.flag(:trap_exit, true)
    test = self()
    capture_log(fn -> send(test, {:crashed, catch_exit(fun.())}) end)
    assert_received {:crashed, {reason, _call}}
    reason
  end

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
    @review_pr "https://github.com/a/b/pull/9"

    defp pr_event(type, id, extra) do
      %{
        event_type: type,
        payload:
          Map.merge(
            %{
              run_id: "r-pr2",
              project_id: id,
              task_id: "t-pr2",
              pr_url: @review_pr,
              head_sha: "h1",
              pr_status: "open",
              digest: "d",
              observation_seq: 1
            },
            extra
          )
      }
    end

    defp pr_review(id, extra), do: pr_event("PrReviewChanged", id, extra)

    defp pr_checks(id, state, seq),
      do:
        pr_event("PrChecksChanged", id, %{checks_state: state, failing: [], observation_seq: seq})

    defp watch_pr(events) do
      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "PrAssociated",
            payload: %{run_id: "r-pr2", pr_url: @review_pr, pr_number: 9}
          }
          | events
        ])
    end

    defp in_group?(view, group),
      do: has_element?(view, "#group-#{group} #thread-run\\:r-pr2")

    test "an unresolved review thread raises the thread to Waiting on you and clears when resolved (foreman-v8wqe)",
         %{id: id} do
      {view, _html} = mount_view(id)
      assert in_group?(view, "ready_for_review")

      watch_pr([pr_review(id, %{thread_ids: ["PRRT_1"], observation_seq: 1})])
      html = await_until(view, fn _ -> in_group?(view, "waiting_on_you") end)

      assert html =~ "Review threads unresolved"
      refute in_group?(view, "ready_for_review")

      {:ok, overview} = ForemanServer.Overview.build(id)
      assert :review_threads in overview.attention.reasons

      # The thread is resolved on GitHub: the next observation carries no thread ids.
      watch_pr([pr_review(id, %{thread_ids: [], digest: "d2", observation_seq: 2})])
      await_until(view, fn _ -> in_group?(view, "ready_for_review") end)

      refute in_group?(view, "waiting_on_you")
      {:ok, overview} = ForemanServer.Overview.build(id)
      refute :review_threads in overview.attention.reasons
    end

    test "an outstanding CHANGES_REQUESTED review raises the thread to Waiting on you (foreman-v8wqe)",
         %{id: id} do
      {view, _html} = mount_view(id)

      watch_pr([pr_review(id, %{review_decision: "changes_requested"})])
      html = await_until(view, fn _ -> in_group?(view, "waiting_on_you") end)

      assert html =~ "Changes requested"
      {:ok, overview} = ForemanServer.Overview.build(id)
      assert :changes_requested in overview.attention.reasons

      watch_pr([pr_review(id, %{review_decision: "approved", digest: "d2", observation_seq: 2})])
      await_until(view, fn _ -> in_group?(view, "ready_for_review") end)
    end

    test "conversation comments alone do not raise attention (they have no resolved state)",
         %{id: id} do
      watch_pr([pr_review(id, %{comment_ids: ["IC_1"]})])
      {:ok, overview} = ForemanServer.Overview.build(id)

      assert Enum.any?(overview.groups.ready_for_review, &(&1.thread_id == "run:r-pr2"))
      refute Enum.any?(overview.groups.waiting_on_you, &(&1.thread_id == "run:r-pr2"))
    end

    test "failing CI and a pending review both hold the thread; CI is the reason until it clears (foreman-v8wqe)",
         %{id: id} do
      {view, _html} = mount_view(id)

      watch_pr([
        pr_checks(id, "failing", 1),
        pr_review(id, %{thread_ids: ["PRRT_1"], review_decision: "changes_requested"})
      ])

      html = await_until(view, fn _ -> in_group?(view, "waiting_on_you") end)
      assert html =~ "CI failing"
      refute html =~ "Review threads unresolved"

      # CI goes green: the review state still holds the thread.
      :ok = ProjectionStore.apply_events([pr_checks(id, "passing", 2)])
      html = await_until(view, fn h -> not (h =~ "CI failing") end)

      assert in_group?(view, "waiting_on_you")
      assert html =~ "Changes requested"

      # The review is addressed too: back to Ready for review.
      :ok =
        ProjectionStore.apply_events([
          pr_review(id, %{
            thread_ids: [],
            review_decision: "approved",
            digest: "d2",
            observation_seq: 2
          })
        ])

      await_until(view, fn _ -> in_group?(view, "ready_for_review") end)
    end

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

      view
      |> element("#thread-run\\:r-failed-#{id} button[phx-value-action=resolve]")
      |> render_click()

      await_element(view, "#group-resolved #thread-run\\:r-failed-#{id}")

      assert {:ok, %{resolved: true}} = Threads.get("run:r-failed-#{id}")

      view |> element("#thread-run\\:r-failed-#{id} button", "Reopen") |> render_click()
      await_element(view, "#group-waiting_on_you #thread-run\\:r-failed-#{id}")
      refute has_element?(view, "#group-resolved #thread-run\\:r-failed-#{id}")
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
      html = render_click(view, "stop", %{"thread-id" => "run:r-failed-#{id}"})
      assert html =~ "not_stoppable"
    end
  end

  describe "tabs" do
    test "library tab is served by the built-in provider (empty library: nothing to show)", %{
      id: id
    } do
      {view, _} = mount_view(id)

      # Library is the default tab, so clicking it on a fresh page proves nothing: leave it
      # for another tab, see the panel go, then come back.
      assert has_element?(view, ~s(#tab-library[aria-selected="true"]))
      assert has_element?(view, "#panel-library")

      view |> element("#tab-pull_requests") |> render_click()
      refute has_element?(view, "#panel-library")
      assert has_element?(view, "#panel-pull_requests")
      assert has_element?(view, ~s(#tab-library[aria-selected="false"]))

      html = view |> element("#tab-library") |> render_click()
      assert has_element?(view, "#panel-library")
      refute has_element?(view, "#panel-pull_requests")
      assert has_element?(view, ~s(#tab-library[aria-selected="true"]))
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

    defp seed_schedule(project, sid, name) do
      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: "sched-#{project}-#{sid}",
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

    defp schedule_event_types(project, sid) do
      {:ok, events} =
        ForemanServer.EventStore.read_stream_forward("schedule:#{project}:#{sid}", 0, 100)

      Enum.map(events, & &1.event_type)
    end

    test "scheduled rows delete only after a confirm step, active or paused alike", %{
      id: id,
      other: other
    } do
      uniq = System.unique_integer([:positive])
      {nightly, weekly, foreign} = {"s-n-#{uniq}", "s-w-#{uniq}", "s-f-#{uniq}"}
      seed_schedule(id, nightly, "nightly")
      seed_schedule(id, weekly, "weekly")
      seed_schedule(other, foreign, "foreign")

      {view, _} = mount_view(id)
      view |> element("#tab-scheduled") |> render_click()

      assert has_element?(view, "#panel-scheduled button", "Delete nightly")
      assert has_element?(view, "#panel-scheduled button", "Delete weekly")
      refute has_element?(view, "#panel-scheduled button", "Delete foreign")

      # the first click only asks: confirm + cancel for THAT row, nothing dispatched
      view |> element("#panel-scheduled button", "Delete nightly") |> render_click()

      assert has_element?(view, "#panel-scheduled button", "Confirm delete nightly")
      assert has_element?(view, "#panel-scheduled button", "Cancel")
      refute has_element?(view, "#panel-scheduled button", "Confirm delete weekly")
      refute has_element?(view, "#panel-scheduled button", "Delete nightly")
      assert has_element?(view, "#panel-scheduled button", "Delete weekly")

      assert Enum.map(ProjectionStore.schedules(id), & &1.schedule_id) |> Enum.sort() ==
               Enum.sort([nightly, weekly])

      assert schedule_event_types(id, nightly) == ["ScheduleCreated"]

      # Cancel backs out without dispatching
      view |> element("#panel-scheduled button", "Cancel") |> render_click()
      refute has_element?(view, "#panel-scheduled button", "Confirm delete")
      refute has_element?(view, "#panel-scheduled button", "Cancel")
      assert has_element?(view, "#panel-scheduled button", "Delete nightly")
      assert schedule_event_types(id, nightly) == ["ScheduleCreated"]
      assert %{status: "active"} = ProjectionStore.schedule(id, nightly)

      # a paused schedule is deletable too
      view |> element("#panel-scheduled button", "Pause weekly") |> render_click()

      await_until(view, fn _ -> has_element?(view, "#panel-scheduled button", "Resume weekly") end)

      assert has_element?(view, "#panel-scheduled button", "Delete weekly")

      view |> element("#panel-scheduled button", "Delete weekly") |> render_click()
      assert schedule_event_types(id, weekly) == ["ScheduleCreated", "SchedulePaused"]
      view |> element("#panel-scheduled button", "Confirm delete weekly") |> render_click()

      refute has_element?(view, "#panel-scheduled td", "weekly")
      assert has_element?(view, "#panel-scheduled td", "nightly")
      assert render(view) =~ "Done: schedule.delete #{weekly}."
      refute has_element?(view, "#panel-scheduled button", "Confirm delete")
      assert Enum.map(ProjectionStore.schedules(id), & &1.schedule_id) == [nightly]
      assert %{status: "deleted"} = ProjectionStore.schedule(id, weekly)
      assert Enum.count(schedule_event_types(id, weekly), &(&1 == "ScheduleDeleted")) == 1

      # the other schedule of the project is untouched
      assert %{status: "active"} = ProjectionStore.schedule(id, nightly)
      assert schedule_event_types(id, nightly) == ["ScheduleCreated"]

      # a forged foreign id and an unknown id are refused and touch nothing
      assert render_click(view, "schedule_delete", %{"id" => foreign}) =~
               "Schedule not found in this project."

      assert %{status: "active"} = ProjectionStore.schedule(other, foreign)
      assert schedule_event_types(other, foreign) == ["ScheduleCreated"]

      # a pending confirm on another row does not linger once any delete is attempted
      view |> element("#panel-scheduled button", "Delete nightly") |> render_click()
      assert has_element?(view, "#panel-scheduled button", "Confirm delete nightly")

      assert render_click(view, "schedule_delete", %{"id" => "s-unknown-#{uniq}"}) =~
               "Schedule not found in this project."

      refute has_element?(view, "#panel-scheduled button", "Confirm delete")
      assert has_element?(view, "#panel-scheduled button", "Delete nightly")

      assert Process.alive?(view.pid)
      assert schedule_event_types(id, nightly) == ["ScheduleCreated"]
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

    # Real task aggregates (`task.create` the way the coordinator makes them, not
    # tracked by a task provider): Decline dispatches `task.update`, which the
    # aggregate only accepts for a task that exists.
    defp seed_proposals(id, other) do
      uniq = System.unique_integer([:positive])
      prop = "t-prop-#{uniq}"
      foreign = "t-foreign-#{uniq}"

      assert {:ok, _} =
               CommandGateway.dispatch_system(%{
                 command_id: "prop-#{id}",
                 aggregate_id: "coordinator:" <> id,
                 type: "coordinator.message",
                 payload: %{project_id: id, message_id: "m-seed", text: "hi", source: "http"}
               })

      for {task_id, project, title} <- [
            {prop, id, "Proposed work"},
            {foreign, other, "Foreign"}
          ] do
        assert {:ok, _} =
                 CommandGateway.dispatch_system(%{
                   command_id: "prop-task-#{task_id}-#{id}",
                   aggregate_id: "task:" <> task_id,
                   type: "task.create",
                   payload: %{
                     task_id: task_id,
                     project_id: project,
                     title: title,
                     status: "open",
                     source: "coordinator",
                     provider_tracked: false
                   }
                 })

        ForemanServer.TestSupport.Eventually.await(fn ->
          ProjectionStore.task_projection(task_id)
        end)
      end

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "CoordinatorActionRecorded",
            payload: %{
              project_id: id,
              action_id: "a1",
              turn_id: "turn1",
              kind: "propose_threads",
              status: "proposed",
              result_ref: %{"task_ids" => [prop, foreign]}
            }
          }
        ])

      %{prop: prop, foreign: foreign}
    end

    test "Decline closes a proposed task: the card loses its buttons and Start is refused", %{
      id: id,
      other: other
    } do
      %{prop: prop, foreign: foreign} = seed_proposals(id, other)
      {view, _} = mount_view(id)

      assert has_element?(view, "#proposal-#{prop} button", "Decline")
      refute has_element?(view, "#proposal-#{foreign} button")

      html = view |> element("#proposal-#{prop} button", "Decline") |> render_click()
      assert html =~ "Done: task.update #{prop}."

      await_until(view, fn _ -> not has_element?(view, "#proposal-#{prop} button") end)
      assert %{status: "closed"} = ProjectionStore.task_projection(prop)
      assert has_element?(view, "#proposal-#{prop}", "(closed)")

      # a declined proposal can be neither started nor declined again
      assert render_click(view, "start_proposed", %{"task-id" => prop}) =~
               "That task is no longer open (closed)."

      assert render_click(view, "decline_proposed", %{"task-id" => prop}) =~
               "That task is no longer open (closed)."
    end

    test "a forged Decline is refused and closes nothing", %{id: id, other: other} do
      %{prop: prop, foreign: foreign} = seed_proposals(id, other)
      {view, _} = mount_view(id)

      # another project's task named in the proposal, a task nobody proposed, an unknown one
      assert render_click(view, "decline_proposed", %{"task-id" => foreign}) =~
               "That task belongs to another project."

      assert render_click(view, "decline_proposed", %{"task-id" => "t-ready"}) =~
               "The coordinator did not propose that task."

      assert render_click(view, "decline_proposed", %{"task-id" => "ghost"}) =~ "Task not found."

      for task_id <- [prop, foreign, "t-ready"],
          do: assert(%{status: "open"} = ProjectionStore.task_projection(task_id))
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

    # E16-S6-T4: the page stays usable with a big project: every thread is rendered.
    test "a project with 200 threads mounts and renders all of them", %{id: id} do
      events =
        Enum.flat_map(1..200, fn n ->
          [
            task("t-budget-#{n}", id, "Budget thread #{n}"),
            run(ForemanServer.TestSupport.UniqueIds.unique_run_id("budget"), "t-budget-#{n}", id)
          ]
        end)

      :ok = ProjectionStore.apply_events(events)

      {:ok, view, html} = live(build_conn(), path(id))

      assert html =~ "Budget thread 200"
      assert render(view) =~ "Budget thread 1"
    end
  end

  describe "idempotent actions" do
    test "the same intent dedupes a repeated action; a new intent is a new action", %{id: id} do
      assert {:ok, _} = Actions.set_resolved(id, "run:r-failed-#{id}", :resolve, "i-1")
      assert {:ok, _} = Actions.set_resolved(id, "run:r-failed-#{id}", :reopen, "i-2")
      # a double click: same intent, same command id, deduplicated by the router
      assert {:ok, _} = Actions.set_resolved(id, "run:r-failed-#{id}", :reopen, "i-2")
      # a genuinely new reopen of a thread that is not resolved is rejected
      assert {:error, message} = Actions.set_resolved(id, "run:r-failed-#{id}", :reopen, "i-3")
      assert message =~ "thread_not_resolved"
    end

    test "errors are distinct for a missing and a foreign thread", %{id: id} do
      assert {:error, "Thread not found."} = Actions.set_resolved(id, "run:ghost", :resolve, "i")

      assert {:error, "That thread belongs to another project."} =
               Actions.set_resolved(id, "run:r-other", :resolve, "i")
    end

    test "a task action on a project that is not there says so, not 'task not found'", %{} do
      assert {:error, "Project not found."} =
               Actions.start_proposed("no-such-project", "t-ready", "i")

      assert {:error, "Project not found."} =
               Actions.decline_proposed("no-such-project", "t-ready", "i")
    end
  end

  describe "intents" do
    test "a view's action after a restart is a new command, never a replay of an old session's",
         %{id: id} do
      # session 1 resolves the thread ...
      {view, _} = mount_view(id)

      view
      |> element("#thread-run\\:r-failed-#{id} button[phx-value-action=resolve]")
      |> render_click()

      await_element(view, "#group-resolved #thread-run\\:r-failed-#{id}")

      # ... someone else reopens it ...
      assert {:ok, _} = Actions.set_resolved(id, "run:r-failed-#{id}", :reopen, "elsewhere")
      assert {:ok, %{resolved: false}} = Threads.get("run:r-failed-#{id}")

      # ... and after a restart a view's counters start from zero again, only its random
      # session nonce is new. Its resolve is a new command and must append a new event; a
      # command id repeating the old session's would be answered "Done" with nothing appended.
      {restarted, _} = mount_view(id)

      restarted
      |> element("#thread-run\\:r-failed-#{id} button[phx-value-action=resolve]")
      |> render_click()

      await_element(restarted, "#group-resolved #thread-run\\:r-failed-#{id}")
      assert {:ok, %{resolved: true}} = Threads.get("run:r-failed-#{id}")
    end
  end

  describe "run control" do
    # `start_run!/1` writes a real RunStarted to the run's stream, so the run aggregate
    # answers `run.pause` and `run.resume`.
    setup %{id: id} do
      run = PrWatchSupport.start_run!(project_id: id)
      {:ok, run_id: run.run_id, thread: "run:" <> run.run_id}
    end

    defp run_event_types(run_id) do
      {:ok, events} = ForemanServer.EventStore.read_stream_forward("run:" <> run_id, 0, 100)
      Enum.map(events, & &1.event_type)
    end

    test "pause and resume each dispatch their own command", %{
      id: id,
      run_id: run_id,
      thread: thread
    } do
      assert {:ok, "Done: run.pause " <> _} = Actions.run_control(id, thread, :pause, "i-1")
      assert run_event_types(run_id) == ["RunStarted", "RunPaused"]

      assert {:ok, "Done: run.resume " <> _} = Actions.run_control(id, thread, :resume, "i-2")
      assert run_event_types(run_id) == ["RunStarted", "RunPaused", "RunResumed"]
    end

    test "any other value raises and dispatches nothing, never a silent run.resume", %{
      id: id,
      run_id: run_id,
      thread: thread
    } do
      assert {:ok, _} = Actions.run_control(id, thread, :pause, "i-1")

      for which <- [:stop, :cancel, :unpause, "resume", nil] do
        assert_raise FunctionClauseError, fn -> Actions.run_control(id, thread, which, "i-x") end
      end

      # any value but :pause used to resume the paused run
      assert run_event_types(run_id) == ["RunStarted", "RunPaused"]
    end
  end

  describe "an event the page does not know" do
    # No catch-all clause: a renamed phx-value key, an unknown tab or an action outside the
    # allowed list is a defect that must show (the view restarts), not a dead button.
    test "restarts the view instead of doing nothing", %{id: id} do
      {view, _} = mount_view(id)

      assert {:function_clause,
              [
                {ForemanServerWeb.ProjectWorkspaceLive, :handle_event, ["no_such_event", %{}, _],
                 _}
                | _
              ]} =
               view_crash(fn -> render_click(view, "no_such_event", %{}) end)
    end

    test "events whose parameters match no clause raise" do
      socket = %Phoenix.LiveView.Socket{}

      for {event, params} <- [
            {"no_such_event", %{}},
            {"tab", %{"tab" => "no_such_tab"}},
            {"thread_action", %{"action" => "explode", "thread-id" => "run:r-work"}},
            {"thread_action", %{"action" => "pause"}},
            {"schedule", %{"op" => "delete", "id" => "s-1"}},
            {"steer", %{"thread-id" => "run:r-work", "text" => "x"}}
          ] do
        assert_raise FunctionClauseError, fn ->
          ForemanServerWeb.ProjectWorkspaceLive.handle_event(event, params, socket)
        end
      end
    end
  end

  describe "thread cards" do
    # Every action id a card can carry, from building a card for every door, status, group
    # and reason (`ThreadCard.build/4` is pure).
    defp card_actions do
      for door <- [:workflow, :jobsite],
          status <- ["in_progress", "paused", "failed", "completed"],
          group <- Group.all(),
          reason <- Group.reasons(),
          thread = %Thread{
            id: if(door == :workflow, do: "run:r1", else: "jobsite:j1"),
            door: door,
            project_id: "p",
            title: "T",
            status: status
          },
          action <- ThreadCard.build(thread, nil, {group, reason}, []).actions,
          uniq: true,
          do: action
    end

    defp card_html(actions) do
      card = %ThreadCard{
        thread_id: "run:r1",
        door: :workflow,
        title: "Card",
        group: :working,
        reason: :in_flight,
        steering: "pause_resume",
        actions: actions
      }

      render_component(&Components.thread_card/1,
        card: card,
        confirm_stop: nil,
        steer_nonce: "n"
      )
    end

    @action_markers %{
      "run.cancel" => ~s(phx-click="confirm_stop"),
      "run.pause" => ~s(phx-value-action="pause"),
      "run.resume" => ~s(phx-value-action="resume"),
      "thread.resolve" => ~s(phx-value-action="resolve"),
      "thread.reopen" => ~s(phx-value-action="reopen"),
      "thread.steer" => ~s(phx-submit="steer")
    }

    test "every action a card can carry renders its own control" do
      ids = card_actions()
      # not vacuous: every documented action is found
      assert Map.keys(@action_markers) -- ids == []

      for id <- ids do
        assert card_html([id]) =~ Map.fetch!(@action_markers, id)
      end
    end

    test "an action with no control raises instead of rendering an empty card" do
      assert_raise FunctionClauseError, fn -> card_html(["thread.merge"]) end
    end

    test "the page accepts every thread_action value its cards send, and only those", %{id: id} do
      sent =
        for action <- card_actions(),
            [_, value] <-
              Regex.scan(
                ~r/phx-click="thread_action"\s+phx-value-action="([^"]+)"/,
                card_html([action])
              ),
            uniq: true,
            do: value

      assert Enum.sort(sent) == Enum.sort(Components.thread_actions())

      {view, _} = mount_view(id)

      for value <- sent do
        assert is_binary(
                 render_click(view, "thread_action", %{
                   "action" => value,
                   "thread-id" => "run:r-work"
                 })
               )
      end

      assert {:function_clause,
              [{ForemanServerWeb.ProjectWorkspaceLive, :handle_event, _, _} | _]} =
               view_crash(fn ->
                 render_click(view, "thread_action", %{
                   "action" => "explode",
                   "thread-id" => "run:r-work"
                 })
               end)
    end
  end

  describe "header" do
    test "shows the name in the project's config whichever key shape it has, else the id", %{
      id: id
    } do
      unique = System.unique_integer([:positive])
      atom_keyed = "named-atom-#{unique}"
      string_keyed = "named-string-#{unique}"

      # an Elixir caller's config has atom keys, an HTTP client's (JSON) string keys
      for {project, config} <- [
            {atom_keyed, %{name: "Atom Keyed"}},
            {string_keyed, %{"name" => "String Keyed"}}
          ] do
        assert {:ok, _} =
                 ProjectStore.save(%{
                   project_id: project,
                   path: "/tmp/#{project}",
                   config: config
                 })
      end

      for {project, shown} <- [
            {atom_keyed, "Atom Keyed"},
            {string_keyed, "String Keyed"},
            {id, id}
          ] do
        {view, _} = mount_view(project)
        assert view |> element("header h1") |> render() =~ shown
      end
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
