defmodule ForemanServer.OverwatchTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{EventStore, Overwatch, ProjectionStore}

  setup do
    Application.stop(:foreman_server)

    path =
      Path.join(
        System.tmp_dir!(),
        "foreman-overwatch-#{System.unique_integer([:positive])}.term.log"
      )

    Application.put_env(:foreman_server, :event_log_path, path)
    {:ok, _} = Application.ensure_all_started(:foreman_server)

    EventStore.append(%{
      stream_id: "task:task-1",
      event_type: "TaskCreated",
      payload: %{task_id: "task-1", project_id: "proj", title: "Task", status: "ready"},
      metadata: %{correlation_id: "test"}
    })

    EventStore.append(%{
      stream_id: "run:run-1",
      event_type: "RunStarted",
      payload: %{run_id: "run-1", task_id: "task-1", status: "in_progress"},
      metadata: %{correlation_id: "test"}
    })

    on_exit(fn ->
      Application.stop(:foreman_server)
      File.rm(path)
    end)

    :ok
  end

  test "denies read tool calls against directories and sends steering mail" do
    assert {:ok, decision} =
             Overwatch.check_tool(%{
               run_id: "run-1",
               task_id: "task-1",
               phase_id: "explorer",
               tool_name: "Read",
               tool_call_id: "tool-1",
               args: %{path: System.tmp_dir!()}
             })

    refute decision.allowed
    assert decision.action == "deny"
    assert decision.reason =~ "directory"

    events = EventStore.stream("run:run-1")
    assert Enum.any?(events, &(&1.event_type == "ToolCallRequested"))
    assert Enum.any?(events, &(&1.event_type == "ToolCallDenied"))

    inbox = ProjectionStore.snapshot().inbox_messages |> Map.values()
    assert Enum.any?(inbox, &(&1.from == "overwatch" and &1.to == "explorer"))
  end

  test "explorer allows Grep and rejects Graphify tools" do
    assert {:ok, %{allowed: true, action: "approve"}} =
             Overwatch.check_tool(%{
               run_id: "run-1",
               task_id: "task-1",
               phase_id: "explorer",
               tool_name: "Grep",
               tool_call_id: "tool-grep",
               args: %{pattern: "Task", path: "src"}
             })

    assert {:ok, decision} =
             Overwatch.check_tool(%{
               run_id: "run-1",
               task_id: "task-1",
               phase_id: "explorer",
               tool_name: "GraphifyQuery",
               tool_call_id: "tool-graphify",
               args: %{query: "Task"}
             })

    refute decision.allowed
    assert decision.reason =~ "Graphify tools are disabled"
  end

  test "approves ordinary file reads" do
    file =
      Path.join(
        System.tmp_dir!(),
        "foreman-overwatch-file-#{System.unique_integer([:positive])}.txt"
      )

    File.write!(file, "ok")
    on_exit(fn -> File.rm(file) end)

    assert {:ok, %{allowed: true, action: "approve"}} =
             Overwatch.check_tool(%{
               run_id: "run-1",
               phase_id: "fix",
               tool_name: "Read",
               args: %{path: file}
             })
  end

  test "denies missing absolute file reads" do
    missing =
      Path.join(
        System.tmp_dir!(),
        "foreman-overwatch-missing-#{System.unique_integer([:positive])}.txt"
      )

    assert {:ok, decision} =
             Overwatch.check_tool(%{
               run_id: "run-1",
               phase_id: "fix",
               tool_name: "Read",
               args: %{path: missing}
             })

    refute decision.allowed
    assert decision.reason =~ "does not exist"
  end

  test "allows relative file reads for worker-local paths" do
    assert {:ok, %{allowed: true, action: "approve"}} =
             Overwatch.check_tool(%{
               run_id: "run-1",
               phase_id: "fix",
               tool_name: "Read",
               args: %{path: "docs/user-guide.md"}
             })
  end

  test "uses phase report events to send compact steering mail to next phase" do
    EventStore.append(%{
      stream_id: "run:run-1",
      event_type: "PhaseReportProduced",
      payload: %{
        run_id: "run-1",
        task_id: "task-1",
        phase_id: "developer",
        details: %{
          "run_id" => "run-1",
          "task_id" => "task-1",
          "phase_id" => "developer",
          "report_id" => "report-1",
          "outcome" => "completed",
          "next_phase" => "qa",
          "artifacts" => [%{"name" => "DEVELOPER_REPORT.md", "content_type" => "text/markdown"}],
          "summary" => %{
            "rootCause" => "Board only watched inbox messages in Elixir mode.",
            "fix" => "Poll task snapshots and diff ids/status/updated fields.",
            "filesChanged" => "- src/cli/commands/board.ts",
            "qaHandoff" => "Verify task create and status update refresh the board."
          }
        }
      },
      metadata: %{correlation_id: "test"}
    })

    Process.sleep(50)

    inbox = ProjectionStore.snapshot().inbox_messages |> Map.values()

    steering =
      Enum.find(
        inbox,
        &(&1.from == "overwatch" and &1.to == "qa" and &1.subject =~ "developer → qa")
      )

    assert steering

    body = Jason.decode!(steering.body)
    assert body["kind"] == "steering"
    assert body["taskId"] == "task-1"
    assert body["sourceReport"] == "DEVELOPER_REPORT.md"
    assert body["summary"]["rootCause"] =~ "Board only watched"
    assert body["summary"]["qaHandoff"] =~ "Verify task create"
  end

  test "steers documentation without inviting scope-broadening churn" do
    EventStore.append(%{
      stream_id: "run:run-1",
      event_type: "PhaseReportProduced",
      payload: %{
        run_id: "run-1",
        task_id: "task-1",
        phase_id: "repair",
        outcome: "completed",
        next_phase: "documentation",
        artifacts: [%{name: "FIX_REPORT.md", content_type: "text/markdown"}],
        summary: %{fix: "Updated docs requested by the task."}
      },
      metadata: %{correlation_id: "test"}
    })

    Process.sleep(50)

    inbox = ProjectionStore.snapshot().inbox_messages |> Map.values()

    steering =
      Enum.find(
        inbox,
        &(&1.from == "overwatch" and &1.to == "documentation" and
            &1.subject =~ "repair → documentation")
      )

    assert steering
    assert steering.phase_id == "documentation"

    body = Jason.decode!(steering.body)
    assert body["targetPhase"] == "documentation"
    assert body["instructions"] =~ "report instead of broadening scope"
    refute body["instructions"] =~ "update only necessary operator-facing docs"
  end

  test "uses QA failure report event to steer retry target" do
    EventStore.append(%{
      stream_id: "run:run-1",
      event_type: "PhaseReportProduced",
      payload: %{
        run_id: "run-1",
        task_id: "task-1",
        phase_id: "qa",
        report_id: "report-qa-1",
        outcome: "retry",
        retryTarget: "developer",
        artifacts: [%{name: "QA_REPORT.md", content_type: "text/markdown"}],
        summary: %{
          verdict: "FAIL",
          testResults:
            "- Command: npx vitest run src/cli/__tests__/board-pure-helpers.test.ts\n- Failure: expected task update to appear."
        }
      },
      metadata: %{correlation_id: "test"}
    })

    Process.sleep(50)

    inbox = ProjectionStore.snapshot().inbox_messages |> Map.values()

    steering =
      Enum.find(
        inbox,
        &(&1.from == "overwatch" and &1.to == "developer" and &1.subject =~ "qa → developer")
      )

    assert steering

    body = Jason.decode!(steering.body)
    assert body["outcome"] == "retry"
    assert body["summary"]["verdict"] == "FAIL"
    assert body["summary"]["testResults"] =~ "npx vitest"
    assert body["instructions"] =~ "QA failure evidence"
  end

  test "sends native stale phase nudges from heartbeat events" do
    EventStore.append(%{
      stream_id: "run:run-1",
      event_type: "PhaseStarted",
      payload: %{run_id: "run-1", task_id: "task-1", phase_id: "explorer"},
      metadata: %{correlation_id: "test"}
    })

    for seq <- 1..3 do
      EventStore.append(%{
        stream_id: "worker:run-1:worker-1",
        event_type: "WorkerHeartbeat",
        payload: %{
          run_id: "run-1",
          task_id: "task-1",
          phase_id: "explorer",
          worker_id: "worker-1",
          sequence: seq
        },
        metadata: %{correlation_id: "test"}
      })
    end

    Process.sleep(50)

    events = EventStore.stream("run:run-1")

    assert Enum.any?(
             events,
             &(&1.event_type == "PhaseNudged" and &1.payload.source == "elixir_overwatch")
           )

    inbox = ProjectionStore.snapshot().inbox_messages |> Map.values()

    assert Enum.any?(
             inbox,
             &(&1.from == "overwatch" and &1.subject == "overwatch nudge: stale phase")
           )
  end
end
