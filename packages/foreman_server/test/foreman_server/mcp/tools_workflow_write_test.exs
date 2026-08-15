defmodule ForemanServer.MCP.ToolsWorkflowWriteTest do
  use ExUnit.Case, async: false

  alias ForemanServer.MCP.Tools

  # Meck helper that gracefully handles already-unloaded modules
  defp safe_unload(module) do
    try do
      :meck.unload(module)
    rescue
      _ -> :meck.reset(module)
    end
  end

  describe "foreman_workflow_put" do
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
                %{
                  code: "INVALID_FILENAME",
                  message: "Path separators and '..' are not allowed"
                }}
    end

    test "returns INVALID_FILENAME for backslash path attempt" do
      manifest = %{"name" => "test", "phases" => []}

      assert Tools.call_tool("foreman_workflow_put", %{
               name: "subdir\\test.yaml",
               manifest: manifest
             }) ==
               {:error,
                %{
                  code: "INVALID_FILENAME",
                  message: "Path separators and '..' are not allowed"
                }}
    end
  end

  describe "foreman_workflow_delete" do
    test "returns INVALID_FILENAME for path traversal attempt" do
      assert Tools.call_tool("foreman_workflow_delete", %{name: "../etc/passwd"}) ==
               {:error,
                %{
                  code: "INVALID_FILENAME",
                  message: "Path separators and '..' are not allowed"
                }}
    end

    test "returns INVALID_FILENAME for backslash path attempt" do
      assert Tools.call_tool("foreman_workflow_delete", %{name: "subdir\\test.yaml"}) ==
               {:error,
                %{
                  code: "INVALID_FILENAME",
                  message: "Path separators and '..' are not allowed"
                }}
    end
  end
end
