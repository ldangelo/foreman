defmodule ForemanServer.Overview.ExpiredSignalsTest do
  @moduledoc """
  A thread that is still paused after a tool-call request or an operator question timed out
  undecided waits on the operator with reason `:approval_expired` / `:question_expired`
  (`Overview.Signals` -> `Overview.Group`), and the reason reaches the Overview DTO served by
  `GET /api/projects/:id/overview` and the `foreman_overview` MCP tool.

  Driven by the durable events the timeout policy appends (`ToolCallExpired`,
  `QuestionExpired`) folded into the real `ProjectionStore`.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.MCP.Tools
  alias ForemanServer.{Overview, ProjectionStore}
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "expired-signals-test-token"
  @project "p-expired"
  @now 1_000_000_000

  setup do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)
    ProjectionStoreReset.reset!()

    on_exit(fn ->
      ProjectionStoreReset.reset!()

      if previous == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous)
    end)

    :ok =
      ProjectionStore.apply_events(
        [
          ev("ProjectRegistered", %{
            project_id: @project,
            path: "/tmp/" <> @project,
            task_provider: %{type: "beads"}
          })
        ] ++
          paused_run("appr", expired_tool_call("appr")) ++
          paused_run("ques", expired_question("ques")) ++
          paused_run("plain")
      )

    :ok
  end

  defp ev(type, payload), do: %{event_type: type, payload: payload}

  defp paused_run(run_id, extra \\ []) do
    [
      ev("RunStarted", %{run_id: run_id, task_id: "t-" <> run_id, project_id: @project}),
      ev("RunPaused", %{run_id: run_id}) | extra
    ]
  end

  defp expired_tool_call(run_id) do
    [
      ev("ToolCallRequested", %{
        run_id: run_id,
        tool_call_id: "c-" <> run_id,
        tool_name: "Write",
        requested_at: "2026-10-21T00:01:00Z"
      }),
      ev("ToolCallExpired", %{
        run_id: run_id,
        tool_call_id: "c-" <> run_id,
        reason: "timeout",
        at: "2026-10-21T00:31:00Z"
      })
    ]
  end

  defp expired_question(run_id) do
    [
      ev("QuestionOpened", %{
        run_id: run_id,
        question_id: "q-" <> run_id,
        text: "which database?",
        at: "2026-10-21T00:01:00Z"
      }),
      ev("QuestionExpired", %{
        run_id: run_id,
        question_id: "q-" <> run_id,
        reason: "timeout",
        at: "2026-10-21T00:06:00Z"
      })
    ]
  end

  defp reasons_by_thread(cards), do: Map.new(cards, &{&1.thread_id, &1.reason})

  defp api_get(path) do
    build_conn() |> put_req_header("authorization", "Bearer #{@token}") |> get(path)
  end

  test "a paused thread whose request or question expired waits on you, with its own reason" do
    {:ok, overview} = Overview.build(@project, now_fun: fn -> @now end)

    assert reasons_by_thread(overview.groups.waiting_on_you) == %{
             "run:appr" => :approval_expired,
             "run:ques" => :question_expired,
             "run:plain" => :paused
           }

    assert overview.counts.waiting_on_you == 3
    assert overview.counts.working == 0

    assert overview.attention == %{
             needed: true,
             count: 3,
             reasons: [:approval_expired, :paused, :question_expired]
           }

    assert Overview.attention(@project) == overview.attention
  end

  test "the expiry is history once the thread resumes: it is working again, not waiting on you" do
    :ok =
      ProjectionStore.apply_events([
        ev("RunResumed", %{run_id: "appr"}),
        ev("RunResumed", %{run_id: "ques"})
      ])

    {:ok, overview} = Overview.build(@project, now_fun: fn -> @now end)

    assert reasons_by_thread(overview.groups.waiting_on_you) == %{"run:plain" => :paused}

    assert reasons_by_thread(overview.groups.working) == %{
             "run:appr" => :in_flight,
             "run:ques" => :in_flight
           }

    assert overview.attention == %{needed: true, count: 1, reasons: [:paused]}
  end

  test "a request still pending, or a question still open, outranks the expired one beside it" do
    :ok =
      ProjectionStore.apply_events([
        ev("ToolCallRequested", %{
          run_id: "appr",
          tool_call_id: "c-fresh",
          tool_name: "Write",
          requested_at: "2026-10-21T01:00:00Z"
        }),
        ev("QuestionOpened", %{
          run_id: "ques",
          question_id: "q-fresh",
          text: "and the cache?",
          at: "2026-10-21T01:00:00Z"
        })
      ])

    {:ok, overview} = Overview.build(@project, now_fun: fn -> @now end)

    assert reasons_by_thread(overview.groups.waiting_on_you) == %{
             "run:appr" => :approval,
             "run:ques" => :question,
             "run:plain" => :paused
           }
  end

  test "the DTO carries the expired reasons as strings" do
    {:ok, overview} = Overview.build(@project, now_fun: fn -> @now end)
    dto = Overview.to_dto(overview)

    cards = Map.new(dto["groups"]["waiting_on_you"], &{&1["thread_id"], &1["reason"]})

    assert cards == %{
             "run:appr" => "approval_expired",
             "run:ques" => "question_expired",
             "run:plain" => "paused"
           }

    assert dto["attention"] == %{
             "needed" => true,
             "count" => 3,
             "reasons" => ["approval_expired", "paused", "question_expired"]
           }
  end

  test "GET /api/projects/:id/overview serves the expired reasons" do
    body = json_response(api_get("/api/projects/#{@project}/overview"), 200)

    cards = Map.new(body["groups"]["waiting_on_you"], &{&1["thread_id"], &1["reason"]})

    assert cards == %{
             "run:appr" => "approval_expired",
             "run:ques" => "question_expired",
             "run:plain" => "paused"
           }

    assert body["counts"]["waiting_on_you"] == 3

    assert body["attention"] == %{
             "needed" => true,
             "count" => 3,
             "reasons" => ["approval_expired", "paused", "question_expired"]
           }
  end

  test "foreman_overview serves the expired reasons, per project and in the all-projects lines" do
    assert {:ok, dto} = Tools.call_tool("foreman_overview", %{project_id: @project})

    cards = Map.new(dto["groups"]["waiting_on_you"], &{&1["thread_id"], &1["reason"]})
    assert cards["run:appr"] == "approval_expired"
    assert cards["run:ques"] == "question_expired"

    assert {:ok, %{"projects" => [line]}} = Tools.call_tool("foreman_overview", %{})
    assert line["project_id"] == @project

    assert line["attention"] == %{
             "needed" => true,
             "count" => 3,
             "reasons" => ["approval_expired", "paused", "question_expired"]
           }
  end
end
