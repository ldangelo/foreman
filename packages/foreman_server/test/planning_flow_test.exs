defmodule ForemanServer.PlanningFlowTest do
  use ExUnit.Case
  import Plug.Conn
  import Plug.Test

  alias ForemanServer.{CommandRouter, EventStore, PlanningFlow, ProjectionStore}

  @router_opts ForemanServer.Http.Router.init([])

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-planning-flow-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    previous_auth_token = Application.get_env(:foreman_server, :auth_token, :__unset__)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    assert :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)

      if previous_auth_token == :__unset__ do
        Application.delete_env(:foreman_server, :auth_token)
      else
        Application.put_env(:foreman_server, :auth_token, previous_auth_token)
      end

      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    {:ok, tmp_dir: tmp_dir}
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
    assert "RunCompleted" in event_types

    assert projection.planning_flows["plan-prd-1"].status == "completed"
    assert projection.runs["plan-prd-1"].status == "completed"
    assert projection.runs["plan-prd-1"].current_phase == nil
    assert projection.runs["plan-prd-1"].phase_status["create-prd"] == "completed"
    assert projection.runs["plan-prd-1"].worker_status["planning-create-prd"] == "completed"
    assert projection.runs["plan-prd-1"].worker_status["planning-refine-prd"] == "completed"
    assert projection.status_counts.active == 0
    assert projection.status_counts.completed == 1
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
    assert {:ok, %{planning: %{kind: "prd", run_id: prd_run_id}}} =
             CommandRouter.handle(%{
               command_id: "plan-command-1",
               command_type: "plan.prd",
               payload: %{
                 run_id: "plan-command-prd",
                 kind: "trd",
                 project_id: "proj-1",
                 description: "Build PRD",
                 output_dir: "docs"
               }
             })

    assert ProjectionStore.snapshot().planning_flows[prd_run_id].planning_kind == "prd"

    assert {:ok, %{planning: %{kind: "trd", run_id: trd_run_id}}} =
             CommandRouter.handle(%{
               command_id: "plan-command-2",
               command_type: "plan.trd",
               payload: %{
                 run_id: "plan-command-trd-alias",
                 kind: "prd",
                 project_id: "proj-1",
                 description: "Build TRD",
                 output_dir: "docs"
               }
             })

    assert ProjectionStore.snapshot().planning_flows[trd_run_id].planning_kind == "trd"

    assert {:ok, %{planning: %{kind: "trd"}}} =
             CommandRouter.handle(%{
               command_id: "plan-command-3",
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

  test "same input reruns without explicit id create unique runs and explicit command ids are retry safe" do
    input = %{
      kind: "prd",
      project_id: "proj-1",
      description: "Repeatable planning",
      output_dir: "docs"
    }

    assert {:ok, first} = PlanningFlow.run(input)
    assert {:ok, second} = PlanningFlow.run(input)
    refute first.run_id == second.run_id

    command = %{
      command_id: "plan-idempotent-command",
      command_type: "PlanningFlowCommand",
      payload: Map.put(input, :kind, "trd")
    }

    assert {:ok, %{planning: first_command}} = CommandRouter.handle(command)
    assert {:ok, %{planning: second_command}} = CommandRouter.handle(command)
    assert first_command.run_id == second_command.run_id
    assert second_command.existing == true
  end

  test "planning projections rebuild after restart", %{tmp_dir: tmp_dir} do
    assert {:ok, %{run_id: run_id}} =
             PlanningFlow.run(%{
               kind: "trd",
               run_id: "plan-restart",
               project_id: "proj-1",
               description: "Restart planning",
               output_dir: "docs"
             })

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    assert :ok = Application.start(:foreman_server)

    projection = ProjectionStore.snapshot()
    assert projection.planning_flows[run_id].status == "completed"
    assert projection.runs[run_id].status == "completed"
    assert projection.status_counts.completed == 1
  end

  test "invalid planning inputs fail before side effects" do
    for input <- [
          %{kind: "prd", project_id: "proj-1"},
          %{kind: "prd", description: "missing project"},
          %{kind: "notes", project_id: "proj-1", description: "bad kind"},
          %{kind: "prd", project_id: "proj-1", description: "bad provider", provider: "other"}
        ] do
      assert {:error, _reason} = PlanningFlow.run(input)
      assert EventStore.all() == []
    end
  end

  test "HTTP command boundary accepts planning commands and validation errors" do
    Application.put_env(:foreman_server, :auth_token, "secret")

    command = %{
      command_id: "http-plan-command",
      command_type: "plan.prd",
      payload: %{
        project_id: "proj-http",
        description: "HTTP planning",
        output_dir: "docs"
      }
    }

    conn =
      :post
      |> conn("/api/v1/commands", Jason.encode!(command))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@router_opts)

    assert conn.status == 202
    run_id = "planning-command-http-plan-command"
    assert ProjectionStore.snapshot().planning_flows[run_id].status == "completed"
    assert ProjectionStore.snapshot().runs[run_id].status == "completed"

    invalid_conn =
      :post
      |> conn(
        "/api/v1/commands",
        Jason.encode!(%{
          command_id: "bad-plan",
          command_type: "plan.trd",
          payload: %{project_id: "proj-http"}
        })
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@router_opts)

    assert invalid_conn.status == 400

    assert Jason.decode!(invalid_conn.resp_body)["error"]["message"] ==
             "missing or invalid description"
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
