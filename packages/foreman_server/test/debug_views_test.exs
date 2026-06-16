defmodule ForemanServer.DebugViewsTest do
  use ExUnit.Case

  alias ForemanServer.{DebugViews, EventStore, WorkerProtocol}

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-debug-view-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    assert :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "worker stdout stderr tool and assistant events render compact and raw logs" do
    seed_worker_events()

    assert {:ok, compact} = DebugViews.logs("run-debug", mode: :compact)
    assert compact.mode == "compact"

    assert Enum.map(compact.entries, & &1.stream) == [
             "event",
             "stdout",
             "stderr",
             "assistant",
             "tool"
           ]

    assert Enum.map(compact.entries, & &1.message) |> Enum.member?("stdout line")
    assert Enum.map(compact.entries, & &1.message) |> Enum.member?("stderr line")
    assert Enum.map(compact.entries, & &1.message) |> Enum.member?("assistant answer")
    assert Enum.any?(compact.entries, &(&1.message == "edit ok"))

    assert {:ok, raw} = DebugViews.logs("run-debug", mode: :raw)
    stdout = Enum.find(raw.entries, &(&1.type == "WorkerStdout"))
    assert stdout.payload.output == "stdout line"
    assert stdout.stream_id == "worker:run-debug:worker-debug"
  end

  test "debug timeline references phase artifacts and report files", %{tmp_dir: tmp_dir} do
    artifact = Path.join(tmp_dir, "artifact.md")
    report = Path.join(tmp_dir, "report.md")
    File.write!(artifact, "artifact body")
    File.write!(report, "report body")

    append_run_event("RunStarted", %{run_id: "run-artifacts", phase_order: ["developer"]})

    append_run_event("PhaseCompleted", %{
      run_id: "run-artifacts",
      phase_id: "developer",
      artifact_paths: [artifact],
      report_paths: [report],
      status: "completed"
    })

    assert {:ok, debug} = DebugViews.debug_timeline("run-artifacts")
    assert artifact in debug.artifacts
    assert report in debug.reports
    assert Enum.map(debug.timeline, & &1.type) == ["RunStarted", "PhaseCompleted"]
    assert hd(Enum.reverse(debug.timeline)).artifact_paths == [artifact]
  end

  test "historical summaries remain possible after external log files are purged", %{
    tmp_dir: tmp_dir
  } do
    log_file = Path.join(tmp_dir, "worker.log")
    File.write!(log_file, "transient raw log")

    append_run_event("RunStarted", %{run_id: "run-purge", phase_order: ["developer"]})

    append_worker_event("WorkerStdout", %{
      run_id: "run-purge",
      phase_id: "developer",
      worker_id: "worker-purge",
      output: "event-backed stdout survives",
      artifact_paths: [log_file],
      sequence: 1
    })

    File.rm!(log_file)
    refute File.exists?(log_file)

    assert {:ok, logs} = DebugViews.logs("run-purge", mode: :compact)

    assert [%{message: "event-backed stdout survives"}] =
             Enum.filter(logs.entries, &(&1.type == "WorkerStdout"))

    assert {:ok, report} = DebugViews.report("run-purge")
    assert report.summary.event_count == 2
    assert log_file in report.artifact_paths
  end

  defp seed_worker_events do
    assert {:ok, _} =
             WorkerProtocol.start_phase("developer", %{
               run_id: "run-debug",
               worker_id: "worker-debug",
               adapter: "pi_sdk"
             })

    assert {:ok, _} =
             WorkerProtocol.ingest_event(%{
               run_id: "run-debug",
               phase_id: "developer",
               worker_id: "worker-debug",
               type: "stdout",
               output: "stdout line",
               sequence: 1
             })

    assert {:ok, _} =
             WorkerProtocol.ingest_event(%{
               run_id: "run-debug",
               phase_id: "developer",
               worker_id: "worker-debug",
               type: "stderr",
               output: "stderr line",
               sequence: 2
             })

    assert {:ok, _} =
             WorkerProtocol.ingest_event(%{
               run_id: "run-debug",
               phase_id: "developer",
               worker_id: "worker-debug",
               type: "assistant_message",
               output: "assistant answer",
               sequence: 3
             })

    assert {:ok, _} =
             WorkerProtocol.ingest_event(%{
               run_id: "run-debug",
               phase_id: "developer",
               worker_id: "worker-debug",
               type: "tool_call_finished",
               tool_name: "edit",
               status: "ok",
               sequence: 4
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

  defp append_worker_event(event_type, payload) do
    EventStore.append(%{
      stream_id: "worker:#{payload.run_id}:#{payload.worker_id}",
      event_type: event_type,
      payload: payload,
      metadata: %{
        correlation_id: payload.run_id,
        idempotency_key: "#{event_type}:#{System.unique_integer([:positive])}"
      }
    })
  end
end
