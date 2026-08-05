defmodule ForemanServer.Workflow.PromptRendererTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.PromptRenderer

  @bundled_root Path.join([
                  Application.app_dir(:foreman_server),
                  "priv",
                  "defaults",
                  "workflows",
                  "prompts"
                ])

  @implement_template Path.join(@bundled_root, "implement.md")

  setup do
    sample = %{
      workflow_name: "implement",
      phase_name: "code-generation",
      phase_index: 1,
      task_id: "task-123",
      run_id: "run-abc",
      artifact_path: "/tmp/IMPLEMENT_REPORT.md",
      project_id: "project-xyz",
      workflow_digest: "deadbeef"
    }

    {:ok, sample: sample}
  end

  describe "render/2" do
    test "renders the bundled implement.md with sample context", %{sample: sample} do
      assert File.regular?(@implement_template),
             "expected bundled implement.md at #{@implement_template}"

      assert {:ok, rendered} = PromptRenderer.render(@implement_template, sample)

      # Mission-specific header (NOT the old "Discover relevant context" copy)
      assert rendered =~ "# implement :: code-generation"
      assert rendered =~ ~r/`(?-i:implement)` workflow agent/i
      assert rendered =~ "Phase index: 1"
      assert rendered =~ "Task ID: task-123"
      assert rendered =~ "Run ID: run-abc"
      assert rendered =~ "/tmp/IMPLEMENT_REPORT.md"
      assert rendered =~ "project-xyz"
      assert rendered =~ "deadbeef"
    end

    test "renders every bundled prompt with its manifest header", %{sample: sample} do
      for {filename, manifest_name, phase_name} <- [
            {"discover.md", "discover", "scope-and-explore"},
            {"assess.md", "assess", "impact-analysis"},
            {"plan.md", "plan", "design-and-decompose"},
            {"implement.md", "implement", "code-generation"},
            {"verify.md", "verify", "test-and-validate"},
            {"release.md", "release", "finalize-and-release"}
          ] do
        path = Path.join(@bundled_root, filename)

        assert File.regular?(path), "expected bundled prompt #{filename}"

        context =
          Map.merge(sample, %{
            workflow_name: manifest_name,
            phase_name: phase_name
          })

        assert {:ok, rendered} = PromptRenderer.render(path, context)
        assert rendered =~ "## Mission", "#{filename} must have a Mission section"
        assert rendered =~ "## Output", "#{filename} must have an Output section"
        assert rendered =~ "## Inputs", "#{filename} must have an Inputs section"
        assert rendered =~ ~r/`#{manifest_name}` workflow agent/i
        assert rendered =~ "#{manifest_name} :: #{phase_name}"
      end
    end
  end

  describe "render_string/2" do
    test "substitutes a known variable" do
      assert {:ok, "hello world"} =
               PromptRenderer.render_string("hello {{name}}", %{name: "world"})
    end

    test "leaves unknown variables intact" do
      assert {:ok, "hello {{missing}}"} =
               PromptRenderer.render_string("hello {{missing}}", %{})
    end
  end
end
