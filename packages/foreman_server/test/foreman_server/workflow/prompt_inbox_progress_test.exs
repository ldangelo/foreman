defmodule ForemanServer.Workflow.PromptInboxProgressTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.{Interpreter, PhaseSpec, RunExecutor}

  @workflow_dir Path.expand("../../../priv/defaults/workflows", __DIR__)
  @prompt_dir Path.join(@workflow_dir, "prompts")

  test "bundled prompts include non-blocking inbox progress and Work Log guidance" do
    prompts = Path.wildcard(Path.join(@prompt_dir, "*.md"))
    assert prompts != []

    for path <- prompts do
      assert_progress_contract!(File.read!(path), path)
    end
  end

  test "command-driven prd and fix phases are covered by the inbox progress sidecar" do
    assert_covered_command_phases!(
      "prd.yaml",
      ~w(create-prd refine-prd create-trd refine-trd implement-trd)
    )

    assert_covered_command_phases!("fix.yaml", ~w(fix))
  end

  test "review prompt phases remain prompt-driven and keep inbox progress guidance" do
    for workflow_file <- ~w(prd.yaml fix.yaml) do
      workflow = load_workflow!(workflow_file)

      for phase <- workflow["phases"], phase["name"] in ~w(coderabbit-review repo-rules-review) do
        phase_name = phase["name"]
        refute Map.has_key?(phase, "command")
        assert is_binary(phase["prompt"])
        {:ok, body} = File.read(Path.join(@prompt_dir, phase["prompt"]))
        assert_progress_contract!(body, "#{workflow_file}:#{phase_name}")
      end
    end
  end

  test "command phase sidecar matches prompt progress cadence, safety, and non-blocking terms" do
    body = RunExecutor.__command_phase_inbox_progress_system_prompt_for_test__()
    assert_progress_contract!(body, "command-phase system_prompt")
  end

  test "command phase sidecar is threaded through driver opts without replacing the prompt" do
    state = state_for_workflow("prd")

    phase = %{
      "name" => "create-prd",
      "command" => "/skill:ensemble-create-prd {{input.prompt}} --foreman"
    }

    opts =
      RunExecutor.__maybe_put_command_phase_inbox_system_prompt_for_test__(
        [timeout: 1_000, await_timeout: 1_000, cwd: "/tmp/work"],
        state,
        phase
      )

    assert Keyword.fetch!(opts, :system_prompt) ==
             RunExecutor.__command_phase_inbox_progress_system_prompt_for_test__()

    assert Keyword.fetch!(opts, :cwd) == "/tmp/work"
    refute Keyword.has_key?(opts, :prompt)
  end

  test "dispatch_agent renders slash-command prompt and injects system_prompt sidecar" do
    state = state_for_workflow("prd")

    phase = %{
      "name" => "create-prd",
      "command" => "/skill:ensemble-create-prd {{input.prompt}} --foreman"
    }

    # The rendered prompt must be the slash command, not the original template.
    rendered =
      RunExecutor.__render_command_template_for_test__(
        "/skill:ensemble-create-prd {{input.prompt}} --foreman",
        state,
        phase,
        0
      )

    assert is_binary(rendered)
    assert rendered =~ "/skill:ensemble-create-prd"
    assert rendered =~ "--foreman"

    # system_prompt sidecar must be present in driver_opts for covered phases.
    opts =
      RunExecutor.__maybe_put_command_phase_inbox_system_prompt_for_test__([], state, phase)

    assert Keyword.has_key?(opts, :system_prompt)

    assert RunExecutor.__command_phase_inbox_progress_system_prompt_for_test__() in Keyword.values(
             opts
           )
  end

  test "uncovered command phases do not receive a sidecar" do
    state = state_for_workflow("prd")
    phase = %{"name" => "other", "command" => "/skill:other"}

    refute RunExecutor.__command_phase_inbox_progress_covered_for_test__(state, phase)

    refute Keyword.has_key?(
             RunExecutor.__maybe_put_command_phase_inbox_system_prompt_for_test__(
               [],
               state,
               phase
             ),
             :system_prompt
           )
  end

  defp assert_covered_command_phases!(workflow_file, expected_names) do
    workflow_name = Path.basename(workflow_file, ".yaml")
    workflow = load_workflow!(workflow_file)
    phases = Map.new(workflow["phases"], &{&1["name"], &1})
    state = state_for_workflow(workflow_name)

    for name <- expected_names do
      phase = Map.fetch!(phases, name)
      assert PhaseSpec.normalize(phase).action == :command
      assert RunExecutor.__command_phase_inbox_progress_covered_for_test__(state, phase)
    end
  end

  defp assert_progress_contract!(body, label) do
    assert body =~ "foreman_inbox_send", "#{label} must mention foreman_inbox_send"
    assert body =~ "foreman_task_add_comment", "#{label} must mention foreman_task_add_comment"
    assert body =~ "Work Log", "#{label} must describe task Work Log comments"
    assert body =~ "Use only the tool", "#{label} must avoid direct provider writes"
    assert body =~ "do not run `br`", "#{label} must prohibit direct Beads CLI usage"
    assert body =~ "phase start", "#{label} must mention phase start progress"
    assert body =~ "material milestones", "#{label} must mention material milestone progress"
    assert body =~ "blockers", "#{label} must mention blocker progress"
    assert body =~ "phase completion", "#{label} must mention phase completion progress"
    assert body =~ "Do not send timer-only chatter", "#{label} must avoid timer-only chatter"
    assert body =~ "secrets", "#{label} must prohibit secrets"
    assert body =~ "prompts", "#{label} must prohibit prompts"
    assert body =~ "credentials", "#{label} must prohibit credentials"
    assert body =~ "large logs", "#{label} must prohibit large logs"
    assert body =~ "command output", "#{label} must prohibit command output"
    assert body =~ "continue the phase", "#{label} must be non-blocking on send failures"
  end

  defp load_workflow!(workflow_file) do
    {:ok, workflow} = Interpreter.load(Path.join(@workflow_dir, workflow_file))
    workflow
  end

  defp state_for_workflow(workflow_name) do
    %{
      task: %{
        workflow_snapshot: %{
          "workflow_name" => workflow_name,
          "input" => %{"prompt" => "fix this critical bug"}
        }
      },
      run_id: "run-test",
      artifact_base: "/tmp/foreman-test-artifacts"
    }
  end
end
