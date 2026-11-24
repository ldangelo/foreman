defmodule ForemanServer.Workflow.RunExecutorPromptSectionTest do
  # TRD-021 regression test: {{#section input.prompt}}...{{/section}} blocks
  # render the inner content when the key is non-empty, and render nothing
  # (remove the entire block including markers) when the key is empty.
  use ExUnit.Case, async: true

  @prompts_dir Path.expand("../../../priv/defaults/workflows/prompts", __DIR__)

  describe "TRD-021: {{#section KEY}}...{{/section}} conditional rendering" do
    test "section is removed when key resolves to empty string" do
      content = "{{#section input.prompt}}\n## Task Prompt\n\n{{input.prompt}}\n{{/section}}"
      assigns = %{"input.prompt" => ""}

      result = render_for_test(content, assigns)

      assert result == ""
    end

    test "section is removed when key is absent from assigns" do
      content = "{{#section input.prompt}}\n## Task Prompt\n\n{{input.prompt}}\n{{/section}}"
      assigns = %{}

      result = render_for_test(content, assigns)

      assert result == ""
    end

    test "section content is rendered when key resolves to non-empty string" do
      content = "{{#section input.prompt}}\n## Task Prompt\n\n{{input.prompt}}\n{{/section}}"
      assigns = %{"input.prompt" => "Fix the login bug"}

      result = render_for_test(content, assigns)

      assert result == "\n## Task Prompt\n\nFix the login bug\n"
    end

    test "empty-prompt rendering of discover.md excludes Task Prompt section" do
      content = File.read!(Path.join(@prompts_dir, "discover.md"))

      assigns = %{
        "artifact_path" => "/tmp/discover.md",
        "phase_index" => "1",
        "phase_name" => "discover",
        "project_id" => "proj-1",
        "run_id" => "run-1",
        "task_id" => "task-1",
        "workflow_digest" => "abc123",
        "workflow_name" => "discover",
        "input.prompt" => "",
        "input.prompt_argument" => "\"\""
      }

      result = render_for_test(content, assigns)

      # The Task Prompt section must be absent when prompt is empty
      refute result =~ "## Task Prompt"
      refute result =~ "{{input.prompt}}"
    end

    test "non-empty-prompt rendering of discover.md includes Task Prompt section" do
      content = File.read!(Path.join(@prompts_dir, "discover.md"))

      assigns = %{
        "artifact_path" => "/tmp/discover.md",
        "phase_index" => "1",
        "phase_name" => "discover",
        "project_id" => "proj-1",
        "run_id" => "run-1",
        "task_id" => "task-1",
        "workflow_digest" => "abc123",
        "workflow_name" => "discover",
        "input.prompt" => "Fix the login bug on line 42",
        "input.prompt_argument" => "\"Fix the login bug on line 42\""
      }

      result = render_for_test(content, assigns)

      assert result =~ "## Task Prompt"
      assert result =~ "Fix the login bug on line 42"
    end

    test "implement.md empty-prompt rendering excludes Task Prompt section" do
      content = File.read!(Path.join(@prompts_dir, "implement.md"))

      assigns = %{
        "artifact_path" => "/tmp/implement.md",
        "phase_index" => "2",
        "phase_name" => "implement",
        "project_id" => "proj-1",
        "run_id" => "run-1",
        "task_id" => "task-1",
        "workflow_digest" => "abc123",
        "workflow_name" => "implement",
        "input.prompt" => "",
        "input.prompt_argument" => "\"\""
      }

      result = render_for_test(content, assigns)

      refute result =~ "## Task Prompt"
      refute result =~ "{{input.prompt}}"
    end

    test "verify.md empty-prompt rendering excludes Task Prompt section" do
      content = File.read!(Path.join(@prompts_dir, "verify.md"))

      assigns = %{
        "artifact_path" => "/tmp/verify.md",
        "phase_index" => "3",
        "phase_name" => "verify",
        "project_id" => "proj-1",
        "run_id" => "run-1",
        "task_id" => "task-1",
        "workflow_digest" => "abc123",
        "workflow_name" => "verify",
        "input.prompt" => "",
        "input.prompt_argument" => "\"\""
      }

      result = render_for_test(content, assigns)

      refute result =~ "## Task Prompt"
      refute result =~ "{{input.prompt}}"
    end

    test "task title and description reach a prompt template and open their own sections" do
      template = """
      {{#section task.title}}
      ## Task Title
      {{task.title}}
      {{/section}}
      {{#section task.description}}
      ## Task Description
      {{task.description}}
      {{/section}}
      {{#section input.prompt}}
      ## Task Prompt
      {{input.prompt}}
      {{/section}}
      """

      result =
        render_for_test(template, %{
          "task.title" => "Fix the widget",
          "task.description" => "Widget rotates counter-clockwise.",
          "input.prompt" => ""
        })

      assert result =~ "## Task Title\nFix the widget\n"
      assert result =~ "## Task Description\nWidget rotates counter-clockwise.\n"
      refute result =~ "## Task Prompt"
      refute result =~ "{{task.title}}"
      refute result =~ "{{task.description}}"
    end

    test "task title and description fall back to empty string and close their sections" do
      template = """
      {{#section task.title}}
      ## Task Title
      {{task.title}}
      {{/section}}
      {{#section task.description}}
      ## Task Description
      {{task.description}}
      {{/section}}
      {{#section input.prompt}}
      ## Task Prompt
      {{input.prompt}}
      {{/section}}
      """

      result =
        render_for_test(template, %{
          "task.title" => "",
          "task.description" => "",
          "input.prompt" => "do the thing"
        })

      refute result =~ "## Task Title"
      refute result =~ "## Task Description"
      assert result =~ "## Task Prompt\ndo the thing\n"
    end

    test "bundled fix.md renders a dispatched title and description and keeps the plan STOP" do
      content = File.read!(Path.join(@prompts_dir, "fix.md"))

      assigns = %{
        "artifact_path" => "/tmp/FIX_REPORT.md",
        "phase_index" => "2",
        "phase_name" => "fix",
        "project_id" => "proj-1",
        "run_id" => "run-1",
        "task_id" => "task-1",
        "workflow_digest" => "abc123",
        "workflow_name" => "fix",
        "input.prompt" => "",
        "input.prompt_argument" => "\"\"",
        "task.title" => "Retries drop the schedule anchor",
        "task.description" => "The anchor is not re-registered after a retry."
      }

      result = render_for_test(content, assigns)

      assert result =~ "## Task Title\n\nRetries drop the schedule anchor\n"
      assert result =~ "## Task Description\n\nThe anchor is not re-registered after a retry.\n"

      # The bundled fix-plan.md must no longer STOP when only a description was dispatched.
      plan = File.read!(Path.join(@prompts_dir, "fix-plan.md"))
      plan_result = render_for_test(plan, assigns)
      assert plan_result =~ "## Task Description\n\nThe anchor is not re-registered after a retry.\n"
      refute plan_result =~ "If there is no Task Prompt section, STOP"
      refute result =~ "## Task Prompt"
      assert result =~ "Blocked: no plan found"
      refute result =~ "blocked on a missing plan alone"
    end
  end

  # Internal test helper — mirrors the logic in RunExecutor.render_prompt_template/4
  defp render_for_test(content, assigns) do
    content
    |> render_sections(assigns)
    |> do_substitution(assigns)
  end

  # Mirrors RunExecutor.render_sections/2
  defp render_sections(content, assigns) do
    # Pattern: {{#section KEY}}...{{/section}}
    pattern = ~r/\{\{#section\s+([A-Za-z0-9_.-]+)\}\}(.*?)\{\{\s*\/section\s*\}\}/s

    Regex.replace(pattern, content, fn _match, key, inner ->
      case Map.get(assigns, key, "") do
        "" -> ""
        _ -> inner
      end
    end)
  end

  defp do_substitution(content, assigns) do
    Regex.replace(~r/\{\{\s*([A-Za-z0-9_.-]+)\s*\}\}/, content, fn _match, key ->
      Map.get(assigns, key, "{{#{key}}}")
    end)
  end
end
