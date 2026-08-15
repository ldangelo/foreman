defmodule ForemanServer.MCP.TransportTest do
  use ExUnit.Case, async: false

  # NOTE: These tests verify the MCP transport layer (TRD-041-TEST).
  # They are designed for --no-start runs (no GenServer startup required).

  alias ForemanServer.MCP
  alias ForemanServer.MCP.Stdio

  describe "tool set identity — both transports expose identical tools" do
    test "ForemanServer.MCP and ForemanServer.MCP.Stdio expose the same tool schemas" do
      http_tools = MCP.__components__(:tool)
      stdio_tools = Stdio.__components__(:tool)

      http_names = Enum.map(http_tools, & &1.name) |> Enum.sort()
      stdio_names = Enum.map(stdio_tools, & &1.name) |> Enum.sort()

      assert http_names == stdio_names,
             "HTTP and stdio transports must expose identical tool sets. " <>
               "HTTP: #{inspect(http_names)}, stdio: #{inspect(stdio_names)}"
    end

    test "both transports expose the complete required tool set" do
      required = [
        "foreman_work_get",
        "foreman_run_get",
        "foreman_queue_status",
        "foreman_project_list",
        "foreman_project_get",
        "foreman_workflow_list",
        "foreman_workflow_get",
        "foreman_workflow_validate",
        "foreman_work_submit",
        "foreman_work_cancel",
        "foreman_workflow_put",
        "foreman_workflow_delete"
      ]

      http_tools = MCP.__components__(:tool)
      http_names = Enum.map(http_tools, & &1.name) |> MapSet.new()

      stdio_tools = Stdio.__components__(:tool)
      stdio_names = Enum.map(stdio_tools, & &1.name) |> MapSet.new()

      missing_in_http = required |> MapSet.new() |> MapSet.difference(http_names)
      missing_in_stdio = required |> MapSet.new() |> MapSet.difference(stdio_names)

      assert MapSet.size(missing_in_http) == 0,
             "HTTP transport missing tools: #{inspect(MapSet.to_list(missing_in_http))}"

      assert MapSet.size(missing_in_stdio) == 0,
             "stdio transport missing tools: #{inspect(MapSet.to_list(missing_in_stdio))}"
    end
  end

  describe "MCP.Stdio transport structure" do
    test "Stdio has a valid child_spec for supervision" do
      spec = Stdio.child_spec([])
      assert spec[:id] == Stdio
      assert spec[:type] == :supervisor
      assert is_tuple(spec[:start])
    end

    test "Stdio uses :stdio transport in its child_spec" do
      spec = Stdio.child_spec([])
      # start_args is [ServerModule, opts]
      start_args = elem(spec[:start], 2)
      opts = start_args |> tl() |> hd()
      transport = Keyword.get(opts, :transport)
      assert transport == :stdio,
             "Stdio transport must use :stdio, got: #{inspect(transport)}"
    end
  end

  describe "HTTP transport structure" do
    test "MCP has a valid child_spec for supervision" do
      spec = MCP.child_spec([])
      assert spec[:id] == MCP
      assert spec[:type] == :supervisor
      assert is_tuple(spec[:start])
    end

    test "MCP uses :streamable_http transport in its child_spec" do
      spec = MCP.child_spec([])
      # start_args is [ServerModule, opts]
      start_args = elem(spec[:start], 2)
      opts = start_args |> tl() |> hd()
      transport = Keyword.get(opts, :transport)
      assert transport == :streamable_http,
             "MCP transport must use :streamable_http, got: #{inspect(transport)}"
    end
  end
end
