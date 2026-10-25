defmodule ForemanServer.MCP.ToolsCoordinatorTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.{CommandRouter, ProjectionStore}
  alias ForemanServer.MCP.{Policy, ToolError, Tools}

  # Pre-existing tools whose names match the forbidden pattern. Reviewed: the
  # only one is run cancellation, which predates the coordinator. Any new
  # (coordinator-related) tool must match nothing; do NOT extend this list to
  # make a new tool pass.
  @forbidden ~r/merge|approve|archive|register|retry|cancel|reset|remove/
  @reviewed_exceptions ["foreman_run_cancel"]

  setup %{tmp_dir: dir} do
    mcp = Application.get_env(:foreman_server, :mcp, [])
    coordinator = Application.get_env(:foreman_server, :coordinator, [])

    on_exit(fn ->
      Application.put_env(:foreman_server, :mcp, mcp)
      Application.put_env(:foreman_server, :coordinator, coordinator)
    end)

    project_id = "mcp-co-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        aggregate_id: "project:#{project_id}",
        payload: %{project_id: project_id, path: dir}
      })

    {:ok, project_id: project_id}
  end

  defp writes(enabled?) do
    config = Application.get_env(:foreman_server, :mcp, [])

    Application.put_env(
      :foreman_server,
      :mcp,
      Keyword.put(config, :allow_workflow_writes, enabled?)
    )
  end

  defp limit(n) do
    config = Application.get_env(:foreman_server, :coordinator, [])

    Application.put_env(
      :foreman_server,
      :coordinator,
      Keyword.put(config, :mcp_messages_per_minute, n)
    )
  end

  test "the message tool is a write tool: hidden and refused without allow_workflow_writes" do
    writes(false)
    names = fn -> Tools.list_tools() |> Policy.list_tools() |> Enum.map(& &1.name) end

    assert "foreman_project_conversation" in names.()
    refute "foreman_project_message" in names.()
    refute Policy.authorized?("foreman_project_message")
    assert Policy.authorized?("foreman_project_conversation")

    writes(true)
    assert "foreman_project_message" in names.()
    assert Policy.authorized?("foreman_project_message")
  end

  test "a refused write leaves the conversation untouched", %{project_id: p} do
    writes(false)

    assert {:error, %ToolError{code: "POLICY_REFUSED"}} =
             Tools.call_tool("foreman_project_message", %{project_id: p, text: "hi"})

    assert {:ok, %{messages: []}} = ProjectionStore.coordinator_conversation(p)
  end

  test "the message tool stores source mcp and is idempotent per message_id", %{project_id: p} do
    writes(true)

    assert {:ok, %{message_id: "m1", seq: seq}} =
             Tools.call_tool("foreman_project_message", %{
               project_id: p,
               text: "please review",
               message_id: "m1"
             })

    assert {:ok, %{message_id: "m1", seq: ^seq}} =
             Tools.call_tool("foreman_project_message", %{
               project_id: p,
               text: "please review",
               message_id: "m1"
             })

    assert {:ok, %{messages: [message]}} = ProjectionStore.coordinator_conversation(p)
    assert message.source == "mcp"
    assert message.role == "operator"
    assert message.seq == seq
  end

  test "the caller cannot choose a source" do
    writes(true)
    schema = Enum.find(Tools.list_tools(), &(&1.name == "foreman_project_message"))
    refute Map.has_key?(schema.inputSchema.properties, "source")
  end

  test "an unknown project is NOT_FOUND" do
    writes(true)

    assert {:error, %ToolError{code: "NOT_FOUND"}} =
             Tools.call_tool("foreman_project_message", %{project_id: "nope", text: "x"})
  end

  test "oversize text is INVALID_PARAMS", %{project_id: p} do
    writes(true)

    assert {:error, %ToolError{code: "INVALID_PARAMS", message: message}} =
             Tools.call_tool("foreman_project_message", %{
               project_id: p,
               text: String.duplicate("a", 16_001)
             })

    assert message =~ "max"
  end

  test "mcp messages are rate limited per project; a repeated id and other projects are not", %{
    project_id: p,
    tmp_dir: dir
  } do
    writes(true)
    limit(2)

    for i <- 1..2 do
      assert {:ok, _} =
               Tools.call_tool("foreman_project_message", %{project_id: p, text: "m#{i}"})
    end

    assert {:error, %ToolError{code: "RATE_LIMITED"}} =
             Tools.call_tool("foreman_project_message", %{project_id: p, text: "m3"})

    assert {:ok, %{messages: messages}} = ProjectionStore.coordinator_conversation(p)
    assert length(messages) == 2

    other = "mcp-co-other-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        aggregate_id: "project:#{other}",
        payload: %{project_id: other, path: dir}
      })

    assert {:ok, _} = Tools.call_tool("foreman_project_message", %{project_id: other, text: "ok"})
  end

  test "non-mcp operator messages do not consume the mcp budget", %{project_id: p} do
    writes(true)
    limit(1)

    {:ok, _} =
      ForemanServer.CommandGateway.dispatch_operator(%{
        command_id: "cli-1",
        aggregate_id: "coordinator:#{p}",
        type: "coordinator.message",
        payload: %{project_id: p, message_id: "cli-1", text: "from cli", source: "cli"}
      })

    assert {:ok, _} = Tools.call_tool("foreman_project_message", %{project_id: p, text: "mcp"})
  end

  test "the read tool returns the whitelisted page plus status", %{project_id: p} do
    writes(true)

    for i <- 1..3 do
      {:ok, _} = Tools.call_tool("foreman_project_message", %{project_id: p, text: "t#{i}"})
    end

    writes(false)

    assert {:ok, result} =
             Tools.call_tool("foreman_project_conversation", %{project_id: p, limit: 2})

    assert result |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
             [
               :has_more,
               :messages,
               :next_cursor,
               :pending_messages,
               :status,
               :truncated_before_seq
             ]

    assert result.has_more
    assert result.status == "idle"
    # no coordinator runs in this test: all three operator messages are still pending
    assert result.pending_messages == 3
    assert Enum.map(result.messages, & &1["text"]) == ["t1", "t2"]

    assert result.messages |> hd() |> Map.keys() |> Enum.sort() ==
             ~w(at kind message_id report_key role seq source suppressed text thread_ref turn_id)

    assert {:ok, rest} =
             Tools.call_tool("foreman_project_conversation", %{
               project_id: p,
               after: result.next_cursor
             })

    assert Enum.map(rest.messages, & &1["text"]) == ["t3"]
    refute rest.has_more
  end

  test "the read tool rejects an out-of-range limit and an unknown project", %{project_id: p} do
    assert {:error, %ToolError{code: "INVALID_PARAMS"}} =
             Tools.call_tool("foreman_project_conversation", %{project_id: p, limit: 0})

    assert {:error, %ToolError{code: "NOT_FOUND"}} =
             Tools.call_tool("foreman_project_conversation", %{project_id: "nope"})
  end

  test "security invariant: no tool name matches a forbidden verb except reviewed exceptions" do
    offenders =
      Tools.list_tools()
      |> Enum.map(& &1.name)
      |> Enum.filter(&Regex.match?(@forbidden, &1))

    assert offenders -- @reviewed_exceptions == []
    assert @reviewed_exceptions -- offenders == []

    for name <- ["foreman_project_message", "foreman_project_conversation"] do
      refute Regex.match?(@forbidden, name)
    end
  end
end
