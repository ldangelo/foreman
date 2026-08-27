defmodule ForemanServer.MCP.ToolsWorkflowValidateTest do
  use ExUnit.Case, async: false

  alias ForemanServer.MCP.Tools
  alias ForemanServer.MCP.ToolError

  describe "foreman_workflow_validate" do
    test "returns valid: true for a well-formed manifest YAML string" do
      yaml = """
      name: test-workflow
      description: A test workflow
      phases:
        - name: plan
          prompt: Hello {{input.name}}
      """

      assert Tools.call_tool("foreman_workflow_validate", %{manifest: yaml}) ==
               {:ok, %{valid: true}}
    end

    test "returns valid: true for a well-formed manifest map" do
      manifest = %{
        "name" => "test-workflow",
        "description" => "A test workflow",
        "phases" => [%{"name" => "plan", "prompt" => "Hello"}]
      }

      assert Tools.call_tool("foreman_workflow_validate", %{manifest: manifest}) ==
               {:ok, %{valid: true}}
    end

    test "returns INVALID_MANIFEST for YAML with missing required fields" do
      yaml = """
      description: Missing name and phases
      """

      result = Tools.call_tool("foreman_workflow_validate", %{manifest: yaml})

      assert match?({:error, %ToolError{code: "INVALID_MANIFEST"}}, result)
    end

    test "returns INVALID_MANIFEST for phase missing name" do
      yaml = """
      name: test
      phases:
        - prompt: step without name
      """

      result = Tools.call_tool("foreman_workflow_validate", %{manifest: yaml})

      assert match?({:error, %ToolError{code: "INVALID_MANIFEST"}}, result)
    end

    test "returns INVALID_PARAMS when manifest is missing" do
      # A wholly absent required argument is now caught at the dispatch
      # boundary, which names the missing key. The tool body still reports
      # "Expected manifest as a YAML string or map" for a manifest that is
      # present but of the wrong type (see the rejection tests below).
      assert {:error, %ToolError{code: "INVALID_PARAMS", message: message}} =
               Tools.call_tool("foreman_workflow_validate", %{})

      assert message =~ "missing required arguments"
      assert message =~ "manifest"
    end
  end

  describe "foreman_workflow_validate (rejection conditions)" do
    test "returns INVALID_PARAMS for non-string non-map manifest" do
      # Lists are not accepted as manifests
      result = Tools.call_tool("foreman_workflow_validate", %{manifest: ["not", "valid"]})

      assert match?({:error, %ToolError{code: "INVALID_PARAMS"}}, result)
    end

    test "rejects phase that is not a map" do
      yaml = """
      name: test
      phases:
        - just a string
      """

      result = Tools.call_tool("foreman_workflow_validate", %{manifest: yaml})

      assert match?({:error, %ToolError{code: "INVALID_MANIFEST"}}, result)
    end

    test "rejects phase with empty name" do
      yaml = """
      name: test
      phases:
        - name: ""
          prompt: step
      """

      result = Tools.call_tool("foreman_workflow_validate", %{manifest: yaml})

      assert match?({:error, %ToolError{code: "INVALID_MANIFEST"}}, result)
    end

    test "rejects phases that is not a list" do
      yaml = """
      name: test
      phases: not-a-list
      """

      result = Tools.call_tool("foreman_workflow_validate", %{manifest: yaml})

      assert match?({:error, %ToolError{code: "INVALID_MANIFEST"}}, result)
    end
  end
end
