defmodule ForemanServer.MCP.ToolsWorkflowWriteTest do
  use ExUnit.Case, async: false

  alias ForemanServer.MCP.Tools

  # Meck helper that uses reset when unload fails (module not mocked)
  defp try_unload(module) do
    try do
      :meck.unload(module)
    rescue
      _ -> :meck.reset(module)
    end
  end

  describe "foreman_workflow_put" do
    test "writes manifest and returns observed: true when catalog reload picks it up" do
      manifest = %{
        "name" => "test-workflow",
        "phases" => [%{"name" => "step1", "command" => "/bin/echo hello"}]
      }

      :meck.new(ForemanServer.Workflow.CatalogWriter, [:non_strict])
      :meck.new(ForemanServer.Workflow.Catalog, [:non_strict])

      :meck.expect(ForemanServer.Workflow.CatalogWriter, :write_manifest, fn "test-workflow.yaml",
                                                                             ^manifest ->
        {:ok, "/tmp/.foreman/workflows/test-workflow.yaml"}
      end)

      :meck.expect(ForemanServer.Workflow.Catalog, :reload, 0, :ok)

      :meck.expect(ForemanServer.Workflow.Catalog, :load, fn "test-workflow.yaml" ->
        {:ok, manifest}
      end)

      try do
        assert Tools.call_tool("foreman_workflow_put", %{
                 name: "test-workflow",
                 manifest: manifest
               }) ==
                 {:ok,
                  %{
                    manifest_path: "workflows/test-workflow.yaml",
                    catalog_path: "/tmp/.foreman/workflows/test-workflow.yaml",
                    observed: true
                  }}
      after
        try_unload(ForemanServer.Workflow.CatalogWriter)
        try_unload(ForemanServer.Workflow.Catalog)
      end
    end

    test "returns observed: false when catalog has not yet reloaded" do
      manifest = %{"name" => "test-workflow", "phases" => []}

      :meck.new(ForemanServer.Workflow.CatalogWriter, [:non_strict])
      :meck.new(ForemanServer.Workflow.Catalog, [:non_strict])

      :meck.expect(ForemanServer.Workflow.CatalogWriter, :write_manifest, fn _, _ ->
        {:ok, "/tmp/.foreman/workflows/test-workflow.yaml"}
      end)

      :meck.expect(ForemanServer.Workflow.Catalog, :reload, 0, :ok)
      :meck.expect(ForemanServer.Workflow.Catalog, :load, fn _ -> {:error, :not_found} end)

      try do
        result =
          Tools.call_tool("foreman_workflow_put", %{
            name: "test-workflow",
            manifest: manifest
          })

        assert match?({:ok, %{observed: false}}, result)
      after
        try_unload(ForemanServer.Workflow.CatalogWriter)
        try_unload(ForemanServer.Workflow.Catalog)
      end
    end

    test "returns NAME_STEM_MISMATCH when manifest name does not match filename" do
      manifest = %{"name" => "wrong-name", "phases" => []}

      assert Tools.call_tool("foreman_workflow_put", %{
               name: "test-workflow",
               manifest: manifest
             }) ==
               {:error,
                %{
                  code: "NAME_STEM_MISMATCH",
                  message:
                    "Manifest name 'wrong-name' does not match filename stem 'test-workflow'"
                }}
    end

    test "returns INVALID_FILENAME for path traversal attempt" do
      manifest = %{"name" => "test", "phases" => []}

      assert Tools.call_tool("foreman_workflow_put", %{
               name: "../etc/passwd",
               manifest: manifest
             }) ==
               {:error,
                %{code: "INVALID_FILENAME", message: "Path separators and '..' are not allowed"}}
    end

    test "returns INVALID_MANIFEST when manifest validation fails" do
      manifest = %{"name" => "test", "phases" => [%{"command" => "echo"}]}

      :meck.new(ForemanServer.Workflow.CatalogWriter, [:non_strict])

      :meck.expect(ForemanServer.Workflow.CatalogWriter, :write_manifest, fn _, _ ->
        {:error, {:unsupported_construct, {:phase_missing_name, 0}}}
      end)

      try do
        assert Tools.call_tool("foreman_workflow_put", %{
                 name: "test",
                 manifest: manifest
               }) ==
                 {:error,
                  %{
                    code: "INVALID_MANIFEST",
                    message:
                      "Manifest validation failed: {:unsupported_construct, {:phase_missing_name, 0}}"
                  }}
      after
        try_unload(ForemanServer.Workflow.CatalogWriter)
      end
    end
  end

  describe "foreman_workflow_delete" do
    test "deletes manifest and returns observed: true when catalog reload drops it" do
      :meck.new(ForemanServer.Workflow.CatalogWriter, [:non_strict])
      :meck.new(ForemanServer.Workflow.Catalog, [:non_strict])

      :meck.expect(
        ForemanServer.Workflow.CatalogWriter,
        :delete_manifest,
        fn "test-workflow.yaml" ->
          :ok
        end
      )

      :meck.expect(ForemanServer.Workflow.Catalog, :reload, 0, :ok)
      :meck.expect(ForemanServer.Workflow.Catalog, :load, fn _ -> {:error, :not_found} end)

      try do
        assert Tools.call_tool("foreman_workflow_delete", %{name: "test-workflow"}) ==
                 {:ok, %{manifest_path: "workflows/test-workflow.yaml", observed: true}}
      after
        try_unload(ForemanServer.Workflow.CatalogWriter)
        try_unload(ForemanServer.Workflow.Catalog)
      end
    end

    test "returns NOT_FOUND when workflow does not exist" do
      :meck.new(ForemanServer.Workflow.CatalogWriter, [:non_strict])

      :meck.expect(
        ForemanServer.Workflow.CatalogWriter,
        :delete_manifest,
        fn "nonexistent.yaml" ->
          {:error, :not_found}
        end
      )

      try do
        assert Tools.call_tool("foreman_workflow_delete", %{name: "nonexistent"}) ==
                 {:error, %{code: "NOT_FOUND", message: "Workflow not found: nonexistent"}}
      after
        try_unload(ForemanServer.Workflow.CatalogWriter)
      end
    end

    test "returns INVALID_FILENAME for path traversal attempt" do
      assert Tools.call_tool("foreman_workflow_delete", %{name: "../etc/passwd"}) ==
               {:error,
                %{code: "INVALID_FILENAME", message: "Path separators and '..' are not allowed"}}
    end
  end
end
