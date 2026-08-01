defmodule ForemanServer.WorkflowInterpreterTest do
  use ExUnit.Case

  alias ForemanServer.{WorkflowInterpreter, WorkflowTemplate.Installer}

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
             WorkflowInterpreter.load_file(Path.join(bundled_workflow_dir(), "default.yaml"))

    assert workflow.name == "default"

    assert workflow.phase_order == [
             "explorer",
             "developer",
             "cicd-developer",
             "cr-developer",
             "merge-resolver",
             "documentation",
             "qa",
             "reviewer",
             "cli-review",
             "finalize",
             "create-pr",
             "pr-wait",
             "merge"
           ]

    assert workflow.models["developer"].default == "MiniMax"
    assert workflow.retry_rules["qa"] == %{retry_with: "developer", retry_on_fail: 2}
    assert workflow.artifacts["qa"] == "{task.projectReportsDir}/QA_REPORT.md"
    assert workflow.mail_hooks["reviewer"].forward_artifact_to == "foreman"
  end

  test "epic workflow preserves PRD/TRD implementation phases and report paths" do
    assert {:ok, workflow} =
             WorkflowInterpreter.load_file(Path.join(bundled_workflow_dir(), "epic.yaml"))

    assert workflow.phase_order == [
             "prd",
             "trd",
             "cicd-developer",
             "cr-developer",
             "merge-resolver",
             "implement",
             "developer",
             "documentation",
             "qa",
             "finalize",
             "create-pr",
             "pr-wait",
             "merge"
           ]

    assert workflow.task_phases == ["developer", "qa"]
    assert workflow.final_phases == ["finalize"]
    assert workflow.artifacts["implement"] == "{task.projectReportsDir}/IMPLEMENT_REPORT.md"

    assert Enum.any?(
             workflow.builtins,
             &(&1.name == "prd" and &1.command =~ "ensemble-create-prd")
           )
  end

  test "load! raises on missing required phase" do
    invalid_workflow =
      Path.join(System.tmp_dir!(), "invalid-workflow-#{System.unique_integer([:positive])}.yaml")

    File.write!(invalid_workflow, """
    name: invalid
    taskPhases:
      - developer
    finalPhases:
      - finalize
    phases:
      - name: developer
        prompt: developer.md
    """)

    on_exit(fn -> File.rm_rf!(invalid_workflow) end)

    assert_raise ArgumentError,
                 ~r/final_phases references missing required phase "finalize"/,
                 fn ->
                   WorkflowInterpreter.load!(invalid_workflow)
                 end
  end

  test "installer copies bundled templates to ~/.foreman/workflows/" do
    with_temporary_home(fn home_dir ->
      workflows_dir = Path.join([home_dir, ".foreman", "workflows"])

      assert {:ok, installed} = Installer.install([])
      assert installed == template_names()

      for name <- template_names() do
        installed_path = Path.join(workflows_dir, "#{name}.yaml")
        bundled_path = Path.join(bundled_workflow_dir(), "#{name}.yaml")

        assert File.read!(installed_path) == File.read!(bundled_path)
        assert %{name: ^name} = WorkflowInterpreter.load!(installed_path)
      end
    end)
  end

  test "installer falls back to remote templates when bundled templates are unavailable" do
    previous_url = Application.get_env(:foreman_server, :workflow_template_url)
    Application.put_env(:foreman_server, :workflow_template_url, "https://example.test/workflows")

    on_exit(fn ->
      if is_nil(previous_url) do
        Application.delete_env(:foreman_server, :workflow_template_url)
      else
        Application.put_env(:foreman_server, :workflow_template_url, previous_url)
      end
    end)

    with_temporary_home(fn home_dir ->
      missing_dir = Path.join(home_dir, "missing-bundle")
      parent = self()

      http_client = fn url ->
        send(parent, {:remote_fetch, url})

        name =
          url
          |> Path.basename(".yaml")

        {:ok,
         """
         name: #{name}
         phases:
           - name: developer
             prompt: developer.md
         """}
      end

      assert {:ok, installed} =
               Installer.install(bundled_dir: missing_dir, http_client: http_client)

      assert installed == template_names()

      for name <- template_names() do
        assert_received {:remote_fetch, fetched_url}
        assert fetched_url == "https://example.test/workflows/#{name}.yaml"

        assert %{name: ^name} =
                 WorkflowInterpreter.load!(
                   Path.join([home_dir, ".foreman", "workflows", "#{name}.yaml"])
                 )
      end
    end)
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

  defp bundled_workflow_dir do
    Application.app_dir(:foreman_server, "priv/defaults/workflows")
  end

  defp template_names do
    ~w(bug default epic feature smoke task)
  end

  defp with_temporary_home(fun) do
    home_dir =
      Path.join(System.tmp_dir!(), "foreman-home-#{System.unique_integer([:positive])}")

    previous_home = System.get_env("HOME")
    File.mkdir_p!(home_dir)
    System.put_env("HOME", home_dir)

    try do
      fun.(home_dir)
    after
      if is_nil(previous_home) do
        System.delete_env("HOME")
      else
        System.put_env("HOME", previous_home)
      end

      File.rm_rf!(home_dir)
    end
  end
end
