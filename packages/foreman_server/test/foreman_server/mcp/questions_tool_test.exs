defmodule ForemanServer.MCP.QuestionsToolTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Anubis.Server.{Frame, Response}
  alias ForemanServer.MCP
  alias ForemanServer.MCP.{Policy, ToolError, Tools}
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Questions.{DTO, Listing}
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload: %{project_id: "mq", path: "/tmp/mq", task_provider: %{type: "beads"}}
        },
        %{event_type: "RunStarted", payload: %{run_id: "mqr1", task_id: "t", project_id: "mq"}},
        %{
          event_type: "QuestionOpened",
          payload: %{
            run_id: "mqr1",
            question_id: "q-gone",
            text: "old?",
            at: "2026-10-21T00:00:00Z"
          }
        },
        %{
          event_type: "QuestionExpired",
          payload: %{
            run_id: "mqr1",
            question_id: "q-gone",
            reason: "timeout",
            at: "2026-10-21T00:06:00Z"
          }
        },
        %{
          event_type: "QuestionOpened",
          payload: %{
            run_id: "mqr1",
            question_id: "q-open",
            agent_id: "a1",
            text: "which database?",
            at: "2026-10-21T00:01:00Z"
          }
        }
      ])

    :ok
  end

  test "foreman_questions_list is a read tool, authorized under the read-only policy" do
    assert "foreman_questions_list" in (Tools.list_tools()
                                        |> Policy.list_tools()
                                        |> Enum.map(& &1.name))

    assert Policy.authorized?("foreman_questions_list")
  end

  test "returns a typed Listing: the open questions by default, every question with status all" do
    assert {:ok, %Listing{questions: [%DTO{} = open]}} =
             Tools.call_tool("foreman_questions_list", %{project_id: "mq"})

    assert open.question_id == "q-open"
    assert open.actions == ["question.answer"]

    assert {:ok, %Listing{questions: [%DTO{question_id: "q-gone", actions: []}, ^open]}} =
             Tools.call_tool("foreman_questions_list", %{project_id: "mq", status: "all"})
  end

  test "the listing enforces its key, so a payload without questions cannot be built" do
    assert_raise ArgumentError, ~r/questions/, fn -> struct!(Listing, []) end
  end

  test "the wire payload of the real MCP tool call equals the HTTP endpoint's body" do
    mcp = Application.get_env(:foreman_server, :mcp, [])
    token = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :mcp, Keyword.put(mcp, :allow_insecure_local, true))

    on_exit(fn ->
      Application.put_env(:foreman_server, :mcp, mcp)

      if token == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, token)
    end)

    tool = Enum.find(MCP.__components__(:tool), &(&1.name == "foreman_questions_list"))
    {:ok, args} = tool.validate_input.(%{"project_id" => "mq", "status" => "all"})

    assert {:reply, %Response{} = response, _frame} =
             MCP.handle_tool_call("foreman_questions_list", args, Frame.new())

    assert %{"content" => [%{"text" => text}], "isError" => false} =
             Response.to_protocol(response)

    wire = Jason.decode!(text)

    assert %{"questions" => [%{"question_id" => "q-gone"}, %{"question_id" => "q-open"} = open]} =
             wire

    assert %{"run_id" => "mqr1", "status" => "open", "actions" => ["question.answer"]} = open
    assert %{"question.answer" => %{"type" => "question.answer"}} = open["command_hints"]

    Application.put_env(:foreman_server, :api_bearer_token, "questions-tool-test")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer questions-tool-test")
      |> get("/api/projects/mq/questions?status=all")

    assert json_response(conn, 200) == wire
  end

  test "an unknown project is NOT_FOUND; a missing project_id or a bad status is INVALID_PARAMS" do
    assert {:error, %ToolError{code: "NOT_FOUND"}} =
             Tools.call_tool("foreman_questions_list", %{project_id: "nope"})

    for args <- [%{}, %{project_id: "mq", status: "x"}] do
      assert {:error, %ToolError{code: "INVALID_PARAMS"}} =
               Tools.call_tool("foreman_questions_list", args)
    end
  end
end
