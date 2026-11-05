defmodule ForemanServerWeb.ProjectWorkspaceLiveTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ForemanServer.{CommandGateway, ProjectionStore, ProjectStore, Threads}
  alias ForemanServer.Overview.{Group, ThreadCard}
  alias ForemanServer.Threads.Thread
  alias ForemanServerWeb.Workspace.{Actions, Components, ThreadView}
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

  # A thread's own URL (the id is percent-encoded by `Components.thread_path/2`).
  defp thread_url(id, thread_id), do: Components.thread_path(id, thread_id) <> "?token=#{@token}"

  # Opens a thread in an already mounted view: a patch, so the view keeps its process and state.
  defp open_thread(view, id, thread_id),
    do: render_patch(view, Components.thread_path(id, thread_id))

  # Attaches the refresh telemetry handler BEFORE the view mounts, so no
  # refresh can happen unobserved between a trigger and a later attach.
  defp mount_view(id, url \\ nil) do
    {handler, ref} =
      Handler.attach_event_handlers(self(), [[:foreman_server, :workspace, :refresh]])

    Process.put(:refresh_ref, ref)
    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, view, html} = live(build_conn(), url || path(id))
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
             |> html_response(200) =~ "Threads"
    end

    test "an unknown project is a 404" do
      assert_error_sent(404, fn ->
        get(build_conn(), "/dashboard/projects/nope?token=#{@token}")
      end)
    end
  end

  describe "thread sidebar" do
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
      open_thread(view, id, "run:r-pr2")
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
      open_thread(view, id, "run:r-pr2")

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
      open_thread(view, id, "run:r-pr2")

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
      open_thread(view, id, "run:r-pr2")
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
      :ok =
        ProjectionStore.apply_events([
          task("t-idle", id, "Finished quietly"),
          run("r-idle", "t-idle", id),
          %{event_type: "RunCompleted", payload: %{run_id: "r-idle", project_id: id}}
        ])

      {view, _html} = mount_view(id)

      assert has_element?(view, ~s(nav#thread-list[aria-label="Threads"]))
      assert has_element?(view, "#group-ready_for_review-title", "Ready for review (2)")
      assert has_element?(view, "#group-waiting_on_you-title", "Waiting on you (1)")
      assert has_element?(view, "#group-working-title", "Working (1)")
      assert has_element?(view, "#group-ready_for_review .thread-row-title", "alert(")
      assert has_element?(view, "#group-waiting_on_you .thread-row-title", "Broken thing")
      assert has_element?(view, "#group-working .thread-row-title", "In flight")

      # groups come in the order Waiting on you, Working, Landing, Ready for review
      html = render(view)

      positions =
        for group <- ["waiting_on_you", "working", "ready_for_review"],
            do: elem(:binary.match(html, ~s(id="group-#{group}")), 0)

      assert positions == Enum.sort(positions)

      # a group with no threads is not rendered at all, not an empty "Nothing here."
      refute has_element?(view, "#group-landing")
      refute has_element?(view, "#group-resolved")
      refute render(view) =~ "Nothing here."

      # idle and resolved threads sit inside the Earlier fold
      assert has_element?(view, "#threads-earlier summary", "Earlier (1)")
      assert has_element?(view, "#threads-earlier #group-idle #thread-run\\:r-idle")

      assert {:ok, _} = Actions.set_resolved(id, "run:r-failed-#{id}", :resolve, "sidebar")
      await_element(view, "#threads-earlier #group-resolved #thread-run\\:r-failed-#{id}")
      refute has_element?(view, "#group-waiting_on_you")

      # another project's thread is never listed
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
      open_thread(view, id, "run:r-failed-#{id}")

      view
      |> element("#thread-pane button[phx-value-action=resolve]")
      |> render_click()

      await_element(view, "#group-resolved #thread-run\\:r-failed-#{id}")

      assert {:ok, %{resolved: true}} = Threads.get("run:r-failed-#{id}")

      view |> element("#thread-pane button", "Reopen") |> render_click()
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

    # foreman-w0tnj: one row per PR; a non-primary repository's row names its repository.
    test "a second repository's PR is its own row, naming its repository", %{id: id} do
      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "PrReady",
            payload: %{run_id: "r-pr2", repo_id: "b", pr_url: "https://github.com/a/b2/pull/3"}
          }
        ])

      {view, _} = mount_view(id)
      html = view |> element("#tab-pull_requests") |> render_click()

      assert has_element?(view, ~s(#panel-pull_requests a[href="https://github.com/a/b/pull/9"]))
      assert has_element?(view, ~s(#panel-pull_requests a[href="https://github.com/a/b2/pull/3"]))
      assert has_element?(view, "#panel-pull_requests li", "repo b")
      # only the non-primary repository's row names a repository
      assert html |> String.split("· repo ") |> length() == 2
    end

    test "a failing check on a second repository's PR keeps the thread waiting on you after the primary's PR merged (foreman-w0tnj)",
         %{id: id} do
      b_url = "https://github.com/a/b2/pull/3"

      {view, _html} = mount_view(id)
      open_thread(view, id, "run:r-pr2")
      assert has_element?(view, "#group-ready_for_review #thread-run\\:r-pr2")

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "PrReady",
            payload: %{run_id: "r-pr2", repo_id: "b", pr_url: b_url, pr_number: 3}
          },
          %{
            event_type: "PrChecksChanged",
            payload: %{
              run_id: "r-pr2",
              repo_id: "b",
              project_id: id,
              task_id: "t-pr2",
              pr_url: b_url,
              head_sha: "h1",
              pr_status: "open",
              checks_state: "failing",
              failing: [%{name: "e2e-ci"}],
              digest: "d1",
              observation_seq: 1
            }
          },
          %{
            event_type: "PrUpdated",
            payload: %{
              run_id: "r-pr2",
              pr_url: "https://github.com/a/b/pull/9",
              pr_status: "merged",
              head_sha: "h9",
              observed_at: 1
            }
          }
        ])

      html =
        await_until(view, fn _ ->
          has_element?(view, "#group-waiting_on_you #thread-run\\:r-pr2")
        end)

      assert html =~ "CI failing"
      refute has_element?(view, "#group-resolved #thread-run\\:r-pr2")

      # Fix CI is offered for b's PR, the one that is still live
      assert has_element?(
               view,
               ~s|#pr-action-run\\:r-pr2-fix_ci[phx-value-pr-url="#{b_url}"]:not([disabled])|
             )
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
    test "composer text and the dashboard URL token are not written to the server log (foreman-mw5rz)",
         %{id: id} do
      canary = "LOGCANARY-#{System.unique_integer([:positive])}"

      mount_log =
        capture_log([level: :debug], fn -> send(self(), {:mounted, mount_view(id)}) end)

      assert_received {:mounted, {view, _}}
      # Controls: the router dispatch line is emitted (so the refute below can fail) ...
      assert mount_log =~ "Parameters:"
      # ... and the token the page was opened with, a query parameter, is filtered from it.
      refute mount_log =~ @token

      event_log =
        capture_log([level: :debug], fn ->
          view |> form("#composer", %{"text" => canary}) |> render_submit()
        end)

      assert event_log =~ "HANDLE EVENT"
      refute event_log =~ canary
    end

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

    test "the transcript shows message text, never raw ISO timestamps or 'via' source noise", %{
      id: id
    } do
      assert {:ok, _} =
               ForemanServer.CoordinatorAPI.post_message(id, %{text: "hello there", source: "cli"})

      {view, _} = mount_view(id)
      log = view |> element("#conversation-log") |> render()

      assert log =~ "hello there"
      refute log =~ ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z/
      refute log =~ "via system"
      refute log =~ "via cli"
    end

    test "the composer lives inside the conversation card and still sends", %{id: id} do
      {view, _} = mount_view(id)

      assert has_element?(view, "#conversation-pane form#composer")

      assert view |> form("#composer", %{"text" => "ping the coordinator"}) |> render_submit() =~
               "ping the coordinator"
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

      await_until(view, fn _ -> not has_element?(view, "#proposal-#{prop}") end)
      assert %{status: "closed"} = ProjectionStore.task_projection(prop)
      # a declined proposal is not listed any more, and with none startable no list at all
      refute has_element?(view, "#proposal-#{prop}")
      refute has_element?(view, "#proposals")

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
      {view, _} = mount_view(id, thread_url(id, "run:r-failed-#{id}"))

      view
      |> element("#thread-pane button[phx-value-action=resolve]")
      |> render_click()

      await_element(view, "#group-resolved #thread-run\\:r-failed-#{id}")

      # ... someone else reopens it ...
      assert {:ok, _} = Actions.set_resolved(id, "run:r-failed-#{id}", :reopen, "elsewhere")
      assert {:ok, %{resolved: false}} = Threads.get("run:r-failed-#{id}")

      # ... and after a restart a view's counters start from zero again, only its random
      # session nonce is new. Its resolve is a new command and must append a new event; a
      # command id repeating the old session's would be answered "Done" with nothing appended.
      {restarted, _} = mount_view(id, thread_url(id, "run:r-failed-#{id}"))

      restarted
      |> element("#thread-pane button[phx-value-action=resolve]")
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

  describe "thread pane controls" do
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

      render_component(&Components.thread_pane/1,
        card: card,
        log: %ThreadView.Log{blocks: [], dropped_turns: 0, omitted_entries: 0, terminal?: false},
        project_id: "p",
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

    test "shows the project goal when the project has one", %{id: _id} do
      project = "goal-#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               ProjectStore.save(%{
                 project_id: project,
                 path: "/tmp/#{project}",
                 goal: "Ship the workspace shell"
               })

      {_view, html} = mount_view(project)
      assert html =~ "Ship the workspace shell"
      assert html =~ ~s(class="ws-goal)
    end

    test "renders without a goal paragraph when the project has none", %{id: id} do
      {_view, html} = mount_view(id)
      refute html =~ ~s(class="ws-goal)
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

    test "the side panel shell container is present for the read-only panels", %{id: id} do
      {view, _html} = mount_view(id)

      assert has_element?(view, ~s(aside.ws-side > section.ws-panels))
    end
  end

  describe "read-only side panels" do
    test "the knowledge panels render inside the shell with their headings", %{id: id} do
      {view, _html} = mount_view(id)

      for heading <- ["Instructions", "Memory", "Files"] do
        assert has_element?(view, ~s(section.ws-panels section.ws-panel h2), heading)
      end
    end

    test "the Instructions panel shows the project's instructions text" do
      project = "instr-#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               ProjectStore.save(%{
                 project_id: project,
                 path: "/tmp/#{project}",
                 instructions: "Keep it surgical."
               })

      {_view, html} = mount_view(project)
      assert html =~ "Keep it surgical."
    end

    test "long instructions keep their full text in the DOM (clamped, not truncated)" do
      project = "instr-long-#{System.unique_integer([:positive])}"
      long = String.duplicate("line of guidance ", 400) <> "SENTINEL_TAIL"

      assert {:ok, _} =
               ProjectStore.save(%{
                 project_id: project,
                 path: "/tmp/#{project}",
                 instructions: long
               })

      {view, html} = mount_view(project)
      assert html =~ "SENTINEL_TAIL"
      assert has_element?(view, "details.ws-showall > summary", "Show all")
      assert has_element?(view, "details.ws-showall", "SENTINEL_TAIL")
    end

    test "the panels show empty states and threads list their titles", %{id: id} do
      {view, html} = mount_view(id)

      # The test project's path does not exist on disk, so memory and library are empty.
      assert html =~ "No memory yet. Agents save durable facts here."
      assert html =~ "No files yet."
      # Thread titles from the Overview are listed in the sidebar.
      assert has_element?(view, "#thread-list .thread-row-title", "Second PR")
    end
  end

  # A JobsiteStarted seed. The projection stamps `started_at_ms` from the applying caller's
  # clock (`apply_event/3` OVERWRITES any `_projection_event_at_ms` the payload carries), so
  # `seed_jobsite/4` injects that clock instead of seeding the timestamp: it is the only way to
  # give two jobsites distinct, controlled start times and make newest-first ordering
  # deterministic rather than insertion order.
  defp jobsite(jobsite_id, bead_id, project_id),
    do: %{
      event_type: "JobsiteStarted",
      payload: %{
        jobsite_id: jobsite_id,
        repo_path: "/tmp/#{jobsite_id}",
        strategy: "worktree",
        bead_id: bead_id,
        project_id: project_id
      }
    }

  defp seed_jobsite(jobsite_id, bead_id, project_id, at_ms) do
    Process.put(:projection_store_now_ms, fn -> at_ms end)
    :ok = ProjectionStore.apply_events([jobsite(jobsite_id, bead_id, project_id)])
  after
    Process.delete(:projection_store_now_ms)
  end

  # A RunStarted seed carrying a TOP-LEVEL workflow name: the branch of `workflow_name/1` that
  # reads the projection's own field (the dispatcher path leaves it nil; see `dispatched_run/3`).
  defp workflow_run(run_id, project_id, workflow_name),
    do: %{
      event_type: "RunStarted",
      payload: %{run_id: run_id, project_id: project_id, workflow_name: workflow_name}
    }

  # A RunStarted seed in the PRODUCTION dispatch shape: no top-level `workflow_name` (the
  # dispatcher's `run.start` payload has none), the name only on the frozen snapshot.
  defp dispatched_run(run_id, project_id, workflow_name),
    do: %{
      event_type: "RunStarted",
      payload: %{
        run_id: run_id,
        project_id: project_id,
        workflow_snapshot: %{run_id: run_id, workflow_name: workflow_name, phases: []}
      }
    }

  # Byte offset of a substring in the rendered HTML, for deterministic order assertions.
  defp panel_order(html, id), do: substring_index(html, id)
  defp row_order(html, text), do: substring_index(html, text)

  defp substring_index(html, needle) do
    case :binary.match(html, needle) do
      {start, _len} -> start
      :nomatch -> flunk("expected #{inspect(needle)} in rendered nav, but it was absent")
    end
  end

  describe "workspace nav sidebar" do
    test "renders the six nav panels inside the nav landmark", %{id: id} do
      {view, _html} = mount_view(id)

      assert has_element?(view, ~s(nav#workspace-nav[aria-label="Workspace navigation"]))

      for heading <- ["Search", "Projects", "Jobsite", "Workflows", "Artifacts", "Schedules"] do
        assert has_element?(view, "#workspace-nav section.ws-panel h2", heading)
      end
    end

    test "the Jobsite panel lists jobsite runs newest-first after Projects, before Workflows",
         %{id: id} do
      seed_jobsite("js-old", "bead-old", id, 1_000)
      seed_jobsite("js-new", "bead-new", id, 2_000)

      {view, html} = mount_view(id)

      # Count badge reflects the two seeded jobsites (exact text: '2' must not match a '12').
      assert has_element?(
               view,
               ~s(#workspace-nav section[aria-labelledby="nav-jobsite-title"] .ws-count),
               ~r/\A\s*2\s*\z/
             )

      # bead_id primary label + status secondary are shown.
      assert has_element?(
               view,
               ~s(#workspace-nav section[aria-labelledby="nav-jobsite-title"] strong),
               "bead-new"
             )

      assert has_element?(
               view,
               ~s(#workspace-nav section[aria-labelledby="nav-jobsite-title"] .ws-muted),
               "starting"
             )

      # Newest started_at_ms first, and the panel sits between Projects and Workflows.
      assert panel_order(html, "nav-projects-title") <
               panel_order(html, "nav-jobsite-title")

      assert panel_order(html, "nav-jobsite-title") <
               panel_order(html, "nav-workflows-title")

      assert row_order(html, "bead-new") < row_order(html, "bead-old")
    end

    test "the Jobsite panel shows its empty state when there are no jobsite runs", %{id: id} do
      {view, _html} = mount_view(id)

      assert has_element?(
               view,
               ~s(#workspace-nav section[aria-labelledby="nav-jobsite-title"] .ws-muted),
               "No jobsite runs."
             )
    end

    test "the Workflows panel lists runs after Jobsite with workflow name and status",
         %{id: id} do
      :ok = ProjectionStore.apply_events([workflow_run("r-wf", id, "implement-trd")])

      {view, html} = mount_view(id)

      # The workflow name and the unnamed setup runs' "workflow" fallback are the muted label
      # of each row; the primary label is the task title (a task-less run reads its run id).
      assert has_element?(
               view,
               ~s(#workspace-nav section[aria-labelledby="nav-workflows-title"] .ws-nav-workflow),
               "implement-trd · awaiting_worker"
             )

      assert has_element?(
               view,
               ~s(#workspace-nav section[aria-labelledby="nav-workflows-title"] .ws-nav-workflow),
               "workflow · "
             )

      refute has_element?(
               view,
               ~s(#workspace-nav section[aria-labelledby="nav-workflows-title"] strong),
               "implement-trd"
             )

      # Count badge reflects THIS project's runs only: its four setup runs plus this one. The
      # other project's run is not among them, and the exact text keeps '5' from matching '15'.
      assert has_element?(
               view,
               ~s(#workspace-nav section[aria-labelledby="nav-workflows-title"] .ws-count),
               ~r/\A\s*5\s*\z/
             )

      # The run's status shows as the muted secondary label, scoped to the Workflows panel.
      assert has_element?(
               view,
               ~s(#workspace-nav section[aria-labelledby="nav-workflows-title"] .ws-muted),
               "awaiting_worker"
             )

      # Panel order: Workflows after Jobsite, before Artifacts (unchanged siblings follow).
      assert panel_order(html, "nav-jobsite-title") <
               panel_order(html, "nav-workflows-title")

      assert panel_order(html, "nav-workflows-title") <
               panel_order(html, "nav-artifacts-title")
    end

    # Every dispatched run reaches the projection with `workflow_name: nil` and its name on the
    # frozen snapshot, so reading the top-level field alone labelled every real run "workflow".
    test "a dispatched run's row shows the name from its frozen workflow snapshot", %{id: id} do
      :ok = ProjectionStore.apply_events([dispatched_run("r-dispatched", id, "prd")])

      {view, _html} = mount_view(id)

      assert has_element?(
               view,
               ~s(#workspace-nav section[aria-labelledby="nav-workflows-title"] .ws-nav-workflow),
               "prd"
             )

      # The workflow is the muted label, never the row's primary one.
      refute has_element?(
               view,
               ~s(#workspace-nav section[aria-labelledby="nav-workflows-title"] strong),
               "prd"
             )
    end

    test "the Workflows panel shows its empty state when there are no workflow runs", %{id: id} do
      # Clear the setup-seeded runs, then re-seed just the project projection the mount reads:
      # every seeded run belongs to this project, so a clean slate is the way to an empty panel.
      ProjectionStoreReset.reset!()

      :ok =
        ProjectionStore.apply_events([
          %{event_type: "ProjectRegistered", payload: %{project_id: id, path: "/tmp/#{id}"}}
        ])

      {view, _html} = mount_view(id)

      assert has_element?(
               view,
               ~s(#workspace-nav section[aria-labelledby="nav-workflows-title"] .ws-muted),
               "No workflow runs."
             )
    end

    test "another project's run and jobsite stay out of this project's nav panels",
         %{id: id, other: other} do
      seed_jobsite("js-mine", "bead-mine", id, 1_000)
      seed_jobsite("js-theirs", "bead-theirs", other, 2_000)
      :ok = ProjectionStore.apply_events([task("t-mine", id, "Mine task")])

      :ok =
        ProjectionStore.apply_events([
          put_in(workflow_run("r-mine", id, "mine-workflow"), [:payload, :task_id], "t-mine")
        ])

      :ok = ProjectionStore.apply_events([workflow_run("r-theirs", other, "their-workflow")])

      {view, _html} = mount_view(id)

      jobsite_panel = ~s(#workspace-nav section[aria-labelledby="nav-jobsite-title"])
      workflows_panel = ~s(#workspace-nav section[aria-labelledby="nav-workflows-title"])

      # This project's jobsite is listed; the other project's (newer, so it would sort first
      # and survive any row cap) is not, and the badge counts only this project's.
      assert has_element?(view, "#{jobsite_panel} strong", "bead-mine")
      refute has_element?(view, "#{jobsite_panel} strong", "bead-theirs")
      assert has_element?(view, "#{jobsite_panel} .ws-count", ~r/\A\s*1\s*\z/)

      # Same for the Workflows panel: this project's named run, not the other project's.
      assert has_element?(view, "#{workflows_panel} .ws-nav-workflow", "mine-workflow")
      refute has_element?(view, "#{workflows_panel} .ws-nav-workflow", "their-workflow")
      assert has_element?(view, "#{workflows_panel} strong", "Mine task")
      refute has_element?(view, "#{workflows_panel} strong", "mine-workflow")
    end

    test "a run or jobsite event for THIS project refreshes the nav panels", %{id: id} do
      {view, html} = mount_view(id)
      refute html =~ "bead-live"

      seed_jobsite("js-live", "bead-live", id, 3_000)

      html = await_until(view, &(&1 =~ "bead-live"))
      refute html =~ "live-workflow"

      :ok = ProjectionStore.apply_events([workflow_run("r-live", id, "live-workflow")])

      await_until(view, &(&1 =~ "live-workflow"))
    end

    test "the Projects panel lists every project, linking to each and marking the open one",
         %{id: id, other: other} do
      {view, _html} = mount_view(id)

      # Both projects are listed; the open one carries aria-current, the other a navigate link.
      # The display name falls back to the id (the test saves `name:` at the top level, which
      # does not populate the projection's config.name the view reads).
      assert has_element?(view, ~s(#workspace-nav a[aria-current="page"]), id)

      assert has_element?(
               view,
               ~s(#workspace-nav a[href="#{Components.project_path(other, @token)}"]),
               other
             )
    end

    test "the Artifacts panel falls back to the library (empty on a path-less project)", %{id: id} do
      {view, _html} = mount_view(id)

      assert has_element?(view, ~s(#workspace-nav section.ws-panel), "No artifacts yet.")
    end

    test "Search filters already-loaded thread titles and reports no matches otherwise",
         %{id: id} do
      {view, _html} = mount_view(id)

      hit = render_change(view, "ws_search", %{"q" => "Second"})
      assert hit =~ "Second PR"
      assert has_element?(view, ~s(#workspace-nav .ws-nav-results a), "Second PR")

      miss = render_change(view, "ws_search", %{"q" => "zzz-no-such-thing"})
      assert miss =~ "No matches."
    end
  end

  @workflows_panel ~s(#workspace-nav section[aria-labelledby="nav-workflows-title"])
  @jobsite_panel ~s(#workspace-nav section[aria-labelledby="nav-jobsite-title"])

  defp worktree_created(op, project_id, run_id, path, branch, cleanup),
    do: %{
      event_type: "WorktreeCreated",
      payload: %{
        operation_id: op,
        project_id: project_id,
        run_id: run_id,
        phase_id: "ph-#{op}",
        worktree_path: path,
        branch: branch,
        base_ref: "main",
        cleanup: cleanup
      }
    }

  defp worktree_cleaned(op, project_id, run_id, path),
    do: %{
      event_type: "WorktreeCleaned",
      payload: %{
        operation_id: op,
        project_id: project_id,
        run_id: run_id,
        phase_id: "ph-#{op}",
        worktree_path: path
      }
    }

  defp titled_task(task_id, project_id, title, extra),
    do: update_in(task(task_id, project_id, title), [:payload], &Map.merge(&1, extra))

  defp task_run(run_id, task_id, project_id, workflow),
    do: put_in(workflow_run(run_id, project_id, workflow), [:payload, :task_id], task_id)

  # The run ids the Workflows panel lists, in row order.
  defp listed_run_ids(html),
    do: ~r/id="nav-run-([^"]+)"/ |> Regex.scan(html) |> Enum.map(&List.last/1)

  defp nav_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp open_details_count(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#workspace-nav details[open]")
    |> Enum.count()
  end

  defp new_project(prefix) do
    project = "#{prefix}-#{System.unique_integer([:positive])}"
    assert {:ok, _} = ProjectStore.save(%{project_id: project, path: "/tmp/#{project}"})
    project
  end

  describe "workspace nav rows" do
    setup %{id: id} do
      :ok =
        ProjectionStore.apply_events([
          worktree_created("op-pr2", id, "r-pr2", "/wt/pr2", "feat/pr2", "never"),
          worktree_created("op-ready", id, "r-ready", "/wt/ready", "feat/ready", "on_success"),
          worktree_cleaned("op-ready", id, "r-ready", "/wt/ready"),
          worktree_created(
            "op-failed",
            id,
            "r-failed-#{id}",
            "/wt/failed",
            "feat/failed",
            "on_success"
          ),
          titled_task("t-fix-a", id, "Fix A", %{trd_path: "docs/TRD/fix-a.md"}),
          task("t-fix-b", id, "Fix B"),
          task_run("r-fix-a", "t-fix-a", id, "fix"),
          task_run("r-fix-b", "t-fix-b", id, "fix")
        ])

      :ok
    end

    test "two runs of one workflow for different tasks get different primary labels",
         %{id: id} do
      {view, _html} = mount_view(id)

      assert has_element?(view, "#nav-run-r-fix-a > a strong", "Fix A")
      assert has_element?(view, "#nav-run-r-fix-b > a strong", "Fix B")
      refute has_element?(view, "#nav-run-r-fix-a > a strong", "fix")

      # The workflow, status and age are the muted line beneath, not the label.
      for run_id <- ["r-fix-a", "r-fix-b"] do
        assert has_element?(
                 view,
                 "#nav-run-#{run_id} .ws-muted.ws-nav-workflow",
                 ~r/\Afix · awaiting_worker · (now|\d+m)\z/
               )
      end
    end

    test "the title links to the run dashboard, with the token only when the page has one",
         %{id: id} do
      {view, _html} = mount_view(id)

      assert has_element?(
               view,
               ~s(#nav-run-r-fix-a > a[href="/dashboard/runs?run_id=r-fix-a&token=#{@token}"] strong),
               "Fix A"
             )

      conn = put_req_header(build_conn(), "authorization", "Bearer #{@token}")
      {:ok, bare, _html} = live(conn, "/dashboard/projects/#{id}")

      assert has_element?(
               bare,
               ~s(#nav-run-r-fix-a > a[href="/dashboard/runs?run_id=r-fix-a"] strong),
               "Fix A"
             )

      refute has_element?(bare, ~s(#workspace-nav a[href*="token"]))
    end

    test "a run's age reads now, minutes, hours and days from its start", %{id: id} do
      now = System.os_time(:millisecond)

      for {run_id, age_ms} <- [
            {"r-age-5m", 5 * 60_000 + 5_000},
            {"r-age-3h", 3 * 3_600_000 + 5_000},
            {"r-age-2d", 2 * 86_400_000 + 5_000}
          ] do
        Process.put(:projection_store_now_ms, fn -> now - age_ms end)
        :ok = ProjectionStore.apply_events([workflow_run(run_id, id, "aged")])
      end

      Process.delete(:projection_store_now_ms)
      :ok = ProjectionStore.apply_events([workflow_run("r-age-new", id, "aged")])

      {view, _html} = mount_view(id)

      for {run_id, age} <- [
            {"r-age-5m", "5m"},
            {"r-age-3h", "3h"},
            {"r-age-2d", "2d"},
            {"r-age-new", "now"}
          ] do
        assert has_element?(
                 view,
                 "#nav-run-#{run_id} .ws-nav-workflow",
                 "aged · awaiting_worker · #{age}"
               )
      end
    end

    test "details carry the branch, base, worktree state, PR and TRD path as text", %{id: id} do
      {view, _html} = mount_view(id)

      assert has_element?(view, "#nav-run-r-pr2 details .ws-nav-branch code", "feat/pr2")
      assert has_element?(view, "#nav-run-r-pr2 details .ws-nav-branch code", "main")
      assert has_element?(view, "#nav-run-r-pr2 details .ws-nav-worktree code", "/wt/pr2")

      assert has_element?(
               view,
               ~s(#nav-run-r-pr2 details .ws-nav-pr a[href="https://github.com/a/b/pull/9"][target="_blank"][rel="noopener noreferrer"]),
               "Pull request"
             )

      assert has_element?(view, "#nav-run-r-fix-a details .ws-nav-trd code", "docs/TRD/fix-a.md")
      assert has_element?(view, "#nav-run-r-fix-a details .ws-nav-trd", "from the task")
      refute has_element?(view, "#nav-run-r-fix-b .ws-nav-trd")
      refute has_element?(view, "#workspace-nav .ws-nav-trd a")
    end

    test "the worktree line says whether the projection kept it, still has it, removed it or has none",
         %{id: id} do
      {view, _html} = mount_view(id)

      assert has_element?(view, "#nav-run-r-pr2 .ws-nav-worktree", "kept, as recorded")
      assert has_element?(view, "#nav-run-r-ready .ws-nav-worktree", "removed, as recorded")

      assert has_element?(
               view,
               "#nav-run-r-failed-#{id} .ws-nav-worktree",
               "active, as recorded"
             )

      assert has_element?(
               view,
               "#nav-run-r-work .ws-nav-worktree",
               "no worktree recorded for this run"
             )

      assert has_element?(view, "#nav-run-r-work .ws-nav-branch", "no branch recorded")
      refute has_element?(view, "#nav-run-r-work .ws-nav-worktree code")
    end

    test "a hostile title is escaped and a javascript: PR URL emits no link", %{id: id} do
      {view, html} = mount_view(id)

      assert has_element?(view, "#nav-run-r-ready > a strong", @xss)
      refute html =~ "<script>alert"
      refute has_element?(view, "#nav-run-r-ready .ws-nav-pr")
      refute has_element?(view, ~s(#workspace-nav a[href^="javascript"]))
    end

    test "no path is linked, the token never rides an external link, and rows carry no actions",
         %{id: id} do
      {view, _html} = mount_view(id)

      assert has_element?(view, ~s(#workspace-nav a[href^="https://github.com"]))
      assert has_element?(view, "#workspace-nav code", "/wt/pr2")
      refute has_element?(view, "#workspace-nav a code")
      refute has_element?(view, "#workspace-nav a", "/wt/")
      refute has_element?(view, ~s(#workspace-nav a[href^="http"][href*="token"]))
      refute has_element?(view, "#workspace-nav .ws-nav-run button")
      refute has_element?(view, "#workspace-nav .ws-nav-run form")
      refute has_element?(view, "#workspace-nav .ws-nav-run", ~r/merge|approve/i)
    end

    test "every details starts closed", %{id: id} do
      {view, _html} = mount_view(id)

      assert has_element?(view, "#workspace-nav details")
      assert open_details_count(view) == 0
    end

    test "jobsite rows show the task title, bead and status, with branch and path in details",
         %{id: id} do
      :ok =
        ProjectionStore.apply_events([
          titled_task("t-js", id, "Jobsite task", %{external_id: "bead-t"})
        ])

      seed_jobsite("js-titled", "bead-t", id, 5_000)

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "JobsiteWorktreeProvisioned",
            payload: %{jobsite_id: "js-titled", path: "/wt/js", branch: "feat/js"}
          }
        ])

      seed_jobsite("js-bare", "bead-bare", id, 4_000)

      {view, _html} = mount_view(id)

      assert has_element?(view, "#nav-jobsite-js-titled > strong", "Jobsite task")
      refute has_element?(view, "#nav-jobsite-js-titled > strong", "bead-t")
      assert has_element?(view, "#nav-jobsite-js-titled .ws-nav-workflow", "bead-t · running")
      assert has_element?(view, "#nav-jobsite-js-titled details .ws-nav-branch code", "feat/js")
      assert has_element?(view, "#nav-jobsite-js-titled details .ws-nav-worktree code", "/wt/js")

      # A task-less jobsite still reads as its bead, and says what it has not recorded.
      assert has_element?(view, "#nav-jobsite-js-bare > strong", "bead-bare")
      assert has_element?(view, "#nav-jobsite-js-bare .ws-nav-workflow", "bead-bare · starting")
      assert has_element?(view, "#nav-jobsite-js-bare .ws-nav-branch", "no branch recorded")
      assert has_element?(view, "#nav-jobsite-js-bare .ws-nav-worktree", "no worktree recorded")
      assert open_details_count(view) == 0
      assert has_element?(view, "#{@jobsite_panel} .ws-count", ~r/\A\s*2\s*\z/)
    end

    test "clicking Details opens that row only, a refresh keeps it open, an unlisted id changes nothing",
         %{id: id} do
      {view, _html} = mount_view(id)

      view |> element("#nav-run-r-fix-a summary") |> render_click()
      assert has_element?(view, "#nav-run-r-fix-a details[open]")
      refute has_element?(view, "#nav-run-r-fix-b details[open]")
      assert open_details_count(view) == 1
      assert nav_assigns(view).nav_open == MapSet.new(["r-fix-a"])

      :ok = ProjectionStore.apply_events([workflow_run("r-after", id, "after")])
      await_element(view, "#nav-run-r-after")
      assert has_element?(view, "#nav-run-r-fix-a details[open]")
      assert open_details_count(view) == 1

      render_click(view, "nav_run_toggle", %{"run-id" => "no-such-run"})
      assert nav_assigns(view).nav_open == MapSet.new(["r-fix-a"])
      assert open_details_count(view) == 1

      view |> element("#nav-run-r-fix-a summary") |> render_click()
      assert open_details_count(view) == 0
      assert nav_assigns(view).nav_open == MapSet.new()
    end
  end

  describe "workspace nav refresh cost" do
    defp seed_bulk_runs(project, count),
      do:
        ProjectionStore.apply_events(
          for n <- 1..count,
              do: %{
                event_type: "RunStarted",
                payload: %{run_id: "bulk-#{n}", project_id: project}
              }
        )

    # Every GenServer call the ProjectionStore process receives while `fun` runs, tallied by
    # request tag (`:list_runs`, `:worktrees_for_runs`, ...).
    defp tally_store_calls(fun) do
      store = Process.whereis(ProjectionStore)
      :erlang.trace(store, true, [:receive])

      try do
        fun.()
        ref = :erlang.trace_delivered(store)
        assert_receive {:trace_delivered, ^store, ^ref}
      after
        :erlang.trace(store, false, [:receive])
      end

      drain_store_calls(store, [])
    end

    defp drain_store_calls(store, acc) do
      receive do
        {:trace, ^store, :receive, {:"$gen_call", _from, request}} ->
          tag = if is_tuple(request), do: elem(request, 0), else: request
          drain_store_calls(store, [tag | acc])

        {:trace, ^store, :receive, _other} ->
          drain_store_calls(store, acc)
      after
        0 -> Enum.frequencies(acc)
      end
    end

    @tag :tmp_dir
    test "100 runs refresh with a constant number of store reads and no git", %{tmp_dir: tmp} do
      # A `git` that only records that it ran: `ChangeEvidence` shells out to the real one with
      # no injectable runner, so a PATH shim is the spy.
      bin = Path.join(tmp, "bin")
      log = Path.join(tmp, "git.log")
      File.mkdir_p!(bin)
      File.write!(log, "")
      File.write!(Path.join(bin, "git"), ~s(#!/bin/sh\necho "$@" >> "#{log}"\n))
      File.chmod!(Path.join(bin, "git"), 0o755)
      path = System.get_env("PATH")
      System.put_env("PATH", bin <> ":" <> path)
      on_exit(fn -> System.put_env("PATH", path) end)

      project = new_project("cost")
      :ok = seed_bulk_runs(project, 100)

      {view, html} = mount_view(project)
      assert length(listed_run_ids(html)) == 100
      assert has_element?(view, "#{@workflows_panel} .ws-count", ~r/\A\s*100\+\s*\z/)
      assert has_element?(view, "#workspace-nav details")
      assert open_details_count(view) == 0

      tally =
        tally_store_calls(fn ->
          seed_jobsite("js-cost", "bead-cost", project, 9_000)
          await_until(view, &(&1 =~ "bead-cost"))
        end)

      # One read of each list the nav owns for the whole panel, however many runs: no per-run
      # lookup. (`pr_states_for_project` is also read by the Overview, so it is counted in
      # `NavRunsTest`, where only the nav's own call is traced.)
      assert %{list_runs: 1, list_jobsites: 1, list_tasks: 1, worktrees_for_runs: 1} = tally

      for per_run <- [:phases_for_run, :run_repositories, :worktrees_for_run, :task_projection] do
        refute Map.has_key?(tally, per_run), "refresh issued #{per_run}"
      end

      assert File.read!(log) == ""

      # The spy works: a git started from this VM is recorded.
      {_out, 0} = System.cmd("git", ["spy-control"])
      assert File.read!(log) == "spy-control\n"
    end

    test "a run that leaves the list drops its open and document state", %{} do
      project = new_project("prune")
      :ok = seed_bulk_runs(project, 100)

      {view, html} = mount_view(project)
      [first | _] = ids = listed_run_ids(html)
      last = List.last(ids)

      view |> element("#nav-run-#{last} summary") |> render_click()
      view |> element("#nav-run-#{first} summary") |> render_click()
      assert nav_assigns(view).nav_open == MapSet.new([first, last])

      :sys.replace_state(view.pid, fn state ->
        docs = %{first => :docs, last => :docs, "never-listed" => :docs}

        %{
          state
          | socket: %{state.socket | assigns: Map.put(state.socket.assigns, :nav_docs, docs)}
        }
      end)

      :ok = ProjectionStore.apply_events([workflow_run("bulk-new", project, "newest")])
      html = await_until(view, &(&1 =~ ~s(id="nav-run-bulk-new")))

      refute last in listed_run_ids(html)
      assert first in listed_run_ids(html)
      assert nav_assigns(view).nav_open == MapSet.new([first])
      assert nav_assigns(view).nav_docs == %{first => :docs}
    end
  end

  describe "workspace nav conversation links" do
    test "every one of 30 resolved runs' Conversation link opens its thread pane", %{} do
      project = new_project("conv")

      events =
        for n <- 1..30 do
          [
            task("t-c#{n}", project, "Resolved task #{n}"),
            task_run("r-c#{n}", "t-c#{n}", project, "fix"),
            %{event_type: "RunCompleted", payload: %{run_id: "r-c#{n}", project_id: project}}
          ]
        end

      :ok = ProjectionStore.apply_events(List.flatten(events))

      for n <- 1..30,
          do: assert({:ok, _} = Actions.set_resolved(project, "run:r-c#{n}", :resolve, "i-#{n}"))

      {view, html} = mount_view(project)
      ids = listed_run_ids(html)
      assert length(ids) == 30

      # The sidebar's Overview window holds at most 20 resolved cards, so some of these
      # threads exist only for the Conversation link.
      assert Enum.any?(ids, &(not has_element?(view, "#thread-list #thread-run\\:#{&1}")))

      for run_id <- ids do
        href = Components.thread_path(project, "run:#{run_id}", @token)

        assert has_element?(
                 view,
                 ~s(#nav-run-#{run_id} .ws-nav-conversation a[href="#{href}"]),
                 "Conversation"
               )

        view |> element("#nav-run-#{run_id} .ws-nav-conversation a") |> render_click()
        assert_patch(view, href)
        assert has_element?(view, "#thread-pane")
        refute has_element?(view, "#thread-not-found-title")
      end
    end

    test "a jobsite row links to its jobsite thread, carrying the token", %{id: id} do
      seed_jobsite("js-conv", "bead-conv", id, 7_000)
      {view, _html} = mount_view(id)

      href = Components.thread_path(id, "jobsite:js-conv", @token)
      assert href =~ "token=#{@token}"

      assert has_element?(
               view,
               ~s(#nav-jobsite-js-conv .ws-nav-conversation a[href="#{href}"]),
               "Conversation"
             )

      view |> element("#nav-jobsite-js-conv .ws-nav-conversation a") |> render_click()
      assert_patch(view, href)
      assert has_element?(view, "#thread-pane")
      refute has_element?(view, "#thread-not-found-title")
    end

    test "an older run of a task links to its task's thread pane, not a dead end", %{} do
      project = new_project("conv-old")

      :ok =
        ProjectionStore.apply_events([
          task("t-two", project, "Two runs"),
          task_run("r-a-old", "t-two", project, "fix")
        ])

      :ok = ProjectionStore.apply_events([task_run("r-b-new", "t-two", project, "fix")])

      {view, _html} = mount_view(project)

      for run_id <- ["r-b-new", "r-a-old"] do
        href = Components.thread_path(project, "run:#{run_id}", @token)

        assert has_element?(
                 view,
                 ~s(#nav-run-#{run_id} .ws-nav-conversation a[href="#{href}"]),
                 "Conversation"
               )

        view |> element("#nav-run-#{run_id} .ws-nav-conversation a") |> render_click()
        assert_patch(view, href)
        assert has_element?(view, "#thread-pane")
        refute has_element?(view, "#thread-not-found-title")
      end
    end

    test "a jobsite whose bead's task has a run links to that run's thread pane", %{} do
      project = new_project("conv-owned")

      :ok =
        ProjectionStore.apply_events([
          titled_task("t-owned", project, "Owned bead", %{external_id: "bead-owned"}),
          task_run("r-owned", "t-owned", project, "fix")
        ])

      seed_jobsite("js-owned", "bead-owned", project, 7_000)
      {view, _html} = mount_view(project)

      href = Components.thread_path(project, "jobsite:js-owned", @token)

      assert has_element?(
               view,
               ~s(#nav-jobsite-js-owned .ws-nav-conversation a[href="#{href}"]),
               "Conversation"
             )

      view |> element("#nav-jobsite-js-owned .ws-nav-conversation a") |> render_click()
      assert_patch(view, href)
      assert has_element?(view, "#thread-pane")
      refute has_element?(view, "#thread-not-found-title")
    end
  end

  describe "workspace nav documents" do
    # A git repo at `dir` with a README base commit and one commit adding `files`; returns the
    # base commit sha (the run's `base_ref`).
    defp git_repo(dir, files) do
      File.mkdir_p!(dir)
      git = fn args -> {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true) end
      ident = ["-c", "user.name=Test", "-c", "user.email=test@example.com"]

      put = fn name, content ->
        File.mkdir_p!(Path.dirname(Path.join(dir, name)))
        File.write!(Path.join(dir, name), content)
      end

      git.(["init"])
      put.("README.md", "base\n")
      git.(["add", "."])
      git.(ident ++ ["commit", "-m", "base"])
      {base, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)

      for {name, content} <- files, do: put.(name, content)
      git.(["add", "-A"])
      git.(ident ++ ["commit", "-m", "change"])
      String.trim(base)
    end

    defp doc_worktree(project, run_id, dir, base),
      do: %{
        event_type: "WorktreeCreated",
        payload: %{
          operation_id: "wt-#{run_id}",
          project_id: project,
          run_id: run_id,
          phase_id: "ph-#{run_id}",
          worktree_path: dir,
          base_ref: base,
          branch: "foreman/#{run_id}"
        }
      }

    # A `git` first on PATH that logs the directory it runs in (one line per call), optionally
    # runs `pre` (a shell snippet, e.g. a sleep) and then hands over to the real git. The log is
    # the spy: every discovery for a run's worktree leaves its directory name in it.
    defp install_git_shim(tmp, pre \\ "") do
      real = System.find_executable("git")
      bin = Path.join(tmp, "shim")
      log = Path.join(tmp, "git.log")
      File.mkdir_p!(bin)
      File.write!(log, "")

      File.write!(Path.join(bin, "git"), """
      #!/bin/sh
      echo "${PWD##*/}" >> '#{log}'
      #{pre}
      exec '#{real}' "$@"
      """)

      File.chmod!(Path.join(bin, "git"), 0o755)
      previous = System.get_env("PATH")
      System.put_env("PATH", bin <> ":" <> previous)
      on_exit(fn -> System.put_env("PATH", previous) end)
      log
    end

    defp git_dirs(log), do: log |> File.read!() |> String.split("\n", trim: true)

    defp open_row(view, run_id),
      do: view |> element("#nav-run-#{run_id} summary") |> render_click()

    # Polls the held state until the row's discovery has left `:loading` (bounded, no refresh
    # needed: the result arrives as an async message).
    defp await_docs(view, run_id, tries \\ 250) do
      case nav_assigns(view).nav_docs[run_id] do
        :loading when tries > 0 ->
          Process.sleep(20)
          await_docs(view, run_id, tries - 1)

        other ->
          other
      end
    end

    @tag :tmp_dir
    test "a prd run lists its PRD then TRD with diff links, and the link shows the diff",
         %{tmp_dir: tmp} do
      repo = Path.join(tmp, "repo")

      base =
        git_repo(repo, %{
          "docs/PRD/PRD-a.md" => "prd words\n",
          "docs/TRD/TRD-a.md" => "trd words unique-marker\n",
          "README.md" => "changed\n"
        })

      project = new_project("docs-prd")

      :ok =
        ProjectionStore.apply_events([
          workflow_run("r-prd", project, "prd"),
          %{
            event_type: "PhaseStarted",
            payload: %{
              phase_id: "r-prd-phase-1",
              run_id: "r-prd",
              index: 1,
              name: "review",
              attempt: 1,
              artifact_template: "REVIEW_REPORT.md"
            }
          },
          doc_worktree(project, "r-prd", repo, base)
        ])

      {view, _html} = mount_view(project)
      refute has_element?(view, "#nav-run-r-prd .ws-nav-docs")

      loading = open_row(view, "r-prd")
      assert loading =~ "Looking for documents"
      assert has_element?(view, ~s(#nav-run-r-prd .ws-nav-docs[aria-live="polite"]))

      html = render_async(view)
      prd = Components.run_detail_path("r-prd", @token, tab: "changes", file: "docs/PRD/PRD-a.md")
      trd = Components.run_detail_path("r-prd", @token, tab: "changes", file: "docs/TRD/TRD-a.md")

      assert prd ==
               "/dashboard/runs?run_id=r-prd&tab=changes&file=docs%2FPRD%2FPRD-a.md&token=#{@token}"

      assert has_element?(
               view,
               ~s(#nav-run-r-prd .ws-nav-docs a[href="#{prd}"]),
               "docs/PRD/PRD-a.md"
             )

      assert has_element?(
               view,
               ~s(#nav-run-r-prd .ws-nav-docs a[href="#{trd}"]),
               "docs/TRD/TRD-a.md"
             )

      refute html =~ "Looking for documents"
      refute has_element?(view, "#nav-run-r-prd .ws-nav-docs", "unavailable")

      {prd_at, trd_at} =
        {row_order(html, "docs/PRD/PRD-a.md"), row_order(html, "docs/TRD/TRD-a.md")}

      assert prd_at < trd_at

      # A phase's artifact is never presented as a document.
      refute html =~ "REVIEW_REPORT"

      # The link lands on the run dashboard showing that file's diff (nav -> run -> diff).
      {:ok, dash, _html} = live(build_conn(), trd)
      assert render_async(dash) =~ "trd words unique-marker"
    end

    @tag :tmp_dir
    test "no git on mount or refresh; one click discovers one run once, a refresh reuses it, reopening redoes it",
         %{tmp_dir: tmp} do
      log = install_git_shim(tmp)
      project = new_project("docs-cost")

      events =
        for n <- 1..100 do
          dir = Path.join(tmp, "wt-bulk-#{n}")
          File.mkdir_p!(dir)

          [
            %{event_type: "RunStarted", payload: %{run_id: "bulk-#{n}", project_id: project}},
            doc_worktree(project, "bulk-#{n}", dir, "main")
          ]
        end

      :ok = ProjectionStore.apply_events(List.flatten(events))

      {view, html} = mount_view(project)
      assert length(listed_run_ids(html)) == 100

      :ok = ProjectionStore.apply_events([workflow_run("bulk-extra", project, "x")])
      await_element(view, "#nav-run-bulk-extra")
      assert git_dirs(log) == []

      first = view |> render() |> listed_run_ids() |> Enum.find(&(&1 =~ ~r/\Abulk-\d+\z/))
      open_row(view, first)
      render_async(view)
      dirs = git_dirs(log)
      assert dirs != []
      assert Enum.uniq(dirs) == ["wt-" <> first]
      per_discovery = length(dirs)
      found = nav_assigns(view).nav_docs[first]
      assert found not in [nil, :loading]
      assert map_size(nav_assigns(view).nav_docs) == 1

      # Cache hit: a refresh after the result reads nothing again.
      :ok = ProjectionStore.apply_events([workflow_run("bulk-extra-2", project, "x")])
      await_element(view, "#nav-run-bulk-extra-2")
      render_async(view)
      assert length(git_dirs(log)) == per_discovery
      assert nav_assigns(view).nav_open == MapSet.new([first])
      assert nav_assigns(view).nav_docs == %{first => found}

      # Closing drops the row's documents; reopening discovers once more.
      open_row(view, first)
      assert nav_assigns(view).nav_docs == %{}
      open_row(view, first)
      render_async(view)
      assert length(git_dirs(log)) == 2 * per_discovery
    end

    test "a toggle for an unlisted id changes nothing and starts no discovery", %{} do
      project = new_project("docs-unlisted")
      :ok = ProjectionStore.apply_events([workflow_run("r-only", project, "x")])
      {view, _html} = mount_view(project)

      render_click(view, "nav_run_toggle", %{"run-id" => "not-listed"})
      render_async(view)

      assert nav_assigns(view).nav_open == MapSet.new()
      assert nav_assigns(view).nav_docs == %{}
    end

    @tag :tmp_dir
    @tag timeout: 15_000
    test "a hung git shows the row as timed out while the page still answers other events",
         %{tmp_dir: tmp} do
      install_git_shim(tmp, "sleep 6")
      project = new_project("docs-hang")
      dir = Path.join(tmp, "wt-hang")
      File.mkdir_p!(dir)

      :ok =
        ProjectionStore.apply_events([
          workflow_run("r-hang", project, "prd"),
          doc_worktree(project, "r-hang", dir, "main")
        ])

      {view, _html} = mount_view(project)
      assert open_row(view, "r-hang") =~ "Looking for documents"

      # The discovery is running (3 s budget); the LiveView is free to handle another event.
      assert render_change(view, "ws_search", %{"q" => "still-answering"}) =~ "still-answering"
      assert nav_assigns(view).nav_docs["r-hang"] == :loading

      render_async(view, 8_000)
      assert nav_assigns(view).nav_docs["r-hang"] == {:unavailable, :evidence_timeout}

      assert has_element?(
               view,
               "#nav-run-r-hang .ws-nav-docs",
               "Documents unavailable: timed out"
             )

      assert has_element?(view, "#nav-run-r-hang .ws-nav-branch")
    end

    @tag :tmp_dir
    @tag timeout: 15_000
    test "two open rows are independent: one finishing leaves the other state and content",
         %{tmp_dir: tmp} do
      install_git_shim(tmp, "case \"$PWD\" in *wt-slow*) sleep 6;; esac")
      project = new_project("docs-two")
      slow = Path.join(tmp, "wt-slow")
      File.mkdir_p!(slow)
      fast = Path.join(tmp, "wt-fast")
      base = git_repo(fast, %{"docs/TRD/TRD-fast.md" => "fast\n"})

      :ok =
        ProjectionStore.apply_events([
          workflow_run("r-slow", project, "prd"),
          doc_worktree(project, "r-slow", slow, "main"),
          workflow_run("r-fast", project, "prd"),
          doc_worktree(project, "r-fast", fast, base)
        ])

      {view, _html} = mount_view(project)
      open_row(view, "r-slow")
      open_row(view, "r-fast")

      assert {:ok, [%{kind: :trd, path: "docs/TRD/TRD-fast.md"}]} = await_docs(view, "r-fast")
      assert nav_assigns(view).nav_docs["r-slow"] == :loading
      assert open_details_count(view) == 2
      assert has_element?(view, "#nav-run-r-slow .ws-nav-docs", "Looking for documents")
      assert has_element?(view, "#nav-run-r-fast .ws-nav-docs a", "docs/TRD/TRD-fast.md")

      fast_before = view |> element("#nav-run-r-fast") |> render()
      render_async(view, 8_000)

      assert nav_assigns(view).nav_docs["r-slow"] == {:unavailable, :evidence_timeout}
      assert open_details_count(view) == 2
      assert view |> element("#nav-run-r-fast") |> render() == fast_before
    end

    # The `:exit` outcome cannot be produced from outside: the LiveView links its async task, so
    # killing the task takes the LiveView with it; only a catch inside the task reports `:exit`.
    # The callback is therefore driven directly with a real socket.
    defp nav_socket(open, docs),
      do: %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, nav_open: MapSet.new(open), nav_docs: docs}
      }

    test "an exited discovery is stored as a failed lookup and logged; a closed row ignores any result" do
      alias ForemanServerWeb.ProjectWorkspaceLive
      socket = nav_socket(["r-open"], %{"r-open" => :loading, "r-other" => {:ok, []}})

      log =
        capture_log(fn ->
          assert {:noreply, crashed} =
                   ProjectWorkspaceLive.handle_async(
                     {:nav_docs, "r-open"},
                     {:exit, :boom},
                     socket
                   )

          assert crashed.assigns.nav_docs ==
                   %{"r-open" => {:unavailable, :crashed}, "r-other" => {:ok, []}}
        end)

      assert log =~ "document discovery for r-open crashed"

      docs = [%{kind: :trd, path: "docs/TRD/TRD-a.md"}]

      assert {:noreply, stored} =
               ProjectWorkspaceLive.handle_async(
                 {:nav_docs, "r-open"},
                 {:ok, {:ok, docs}},
                 socket
               )

      assert stored.assigns.nav_docs["r-open"] == {:ok, docs}
      assert stored.assigns.nav_docs["r-other"] == {:ok, []}

      # A result for a row that was closed meanwhile is dropped, whatever it says.
      closed = nav_socket([], %{})

      for outcome <- [
            {:ok, {:ok, docs}},
            {:ok, {:unavailable, :evidence_timeout}},
            {:exit, :boom}
          ] do
        capture_log(fn ->
          assert {:noreply, ^closed} =
                   ProjectWorkspaceLive.handle_async({:nav_docs, "r-open"}, outcome, closed)
        end)
      end
    end

    @tag :tmp_dir
    test "each unavailable reason reads differently and the other rows still render",
         %{tmp_dir: tmp} do
      repo = Path.join(tmp, "repo")
      base = git_repo(repo, %{"README.md" => "changed\n"})
      project = new_project("docs-reasons")
      nogit = Path.join(tmp, "nogit")
      File.mkdir_p!(nogit)

      :ok =
        ProjectionStore.apply_events([
          workflow_run("r-nowt", project, "prd"),
          workflow_run("r-nobase", project, "prd"),
          doc_worktree(project, "r-nobase", repo, "no-such-ref"),
          workflow_run("r-nogit", project, "prd"),
          doc_worktree(project, "r-nogit", repo, base)
        ])

      {view, _html} = mount_view(project)

      open_row(view, "r-nowt")
      open_row(view, "r-nobase")
      render_async(view)

      assert has_element?(
               view,
               "#nav-run-r-nowt .ws-nav-docs",
               "Documents unavailable: worktree directory missing"
             )

      assert has_element?(
               view,
               "#nav-run-r-nobase .ws-nav-docs",
               "Documents unavailable: base ref unavailable"
             )

      previous = System.get_env("PATH")
      System.put_env("PATH", nogit)
      on_exit(fn -> System.put_env("PATH", previous) end)
      open_row(view, "r-nogit")
      render_async(view)
      System.put_env("PATH", previous)

      assert has_element?(
               view,
               "#nav-run-r-nogit .ws-nav-docs",
               "Documents unavailable: git unavailable"
             )

      for id <- ["r-nowt", "r-nobase", "r-nogit"] do
        assert has_element?(view, "#nav-run-#{id} .ws-nav-branch")
        assert has_element?(view, "#nav-run-#{id} .ws-nav-worktree")
        assert has_element?(view, "#nav-run-#{id} .ws-nav-conversation a")
      end

      # The remaining reasons are not reachable from a listed row with a healthy store; the
      # render still has to give each its own words.
      :sys.replace_state(view.pid, fn state ->
        docs = %{
          "r-nowt" => {:unavailable, :evidence_timeout},
          "r-nobase" => {:unavailable, :run_not_found},
          "r-nogit" => {:unavailable, :crashed}
        }

        assigns =
          state.socket.assigns
          |> Map.put(:nav_docs, docs)
          |> Map.update!(:__changed__, &Map.put(&1, :nav_docs, true))

        %{state | socket: %{state.socket | assigns: assigns}}
      end)

      # Any event renders the swapped assign.
      render_change(view, "ws_search", %{"q" => "x"})

      assert has_element?(
               view,
               "#nav-run-r-nowt .ws-nav-docs",
               "Documents unavailable: timed out"
             )

      assert has_element?(
               view,
               "#nav-run-r-nobase .ws-nav-docs",
               "Documents unavailable: run not found"
             )

      assert has_element?(
               view,
               "#nav-run-r-nogit .ws-nav-docs",
               "Documents unavailable: lookup failed"
             )
    end

    @tag :tmp_dir
    test "a fix run that changed no planning document shows no Documents section",
         %{tmp_dir: tmp} do
      repo = Path.join(tmp, "repo")
      base = git_repo(repo, %{"lib/thing.ex" => "x\n"})
      project = new_project("docs-fix")

      :ok =
        ProjectionStore.apply_events([
          workflow_run("r-fix", project, "fix"),
          doc_worktree(project, "r-fix", repo, base)
        ])

      {view, _html} = mount_view(project)
      open_row(view, "r-fix")
      render_async(view)

      assert nav_assigns(view).nav_docs["r-fix"] == {:ok, []}
      refute has_element?(view, "#nav-run-r-fix .ws-nav-docs")
      assert has_element?(view, "#nav-run-r-fix .ws-nav-branch", "foreman/r-fix")
    end

    @tag :tmp_dir
    test "a task TRD path shows at once without git and links only when the branch changed it",
         %{tmp_dir: tmp} do
      log = install_git_shim(tmp)
      changed = Path.join(tmp, "wt-changed")
      untouched = Path.join(tmp, "wt-untouched")
      base_a = git_repo(changed, %{"specs/custom-trd.md" => "custom\n"})
      base_b = git_repo(untouched, %{"lib/x.ex" => "x\n"})
      File.write!(log, "")
      project = new_project("docs-task-trd")

      :ok =
        ProjectionStore.apply_events([
          titled_task("t-a", project, "Impl A", %{trd_path: "specs/custom-trd.md"}),
          task_run("r-a", "t-a", project, "implement-trd"),
          doc_worktree(project, "r-a", changed, base_a),
          titled_task("t-b", project, "Impl B", %{trd_path: "specs/custom-trd.md"}),
          task_run("r-b", "t-b", project, "implement-trd"),
          doc_worktree(project, "r-b", untouched, base_b)
        ])

      {view, _html} = mount_view(project)

      for id <- ["r-a", "r-b"] do
        assert has_element?(view, "#nav-run-#{id} .ws-nav-trd code", "specs/custom-trd.md")
        refute has_element?(view, "#nav-run-#{id} .ws-nav-trd a")
      end

      assert git_dirs(log) == []

      open_row(view, "r-a")
      open_row(view, "r-b")
      render_async(view)

      href =
        Components.run_detail_path("r-a", @token, tab: "changes", file: "specs/custom-trd.md")

      assert has_element?(
               view,
               ~s(#nav-run-r-a .ws-nav-trd a[href="#{href}"]),
               "specs/custom-trd.md"
             )

      assert has_element?(view, "#nav-run-r-b .ws-nav-trd code", "specs/custom-trd.md")
      refute has_element?(view, "#nav-run-r-b .ws-nav-trd a")
    end
  end
end
