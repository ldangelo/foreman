defmodule ForemanServer.Overview.UndeliveredAnswerSignalTest do
  @moduledoc """
  A paused thread whose operator answer was recorded (`QuestionAnswered`) but can never reach
  the agent (`QuestionAnswerUndelivered`) waits on the operator with reason
  `:answer_undelivered` (`Overview.Signals` -> `Overview.Group`), so an operator looking only at
  the Overview sees it. A delivered answer adds no reason, and the reason is history once the
  thread resumes (the operator steers it with a deliverable message).

  Driven by the durable events folded into the real `ProjectionStore`.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.{Overview, ProjectionStore}
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "undelivered-answer-signal-test-token"
  @project "p-undelivered"
  @now 1_000_000_000
  @at "2026-10-21T00:01:00Z"

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
          paused_run("lost", answered_question("lost", undelivered?: true)) ++
          paused_run("sent", answered_question("sent", undelivered?: false))
      )

    :ok
  end

  defp ev(type, payload), do: %{event_type: type, payload: payload}

  defp paused_run(run_id, extra) do
    [
      ev("RunStarted", %{run_id: run_id, task_id: "t-" <> run_id, project_id: @project}),
      ev("RunPaused", %{run_id: run_id}) | extra
    ]
  end

  defp answered_question(run_id, undelivered?: undelivered?) do
    id = "q-" <> run_id

    [
      ev("QuestionOpened", %{run_id: run_id, question_id: id, text: "which database?", at: @at}),
      ev("QuestionAnswered", %{
        run_id: run_id,
        question_id: id,
        text: "postgres",
        answered_by: "me",
        at: @at
      })
    ] ++
      if undelivered? do
        [
          ev("QuestionAnswerUndelivered", %{
            run_id: run_id,
            question_id: id,
            reason: "answer too long to deliver",
            at: @at
          })
        ]
      else
        []
      end
  end

  defp reasons_by_thread(cards), do: Map.new(cards, &{&1.thread_id, &1.reason})

  defp api_get(path) do
    build_conn() |> put_req_header("authorization", "Bearer #{@token}") |> get(path)
  end

  test "a paused thread whose answer never reached the agent waits on you with its own reason" do
    {:ok, overview} = Overview.build(@project, now_fun: fn -> @now end)

    # the delivered answer adds nothing: that thread is just paused
    assert reasons_by_thread(overview.groups.waiting_on_you) == %{
             "run:lost" => :answer_undelivered,
             "run:sent" => :paused
           }

    assert overview.attention == %{
             needed: true,
             count: 2,
             reasons: [:answer_undelivered, :paused]
           }
  end

  test "the reason is history once the thread resumes" do
    :ok = ProjectionStore.apply_events([ev("RunResumed", %{run_id: "lost"})])

    {:ok, overview} = Overview.build(@project, now_fun: fn -> @now end)

    assert reasons_by_thread(overview.groups.waiting_on_you) == %{"run:sent" => :paused}
    assert reasons_by_thread(overview.groups.working) == %{"run:lost" => :in_flight}
  end

  test "the DTO and GET /api/projects/:id/overview carry the reason as a string" do
    {:ok, overview} = Overview.build(@project, now_fun: fn -> @now end)

    dto = Overview.to_dto(overview)
    cards = Map.new(dto["groups"]["waiting_on_you"], &{&1["thread_id"], &1["reason"]})
    assert cards == %{"run:lost" => "answer_undelivered", "run:sent" => "paused"}

    body = json_response(api_get("/api/projects/#{@project}/overview"), 200)
    cards = Map.new(body["groups"]["waiting_on_you"], &{&1["thread_id"], &1["reason"]})
    assert cards == %{"run:lost" => "answer_undelivered", "run:sent" => "paused"}
    assert body["attention"]["reasons"] == ["answer_undelivered", "paused"]
  end
end
