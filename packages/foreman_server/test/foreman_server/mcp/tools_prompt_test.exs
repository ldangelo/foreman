defmodule ForemanServer.MCP.ToolsPromptTest do
  use ExUnit.Case, async: false

  alias ForemanServer.MCP.Tools
  alias ForemanServer.MCP.ToolError

  setup do
    prev = Application.get_env(:foreman_server, :mcp, [])
    Application.put_env(:foreman_server, :mcp, Keyword.put(prev, :allow_workflow_writes, true))
    on_exit(fn -> Application.put_env(:foreman_server, :mcp, prev) end)
    :ok
  end

  # Tests for filename/path validation that run without needing the Catalog GenServer.
  # App-dependent tests (prompt get with real read, prompt put with real write) require
  # the application to be running.

  describe "foreman_prompt_get (file validation only)" do
    test "returns INVALID_FILENAME for path traversal attempt" do
      assert Tools.call_tool("foreman_prompt_get", %{name: "../etc/passwd"}) ==
               {:error,
                %ToolError{                  code: "INVALID_FILENAME",
                  message: "Path separators and '..' are not allowed"
                }}
    end

    test "returns INVALID_FILENAME for backslash path attempt" do
      assert Tools.call_tool("foreman_prompt_get", %{name: "subdir\\test.md"}) ==
               {:error,
                %ToolError{                  code: "INVALID_FILENAME",
                  message: "Path separators and '..' are not allowed"
                }}
    end
  end

  describe "foreman_prompt_put (file validation only)" do
    test "returns INVALID_FILENAME for path traversal attempt" do
      assert Tools.call_tool("foreman_prompt_put", %{
               name: "../etc/passwd",
               content: "# Test"
             }) ==
               {:error,
                %ToolError{                  code: "INVALID_FILENAME",
                  message: "Path separators and '..' are not allowed"
                }}
    end

    test "returns INVALID_FILENAME for backslash path attempt" do
      assert Tools.call_tool("foreman_prompt_put", %{
               name: "subdir\\test.md",
               content: "# Test"
             }) ==
               {:error,
                %ToolError{                  code: "INVALID_FILENAME",
                  message: "Path separators and '..' are not allowed"
                }}
    end
  end
end
