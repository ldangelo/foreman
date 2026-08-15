defmodule ForemanServer.MCP.ToolsWorkflowWriteTest do
  use ExUnit.Case, async: false

  alias ForemanServer.MCP.Tools

  # NOTE: Tests in this file are designed for --no-start runs.
  # Tests requiring the Catalog GenServer are in tools_workflow_write_integration_test.exs

  describe "foreman_workflow_put" do
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
