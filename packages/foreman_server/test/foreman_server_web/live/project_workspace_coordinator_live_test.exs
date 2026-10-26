defmodule ForemanServerWeb.ProjectWorkspaceCoordinatorLiveTest do
  # foreman-q9zzo C5: the workspace's "Restart coordinator" control. It is offered only
  # while the coordinator is `unhealthy` (three consecutive failed turns) and its click
  # is the operator's `coordinator.restart`, the command behind
  # `POST /api/projects/:id/coordinator/restart` and `foreman project chat --restart`.
  #
  # The coordinator is made unhealthy the way production does it: the real
  # `TurnRunner` runs a scripted agent that fails three turns in a row, so the failures,
  # the health counters and the last error are real commands and events, not a poked
  # projection.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ForemanServer.Coordinator.{Agent.Stub, Error, Runtime, Turn, TurnRunner}
  alias ForemanServer.{CoordinatorAPI, EventStore, ProjectionStore, ProjectStore}
  alias ForemanServer.TestSupport.{Eventually, ProjectionStoreReset}

  @endpoint ForemanServerWeb.Endpoint
  @token "workspace-coordinator-live-token"
  @restart ~s(button[phx-click="restart_coordinator"])
  @health "#coordinator-health"

  setup %{tmp_dir: dir} do
    Eventually.put_env_for_test(:foreman_server, :api_bearer_token, @token)
    Eventually.put_env_for_test(:foreman_server, :workspace, coalesce_ms: 20)
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    id = "wscoord-#{System.unique_integer([:positive])}"
    assert {:ok, _} = ProjectStore.save(%{project_id: id, path: dir, name: "Coordinator Demo"})

    script = start_supervised!({Stub, responses: []})

    runtime =
      Runtime.new(:workspace_coordinator_live,
        agent: Stub,
        agent_opts: [script: script],
        only: [id],
        retry_backoff_ms: 0
      )

    # One operator message the coordinator never manages to answer.
    assert {:ok, _} =
             CoordinatorAPI.post_message(id, %{
               text: "the login page 500s",
               source: "http",
               message_id: "m1"
             })

    {:ok, id: id, script: script, runtime: runtime}
  end

  defp mount_view(id) do
    {:ok, view, html} = live(build_conn(), "/dashboard/projects/#{id}?token=#{@token}")
    {view, html}
  end

  # One real coordinator turn whose agent fails.
  defp fail_turn!(ctx) do
    Stub.push(ctx.script, [{:error, Error.new(:agent_failed, "provider down")}])
    assert {:failed, :agent_failed} = TurnRunner.run(ctx.id, ctx.runtime)
  end

  defp make_unhealthy!(ctx) do
    for _ <- 1..3, do: fail_turn!(ctx)

    assert {:ok, %{status: :unhealthy, consecutive_failures: 3}} =
             ProjectionStore.coordinator_status(ctx.id)
  end

  defp restarted_events(id) do
    {:ok, events} = EventStore.read_stream_forward("coordinator:#{id}", 0, 1_000)
    Enum.filter(events, &(&1.event_type == "CoordinatorRestarted"))
  end

  describe "the Restart coordinator button" do
    test "is absent while the coordinator is healthy and appears with the third consecutive failed turn",
         ctx do
      {view, _html} = mount_view(ctx.id)
      assert has_element?(view, @health, "Status: idle")
      refute has_element?(view, @restart)

      # Two failed turns are not yet "unhealthy": the failures show, the control does not.
      fail_turn!(ctx)
      fail_turn!(ctx)
      Eventually.await(fn -> has_element?(view, @health, "2 consecutive failures") end)
      assert has_element?(view, @health, "Status: idle")
      refute has_element?(view, @restart)

      fail_turn!(ctx)
      Eventually.await(fn -> has_element?(view, @restart) end)
      assert has_element?(view, @health, "Status: unhealthy")
      assert has_element?(view, @health, "3 consecutive failures")
      assert has_element?(view, @health, "last error: provider down")
    end

    test "restarts the coordinator: a CoordinatorRestarted event, a healthy status and a confirmation",
         ctx do
      make_unhealthy!(ctx)
      {view, _html} = mount_view(ctx.id)
      assert has_element?(view, @restart)
      assert restarted_events(ctx.id) == []

      view |> element(@restart) |> render_click()

      # The operator's command reached the coordinator stream, attributed to the dashboard ...
      project_id = ctx.id
      assert [%{data: %{project_id: ^project_id, by: "dashboard"}}] = restarted_events(ctx.id)

      # ... which cleared the failure counters ...
      assert {:ok, %{status: :idle, consecutive_failures: 0, last_error: nil}} =
               ProjectionStore.coordinator_status(ctx.id)

      # ... and the page says so: confirmation, a healthy status and no control left.
      assert has_element?(view, "#notice", "Coordinator restart requested.")
      refute has_element?(view, "#notice.ws-error")
      assert has_element?(view, @health, "Status: idle")
      refute has_element?(view, @health, "consecutive failures")
      refute has_element?(view, @health, "last error")
      refute has_element?(view, @restart)
    end

    test "the restart lets the coordinator take its pending message again", ctx do
      make_unhealthy!(ctx)
      {view, _html} = mount_view(ctx.id)
      Stub.push(ctx.script, [{:ok, %Turn{reply: "Back online.", actions: []}}])

      # An unhealthy coordinator takes no turn: the message stays unanswered.
      assert :idle = TurnRunner.run(ctx.id, ctx.runtime)
      refute has_element?(view, "#conversation-log", "Back online.")

      view |> element(@restart) |> render_click()

      assert :ok = TurnRunner.run(ctx.id, ctx.runtime)

      Eventually.await(fn ->
        has_element?(view, "#conversation-log", "Back online.") and
          has_element?(view, @health, "Status: idle")
      end)
    end

    test "a refused restart says why, restarts nothing and keeps the control", ctx do
      make_unhealthy!(ctx)
      assert {:ok, _} = ProjectStore.archive(ctx.id)
      {view, _html} = mount_view(ctx.id)
      assert has_element?(view, @restart)

      view |> element(@restart) |> render_click()

      assert has_element?(
               view,
               "#notice.ws-error",
               "Could not restart: project #{ctx.id} is archived"
             )

      assert restarted_events(ctx.id) == []

      assert {:ok, %{status: :unhealthy, consecutive_failures: 3}} =
               ProjectionStore.coordinator_status(ctx.id)

      assert has_element?(view, @health, "Status: unhealthy")
      assert has_element?(view, @restart)
    end
  end
end
