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

  test "historical summaries remain possible after external log files are purged and server restarts",
       %{
         tmp_dir: tmp_dir
       } do
    log_file = Path.join(tmp_dir, "worker.log")
    event_log_path = Application.fetch_env!(:foreman_server, :event_log_path)
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

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, event_log_path)
    assert :ok = Application.start(:foreman_server)

    assert {:ok, logs} = DebugViews.logs("run-purge", mode: :compact)

    assert [%{message: "event-backed stdout survives"}] =
             Enum.filter(logs.entries, &(&1.type == "WorkerStdout"))

    assert {:ok, report} = DebugViews.report("run-purge")
    assert report.status == "in_progress"
    assert report.summary.event_count == 2
    assert log_file in report.artifact_paths

    assert {:ok, debug} = DebugViews.debug_timeline("run-purge")
    assert debug.summary.event_count == 2
    assert log_file in debug.artifacts
  end

  test "debug views redact secrets and truncate large log values" do
    large_output = String.duplicate("x", 5_000)

    append_worker_event("WorkerStdout", %{
      run_id: "run-secret",
      phase_id: "developer",
      worker_id: "worker-secret",
      output:
        large_output <>
          " token=abc123 token: colon-token access_token=atok auth_token: authv Authorization: Bearer auth-bearer-value secret: sss {\"token\":\"jsonsecret\"}",
      details: %{password: "super-secret"},
      sequence: 1
    })

    append_worker_event("WorkerStderr", %{
      run_id: "run-secret",
      phase_id: "developer",
      worker_id: "worker-secret",
      output:
        "stderr api_key=abc123 api-key=hyphen-value api_key: colon-key client_secret=csec client-secret=hyphen-client-value password: hunter2 Bearer loose-token {\"client_secret\": \"json-client-value\"}",
      sequence: 2
    })

    append_worker_event("AssistantMessage", %{
      run_id: "run-secret",
      phase_id: "developer",
      worker_id: "worker-secret",
      message:
        "assistant password=hunter2 password: colon-password access_token=assistant-access access-token=assistant-hyphen-access auth_token: assistant-auth auth-token: assistant-hyphen-auth {\"token\":\"assistant-json-token\"}",
      sequence: 3
    })

    append_worker_event("ToolCallFinished", %{
      run_id: "run-secret",
      phase_id: "developer",
      worker_id: "worker-secret",
      tool_name: "shell",
      status: "ok",
      metadata: %{authorization: "Bearer abc123"},
      details: %{client_secret: "secret-value", note: "safe"},
      event_metadata: %{authorization: "Bearer eventtoken"},
      sequence: 4
    })

    append_run_event("PhaseFailed", %{
      run_id: "run-secret",
      phase_id: "developer",
      reason:
        "failed with client_secret=debug-client-secret client-secret=debug-hyphen-client {\"client_secret\": \"debug-json-client\"}",
      status: "failed"
    })

    assert {:ok, compact} = DebugViews.logs("run-secret", mode: :compact)
    messages = Enum.map(compact.entries, & &1.message)

    for secret <- [
          "abc123",
          "hunter2",
          "colon-token",
          "atok",
          "authv",
          "auth-bearer-value",
          "colon-key",
          "hyphen-value",
          "csec",
          "hyphen-client-value",
          "jsonsecret",
          "json-client-value",
          "colon-password",
          "assistant-access",
          "assistant-hyphen-access",
          "assistant-auth",
          "assistant-hyphen-auth",
          "assistant-json-token",
          "loose-token"
        ] do
      refute Enum.any?(messages, &String.contains?(&1, secret))
    end

    assert Enum.any?(messages, &String.ends_with?(&1, "...[truncated]"))

    assert {:ok, raw} = DebugViews.logs("run-secret", mode: :raw)
    stdout = Enum.find(raw.entries, &(&1.type == "WorkerStdout"))
    stderr = Enum.find(raw.entries, &(&1.type == "WorkerStderr"))
    assistant = Enum.find(raw.entries, &(&1.type == "AssistantMessage"))
    tool = Enum.find(raw.entries, &(&1.type == "ToolCallFinished"))

    assert String.ends_with?(stdout.payload.output, "...[truncated]")
    refute stdout.payload.output =~ "abc123"
    refute stdout.payload.output =~ "atok"
    refute stdout.payload.output =~ "authv"
    refute stdout.payload.output =~ "jsonsecret"
    refute stderr.payload.output =~ "colon-key"
    refute stderr.payload.output =~ "hyphen-value"
    refute stderr.payload.output =~ "csec"
    refute stderr.payload.output =~ "hyphen-client-value"
    refute stderr.payload.output =~ "json-client-value"
    refute stderr.payload.output =~ "loose-token"
    assert stderr.payload.output =~ "api_key=[REDACTED]"
    assert stderr.payload.output =~ "api-key=[REDACTED]"
    assert stderr.payload.output =~ "client-secret=[REDACTED]"
    assert stderr.payload.output =~ "password=[REDACTED]"
    assert stderr.payload.output =~ "Bearer [REDACTED]"
    refute assistant.payload.message =~ "colon-password"
    refute assistant.payload.message =~ "assistant-access"
    refute assistant.payload.message =~ "assistant-hyphen-access"
    refute assistant.payload.message =~ "assistant-auth"
    refute assistant.payload.message =~ "assistant-hyphen-auth"
    refute assistant.payload.message =~ "assistant-json-token"
    assert assistant.payload.message =~ "password=[REDACTED]"
    assert tool.payload.details.client_secret == "[REDACTED]"
    assert tool.payload.metadata.authorization == "[REDACTED]"
    assert tool.metadata.authorization == "[REDACTED]"

    assert {:ok, debug} = DebugViews.debug_timeline("run-secret")

    for secret <- [
          "abc123",
          "hunter2",
          "colon-token",
          "atok",
          "authv",
          "auth-bearer-value",
          "colon-key",
          "csec",
          "jsonsecret",
          "json-client-value",
          "colon-password",
          "assistant-access",
          "assistant-auth",
          "assistant-json-token",
          "debug-client-secret",
          "debug-hyphen-client",
          "debug-json-client",
          "loose-token"
        ] do
      refute inspect(debug) =~ secret
    end
  end

  test "debug view truncation preserves valid UTF-8 for long unicode log values" do
    unicode_output = String.duplicate("🔐", 2_000) <> " token: unicode-secret"

    append_worker_event("WorkerStdout", %{
      run_id: "run-unicode",
      phase_id: "developer",
      worker_id: "worker-unicode",
      output: unicode_output,
      sequence: 1
    })

    assert {:ok, compact} = DebugViews.logs("run-unicode", mode: :compact)
    [compact_entry] = compact.entries
    assert String.valid?(compact_entry.message)
    assert String.ends_with?(compact_entry.message, "...[truncated]")
    refute compact_entry.message =~ "unicode-secret"
    assert Jason.encode!(compact)

    assert {:ok, raw} = DebugViews.logs("run-unicode", mode: :raw)
    [raw_entry] = raw.entries
    assert String.valid?(raw_entry.payload.output)
    assert String.ends_with?(raw_entry.payload.output, "...[truncated]")
    refute raw_entry.payload.output =~ "unicode-secret"
    assert Jason.encode!(raw)
  end

  test "assistant_message events sent with message render non-blank" do
    assert {:ok, _} =
             WorkerProtocol.start_phase("developer", %{
               run_id: "run-message",
               worker_id: "worker-message",
               adapter: "pi_sdk"
             })

    assert {:ok, _} =
             WorkerProtocol.ingest_event(%{
               run_id: "run-message",
               phase_id: "developer",
               worker_id: "worker-message",
               type: "assistant_message",
               message: "assistant message body",
               sequence: 1
             })

    assert {:ok, logs} = DebugViews.logs("run-message", mode: :compact)

    assert Enum.any?(
             logs.entries,
             &(&1.type == "AssistantMessage" and &1.message == "assistant message body")
           )
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
    event_metadata = Map.get(payload, :event_metadata, %{})
    payload = Map.delete(payload, :event_metadata)

    EventStore.append(%{
      stream_id: "worker:#{payload.run_id}:#{payload.worker_id}",
      event_type: event_type,
      payload: payload,
      metadata:
        Map.merge(
          %{
            correlation_id: payload.run_id,
            idempotency_key: "#{event_type}:#{System.unique_integer([:positive])}"
          },
          event_metadata
        )
    })
  end
end
