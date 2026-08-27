defmodule ForemanServer.MCP.TransportTest do
  use ExUnit.Case, async: false

  # NOTE: These tests verify the MCP transport layer (TRD-041-TEST).
  # They are designed for --no-start runs (no GenServer startup required).

  alias ForemanServer.MCP
  alias ForemanServer.MCP.Stdio
  alias Anubis.Server.Context
  alias Anubis.Server.Frame

  setup do
    prev = Application.get_env(:foreman_server, :mcp, [])
    Application.put_env(:foreman_server, :mcp, Keyword.put(prev, :allow_workflow_writes, true))
    on_exit(fn -> Application.put_env(:foreman_server, :mcp, prev) end)
    :ok
  end
  describe "Anubis dispatch contract — both transports" do
    # Each assertion below corresponds to a defect that made EVERY tool call
    # fail at runtime while the tool *schemas* still looked correct, so
    # schema-parity tests alone passed throughout.
    # These exercise dispatch wiring, not authentication. `Dispatch.call/4`
    # fails closed on a nil token, so opt into the documented local-dev mode.
    setup do
      prev = Application.get_env(:foreman_server, :mcp, [])
      Application.put_env(:foreman_server, :mcp, Keyword.put(prev, :allow_insecure_local, true))
      on_exit(fn -> Application.put_env(:foreman_server, :mcp, prev) end)
      :ok
    end


    test "tools declare handler: nil so dispatch reaches handle_tool_call/3" do
      # Anubis.Server.Handlers.Tools.forward_to/4 routes to
      # server.handle_tool_call/3 only when handler is nil; a non-nil handler
      # is called as handler.execute/2 — undefined here, and it would skip the
      # auth and policy gates.
      for {label, tools} <- [http: MCP.__components__(:tool), stdio: Stdio.__components__(:tool)],
          tool <- tools do
        assert tool.handler == nil,
               "#{label} tool #{tool.name} must declare handler: nil, got #{inspect(tool.handler)}"
      end
    end

    test "tools declare validate_input so arguments are not discarded" do
      # With validate_input: nil, Anubis's validate_params/3 returns {:ok, %{}}
      # and drops the caller's arguments, so every tool taking a named
      # argument falls through to the call_tool/2 catch-all.
      for {label, tools} <- [http: MCP.__components__(:tool), stdio: Stdio.__components__(:tool)],
          tool <- tools do
        assert is_function(tool.validate_input, 1),
               "#{label} tool #{tool.name} must declare validate_input/1"
      end
    end

    test "validate_input preserves arguments and atomizes schema-declared keys" do
      tool = Enum.find(MCP.__components__(:tool), &(&1.name == "foreman_run_get"))

      assert {:ok, %{run_id: "r-1"}} = tool.validate_input.(%{"run_id" => "r-1"})
    end

    test "tool replies are Anubis.Server.Response structs" do
      # Anubis.Server.Handlers.Tools pattern-matches Anubis.Server.Response.
      # Replying with Anubis.MCP.Response raises CaseClauseError in forward_to/4.
      for {label, mod} <- [http: MCP, stdio: Stdio] do
        assert {:reply, %Anubis.Server.Response{}, _frame} =
                 mod.handle_tool_call("foreman_workflow_list", %{}, Frame.new()),
               "#{label} transport must reply with Anubis.Server.Response"
      end
    end

    test "an unknown tool yields a typed error, never a successful reply" do
      # The old permissive wrap_tool_result/3 catch-all reported unmatched
      # returns to the client as isError: false.
      for {label, mod} <- [http: MCP, stdio: Stdio] do
        assert {:error, %Anubis.MCP.Error{code: "METHOD_NOT_FOUND"}, _frame} =
                 mod.handle_tool_call("no_such_tool", %{}, Frame.new()),
               "#{label} transport must surface unknown tools as an error"
      end
    end

    test "each transport recovers the bearer token from its real frame path" do
      # Both transports previously read fields that do not exist on a Frame
      # (`frame.transport_context` for HTTP, `frame.init_meta` for stdio), so
      # a configured token was silently dropped and every authenticated call
      # was rejected. Anubis carries both on `frame.context`.
      prev = Application.get_env(:foreman_server, :mcp, [])

      Application.put_env(
        :foreman_server,
        :mcp,
        Keyword.put(prev, :allow_insecure_local, false)
      )

      Application.put_env(:foreman_server, :api_bearer_token, "s3cret")

      on_exit(fn ->
        Application.put_env(:foreman_server, :mcp, prev)
        Application.delete_env(:foreman_server, :api_bearer_token)
      end)

      http_frame = %Frame{
        Frame.new()
        | context: %Context{headers: %{"authorization" => "Bearer s3cret"}}
      }

      assert {:reply, %Anubis.Server.Response{}, _} =
               MCP.handle_tool_call("foreman_workflow_list", %{}, http_frame)

      {:ok, stdio_frame} =
        Stdio.init(nil, %Frame{
          Frame.new()
          | context: %Context{init_meta: %{"authorization" => "Bearer s3cret"}}
        })

      assert {:reply, %Anubis.Server.Response{}, _} =
               Stdio.handle_tool_call("foreman_workflow_list", %{}, stdio_frame)
    end

    test "a wrong bearer token is rejected by both transports" do
      prev = Application.get_env(:foreman_server, :mcp, [])

      Application.put_env(
        :foreman_server,
        :mcp,
        Keyword.put(prev, :allow_insecure_local, false)
      )

      Application.put_env(:foreman_server, :api_bearer_token, "s3cret")

      on_exit(fn ->
        Application.put_env(:foreman_server, :mcp, prev)
        Application.delete_env(:foreman_server, :api_bearer_token)
      end)

      http_frame = %Frame{
        Frame.new()
        | context: %Context{headers: %{"authorization" => "Bearer wrong"}}
      }

      assert {:error, %Anubis.MCP.Error{code: "UNAUTHORIZED"}, _} =
               MCP.handle_tool_call("foreman_workflow_list", %{}, http_frame)

      assert {:error, %Anubis.MCP.Error{code: "UNAUTHORIZED"}} =
               Stdio.init(nil, %Frame{
                 Frame.new()
                 | context: %Context{init_meta: %{"authorization" => "Bearer wrong"}}
               })
    end
  end

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
