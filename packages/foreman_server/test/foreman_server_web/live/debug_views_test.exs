defmodule ForemanServerWeb.DebugViewsTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ForemanServer.{EventStore, WorkerProtocol}

  @endpoint ForemanServerWeb.Endpoint

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-web-debug-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    previous_env = [
      event_log_path: Application.get_env(:foreman_server, :event_log_path),
      project_store_path: Application.get_env(:foreman_server, :project_store_path),
      debug_live_views_enabled: Application.get_env(:foreman_server, :debug_live_views_enabled)
    ]

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    Application.put_env(:foreman_server, :project_store_path, Path.join(tmp_dir, "projects.term"))
    Application.put_env(:foreman_server, :debug_live_views_enabled, true)
    assert :ok = Application.start(:foreman_server)

    seed_debug_run()

    on_exit(fn ->
      Application.stop(:foreman_server)

      Enum.each(previous_env, fn {key, value} ->
        if is_nil(value) do
          Application.delete_env(:foreman_server, key)
        else
          Application.put_env(:foreman_server, key, value)
        end
      end)

      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    :ok
  end

  test "/debug/runs page renders active run state" do
    {:ok, _view, html} = live(build_conn(), "/debug/runs")

    assert html =~ "Run diagnostics"
    assert html =~ "run-live"
    assert html =~ "developer"
    assert html =~ "in_progress"
  end

  test "/debug/runs page includes live socket bootstrap assets" do
    conn = get(build_conn(), "/debug/runs")
    html = html_response(conn, 200)

    assert html =~ ~s(name="csrf-token")
    assert html =~ ~s(src="/debug-live.js")
  end

  test "/debug/phases page renders phase state" do
    {:ok, _view, html} = live(build_conn(), "/debug/phases")

    assert html =~ "Phase diagnostics"
    assert html =~ "run-live"
    assert html =~ "developer"
    assert html =~ "worker-live"
  end

  test "/debug/workers page reflects worker liveness within one second" do
    {:ok, view, html} = live(build_conn(), "/debug/workers")

    assert html =~ "Worker diagnostics"
    assert html =~ "worker-live"
    assert html =~ "live"

    assert {:ok, _} =
             WorkerProtocol.heartbeat(%{
               run_id: "run-live",
               phase_id: "developer",
               worker_id: "worker-live",
               sequence: 2,
               attach: %{connected: true}
             })

    assert_eventually(fn ->
      rendered = render(view)
      rendered =~ "seq 2" and rendered =~ "heartbeat"
    end)
  end

  test "debug routes are unavailable unless enabled" do
    Application.put_env(:foreman_server, :debug_live_views_enabled, false)

    conn = get(build_conn(), "/debug/runs")

    assert conn.status == 404
    assert conn.resp_body =~ "Not Found"
  end

  defp seed_debug_run do
    assert {:ok, _event} =
             append_run_event("RunStarted", %{
               run_id: "run-live",
               task_id: "task-live",
               project_id: "project-live",
               phase_order: ["developer"],
               current_phase: "developer"
             })

    assert {:ok, _} =
             WorkerProtocol.start_phase("developer", %{
               run_id: "run-live",
               worker_id: "worker-live",
               adapter: "pi_sdk"
             })

    assert {:ok, _} =
             WorkerProtocol.ingest_event(%{
               run_id: "run-live",
               phase_id: "developer",
               worker_id: "worker-live",
               type: "stdout",
               output: "seed output",
               sequence: 1
             })
  end

  defp append_run_event(event_type, payload) do
    EventStore.append(%{
      stream_id: "run:#{payload.run_id}",
      event_type: event_type,
      payload: payload,
      metadata: %{
        correlation_id: payload.run_id,
        idempotency_key: "#{event_type}:#{System.unique_integer([:positive])}"
      }
    })
  end

  defp assert_eventually(fun, timeout_ms \\ 1_000, interval_ms \\ 50)

  defp assert_eventually(fun, timeout_ms, interval_ms) do
    started_at = System.monotonic_time(:millisecond)
    do_assert_eventually(fun, timeout_ms, interval_ms, started_at)
  end

  defp do_assert_eventually(fun, timeout_ms, interval_ms, started_at) do
    if fun.() do
      assert true
    else
      now = System.monotonic_time(:millisecond)

      if now - started_at >= timeout_ms do
        flunk("condition not met within #{timeout_ms}ms")
      else
        Process.sleep(interval_ms)
        do_assert_eventually(fun, timeout_ms, interval_ms, started_at)
      end
    end
  end
end
