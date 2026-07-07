defmodule ForemanServer.HighMediumAggregateTest do
  use ExUnit.Case

  alias ForemanServer.{AggregateRouter, CommandRouter, EventStore}

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-high-medium-aggregate-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    assert :ok = Application.start(:foreman_server)
    :ok
  end

  test "planning flow aggregate enforces start/trace/complete lifecycle" do
    assert {:error, :planning_flow_not_started} =
             AggregateRouter.route("planning.trace.link", %{flow_id: "plan-1", phase_id: "prd"})

    assert {:ok, started} =
             AggregateRouter.route("planning.start", %{flow_id: "plan-1", project_id: "proj"})

    assert started.event_type == "PlanningFlowStarted"
    assert {:ok, _event} = EventStore.append(started)

    assert {:error, :planning_flow_already_started} =
             AggregateRouter.route("planning.start", %{flow_id: "plan-1", project_id: "proj"})

    assert {:ok, trace} =
             AggregateRouter.route("planning.trace.link", %{flow_id: "plan-1", phase_id: "prd"})

    assert trace.event_type == "PlanningTraceLinked"
    assert {:ok, _event} = EventStore.append(trace)

    assert {:ok, completed} = AggregateRouter.route("planning.complete", %{flow_id: "plan-1"})
    assert completed.event_type == "PlanningFlowCompleted"
    assert {:ok, _event} = EventStore.append(completed)

    assert {:error, :planning_flow_completed} =
             AggregateRouter.route("planning.command", %{flow_id: "plan-1", command: "after"})
  end

  test "tool call aggregate rejects duplicate requests and double terminal events" do
    assert {:error, :tool_call_not_requested} =
             AggregateRouter.route("tool.finish", %{run_id: "run-1", tool_call_id: "tool-1"})

    assert {:ok, requested} =
             AggregateRouter.route("tool.request", %{run_id: "run-1", tool_call_id: "tool-1"})

    assert requested.event_type == "ToolCallRequested"
    assert {:ok, _event} = EventStore.append(requested)

    assert {:error, :tool_call_already_requested} =
             AggregateRouter.route("tool.request", %{run_id: "run-1", tool_call_id: "tool-1"})

    assert {:ok, approved} =
             AggregateRouter.route("tool.approve", %{run_id: "run-1", tool_call_id: "tool-1"})

    assert approved.event_type == "ToolCallApproved"
    assert {:ok, _event} = EventStore.append(approved)

    assert {:ok, finished} =
             AggregateRouter.route("tool.finish", %{run_id: "run-1", tool_call_id: "tool-1"})

    assert finished.event_type == "ToolCallFinished"
    assert {:ok, _event} = EventStore.append(finished)

    assert {:error, {:tool_call_terminal, "finished"}} =
             AggregateRouter.route("tool.deny", %{run_id: "run-1", tool_call_id: "tool-1"})
  end

  test "operator intervention aggregate requires active interruption before resume" do
    assert {:error, :operator_intervention_not_active} =
             AggregateRouter.route("operator.resume", %{run_id: "run-op"})

    assert {:ok, interrupt} = AggregateRouter.route("operator.interrupt", %{run_id: "run-op"})
    assert interrupt.event_type == "HumanInterruptionRecorded"
    assert {:ok, _event} = EventStore.append(interrupt)

    assert {:error, :operator_intervention_active} =
             AggregateRouter.route("operator.needs", %{run_id: "run-op"})

    assert {:ok, resumed} = AggregateRouter.route("operator.resume", %{run_id: "run-op"})
    assert resumed.event_type == "InteractiveRecoveryResumed"
    assert {:ok, _event} = EventStore.append(resumed)

    assert {:error, :operator_intervention_not_active} =
             AggregateRouter.route("operator.resume", %{run_id: "run-op"})
  end

  test "migration import aggregate bounds records to an active import" do
    assert {:error, :migration_import_not_started} =
             AggregateRouter.route("migration.record.import", %{
               import_id: "import-1",
               record_id: "r1"
             })

    assert {:ok, started} =
             AggregateRouter.route("migration.import.start", %{
               import_id: "import-1",
               source: "test"
             })

    assert started.event_type == "MigrationImportStarted"
    assert {:ok, _event} = EventStore.append(started)

    assert {:ok, record} =
             AggregateRouter.route("migration.record.import", %{
               import_id: "import-1",
               record_id: "r1"
             })

    assert record.event_type == "MigrationRecordImported"
    assert {:ok, _event} = EventStore.append(record)

    assert {:error, {:migration_record_already_imported, "r1"}} =
             AggregateRouter.route("migration.record.import", %{
               import_id: "import-1",
               record_id: "r1"
             })

    assert {:ok, completed} =
             AggregateRouter.route("migration.import.complete", %{import_id: "import-1"})

    assert completed.event_type == "MigrationImportCompleted"
    assert {:ok, _event} = EventStore.append(completed)

    assert {:error, :migration_import_completed} =
             AggregateRouter.route("migration.record.import", %{
               import_id: "import-1",
               record_id: "r2"
             })
  end

  test "medium aggregates cover external triggers, reports, and attachments" do
    assert {:ok, trigger} =
             AggregateRouter.route("external.trigger", %{
               trigger_id: "trigger-1",
               source: "github"
             })

    assert trigger.event_type == "ExternalTriggerCommand"
    assert {:ok, _event} = EventStore.append(trigger)

    assert {:error, :external_trigger_already_recorded} =
             AggregateRouter.route("external.trigger", %{trigger_id: "trigger-1"})

    assert {:ok, accepted} = AggregateRouter.route("external.accept", %{trigger_id: "trigger-1"})
    assert accepted.event_type == "CommandAccepted"
    assert {:ok, _event} = EventStore.append(accepted)

    assert {:ok, report} =
             AggregateRouter.route("phase.report.produce", %{
               run_id: "run-r",
               phase_id: "qa",
               report_id: "r1"
             })

    assert report.event_type == "PhaseReportProduced"
    assert {:ok, _event} = EventStore.append(report)

    assert {:ok, verdict} =
             AggregateRouter.route("phase.verdict", %{
               run_id: "run-r",
               phase_id: "qa",
               verdict: "PASS"
             })

    assert verdict.event_type == "PhaseVerdict"
    assert {:ok, _event} = EventStore.append(verdict)

    assert {:error, :phase_verdict_already_recorded} =
             AggregateRouter.route("phase.verdict", %{
               run_id: "run-r",
               phase_id: "qa",
               verdict: "FAIL"
             })

    assert {:ok, attach} =
             AggregateRouter.route("attach.request", %{run_id: "run-a", worker_id: "w1"})

    assert attach.event_type == "AttachRequested"
    assert {:ok, _event} = EventStore.append(attach)

    assert {:error, :attachment_already_requested} =
             AggregateRouter.route("attach.request", %{run_id: "run-a", worker_id: "w1"})
  end

  test "new aggregate routes work through generic command router path" do
    assert {:ok, %{event: %{event_type: "ToolCallRequested"}}} =
             CommandRouter.handle(%{
               command_id: "tool-command-1",
               command_type: "tool.request",
               payload: %{run_id: "run-command", tool_call_id: "tool-command"}
             })
  end
end
