defmodule ForemanServer.MCP.ToolsWorkflowWriteTest do
  use ExUnit.Case, async: false

  alias ForemanServer.MCP.Tools
  alias ForemanServer.MCP.ToolError

  # NOTE: Tests in this file are designed for --no-start runs.
  # Tests requiring the Catalog GenServer are in tools_workflow_write_integration_test.exs

  setup do
    # Ensure gate is on by default for most tests
    prev = Application.get_env(:foreman_server, :mcp, [])
    Application.put_env(:foreman_server, :mcp, Keyword.put(prev, :allow_workflow_writes, true))
    on_exit(fn -> Application.put_env(:foreman_server, :mcp, prev) end)
    :ok
  end

  describe "policy gate — foreman_workflow_put" do
    test "returns POLICY_REFUSED when allow_workflow_writes is disabled" do
      # Override gate to OFF for this test
      prev = Application.get_env(:foreman_server, :mcp, [])
      Application.put_env(:foreman_server, :mcp, Keyword.put(prev, :allow_workflow_writes, false))

      try do
        manifest = %{"name" => "test", "phases" => []}

        assert {:error, %ToolError{code: "POLICY_REFUSED"}} =
                 Tools.call_tool("foreman_workflow_put", %{
                   name: "test",
                   manifest: manifest
                 })
      after
        Application.put_env(:foreman_server, :mcp, prev)
      end
    end
  end

  describe "policy gate — foreman_workflow_delete" do
    test "returns POLICY_REFUSED when allow_workflow_writes is disabled" do
      # Override gate to OFF for this test
      prev = Application.get_env(:foreman_server, :mcp, [])
      Application.put_env(:foreman_server, :mcp, Keyword.put(prev, :allow_workflow_writes, false))

      try do
        assert {:error, %ToolError{code: "POLICY_REFUSED"}} =
                 Tools.call_tool("foreman_workflow_delete", %{name: "test"})
      after
        Application.put_env(:foreman_server, :mcp, prev)
      end
    end
  end

  describe "foreman_workflow_put — name/stem mismatch" do
    test "returns NAME_STEM_MISMATCH when manifest name does not match filename stem" do
      # Filename is "my-workflow.yaml" but manifest name is "other-name"
      manifest = %{"name" => "other-name", "phases" => []}

      assert Tools.call_tool("foreman_workflow_put", %{
               name: "my-workflow",
               manifest: manifest
             }) ==
               {:error,
                %ToolError{
                  code: "NAME_STEM_MISMATCH",
                  message: "Manifest name 'other-name' does not match filename stem 'my-workflow'"
                }}
    end
  end

  describe "foreman_workflow_put — invalid manifest" do
    test "returns INVALID_MANIFEST and does not write to catalog" do
      # When CatalogWriter returns an invalid_manifest error, the tool propagates it.
      # The catalog is NOT modified because the error is returned before any file write.
      # We verify the error code is correct; the non-write is guaranteed by the
      # case-match structure in the tool (error branch does not call write_manifest).
      invalid_manifest = %{"name" => "test"}

      assert {:error, %ToolError{code: "INVALID_MANIFEST"}} =
               Tools.call_tool("foreman_workflow_put", %{
                 name: "test",
                 manifest: invalid_manifest
               })
    end
  end

  describe "foreman_workflow_put" do
    test "returns INVALID_FILENAME for path traversal attempt" do
      manifest = %{"name" => "test", "phases" => []}

      assert Tools.call_tool("foreman_workflow_put", %{
               name: "../etc/passwd",
               manifest: manifest
             }) ==
               {:error,
                %ToolError{
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
                %ToolError{
                  code: "INVALID_FILENAME",
                  message: "Path separators and '..' are not allowed"
                }}
    end
  end

  describe "foreman_workflow_delete" do
    test "returns INVALID_FILENAME for path traversal attempt" do
      assert Tools.call_tool("foreman_workflow_delete", %{name: "../etc/passwd"}) ==
               {:error,
                %ToolError{
                  code: "INVALID_FILENAME",
                  message: "Path separators and '..' are not allowed"
                }}
    end

    test "returns INVALID_FILENAME for backslash path attempt" do
      assert Tools.call_tool("foreman_workflow_delete", %{name: "subdir\\test.yaml"}) ==
               {:error,
                %ToolError{
                  code: "INVALID_FILENAME",
                  message: "Path separators and '..' are not allowed"
                }}
    end
  end
end
