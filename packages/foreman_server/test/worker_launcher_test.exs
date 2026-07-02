defmodule ForemanServer.WorkerLauncherTest do
  use ExUnit.Case

  alias ForemanServer.{EventStore, ProjectionStore, WorkerLauncher}

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-worker-launcher-test-#{System.unique_integer([:positive])}"
      )

    bin_dir = Path.join(tmp_dir, "bin")
    project_dir = Path.join(tmp_dir, "project")
    File.mkdir_p!(bin_dir)
    File.mkdir_p!(project_dir)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))

    old_path = System.get_env("PATH") || ""
    System.put_env("PATH", bin_dir <> ":" <> old_path)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      System.put_env("PATH", old_path)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    assert :ok = Application.start(:foreman_server)
    {:ok, bin_dir: bin_dir, project_dir: project_dir}
  end

  test "worker launch disables nested HTTP server and passes operator server URL", %{
    bin_dir: bin_dir,
    project_dir: project_dir
  } do
    foreman = Path.join(bin_dir, "foreman")

    File.write!(foreman, """
    #!/usr/bin/env sh
    echo "server_url=$FOREMAN_SERVER_URL"
    echo "http_enabled=$FOREMAN_SERVER_HTTP_ENABLED"
    echo "http_port=$FOREMAN_SERVER_HTTP_PORT"
    exit 0
    """)

    File.chmod!(foreman, 0o755)

    task = %{
      task_id: "task-env",
      project_id: "project-a",
      project_path: project_dir,
      task_type: "feature"
    }

    assert {:ok, _} =
             WorkerLauncher.launch(task, "00000000-0000-0000-0000-000000000002", ["developer"])

    assert_eventually(
      fn -> EventStore.stream("worker-launch:00000000-0000-0000-0000-000000000002") end,
      fn events ->
        Enum.any?(events, fn event ->
          event.event_type == "WorkerProcessExited" &&
            String.contains?(event.payload.output, "server_url=http://127.0.0.1:4766") &&
            String.contains?(event.payload.output, "http_enabled=false") &&
            String.contains?(event.payload.output, "http_port=0")
        end)
      end
    )
  end

  test "worker fallback failure uses output phase instead of stale projection phase", %{
    bin_dir: bin_dir,
    project_dir: project_dir
  } do
    foreman = Path.join(bin_dir, "foreman")

    File.write!(foreman, """
    #!/usr/bin/env sh
    echo '▶ ✗ foreman-ecd62 FAILED —  developer  [cli-review]  $8.1779  19t 538 tools'
    echo '[PIPELINE] cli-review failed after 2 retries'
    echo 'Run completed: failed'
    exit 0
    """)

    File.chmod!(foreman, 0o755)

    task = %{
      task_id: "foreman-ecd62",
      project_id: "project-a",
      project_path: project_dir,
      task_type: "bug"
    }

    run_id = "00000000-0000-0000-0000-000000000003"

    {:ok, _} =
      EventStore.append(%{
        event_type: "RunStarted",
        stream_id: "run:#{run_id}",
        payload: %{run_id: run_id, task_id: "foreman-ecd62", current_phase: "explorer"}
      })

    {:ok, _} =
      EventStore.append(%{
        event_type: "PhaseStarted",
        stream_id: "run:#{run_id}",
        payload: %{run_id: run_id, task_id: "foreman-ecd62", phase_id: "explorer"}
      })

    assert {:ok, _} = WorkerLauncher.launch(task, run_id, ["explorer", "cli-review"])

    assert_eventually(fn -> EventStore.stream("worker-launch:#{run_id}") end, fn events ->
      Enum.any?(events, fn event ->
        event.event_type == "RunFailed" &&
          event.payload.phase_id == "cli-review" &&
          event.payload.reason == "cli-review_failed" &&
          event.payload.diagnostic_reason == "worker_exited_without_terminal_event"
      end)
    end)
  end

  test "zero-exit failed worker output records diagnostic fallback failure", %{
    bin_dir: bin_dir,
    project_dir: project_dir
  } do
    foreman = Path.join(bin_dir, "foreman")

    File.write!(foreman, """
    #!/usr/bin/env sh
    echo '[PIPELINE] FAILED ($1.23)'
    echo '[PHASE: DEVELOPER] FAILED: Phase exceeded maxTurns (120)'
    exit 0
    """)

    File.chmod!(foreman, 0o755)

    task = %{
      task_id: "task-a",
      project_id: "project-a",
      project_path: project_dir,
      task_type: "feature"
    }

    assert {:ok, _} =
             WorkerLauncher.launch(task, "00000000-0000-0000-0000-000000000001", ["developer"])

    assert_eventually(
      fn -> EventStore.stream("worker-launch:00000000-0000-0000-0000-000000000001") end,
      fn events ->
        Enum.any?(events, fn event ->
          event.event_type == "WorkerProcessExited" &&
            event.payload.exit_code == 0 &&
            String.contains?(event.payload.output, "[PIPELINE] FAILED")
        end)
      end
    )

    assert_eventually(fn -> ProjectionStore.task("task-a") end, fn task ->
      task && task.status == "failed" && task.failure_reason == "pipeline_failed"
    end)
  end

  defp assert_eventually(fun, predicate, attempts \\ 20)

  defp assert_eventually(fun, predicate, attempts) when attempts > 0 do
    value = fun.()

    if predicate.(value) do
      :ok
    else
      Process.sleep(20)
      assert_eventually(fun, predicate, attempts - 1)
    end
  end

  defp assert_eventually(fun, predicate, 0) do
    value = fun.()
    flunk("condition not met; last value: #{inspect(value)}, predicate: #{inspect(predicate)}")
  end
end
