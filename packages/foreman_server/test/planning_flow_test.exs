defmodule ForemanServer.PlanningFlowTest do
  use ExUnit.Case

  alias ForemanServer.{CommandRouter, EventStore, PlanningFlow, ProjectionStore}

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-planning-flow-test-#{System.unique_integer([:positive])}"
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

    :ok
  end

  test "plan prd executes planning phases through worker event pipeline" do
    assert {:ok, %{run_id: "plan-prd-1", phases: phases}} =
             PlanningFlow.run(%{
               kind: "prd",
               run_id: "plan-prd-1",
               project_id: "proj-1",
               description: "Build planning",
               output_dir: "docs/plans"
             })

    assert Enum.map(phases, & &1.phase_id) == ["create-prd", "refine-prd"]

    event_types = EventStore.all() |> Enum.map(& &1.event_type)
    assert "PlanningFlowStarted" in event_types
    assert "WorkerStarted" in event_types
    assert "PhaseCompleted" in event_types
    assert "PlanningFlowCompleted" in event_types

    projection = ProjectionStore.snapshot()
    assert projection.planning_flows["plan-prd-1"].status == "completed"
    assert projection.runs["plan-prd-1"].phase_status["create-prd"] == "completed"
    assert projection.runs["plan-prd-1"].worker_status["planning-create-prd"] == "running"
  end

  test "planning artifact traceability links are stored on events and task projections" do
    assert {:ok, %{traceability: trace_events, tasks: task_events}} =
             PlanningFlow.run(%{
               kind: "trd",
               run_id: "plan-trd-1",
               project_id: "proj-1",
               description: "Build TRD",
               from_prd: "docs/PRD.md",
               output_dir: "docs/TRD"
             })

    assert Enum.map(trace_events, & &1.event_type) == [
             "PlanningTraceLinked",
             "PlanningTraceLinked"
           ]

    assert Enum.map(task_events, & &1.event_type) == ["TaskCreated", "TaskCreated"]

    projection = ProjectionStore.snapshot()

    assert projection.planning_traceability["plan-trd-1:create-trd"].artifact_path ==
             "docs/TRD/TRD.md"

    task = projection.tasks["plan-plan-trd-1-create-trd"]
    assert task.source == "planning_flow"
    assert task.external_link == "docs/TRD/TRD.md"
    assert task.planning_run_id == "plan-trd-1"
    assert task.planning_kind == "trd"
    assert task.planning_phase_id == "create-trd"
    assert is_binary(task.trace_event_id)
  end

  test "command router supports plan.prd and plan.trd command API aliases" do
    assert {:ok, %{planning: %{kind: "prd"}}} =
             CommandRouter.handle(%{
               command_id: "plan-command-1",
               command_type: "plan.prd",
               payload: %{
                 run_id: "plan-command-prd",
                 project_id: "proj-1",
                 description: "Build PRD",
                 output_dir: "docs"
               }
             })

    assert {:ok, %{planning: %{kind: "trd"}}} =
             CommandRouter.handle(%{
               command_id: "plan-command-2",
               command_type: "PlanningFlowCommand",
               payload: %{
                 kind: "trd",
                 run_id: "plan-command-trd",
                 project_id: "proj-1",
                 description: "Build TRD",
                 output_dir: "docs"
               }
             })
  end

  test "compatibility mode preserves legacy ensemble and skill create-prd commands" do
    assert {:ok, %{phases: [ensemble_phase | _]}} =
             PlanningFlow.run(%{
               kind: "prd",
               run_id: "plan-compat-ensemble",
               project_id: "proj-1",
               description: "Build PRD",
               compatibility_mode: true
             })

    assert ensemble_phase.command == "/ensemble:create-prd"

    assert {:ok, %{phases: [skill_phase | _]}} =
             PlanningFlow.run(%{
               kind: "prd",
               run_id: "plan-compat-skill",
               project_id: "proj-1",
               description: "Build PRD",
               compatibility_mode: true,
               create_prd_command: "/skill:ensemble-create-prd"
             })

    assert skill_phase.command == "/skill:ensemble-create-prd"
  end
end
