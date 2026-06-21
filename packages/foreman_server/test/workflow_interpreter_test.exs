defmodule ForemanServer.WorkflowInterpreterTest do
  use ExUnit.Case

  alias ForemanServer.WorkflowInterpreter

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "foreman-workflow-test-#{System.unique_integer([:positive])}")

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

  test "loads existing YAML workflow preserving order models retries artifacts mail and builtins" do
    assert {:ok, workflow} =
             WorkflowInterpreter.load_file("../../.foreman/workflows/default.yaml")

    assert workflow.name == "default"

    assert workflow.phase_order == [
             "explorer",
             "developer",
             "documentation",
             "qa",
             "reviewer",
             "finalize"
           ]

    assert workflow.models["developer"].default == "MiniMax"
    assert workflow.retry_rules["qa"] == %{retry_with: "developer", retry_on_fail: 3}
    assert workflow.artifacts["qa"] == "{task.projectReportsDir}/QA_REPORT.md"
    assert workflow.mail_hooks["reviewer"].forward_artifact_to == "foreman"
  end

  test "epic workflow preserves PRD/TRD implementation phases and report paths" do
    assert {:ok, workflow} = WorkflowInterpreter.load_file("../../.foreman/workflows/epic.yaml")

    assert ["prd", "trd", "implement" | _] = workflow.phase_order
    assert workflow.task_phases == ["developer", "qa"]
    assert workflow.final_phases == ["finalize"]
    assert workflow.artifacts["implement"] == "{task.projectReportsDir}/IMPLEMENT_REPORT.md"

    assert Enum.any?(
             workflow.builtins,
             &(&1.name == "prd" and &1.command =~ "/ensemble:create-prd")
           )
  end

  test "bash and builtin phases convert output and exit status into phase events" do
    bash = %{name: "smoke", command: "printf ok", artifact: "docs/reports/smoke.txt"}

    assert {:ok, %{event: bash_event, payload: bash_payload}} =
             WorkflowInterpreter.execute_phase("run-workflow", bash)

    assert bash_event.event_type == "PhaseCompleted"
    assert bash_payload.output == "ok"
    assert bash_payload.exit_code == 0
    assert bash_payload.kind == "bash"

    builtin = %{
      name: "prd",
      command: "/ensemble:create-prd Build thing",
      artifact: "docs/PRD/PRD.md"
    }

    assert {:ok, %{event: builtin_event, payload: builtin_payload}} =
             WorkflowInterpreter.execute_phase("run-workflow", builtin)

    assert builtin_event.event_type == "PhaseCompleted"
    assert builtin_payload.kind == "builtin"
    assert builtin_payload.report_paths == ["docs/PRD/PRD.md"]
  end
end
