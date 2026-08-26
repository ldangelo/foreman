defmodule ForemanServer.MCP.ToolsWorkflowTest do
  use ExUnit.Case, async: false

  alias ForemanServer.MCP.Tools
  alias ForemanServer.ProjectionStore

  setup do
    # Capture current state to restore on exit
    original_state = :sys.get_state(ProjectionStore)

    on_exit(fn ->
      :sys.replace_state(ProjectionStore, fn _ -> original_state end)
      # Unload Meck if active
      try do
        :meck.unload(ForemanServer.Workflow.Catalog)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  describe "foreman_workflow_list" do
    test "returns list of workflows" do
      :meck.new(ForemanServer.Workflow.Catalog, [:non_strict])

      :meck.expect(ForemanServer.Workflow.Catalog, :manifests, 0, [
        "workflow-a.yaml",
        "workflow-b.yaml"
      ])

      try do
        assert Tools.call_tool("foreman_workflow_list", %{}) ==
                 {:ok, ["workflow-a.yaml", "workflow-b.yaml"]}
      after
        :meck.unload(ForemanServer.Workflow.Catalog)
      end
    end
  end

  describe "foreman_workflow_get" do
    test "returns workflow details when found" do
      manifest = %{
        "name" => "workflow-a",
        "description" => "Description A",
        "digest" => "abc123",
        "phases" => [%{"name" => "phase-1", "command" => "echo hello"}]
      }

      :meck.new(ForemanServer.Workflow.Catalog, [:non_strict])

      :meck.expect(ForemanServer.Workflow.Catalog, :load, fn "workflow-a.yaml" ->
        {:ok, manifest}
      end)

      try do
        assert Tools.call_tool("foreman_workflow_get", %{name: "workflow-a"}) ==
                 {:ok,
                  %{
                    name: "workflow-a",
                    description: "Description A",
                    digest: "abc123",
                    phase_count: 1,
                    manifest_path: "workflows/workflow-a.yaml",
                    phases: [%{"name" => "phase-1", "command" => "echo hello"}]
                  }}
      after
        :meck.unload(ForemanServer.Workflow.Catalog)
      end
    end

    test "returns NOT_FOUND when workflow not found" do
      :meck.new(ForemanServer.Workflow.Catalog, [:non_strict])
      :meck.expect(ForemanServer.Workflow.Catalog, :load, fn _ -> {:error, :not_found} end)

      try do
        assert Tools.call_tool("foreman_workflow_get", %{name: "nonexistent-workflow"}) ==
                 {:error,
                  %{code: "NOT_FOUND", message: "Workflow not found: nonexistent-workflow"}}
      after
        :meck.unload(ForemanServer.Workflow.Catalog)
      end
    end
  end
end
