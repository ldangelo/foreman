defmodule ForemanServer.MCP.ToolsWorkflowValidateTest do
  use ExUnit.Case, async: false

  alias ForemanServer.MCP.Tools

  describe "foreman_workflow_validate" do
    test "returns valid: true for a well-formed manifest YAML string" do
      yaml = """
      name: test-workflow
      description: A test workflow
      phases:
        - name: plan
          prompt: Hello {{input.name}}
      """

      assert Tools.call_tool("foreman_workflow_validate", %{"manifest" => yaml}) ==
               {:ok, %{valid: true}}
    end

    test "returns valid: true for a well-formed manifest map" do
      manifest = %{
        "name" => "test-workflow",
        "description" => "A test workflow",
        "phases" => [%{"name" => "plan", "prompt" => "Hello"}]
      }

      assert Tools.call_tool("foreman_workflow_validate", %{"manifest" => manifest}) ==
               {:ok, %{valid: true}}
    end

    test "returns INVALID_MANIFEST for YAML with missing required fields" do
      yaml = """
      description: Missing name and phases
      """

      result = Tools.call_tool("foreman_workflow_validate", %{"manifest" => yaml})

      assert match?({:error, %{code: "INVALID_MANIFEST"}}, result)
    end

    test "returns INVALID_MANIFEST for phase missing name" do
      yaml = """
      name: test
      phases:
        - prompt: step without name
      """

      result = Tools.call_tool("foreman_workflow_validate", %{"manifest" => yaml})

      assert match?({:error, %{code: "INVALID_MANIFEST"}}, result)
    end

    test "returns INVALID_PARAMS when manifest is missing" do
      assert Tools.call_tool("foreman_workflow_validate", %{}) ==
               {:error,
                %{
                  code: "INVALID_PARAMS",
                  message: "Expected manifest as a YAML string or map"
                }}
    end
  end

  describe "foreman_workflow_validate (rejection conditions)" do
    test "returns INVALID_PARAMS for non-string non-map manifest" do
      # Lists are not accepted as manifests
      result = Tools.call_tool("foreman_workflow_validate", %{"manifest" => ["not", "valid"]})

      assert match?({:error, %{code: "INVALID_PARAMS"}}, result)
    end

    test "rejects phase that is not a map" do
      yaml = """
      name: test
      phases:
        - just a string
      """

      result = Tools.call_tool("foreman_workflow_validate", %{"manifest" => yaml})

      assert match?({:error, %{code: "INVALID_MANIFEST"}}, result)
    end

    test "rejects phase with empty name" do
      yaml = """
      name: test
      phases:
        - name: ""
          prompt: step
      """

      result = Tools.call_tool("foreman_workflow_validate", %{"manifest" => yaml})

      assert match?({:error, %{code: "INVALID_MANIFEST"}}, result)
    end

    test "rejects phases that is not a list" do
      yaml = """
      name: test
      phases: not-a-list
      """

      result = Tools.call_tool("foreman_workflow_validate", %{"manifest" => yaml})

      assert match?({:error, %{code: "INVALID_MANIFEST"}}, result)
    end
  end
end
