defmodule ForemanServerWeb.ProjectWorkspaceThreadsLiveTest do
  # The thread sidebar and the open thread's pane (`/dashboard/projects/:id/threads/:thread_id`),
  # through the real router, LiveView, `Threads.Transcript` and projections. The controls the pane
  # carries (Pause, Stop, Resolve, PR actions, approvals) are covered by the files that own them.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog
  import Plug.Conn, only: [put_req_header: 3]

  alias EventStore.EventData
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.Overview
  alias ForemanServer.Overview.{Group, ThreadCard}
  alias ForemanServer.TelemetryTest.Handler

  alias ForemanServer.TestSupport.{
    Eventually,
    PrWatchSupport,
    ProjectionStoreReset,
    SecretStoreDir
  }

  alias ForemanServer.{CommandGateway, ProjectionStore, ProjectStore, Threads}
  alias ForemanServer.Threads.Transcript
  alias ForemanServerWeb.Workspace.{Actions, Components}

  @endpoint ForemanServerWeb.Endpoint
  @token "project-workspace-threads-token"
  @refreshes [
    [:foreman_server, :workspace, :refresh],
    [:foreman_server, :workspace, :thread_refresh]
  ]

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

    id = "thr-#{System.unique_integer([:positive])}"
    other = "thr-other-#{System.unique_integer([:positive])}"

    for p <- [id, other] do
      assert {:ok, _} = ProjectStore.save(%{project_id: p, path: "/tmp/#{p}", name: "Demo #{p}"})
    end

    {:ok, id: id, other: other}
  end

  defp restore(key, nil), do: Application.delete_env(:foreman_server, key)
  defp restore(key, value), do: Application.put_env(:foreman_server, key, value)

  # -- fixtures --------------------------------------------------------------

  defp event(type, payload), do: %{event_type: type, payload: payload}

  defp task(task_id, project_id, title),
    do:
      event("TaskCreated", %{
        task_id: task_id,
        project_id: project_id,
        title: title,
        status: "open",
        task_type: "implement"
      })

  defp run(run_id, task_id, project_id),
    do: event("RunStarted", %{run_id: run_id, task_id: task_id, project_id: project_id})

  # A started run with a titled task: one working thread, `run:<run_id>`.
  defp seed_run!(run_id, project_id, title) do
    :ok =
      ProjectionStore.apply_events([
        task("t-" <> run_id, project_id, title),
        run(run_id, "t-" <> run_id, project_id)
      ])

    "run:" <> run_id
  end

  defp iso(offset_ms),
    do: DateTime.utc_now() |> DateTime.add(offset_ms, :millisecond) |> DateTime.to_iso8601()

  defp stdout(run_id, seq, line, at),
    do:
      event("WorkerStdout", %{
        run_id: run_id,
        worker_id: "w1",
        sequence: seq,
        line: line,
        timestamp: at
      })

  defp stderr(run_id, seq, line, at),
    do:
      event("WorkerStderr", %{
        run_id: run_id,
        worker_id: "w1",
        sequence: seq,
        line: line,
        timestamp: at
      })

  # A run that exists on the event store too (`run.steer`, pause and the rest need the aggregate).
  defp start_real_run!(project_id, title) do
    run = PrWatchSupport.start_run!(project_id: project_id)
    :ok = ProjectionStore.apply_events([task(run.task_id, project_id, title)])
    run
  end

  # Durable events of the run's stream, which `Transcript` reads as steer and lifecycle turns.
  defp append_run_events!(run_id, expected_version, events) do
    :ok =
      Store.append_to_stream(
        "run:#{run_id}",
        expected_version,
        Enum.map(events, fn {type, data} ->
          %EventData{event_type: type, data: Map.put(data, :run_id, run_id), metadata: %{}}
        end)
      )
  end

  # -- views -----------------------------------------------------------------

  defp project_url(id), do: Components.project_path(id, @token)

  # The page of a thread, the way a browser asks for it: the token rides the query.
  defp thread_url(id, thread_id), do: Components.thread_path(id, thread_id, @token)

  # A CSS selector for an id that holds a colon.
  defp css(id), do: String.replace(id, ":", "\\:")
  defp row(thread_id), do: "#thread-" <> css(thread_id)
  defp steer_form(thread_id), do: "#steer-" <> css(thread_id)

  # The refresh telemetry handler is attached BEFORE the view mounts, so no refresh of the
  # view can happen unobserved.
  defp attach_telemetry! do
    {handler, ref} = Handler.attach_event_handlers(self(), @refreshes)
    Process.put(:refresh_ref, ref)
    on_exit(fn -> :telemetry.detach(handler) end)
    ref
  end

  defp mount!(url) do
    ref = attach_telemetry!()
    {:ok, view, html} = live(build_conn(), url)
    {view, html, ref}
  end

  # Re-checks `fun.(html)` after every refresh of the view (state or thread) and once up
  # front, until it holds; flunks after 5s. No sleeps. Every refresh it waits for is tallied
  # (see `refreshes/3`), so what it consumed is still there for the assertions after it.
  defp await_until(view, fun) do
    ref = Process.get(:refresh_ref)
    pid = view.pid
    html = render(view)

    if fun.(html) do
      html
    else
      receive do
        {[:foreman_server, :workspace, kind], ^ref, _m, %{pid: ^pid}}
        when kind in [:refresh, :thread_refresh] ->
          tally(kind)
          await_until(view, fun)
      after
        5_000 ->
          flunk(
            "condition not reached after a refresh; last html:\n" <> String.slice(html, 0, 800)
          )
      end
    end
  end

  defp tally(kind),
    do: Process.put(:refreshes, Map.update(Process.get(:refreshes, %{}), kind, 1, &(&1 + 1)))

  # How many refreshes of `kind` the view has made since it mounted: what `await_until` already
  # consumed plus what is in the mailbox, after waiting `quiet_ms` for more to arrive.
  defp refreshes(view, kind, quiet_ms \\ 0) do
    drain_refreshes(Process.get(:refresh_ref), view.pid, quiet_ms)
    Map.get(Process.get(:refreshes, %{}), kind, 0)
  end

  defp drain_refreshes(ref, pid, quiet_ms) do
    receive do
      {[:foreman_server, :workspace, kind], ^ref, _m, %{pid: ^pid}} ->
        tally(kind)
        drain_refreshes(ref, pid, quiet_ms)
    after
      quiet_ms -> :ok
    end
  end

  # The html of the elements `selector` matches, in document order.
  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  # The href of the one link `selector` matches.
  defp href(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("href")
    |> List.first()
  end

  defp steer_field_id(view, thread_id) do
    html = view |> element(steer_form(thread_id) <> " textarea") |> render()
    [_, field_id] = Regex.run(~r/\sid="([^"]+)"/, html)
    field_id
  end

  # The CSS variants of the log's blocks, in order: agent, stderr, operator, system, verdict.
  defp log_variants(view) do
    view
    |> element("#thread-log")
    |> render()
    |> then(&Regex.scan(~r/class="msg msg--(\w+)"/, &1))
    |> Enum.map(fn [_, variant] -> variant end)
  end

  # -- the sidebar -----------------------------------------------------------

  describe "the thread sidebar" do
    defp seed_every_group!(id, other) do
      other_run = seed_run!("r-foreign", other, "Other project thread")
      assert other_run == "run:r-foreign"

      :ok =
        ProjectionStore.apply_events([
          task("t-working", id, "In flight"),
          run("r-working", "t-working", id),
          task("t-ready", id, "Ready one"),
          run("r-ready", "t-ready", id),
          event("RunCompleted", %{run_id: "r-ready", project_id: id}),
          event("PrReady", %{run_id: "r-ready", pr_url: "https://github.com/a/b/pull/1"}),
          task("t-landing", id, "Landing one"),
          run("r-landing", "t-landing", id),
          event("RunCompleted", %{run_id: "r-landing", project_id: id}),
          event("PrReady", %{run_id: "r-landing", pr_url: "https://github.com/a/b/pull/2"}),
          event("MergeGateApproved", %{run_id: "r-landing", approver: "a", approver_identity: "a"}),
          task("t-failed", id, "Broken one"),
          run("r-failed", "t-failed", id),
          event("RunFailed", %{run_id: "r-failed", project_id: id, reason: "boom"}),
          task("t-idle", id, "Idle one"),
          run("r-idle", "t-idle", id),
          event("RunCompleted", %{run_id: "r-idle", project_id: id}),
          task("t-done", id, "Done one"),
          run("r-done", "t-done", id),
          event("RunCompleted", %{run_id: "r-done", project_id: id}),
          event("ThreadResolved", %{
            thread_id: "run:r-done",
            project_id: id,
            reason: "x",
            resolved_by: "op",
            source: "operator",
            at: "2026-10-20T00:00:00Z"
          })
        ])
    end

    test "lists the groups in the order Waiting on you, Working, Landing, Ready for review, then folds Idle and Resolved into Earlier",
         %{id: id, other: other} do
      seed_every_group!(id, other)
      {view, html, _ref} = mount!(project_url(id))

      positions =
        for dom_id <-
              ~w(group-waiting_on_you group-working group-landing group-ready_for_review threads-earlier) do
          {pos, _} = :binary.match(html, ~s(id="#{dom_id}"))
          pos
        end

      assert positions == Enum.sort(positions)

      assert texts(view, "#thread-list h3") == [
               "Waiting on you (1)",
               "Working (1)",
               "Landing (1)",
               "Ready for review (1)"
             ]

      assert texts(view, "#threads-earlier summary") == ["Earlier (2)"]
      assert has_element?(view, "#group-waiting_on_you #{row("run:r-failed")}")
      assert has_element?(view, "#group-working #{row("run:r-working")}")
      assert has_element?(view, "#group-landing #{row("run:r-landing")}")
      assert has_element?(view, "#group-ready_for_review #{row("run:r-ready")}")
      assert has_element?(view, "#threads-earlier #group-idle #{row("run:r-idle")}")
      assert has_element?(view, "#threads-earlier #group-resolved #{row("run:r-done")}")

      # the project's threads only
      refute has_element?(view, row("run:r-foreign"))
      refute html =~ "Other project thread"
      refute html =~ "Nothing here."
    end

    test "a group with no thread is not rendered, and a project with none says so", %{id: id} do
      seed_run!("r-only", id, "The only one")
      {view, _html, _ref} = mount!(project_url(id))

      assert has_element?(view, "#group-working #{row("run:r-only")}")

      for group <- ~w(waiting_on_you landing ready_for_review) do
        refute has_element?(view, "#group-#{group}")
      end

      refute has_element?(view, "#threads-earlier")
      refute has_element?(view, "#thread-list [role=img]")

      empty = "thr-empty-#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               ProjectStore.save(%{project_id: empty, path: "/tmp/#{empty}", name: empty})

      {empty_view, _html, _ref} = mount!(project_url(empty))

      assert has_element?(empty_view, "#thread-list-chat", "Project chat")
      assert has_element?(empty_view, "#thread-list", "No threads yet.")
    end

    test "the attention dot sits on the Threads heading with the real count", %{
      id: id,
      other: other
    } do
      seed_every_group!(id, other)
      {view, _html, _ref} = mount!(project_url(id))

      # one failed thread waits on the operator, one has a pull request to review
      assert has_element?(
               view,
               ~s(#threads-heading [role=img][aria-label="2 threads need attention"])
             )
    end

    test "Earlier starts closed, and open only when the open thread is inside it", %{
      id: id,
      other: other
    } do
      seed_every_group!(id, other)

      {view, _html, _ref} = mount!(project_url(id))
      assert has_element?(view, "details#threads-earlier")
      refute has_element?(view, "details#threads-earlier[open]")

      {working, _html, _ref} = mount!(thread_url(id, "run:r-working"))
      refute has_element?(working, "details#threads-earlier[open]")

      {idle, _html, _ref} = mount!(thread_url(id, "run:r-idle"))
      assert has_element?(idle, "details#threads-earlier[open]")

      {resolved, _html, _ref} = mount!(thread_url(id, "run:r-done"))
      assert has_element?(resolved, "details#threads-earlier[open]")
      assert has_element?(resolved, "#{row("run:r-done")}[aria-current=page]")
    end

    test "a row links by patch to the encoded thread path and carries title, status label and age",
         %{id: id} do
      thread = seed_run!("r-row", id, "A fairly long title that the row clips to one line")
      {view, _html, _ref} = mount!(project_url(id))

      assert has_element?(
               view,
               ~s(#{row(thread)}[data-phx-link=patch][href="#{thread_url(id, thread)}"])
             )

      assert Components.thread_path(id, thread) == "/dashboard/projects/#{id}/threads/run%3Ar-row"

      assert has_element?(
               view,
               ~s(#{row(thread)} .thread-row-title[title="A fairly long title that the row clips to one line"]),
               "A fairly long title"
             )

      [meta] = texts(view, "#{row(thread)} .thread-row-meta")
      assert meta =~ "working"
      # just started: under a minute
      assert meta =~ "now"
    end

    test "the chat row is first and selected until a thread is open; clicking a row patches to its pane",
         %{id: id} do
      thread = seed_run!("r-click", id, "Click me")
      {view, _html, _ref} = mount!(project_url(id))

      assert has_element?(view, "#thread-list-chat[aria-current=page]")
      refute has_element?(view, "#{row(thread)}[aria-current]")
      assert has_element?(view, "#conversation-pane")

      view |> element(row(thread)) |> render_click()
      assert_patch(view, thread_url(id, thread))

      assert has_element?(view, "#thread-pane")
      assert has_element?(view, "#{row(thread)}[aria-current=page]")
      refute has_element?(view, "#thread-list-chat[aria-current]")
      refute has_element?(view, "#conversation-pane")

      view |> element("#thread-list-chat") |> render_click()
      assert_patch(view, project_url(id))
      assert has_element?(view, "#conversation-pane")
      refute has_element?(view, "#thread-pane")
    end

    test "every group the Overview has is listed (none can go missing)" do
      groups = for group <- Group.all(), into: %{}, do: {group, [card(group)]}

      html =
        render_component(&Components.thread_sidebar/1,
          project_id: "p",
          overview: overview(groups),
          selected_id: nil,
          status: nil
        )

      for group <- Group.all() do
        assert html =~ ~s(id="thread-run:#{group}"), "the #{group} thread is not in the sidebar"
      end
    end

    test "ages and the full time come from the thread's last event; no time, no age" do
      now = System.system_time(:millisecond)

      groups = %{
        working: [
          card(:working, thread_id: "run:five", updated_at: now - 5 * 60_000),
          card(:working, thread_id: "run:three-h", updated_at: now - 3 * 3_600_000),
          card(:working, thread_id: "run:two-d", updated_at: now - 2 * 86_400_000 - 1_000),
          card(:working, thread_id: "run:never", updated_at: nil)
        ]
      }

      rows =
        render_component(&Components.thread_sidebar/1,
          project_id: "p",
          overview: overview(groups),
          selected_id: nil,
          status: nil
        )
        |> LazyHTML.from_fragment()

      meta = fn thread_id ->
        rows
        |> LazyHTML.query(~s(a[id="thread-#{thread_id}"] .thread-row-meta))
        |> LazyHTML.text()
      end

      assert meta.("run:five") =~ "5m"
      assert meta.("run:three-h") =~ "3h"
      assert meta.("run:two-d") =~ "2d"
      refute meta.("run:never") =~ "·"

      {_display, full_time} = Components.message_time(now - 5 * 60_000)

      assert rows
             |> LazyHTML.query(~s(a[id="thread-run:five"] .thread-row-meta span[title]))
             |> LazyHTML.attribute("title") == [full_time]

      assert full_time =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z UTC$/
    end

    test "the chat row carries the coordinator's status chip: idle, working while a turn is open, unhealthy" do
      chip = fn status ->
        render_component(&Components.thread_sidebar/1,
          project_id: "p",
          overview: overview(%{}),
          selected_id: nil,
          status: %{"status" => status, "consecutive_failures" => 0, "last_error" => nil}
        )
        |> LazyHTML.from_fragment()
      end

      for {status, label, kind} <- [
            {"idle", "idle", "muted"},
            {"turn_open", "working", "info"},
            {"unhealthy", "unhealthy", "err"}
          ] do
        assert chip.(status)
               |> LazyHTML.query("#thread-list-chat .chip--#{kind}")
               |> LazyHTML.text() ==
                 label,
               status
      end
    end

    test "a status outside the aggregate's vocabulary is a defect, not a chip" do
      for status <- ["working", "bogus", ""] do
        assert_raise FunctionClauseError, fn ->
          render_component(&Components.thread_sidebar/1,
            project_id: "p",
            overview: overview(%{}),
            selected_id: nil,
            status: %{"status" => status, "consecutive_failures" => 0, "last_error" => nil}
          )
        end
      end
    end

    defp card(group, extra \\ []) do
      struct!(
        ThreadCard,
        Keyword.merge(
          [
            thread_id: "run:#{group}",
            door: :workflow,
            title: "Thread #{group}",
            status: "in_progress",
            group: group,
            reason: :in_flight,
            steering: "pause_resume"
          ],
          extra
        )
      )
    end

    defp overview(groups) do
      %Overview{
        project_id: "p",
        groups: Map.merge(Map.new(Group.all(), &{&1, []}), groups),
        counts: %{},
        attention: %{needed: false, count: 0, reasons: []},
        truncated: false,
        tabs: %{},
        generated_at: 0
      }
    end
  end

  # -- the pane --------------------------------------------------------------

  describe "a thread's URL" do
    test "shows that thread's pane, selects its row and leaves the chat out", %{id: id} do
      thread = seed_run!("r-pane", id, "In flight")
      {view, html, _ref} = mount!(thread_url(id, thread))

      assert html =~ "In flight"
      assert has_element?(view, "section#thread-pane[aria-label='Thread: In flight']")
      assert has_element?(view, "#thread-pane h2", "In flight")
      assert has_element?(view, "#thread-pane .chip", "working")
      assert has_element?(view, "#thread-log[role=log][aria-live=polite]")
      assert has_element?(view, "#{row(thread)}[aria-current=page]")
      refute has_element?(view, "#thread-list-chat[aria-current]")
      refute has_element?(view, "#conversation-pane")
      refute has_element?(view, "#thread-not-found")

      # the right column and the landmarks are there on this route too
      assert has_element?(view, "aside.ws-side section.ws-panels")
      assert has_element?(view, "#tabs-pane")
      assert has_element?(view, ~s(nav[aria-label=Threads]#thread-list))
    end

    test "has a Project chat link back, by patch", %{id: id} do
      thread = seed_run!("r-back", id, "Back and forth")
      {view, _html, _ref} = mount!(thread_url(id, thread))

      assert has_element?(
               view,
               ~s(#thread-pane a.thread-back[data-phx-link=patch][href="#{project_url(id)}"]),
               "Project chat"
             )

      view |> element("#thread-pane a.thread-back") |> render_click()
      assert_patch(view, project_url(id))
      assert has_element?(view, "#conversation-pane")
    end

    test "a streamed message, its deltas and then the whole message once more, is ONE article that is patched in place",
         %{id: id} do
      thread = seed_run!("r-msg", id, "Streams a message")
      {view, _html, _ref} = mount!(thread_url(id, thread))
      message = "Starting assess. Need discovery report + task description first."

      deltas = [
        "Star",
        "ting ass",
        "ess. Need discovery report",
        " + task description",
        " first."
      ]

      # a burst of deltas: they read as the message so far
      :ok =
        ProjectionStore.apply_events(
          for {delta, n} <- Enum.with_index(deltas, 1),
              do: stdout("r-msg", n, delta, iso(-1_000 + n))
        )

      await_until(view, &(&1 =~ message))
      assert texts(view, "#thread-log .msg--agent .msg-text") == [message]
      assert has_element?(view, "#thread-log article#turn-0.msg--agent")

      # the final repeats the whole message: the deltas are dropped, the article stays
      before = refreshes(view, :thread_refresh)
      :ok = ProjectionStore.apply_events([stdout("r-msg", 6, message, iso(-500))])
      await_until(view, fn _html -> refreshes(view, :thread_refresh, 50) > before end)

      assert texts(view, "#thread-log .msg--agent .msg-text") == [message]
      assert has_element?(view, "#thread-log article#turn-0.msg--agent")
      assert length(texts(view, "#thread-log article")) == 1
    end

    test "shows the run's turns: output chunks of one source together, the steer, lifecycle lines, each labelled",
         %{id: id} do
      run = start_real_run!(id, "A real run")
      thread = "run:" <> run.run_id

      append_run_events!(run.run_id, 1, [
        {"RunSteerQueued", %{message_id: "m-1", text: "switch to plan B password=hunter2"}},
        {"RunPaused", %{reason: "steer"}},
        {"RunResumed", %{}}
      ])

      :ok =
        ProjectionStore.apply_events([
          stdout(run.run_id, 1, "out one\n", iso(-20_000)),
          stdout(run.run_id, 2, "out two\n", iso(-19_900)),
          stderr(run.run_id, 3, "err one token=sk-livesecret123", iso(-19_800))
        ])

      {view, _html, _ref} = mount!(thread_url(id, thread))
      log = view |> element("#thread-log") |> render()

      # one block of output (its two lines together), the stderr, then the operator's steer and
      # Foreman's own lines, in the order they happened
      assert log =~ "out one\nout two"
      assert log_variants(view) == ~w(agent stderr operator system system)

      assert texts(view, "#thread-log .msg-sender") == [
               "Agent",
               "stderr",
               "You",
               "Foreman",
               "Foreman"
             ]

      assert texts(view, "#thread-log .msg--operator .msg-text") == [
               "switch to plan B password=[REDACTED]"
             ]

      assert texts(view, "#thread-log .msg--system .msg-text") == [
               "Run paused: steer",
               "Run resumed"
             ]

      # redacted at read time, never shown
      refute log =~ "sk-livesecret123"
      refute log =~ "hunter2"

      # a human time, the full ISO time on hover, never the raw stamp
      assert has_element?(view, "#thread-log .msg-meta span[title$=' UTC']")
      refute log =~ ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z/
    end

    test "escapes everything the agent wrote", %{id: id} do
      thread = seed_run!("r-xss", id, "<img src=x onerror=alert(1)>")

      :ok =
        ProjectionStore.apply_events([
          stdout("r-xss", 1, "<script>alert('xss')</script>", iso(-5_000))
        ])

      {view, html, _ref} = mount!(thread_url(id, thread))
      html = html <> render(view)

      assert html =~ "&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;"
      assert html =~ "&lt;img src=x onerror=alert(1)&gt;"
      refute html =~ "<script>alert"
      refute html =~ "<img src=x"
    end

    test "says so when there is no output yet, and that it will appear while the thread is live",
         %{id: id} do
      live_thread = seed_run!("r-live", id, "Live one")
      {live_view, _html, _ref} = mount!(thread_url(id, live_thread))

      assert has_element?(live_view, "#thread-log", "No output recorded yet.")
      assert has_element?(live_view, "#thread-log", "Output appears here as the agent works.")

      :ok =
        ProjectionStore.apply_events([event("RunCompleted", %{run_id: "r-live", project_id: id})])

      finished = await_until(live_view, &(not (&1 =~ "Output appears here as the agent works.")))

      assert finished =~ "No output recorded yet."
    end

    test "keeps the newest 100 blocks and says how many earlier turns it leaves out", %{id: id} do
      thread = seed_run!("r-long", id, "Long one")

      # stdout and stderr alternating: every line is a block of its own
      lines =
        for n <- 0..119 do
          at = iso(-60_000 + n * 10)

          if rem(n, 2) == 0,
            do: stdout("r-long", n, "line #{n}", at),
            else: stderr("r-long", n, "line #{n}", at)
        end

      :ok = ProjectionStore.apply_events(lines)
      {view, _html, _ref} = mount!(thread_url(id, thread))

      assert length(texts(view, "#thread-log article")) == 100
      assert has_element?(view, "#thread-log", "20 earlier turns not shown.")
      assert has_element?(view, "#thread-log article#turn-20")
      refute has_element?(view, "#thread-log article#turn-19")
      assert has_element?(view, "#thread-log article#turn-119", "line 119")
    end

    test "shows a jobsite thread's iterations and takes steering while it runs", %{id: id} do
      :ok =
        ProjectionStore.apply_events([
          event("JobsiteStarted", %{
            jobsite_id: "j-pane",
            repo_path: "/r",
            strategy: "worktree",
            project_id: id
          }),
          event("JobsiteIterationCompleted", %{
            jobsite_id: "j-pane",
            index: 1,
            status: "completed",
            text: "worked on the parser"
          })
        ])

      {view, _html, _ref} = mount!(thread_url(id, "jobsite:j-pane"))

      assert has_element?(view, "#thread-pane")
      assert has_element?(view, "#thread-log .msg--agent", "worked on the parser")
      assert has_element?(view, steer_form("jobsite:j-pane"))
    end

    test "the pane follows the thread's state: a finished thread has a note, not a composer",
         %{id: id} do
      thread = seed_run!("r-state", id, "State change")
      {view, _html, _ref} = mount!(thread_url(id, thread))

      assert has_element?(view, steer_form(thread))
      refute has_element?(view, "#thread-pane .thread-note")

      :ok =
        ProjectionStore.apply_events([
          event("RunCompleted", %{run_id: "r-state", project_id: id})
        ])

      await_until(view, &(&1 =~ "This thread is finished."))

      refute has_element?(view, steer_form(thread))
      assert has_element?(view, "#thread-pane .thread-note", "This thread is finished.")
      assert has_element?(view, "#thread-pane .chip", "completed")
    end

    test "a thread that is waiting on the operator, not over, says it takes no steering now",
         %{id: id} do
      run = start_real_run!(id, "Paused one")
      thread = "run:" <> run.run_id
      assert {:ok, _} = Actions.run_control(id, thread, :pause, "i-pause")
      Eventually.await(fn -> match?({:ok, %{status: "paused"}}, Threads.get(thread)) end)

      {view, _html, _ref} = mount!(thread_url(id, thread))

      refute has_element?(view, steer_form(thread))
      assert has_element?(view, "#thread-pane .thread-note", "not taking steering")
      refute has_element?(view, "#thread-pane .thread-note", "finished")
    end

    test "the header carries the failure and the chip; the review is a turn of the log, not header text",
         %{id: id} do
      thread = seed_run!("r-bad", id, "Broken thing")

      :ok =
        ProjectionStore.apply_events([
          event("RunFailed", %{run_id: "r-bad", project_id: id, reason: "boom"}),
          event("ReviewRecorded", %{
            subject_kind: "run",
            subject_id: "r-bad",
            verdict: "not_met",
            summary: "tests are red",
            at: "2026-10-20T00:00:00Z"
          })
        ])

      {view, _html, _ref} = mount!(thread_url(id, thread))

      assert has_element?(view, "#thread-pane .chip--err", "failed")
      assert has_element?(view, "#thread-pane .ws-error", "Failure: boom")
      refute has_element?(view, "#thread-pane header", "tests are red")
      assert has_element?(view, "#thread-log .msg--verdict .msg-sender", "Review")
      assert has_element?(view, "#thread-log .msg--verdict", "not_met: tests are red")
    end
  end

  describe "a thread id that is not one of this project's threads" do
    setup do
      :ok = ForemanServer.TestSupport.MeckScope.new_once!([Transcript])
      ForemanServer.TestSupport.MeckScope.restore_on_exit!([Transcript])
    end

    test "is Thread not found, never raises and never reads or leaks another project's transcript",
         %{id: id, other: other} do
      foreign = seed_run!("r-foreign", other, "Foreign title")

      :ok =
        ProjectionStore.apply_events([stdout("r-foreign", 1, "FOREIGN-SECRET-LINE", iso(-5_000))])

      seed_run!("r-mine", id, "Mine")

      ids = [
        foreign,
        "run:no-such-run",
        "jobsite:no-such-jobsite",
        "garbage",
        "run:",
        "run:r-mine ",
        "RUN:R-MINE",
        "../run:r-mine",
        "run:r-mine/../r-foreign"
      ]

      for thread_id <- ids do
        {view, html, _ref} = mount!(thread_url(id, thread_id))
        html = html <> render(view)

        assert has_element?(view, "section#thread-not-found", "Thread not found"), thread_id

        assert has_element?(view, "#thread-not-found a[data-phx-link=patch]", "Project chat"),
               thread_id

        refute has_element?(view, "#thread-pane"), thread_id
        refute has_element?(view, "#conversation-pane"), thread_id
        refute html =~ "FOREIGN-SECRET-LINE", thread_id
        refute html =~ "Foreign title", thread_id
        # the page is still the workspace: sidebar, panels
        assert has_element?(view, "#thread-list"), thread_id
        assert has_element?(view, "aside.ws-side"), thread_id
      end

      # not one read of any transcript for any of them
      assert :meck.num_calls(Transcript, :full, :_) == 0

      # the control: one of this project's own threads is read
      {_view, _html, _ref} = mount!(thread_url(id, "run:r-mine"))
      assert :meck.num_calls(Transcript, :full, :_) >= 1
    end

    test "the way back is a patch to the project chat", %{id: id} do
      {view, _html, _ref} = mount!(thread_url(id, "run:nope"))

      view |> element("#thread-not-found a") |> render_click()
      assert_patch(view, project_url(id))
      assert has_element?(view, "#conversation-pane")
    end

    test "a thread that stops being this project's is not found at the next refresh",
         %{id: id} do
      thread = seed_run!("r-moves", id, "Moving")
      {view, _html, _ref} = mount!(thread_url(id, thread))
      assert has_element?(view, "#thread-pane")

      ProjectionStoreReset.reset!()
      # an event of the project makes the view re-read the (now empty) Overview
      :ok = ProjectionStore.apply_events([task("t-new", id, "New")])

      await_until(view, &(&1 =~ "Thread not found"))
      refute has_element?(view, "#thread-pane")
    end
  end

  describe "a resolved thread older than the Overview's resolved window" do
    # 30 resolved runs, one more resolved a minute after the one before: the Overview shows the
    # newest `Overview.default_resolved_limit/0` of them, so the oldest are not among its cards.
    defp seed_resolved_runs!(project_id, count) do
      base = ~U[2026-10-01 00:00:00Z]

      for n <- 1..count do
        run_id = "r-res-#{n}"
        at = base |> DateTime.add(n * 60, :second) |> DateTime.to_iso8601()

        :ok =
          ProjectionStore.apply_events([
            task("t-" <> run_id, project_id, "Resolved #{n}"),
            run(run_id, "t-" <> run_id, project_id),
            event("RunCompleted", %{run_id: run_id, project_id: project_id}),
            event("ThreadResolved", %{
              thread_id: "run:" <> run_id,
              project_id: project_id,
              reason: "x",
              resolved_by: "op",
              source: "operator",
              at: at
            })
          ])

        "run:" <> run_id
      end
    end

    test "opens its conversation pane; an unknown id and another project's id stay not found",
         %{id: id, other: other} do
      [oldest | _] = thread_ids = seed_resolved_runs!(id, 30)
      foreign = seed_run!("r-foreign-res", other, "Foreign")

      {:ok, overview} = Overview.build(id, include_resolved: true)
      shown = overview.groups[:resolved]
      assert length(shown) < 30
      refute Enum.any?(shown, &(&1.thread_id == oldest))

      {view, _html, _ref} = mount!(thread_url(id, oldest))
      assert has_element?(view, "#thread-pane")
      refute has_element?(view, "#thread-not-found")

      for missing <- ["run:no-such-run", foreign] do
        {view, _html, _ref} = mount!(thread_url(id, missing))
        assert has_element?(view, "section#thread-not-found", "Thread not found"), missing
        refute has_element?(view, "#thread-pane"), missing
      end

      for thread_id <- thread_ids do
        {view, html, _ref} = mount!(thread_url(id, thread_id))
        refute html <> render(view) =~ "no thread with that id", thread_id
        assert has_element?(view, "#thread-pane"), thread_id
      end
    end
  end

  # -- switching, live output, steering ---------------------------------------

  describe "switching between the chat and threads" do
    test "is a patch: the same process keeps its state, so nothing is remounted", %{id: id} do
      first = seed_run!("r-one", id, "First")
      second = seed_run!("r-two", id, "Second")
      {view, _html, _ref} = mount!(project_url(id))
      pid = view.pid

      session = fn ->
        assigns = :sys.get_state(view.pid).socket.assigns
        {assigns.intent_base, assigns.draft_id, assigns.steer_nonce}
      end

      before = session.()

      render_patch(view, thread_url(id, first))
      assert has_element?(view, "#thread-pane h2", "First")
      assert session.() == before

      render_patch(view, thread_url(id, second))
      assert has_element?(view, "#thread-pane h2", "Second")
      refute has_element?(view, "#thread-pane h2", "First")
      assert has_element?(view, "#{row(second)}[aria-current=page]")
      refute has_element?(view, "#{row(first)}[aria-current]")
      assert session.() == before

      render_patch(view, project_url(id))
      assert has_element?(view, "#conversation-pane")
      refute has_element?(view, "#thread-pane")
      assert session.() == before
      assert view.pid == pid and Process.alive?(pid)
    end

    test "the chat's messages are still there when the operator comes back", %{id: id} do
      thread = seed_run!("r-away", id, "Away")
      {view, _html, _ref} = mount!(project_url(id))

      view |> form("#composer", %{"text" => "remember this message"}) |> render_submit()
      assert has_element?(view, "#conversation-log", "remember this message")

      render_patch(view, thread_url(id, thread))
      refute has_element?(view, "#conversation-log")

      render_patch(view, project_url(id))
      assert has_element?(view, "#conversation-log", "remember this message")
    end

    test "a stop asked for on one thread is not pending on the next", %{id: id} do
      first = seed_run!("r-s1", id, "Stop one")
      second = seed_run!("r-s2", id, "Stop two")
      {view, _html, _ref} = mount!(thread_url(id, first))

      view |> element("#thread-pane button", "Stop") |> render_click()
      assert has_element?(view, "#thread-pane button", "Confirm stop")

      render_patch(view, thread_url(id, second))
      refute has_element?(view, "#thread-pane button", "Confirm stop")

      render_patch(view, thread_url(id, first))
      refute has_element?(view, "#thread-pane button", "Confirm stop")
      assert has_element?(view, "#thread-pane button", "Stop")
    end
  end

  describe "worker output of the open thread" do
    test "appears in the log without any state event; another run's output is not re-read",
         %{id: id} do
      thread = seed_run!("r-out", id, "Streaming")
      seed_run!("r-quiet", id, "Quiet")
      {view, _html, ref} = mount!(thread_url(id, thread))
      pid = view.pid

      refute render(view) =~ "first line from the agent"
      refute_received {[:foreman_server, :workspace, _kind], ^ref, _m, %{pid: ^pid}}

      :ok =
        ProjectionStore.apply_events([stdout("r-out", 1, "first line from the agent", iso(0))])

      html = await_until(view, &(&1 =~ "first line from the agent"))

      assert html =~ "Agent"
      assert refreshes(view, :thread_refresh) >= 1
      # the state refresh ignores worker output: only the transcript was re-read
      assert refreshes(view, :refresh) == 0

      # more output of the same run reaches the same block
      :ok = ProjectionStore.apply_events([stderr("r-out", 2, "a warning", iso(0))])
      html = await_until(view, &(&1 =~ "a warning"))
      assert html =~ "stderr"

      # another run's output (same project) arms nothing and shows nothing here
      settled = refreshes(view, :thread_refresh, 100)

      :ok =
        ProjectionStore.apply_events([stdout("r-quiet", 1, "output of the other run", iso(0))])

      assert refreshes(view, :thread_refresh, 200) == settled
      assert refreshes(view, :refresh) == 0
      refute render(view) =~ "output of the other run"
    end

    test "a burst of output costs a bounded number of re-reads", %{id: id} do
      thread = seed_run!("r-burst", id, "Burst")
      {view, _html, _ref} = mount!(thread_url(id, thread))

      :ok =
        ProjectionStore.apply_events(
          for n <- 1..200, do: stdout("r-burst", n, "burst line #{n}", iso(0))
        )

      await_until(view, &(&1 =~ "burst line 200"))

      # 200 lines in one batch coalesce: a handful of re-reads at most, never one per line
      count = refreshes(view, :thread_refresh, 100)
      assert count >= 1 and count <= 3
    end

    test "nothing is armed while no thread is open", %{id: id} do
      seed_run!("r-no-pane", id, "No pane open")
      {view, _html, ref} = mount!(project_url(id))
      pid = view.pid

      :ok = ProjectionStore.apply_events([stdout("r-no-pane", 1, "nobody is looking", iso(0))])

      refute_receive {[:foreman_server, :workspace, _kind], ^ref, _m, %{pid: ^pid}}, 200
      refute render(view) =~ "nobody is looking"
    end
  end

  describe "a thread that appears after the page was opened" do
    test "gets its log, and a click elsewhere on the page does not take the view down",
         %{id: id} do
      # No refresh timer fires in this test: the click is the first thing to see the new thread,
      # which is how a click lands between a run's events and the refresh that follows them.
      Application.put_env(:foreman_server, :workspace, coalesce_ms: 60_000)

      {view, _html, _ref} = mount!(thread_url(id, "run:r-late"))
      assert has_element?(view, "#thread-not-found")

      seed_run!("r-late", id, "Late thread")

      :ok =
        ProjectionStore.apply_events([stdout("r-late", 1, "first line of a late thread", iso(0))])

      html = view |> element("#tab-scheduled") |> render_click()

      assert Process.alive?(view.pid)
      assert has_element?(view, "#thread-pane")
      refute has_element?(view, "#thread-not-found")
      assert html =~ "first line of a late thread"
    end
  end

  describe "a secret split across output chunks" do
    @describetag :tmp_dir
    @secret "s3cr3t-DEPLOYKEY-0123456789"

    test "is never shown by the pane, while the message streams or after its final", %{
      id: id,
      tmp_dir: tmp
    } do
      SecretStoreDir.use_tmp_dir!(tmp)
      SecretStoreDir.put!(id, "DEPLOY_KEY", @secret)
      thread = seed_run!("r-split", id, "Secret echo")
      {view, _html, _ref} = mount!(thread_url(id, thread))

      deltas = [
        "I found the key s3cr3t-DEPLOY",
        "KEY-0123456789 in the env, and password=",
        "hunter2 too. Done."
      ]

      :ok =
        ProjectionStore.apply_events(
          for {delta, n} <- Enum.with_index(deltas, 1), do: stdout("r-split", n, delta, iso(0))
        )

      streaming = await_until(view, &(&1 =~ "[REDACTED]"))
      refute streaming =~ @secret
      refute streaming =~ "hunter2"

      # the final repeats the whole message, in one chunk the store's own redaction scrubs
      :ok = ProjectionStore.apply_events([stdout("r-split", 4, Enum.join(deltas), iso(0))])
      settled = refreshes(view, :thread_refresh, 150)
      assert settled >= 1

      finished = render(view)
      assert finished =~ "[REDACTED]"
      refute finished =~ @secret
      refute finished =~ "hunter2"
    end
  end

  describe "a run with more output than the API's tail" do
    # An entry is one chunk, so a run that streams for a minute writes hundreds of them.
    defp seed_chunks!(run_id, count, first_text) do
      :ok =
        ProjectionStore.apply_events(
          for n <- 1..count do
            text = if n == 1, do: first_text, else: "chunk #{n}. "
            stdout(run_id, n, text, iso(-120_000 + n * 10))
          end
        )
    end

    test "shows the whole conversation, its first message included, and says nothing is missing",
         %{id: id} do
      thread = seed_run!("r-long-run", id, "A long run")
      seed_chunks!("r-long-run", 600, "THE FIRST MESSAGE. ")

      # the API's 500-entry tail would have cut the first hundred
      assert {:ok, %{count: 500, omitted_entries: 100}} = ProjectionStore.run_logs("r-long-run")

      {view, _html, _ref} = mount!(thread_url(id, thread))

      assert has_element?(view, "#thread-log .msg-text", "THE FIRST MESSAGE. chunk 2. chunk 3. ")
      assert has_element?(view, "#thread-log .msg-text", "chunk 599. chunk 600.")
      refute has_element?(view, "#thread-log-omitted")
      refute render(view) =~ "no longer stored"
    end

    test "a small run shows no note", %{id: id} do
      thread = seed_run!("r-small-run", id, "A small run")
      seed_chunks!("r-small-run", 3, "Hello. ")

      {view, _html, _ref} = mount!(thread_url(id, thread))

      assert has_element?(view, "#thread-log .msg-text", "Hello. chunk 2. chunk 3.")
      refute has_element?(view, "#thread-log-omitted")
    end

    test "says how many stored entries are gone when the store's own window dropped them",
         %{id: id} do
      thread = seed_run!("r-window", id, "A run past the window")
      big = String.duplicate("x", 300_000)

      # the store keeps 1 MiB of output per run: of five 300 kB chunks the oldest are evicted
      :ok =
        ProjectionStore.apply_events(
          for n <- 1..5, do: stdout("r-window", n, "CHUNK-#{n}-" <> big, iso(-10_000 + n))
        )

      max = ProjectionStore.run_logs_max_limit()

      assert {:ok, %{truncated: true, omitted_entries: omitted}} =
               ProjectionStore.run_logs("r-window", limit: max)

      assert omitted > 0

      {view, _html, _ref} = mount!(thread_url(id, thread))

      assert has_element?(
               view,
               "#thread-log-omitted.ws-muted",
               "The first #{omitted} output entries are no longer stored."
             )

      html = render(view)
      refute html =~ "CHUNK-1-"
      assert html =~ "CHUNK-5-"
    end
  end

  describe "steering from the pane" do
    test "sends the message once, shows it as the operator's turn and clears the field", %{id: id} do
      run = start_real_run!(id, "Steer me")
      thread = "run:" <> run.run_id
      {view, _html, _ref} = mount!(thread_url(id, thread))

      assert has_element?(
               view,
               "#{steer_form(thread)} textarea[name=text][placeholder='Steer this thread...']"
             )

      assert has_element?(view, "#{steer_form(thread)} label .ws-vh", "Steer Steer me")
      before_id = steer_field_id(view, thread)

      html = view |> form(steer_form(thread), %{"text" => "use the cache"}) |> render_submit()

      assert html =~ "Message sent to #{thread}."
      refute steer_field_id(view, thread) == before_id

      await_until(view, &(&1 =~ "use the cache"))
      assert texts(view, "#thread-log .msg--operator .msg-text") == ["use the cache"]
      assert texts(view, "#thread-log .msg--operator .msg-sender") == ["You"]
    end

    test "the field belongs to the browser: a refused send keeps it, a refresh never replaces it",
         %{id: id} do
      run = start_real_run!(id, "Draft me")
      thread = "run:" <> run.run_id
      {view, _html, _ref} = mount!(thread_url(id, thread))

      # LiveView rewrites an input the browser does not have focused from the server's
      # markup, and the pane re-renders as output arrives: the field is ignored by patches
      assert has_element?(view, "#{steer_form(thread)} textarea[phx-update=ignore]")
      field = steer_field_id(view, thread)

      # a refused send (blank) changes nothing, so what the operator typed stays
      html =
        render_submit(view, "steer", %{"thread_id" => thread, "text" => "  ", "message_id" => "m"})

      assert html =~ "the message is empty"
      assert steer_field_id(view, thread) == field

      # worker output refreshes the pane; the field and its id are the same element
      :ok = ProjectionStore.apply_events([stdout(run.run_id, 1, "output while typing", iso(0))])
      await_until(view, &(&1 =~ "output while typing"))
      assert refreshes(view, :thread_refresh) >= 1
      assert steer_field_id(view, thread) == field

      # a state refresh does not replace it either
      before = refreshes(view, :refresh)
      :ok = ProjectionStore.apply_events([task("t-other-event", id, "Something else")])
      await_until(view, fn _html -> refreshes(view, :refresh, 50) > before end)
      assert steer_field_id(view, thread) == field
    end

    test "the hidden message id carries the nonce, so a second message is a new one", %{id: id} do
      run = start_real_run!(id, "Twice")
      thread = "run:" <> run.run_id
      {view, _html, _ref} = mount!(thread_url(id, thread))

      message_id = fn ->
        view
        |> element("#{steer_form(thread)} input[name=message_id]")
        |> render()
        |> then(&Regex.run(~r/value="([^"]+)"/, &1))
        |> List.last()
      end

      first = message_id.()
      assert String.ends_with?(first, ":" <> thread)

      view |> form(steer_form(thread), %{"text" => "one"}) |> render_submit()
      second = message_id.()

      refute second == first
      assert String.ends_with?(second, ":" <> thread)
    end
  end

  # -- the polish ------------------------------------------------------------

  describe "the header" do
    test "has a Project landmark around its actions", %{id: id} do
      {view, _html, _ref} = mount!(project_url(id))

      assert has_element?(
               view,
               ~s(header nav[aria-label=Project] a[href*="/settings"]),
               "Settings"
             )

      assert has_element?(view, ~s(header nav[aria-label=Project] .chip[role=status]))
    end
  end

  describe "the token" do
    # The dashboard has no cookie: a page opened with `?token=` is authorised by that query alone,
    # so every link and patch the page offers has to carry it or the next click is a 401.
    test "a page opened with ?token= hands it to every link that moves around the workspace",
         %{id: id} do
      thread = seed_run!("r-tok", id, "Token thread")
      other = seed_run!("r-tok2", id, "Second thread")
      {view, _html, _ref} = mount!(thread_url(id, thread))

      assert href(view, "#thread-list-chat") == project_url(id)
      assert href(view, row(thread)) == thread_url(id, thread)
      assert href(view, row(other)) == thread_url(id, other)
      assert href(view, "#thread-pane a.thread-back") == project_url(id)

      assert href(view, ~s(header nav[aria-label=Project] a[href*="/settings"])) ==
               Components.settings_path(id, @token)

      # a patch to another thread keeps it
      view |> element(row(other)) |> render_click()
      assert_patch(view, thread_url(id, other))
      assert href(view, "#thread-list-chat") == project_url(id)
      assert href(view, row(thread)) == thread_url(id, thread)
    end

    test "a page opened with the Authorization header has no token to hand on", %{id: id} do
      thread = seed_run!("r-hdr", id, "Header thread")

      {:ok, view, html} =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> @token)
        |> live(Components.thread_path(id, thread))

      assert href(view, "#thread-list-chat") == Components.project_path(id)
      assert href(view, row(thread)) == Components.thread_path(id, thread)

      assert href(view, ~s(header nav[aria-label=Project] a[href*="/settings"])) ==
               Components.settings_path(id)

      refute html =~ "token="
    end

    test "the settings page hands it back to the workspace", %{id: id} do
      {:ok, view, _html} = live(build_conn(), Components.settings_path(id, @token))

      assert href(view, "header nav[aria-label=Project] a") == project_url(id)
    end

    test "no log line of a mount or a patch carries it", %{id: id} do
      thread = seed_run!("r-log", id, "Logged thread")
      other = seed_run!("r-log2", id, "Logged too")

      log =
        capture_log([level: :debug], fn ->
          {view, _html, _ref} = mount!(thread_url(id, thread))
          view |> element(row(other)) |> render_click()
          assert_patch(view, thread_url(id, other))
        end)

      assert log =~ "HANDLE PARAMS"
      refute log =~ @token
    end
  end

  describe "the coordinator's proposed threads" do
    defp propose!(id, task_ids) do
      assert {:ok, _} =
               CommandGateway.dispatch_system(%{
                 command_id: "prop-#{id}",
                 aggregate_id: "coordinator:" <> id,
                 type: "coordinator.message",
                 payload: %{project_id: id, message_id: "m-seed", text: "hi", source: "http"}
               })

      :ok =
        ProjectionStore.apply_events([
          event("CoordinatorActionRecorded", %{
            project_id: id,
            action_id: "a1",
            turn_id: "turn1",
            kind: "propose_threads",
            status: "proposed",
            result_ref: %{"task_ids" => task_ids}
          })
        ])
    end

    test "show only those that can still be started; with none the section is absent",
         %{id: id} do
      closed =
        event("TaskCreated", %{
          task_id: "t-closed",
          project_id: id,
          title: "Closed work",
          status: "closed",
          task_type: "implement"
        })

      :ok = ProjectionStore.apply_events([closed])
      propose!(id, ["t-closed"])

      {view, html, _ref} = mount!(project_url(id))
      refute has_element?(view, "#proposals")
      refute has_element?(view, "#proposal-t-closed")
      refute html =~ "Proposed threads"
      refute html =~ "Closed work"

      :ok = ProjectionStore.apply_events([task("t-open", id, "Open work")])
      propose!(id, ["t-closed", "t-open"])

      {view, _html, _ref} = mount!(project_url(id))
      assert has_element?(view, "#proposals h3", "Proposed threads")
      assert has_element?(view, "#proposal-t-open button", "Start")
      assert has_element?(view, "#proposal-t-open button", "Decline")
      refute has_element?(view, "#proposal-t-closed")
    end
  end

  describe "paths" do
    test "a thread id is percent-encoded, everything else the router sees stays plain" do
      assert Components.project_path("p-1") == "/dashboard/projects/p-1"

      assert Components.thread_path("p-1", "run:run-abc") ==
               "/dashboard/projects/p-1/threads/run%3Arun-abc"

      assert Components.thread_path("p-1", "jobsite:j 1/2") ==
               "/dashboard/projects/p-1/threads/jobsite%3Aj%201%2F2"
    end

    test "a token rides the query, form-encoded; without one the path has no query" do
      assert Components.project_path("p-1", "s3cr/et k") ==
               "/dashboard/projects/p-1?token=s3cr%2Fet+k"

      assert Components.thread_path("p-1", "run:run-abc", "tok") ==
               "/dashboard/projects/p-1/threads/run%3Arun-abc?token=tok"

      assert Components.settings_path("p-1", "tok") ==
               "/dashboard/projects/p-1/settings?token=tok"

      assert Components.settings_path("p-1") == "/dashboard/projects/p-1/settings"
      assert Components.project_path("p-1", nil) == "/dashboard/projects/p-1"
    end

    test "a message time takes unix milliseconds as well as ISO text" do
      ms = 1_793_000_000_123

      assert Components.message_time(ms) ==
               Components.message_time(DateTime.to_iso8601(DateTime.from_unix!(ms, :millisecond)))

      assert {display, title} = Components.message_time(ms)
      assert display =~ ~r/^[A-Z][a-z]{2} \d{1,2}, \d{1,2}:\d{2} [AP]M$/
      assert title =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z UTC$/
      assert Components.message_time(nil) == {"", nil}
    end
  end
end
