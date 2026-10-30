defmodule ForemanServer.MCP.ToolsProjectMemoryTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Anubis.Server.Frame
  alias ForemanServer.{CommandRouter, EventStore, MCP, ProjectionStore}
  alias ForemanServer.MCP.{Policy, ToolError, Tools}

  @write_tools ["foreman_project_memory_write", "foreman_project_memory_forget"]
  @read_tools ["foreman_project_memory_list", "foreman_project_memory_read"]

  setup %{tmp_dir: dir} do
    original = Application.get_env(:foreman_server, :mcp, [])
    on_exit(fn -> Application.put_env(:foreman_server, :mcp, original) end)

    project_id = "mcp-pm-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        aggregate_id: "project:#{project_id}",
        payload: %{project_id: project_id, path: dir}
      })

    {:ok, project_id: project_id, dir: dir}
  end

  defp writes(enabled?) do
    config = Application.get_env(:foreman_server, :mcp, [])

    Application.put_env(
      :foreman_server,
      :mcp,
      Keyword.put(config, :allow_workflow_writes, enabled?)
    )
  end

  defp stream(project_id) do
    case EventStore.read_stream_forward("project_memory:#{project_id}", 0, 100) do
      {:ok, events} -> events
      {:error, :stream_not_found} -> []
    end
  end

  test "tools/list shows read tools always and write/forget only when writes are enabled" do
    names = fn -> Tools.list_tools() |> Policy.list_tools() |> Enum.map(& &1.name) end

    writes(false)
    assert @read_tools -- names.() == []
    assert Enum.all?(@write_tools, &(&1 not in names.()))

    writes(true)
    assert @write_tools -- names.() == []
  end

  test "with writes disabled a write is refused by policy and leaves no file or event",
       %{project_id: p, dir: dir} do
    writes(false)

    assert {:error, %ToolError{code: "POLICY_REFUSED"}} =
             Tools.call_tool("foreman_project_memory_write", %{
               project_id: p,
               name: "a",
               content: "x"
             })

    assert {:error, %ToolError{code: "POLICY_REFUSED"}} =
             Tools.call_tool("foreman_project_memory_forget", %{project_id: p, name: "a"})

    refute File.exists?(Path.join(dir, ".foreman/memory/a.md"))
    assert stream(p) == []
  end

  test "write -> list -> read round trip with redaction and agent attribution", %{project_id: p} do
    writes(true)

    assert {:ok, %{name: "deploy", bytes: bytes, redactions: 1, sha256: sha}} =
             Tools.call_tool("foreman_project_memory_write", %{
               project_id: p,
               name: "deploy",
               description: "How we deploy",
               content: "Run make deploy. API_KEY=sk-live-999",
               run_id: "run-42"
             })

    assert bytes > 0 and byte_size(sha) == 64

    assert {:ok,
            %{
              entries: [%{name: "deploy", description: "How we deploy", author_kind: "agent"}],
              index: index
            }} =
             Tools.call_tool("foreman_project_memory_list", %{project_id: p})

    assert index =~ "[deploy](deploy.md) - How we deploy"

    assert {:ok, %{content: content}} =
             Tools.call_tool("foreman_project_memory_read", %{project_id: p, name: "deploy"})

    assert content =~ "Run make deploy."
    refute content =~ "sk-live-999"

    assert [%{author_kind: "agent", author_ref: "run-42"}] = ProjectionStore.project_memory(p)
  end

  test "session_id is the author ref when no run_id is given", %{project_id: p} do
    writes(true)

    {:ok, _} =
      Tools.call_tool("foreman_project_memory_write", %{
        project_id: p,
        name: "a",
        content: "x",
        session_id: "sess-1"
      })

    assert [%{author_ref: "sess-1"}] = ProjectionStore.project_memory(p)
  end

  test "over-cap content and bad names map to INVALID_PARAMS naming the code", %{project_id: p} do
    writes(true)

    assert {:error, %ToolError{code: "INVALID_PARAMS", message: message}} =
             Tools.call_tool("foreman_project_memory_write", %{
               project_id: p,
               name: "big",
               content: String.duplicate("a", 65_537)
             })

    assert message =~ "content_too_large"

    assert {:error, %ToolError{code: "INVALID_PARAMS", message: "name_invalid" <> _}} =
             Tools.call_tool("foreman_project_memory_write", %{
               project_id: p,
               name: "Bad/Name",
               content: "x"
             })
  end

  test "unknown project and unknown topic are NOT_FOUND; archived project write is rejected", %{
    project_id: p
  } do
    writes(true)

    assert {:error, %ToolError{code: "NOT_FOUND", message: "project_not_found" <> _}} =
             Tools.call_tool("foreman_project_memory_list", %{project_id: "nope"})

    assert {:error, %ToolError{code: "NOT_FOUND"}} =
             Tools.call_tool("foreman_project_memory_read", %{project_id: p, name: "ghost"})

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.archive",
        aggregate_id: "project:#{p}",
        payload: %{project_id: p}
      })

    assert {:error, %ToolError{code: "DOMAIN_ERROR", message: "project_archived" <> _}} =
             Tools.call_tool("foreman_project_memory_write", %{
               project_id: p,
               name: "a",
               content: "x"
             })
  end

  test "forget then read is not_found", %{project_id: p} do
    writes(true)

    {:ok, _} =
      Tools.call_tool("foreman_project_memory_write", %{project_id: p, name: "a", content: "x"})

    assert {:ok, %{name: "a", status: "forgotten"}} =
             Tools.call_tool("foreman_project_memory_forget", %{project_id: p, name: "a"})

    assert {:error, %ToolError{code: "NOT_FOUND"}} =
             Tools.call_tool("foreman_project_memory_read", %{project_id: p, name: "a"})
  end

  describe "argument types through the real MCP dispatch path" do
    setup do
      config = Application.get_env(:foreman_server, :mcp, [])
      Application.put_env(:foreman_server, :mcp, Keyword.put(config, :allow_insecure_local, true))
      writes(true)
      :ok
    end

    # Anubis's `validate_input` only renames keys (`ForemanServer.MCP.Dispatch`), so a
    # wrongly typed value reaches the handler exactly as it does in production.
    defp mcp_call(name, arguments) do
      tool = Enum.find(MCP.__components__(:tool), &(&1.name == name))
      {:ok, atomized} = tool.validate_input.(arguments)
      MCP.handle_tool_call(name, atomized, Frame.new())
    end

    test "non-string arguments are INVALID_PARAMS, never a FunctionClauseError", %{
      project_id: p,
      dir: dir
    } do
      cases = [
        {"foreman_project_memory_write", %{"project_id" => p, "name" => "a", "content" => 123},
         "content"},
        {"foreman_project_memory_write", %{"project_id" => p, "name" => 5, "content" => "x"},
         "name"},
        {"foreman_project_memory_write",
         %{"project_id" => p, "name" => "a", "content" => "x", "description" => 5},
         "description"},
        {"foreman_project_memory_write",
         %{"project_id" => p, "name" => "a", "content" => "x", "run_id" => 5}, "run_id"},
        {"foreman_project_memory_write", %{"project_id" => 7, "name" => "a", "content" => "x"},
         "project_id"},
        {"foreman_project_memory_forget", %{"project_id" => p, "name" => 5}, "name"},
        {"foreman_project_memory_forget",
         %{"project_id" => p, "name" => "a", "session_id" => %{}}, "session_id"},
        {"foreman_project_memory_read", %{"project_id" => p, "name" => 5}, "name"},
        {"foreman_project_memory_list", %{"project_id" => 7}, "project_id"}
      ]

      for {tool, arguments, field} <- cases do
        assert {:error,
                %Anubis.MCP.Error{
                  code: -32_602,
                  data: %{code: "INVALID_PARAMS"},
                  message: message
                }, _frame} =
                 mcp_call(tool, arguments)

        assert message == "Tool #{tool} arguments must be strings: #{field}"
      end

      refute File.exists?(Path.join(dir, ".foreman/memory/a.md"))
      assert stream(p) == []
    end

    test "an explicit null description and run_id stay accepted", %{project_id: p} do
      assert {:reply, %Anubis.Server.Response{}, _frame} =
               mcp_call("foreman_project_memory_write", %{
                 "project_id" => p,
                 "name" => "a",
                 "content" => "x",
                 "description" => nil,
                 "run_id" => nil
               })
    end
  end

  test "the write tool's maxLength values follow the configured caps" do
    original = Application.fetch_env!(:foreman_server, :project_memory)
    on_exit(fn -> Application.put_env(:foreman_server, :project_memory, original) end)

    properties = fn ->
      Tools.list_tools()
      |> Enum.find(&(&1.name == "foreman_project_memory_write"))
      |> get_in([:inputSchema, :properties])
    end

    assert %{"description" => %{maxLength: 200}, "content" => %{maxLength: 65_536}} =
             properties.()

    Application.put_env(
      :foreman_server,
      :project_memory,
      Keyword.merge(original, max_description_chars: 17, max_topic_bytes: 4_321)
    )

    assert %{"description" => %{maxLength: 17}, "content" => %{maxLength: 4_321}} =
             properties.()
  end
end
