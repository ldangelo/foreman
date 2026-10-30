defmodule ForemanServer.ProjectionStoreToolCallsTest do
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    :ok =
      ProjectionStore.apply_events([
        ev("RunStarted", %{run_id: "r1", task_id: "t1", project_id: "p"}),
        ev("RunStarted", %{run_id: "r2", task_id: "t2", project_id: "q"})
      ])

    :ok
  end

  defp ev(type, payload), do: %{event_type: type, payload: payload}

  defp requested(run_id, id, at, extra \\ %{}) do
    ev(
      "ToolCallRequested",
      Map.merge(
        %{run_id: run_id, tool_call_id: id, tool_name: "Write", requested_at: at},
        extra
      )
    )
  end

  defp decided(type, run_id, id),
    do: ev(type, %{run_id: run_id, tool_call_id: id, decided_at: "2026-10-21T00:05:00Z"})

  test "a requested call is pending with the project resolved from the run, oldest first" do
    :ok =
      ProjectionStore.apply_events([
        requested("r1", "later", "2026-10-21T00:02:00Z"),
        requested("r1", "earlier", "2026-10-21T00:01:00Z", %{input_summary: "write a.txt"})
      ])

    assert [
             %{tool_call_id: "earlier", project_id: "p", status: "requested"},
             %{tool_call_id: "later"}
           ] =
             ProjectionStore.pending_approvals("p")

    assert ProjectionStore.pending_approvals_by_run("p") == %{"r1" => 2}
    assert ProjectionStore.pending_approvals("q") == []
  end

  test "approved, denied and expired calls leave the pending set but stay readable with status :all" do
    :ok =
      ProjectionStore.apply_events([
        requested("r1", "a", "2026-10-21T00:01:00Z"),
        requested("r1", "d", "2026-10-21T00:01:01Z"),
        requested("r1", "e", "2026-10-21T00:01:02Z"),
        requested("r1", "f", "2026-10-21T00:01:03Z"),
        decided("ToolCallApproved", "r1", "a"),
        decided("ToolCallDenied", "r1", "d"),
        ev("ToolCallExpired", %{run_id: "r1", tool_call_id: "e", at: "2026-10-21T01:00:00Z"}),
        decided("ToolCallApproved", "r1", "f"),
        ev("ToolCallFinished", %{
          worker_id: "approvals",
          run_id: "r1",
          tool_call_id: "f",
          outcome: "delivered"
        })
      ])

    assert ProjectionStore.pending_approvals("p") == []

    statuses =
      "r1"
      |> ProjectionStore.run_approvals(status: :all)
      |> Map.new(&{&1.tool_call_id, &1.status})

    assert statuses == %{"a" => "approved", "d" => "denied", "e" => "expired", "f" => "finished"}

    # "a" is approved and never settled, so it counts as an undelivered decision
    assert %{approvals: %{"r1" => counts}} = ProjectionStore.needs_you_counts(["r1"])
    assert counts == %{pending: 0, expired: 1, failed_deliveries: 1}

    # What the deliverers recover at startup is exactly the approved and denied calls: a
    # delivered (finished), expired or still-requested call is not "undelivered".
    undelivered =
      for %{run_id: "r1"} = call <- ProjectionStore.undelivered_tool_calls(),
          do: {call.tool_call_id, call.status}

    assert Enum.sort(undelivered) == [{"a", "approved"}, {"d", "denied"}]
  end

  test "needs_you_counts reads many subjects at once, counts only the asked ones and omits empty ones" do
    :ok =
      ProjectionStore.apply_events([
        requested("r1", "x", "2026-10-21T00:01:00Z"),
        requested("r1", "y", "2026-10-21T00:01:01Z"),
        requested("r2", "z", "2026-10-21T00:01:02Z"),
        ev("QuestionOpened", %{
          run_id: "r1",
          question_id: "q1",
          text: "?",
          at: "2026-10-21T00:02:00Z"
        }),
        ev("QuestionOpened", %{
          run_id: "r2",
          question_id: "q2",
          text: "?",
          at: "2026-10-21T00:02:01Z"
        }),
        ev("QuestionExpired", %{
          run_id: "r2",
          question_id: "q2",
          reason: "timeout",
          at: "2026-10-21T00:09:00Z"
        })
      ])

    assert ProjectionStore.needs_you_counts(["r1", "r2", "nobody"]) == %{
             approvals: %{
               "r1" => %{pending: 2, expired: 0, failed_deliveries: 0},
               "r2" => %{pending: 1, expired: 0, failed_deliveries: 0}
             },
             questions: %{
               "r1" => %{open: 1, expired: 0, undelivered: 0},
               "r2" => %{open: 0, expired: 1, undelivered: 0}
             }
           }

    # a subject that was not asked for is not counted
    assert ProjectionStore.needs_you_counts(["r2"]).approvals == %{
             "r2" => %{pending: 1, expired: 0, failed_deliveries: 0}
           }

    assert ProjectionStore.needs_you_counts([]) == %{approvals: %{}, questions: %{}}
  end

  # Run-id membership is a `MapSet` lookup per entry, not a list scan per entry: asking about
  # 20,000 subjects while 300 calls and 300 questions exist must not cost entries x subjects.
  # The bound is the store process's own work (reductions are deterministic, unlike time):
  # the list-membership version needs ~760,000 here, the set version ~45,000.
  test "needs_you_counts membership does not cost entries times subjects" do
    :ok =
      ProjectionStore.apply_events(
        Enum.flat_map(1..300, fn n ->
          [
            requested("m#{n}", "c", "2026-10-21T00:01:00Z"),
            ev("QuestionOpened", %{
              run_id: "m#{n}",
              question_id: "q",
              text: "?",
              at: "2026-10-21T00:02:00Z"
            })
          ]
        end)
      )

    subjects = for n <- 1..20_000, do: "s#{n}"
    store = Process.whereis(ProjectionStore)

    {:reductions, before} = Process.info(store, :reductions)
    assert ProjectionStore.needs_you_counts(subjects) == %{approvals: %{}, questions: %{}}
    {:reductions, finished} = Process.info(store, :reductions)

    assert finished - before < 200_000
  end

  test "a worker's ToolCallFinished (no tool_call_id) never settles a pending call" do
    :ok =
      ProjectionStore.apply_events([
        requested("r1", "a", "2026-10-21T00:01:00Z"),
        ev("ToolCallFinished", %{worker_id: "w", run_id: "r1", tool_name: "Write"})
      ])

    assert [%{tool_call_id: "a", status: "requested"}] = ProjectionStore.pending_approvals("p")
  end

  test "a decision for an unknown call and a malformed request are ignored, not fatal" do
    :ok =
      ProjectionStore.apply_events([
        decided("ToolCallApproved", "r1", "ghost"),
        ev("ToolCallRequested", %{run_id: "r1", bogus: true}),
        requested("r1", "ok", "2026-10-21T00:01:00Z")
      ])

    assert [%{tool_call_id: "ok"}] = ProjectionStore.pending_approvals("p")
    assert ProjectionStore.tool_call("r1", "ghost") == nil
  end

  # `QuestionAnswerUndelivered` marks an answered question whose answer can never be delivered:
  # the question stays answered and nothing else changes, so a log without the event rebuilds
  # exactly as it did.
  test "an undelivered answer marks the answered question and changes nothing else" do
    question = fn id, at ->
      ev("QuestionOpened", %{run_id: "r1", question_id: id, text: "?", at: at})
    end

    answered = fn id, at ->
      ev("QuestionAnswered", %{
        run_id: "r1",
        question_id: id,
        text: "a",
        answered_by: "me",
        at: at
      })
    end

    :ok =
      ProjectionStore.apply_events([
        question.("qa", "2026-10-21T00:02:00Z"),
        question.("qb", "2026-10-21T00:02:01Z"),
        answered.("qa", "2026-10-21T00:03:00Z"),
        answered.("qb", "2026-10-21T00:03:01Z"),
        ev("QuestionAnswerUndelivered", %{
          run_id: "r1",
          question_id: "qa",
          reason: "answer too long to deliver",
          at: "2026-10-21T00:04:00Z"
        })
      ])

    assert %{
             status: "answered",
             answered_by: "me",
             decided_at: "2026-10-21T00:03:00Z",
             reason: nil,
             undelivered_reason: "answer too long to deliver"
           } = ProjectionStore.question("r1", "qa")

    assert %{status: "answered", undelivered_reason: nil} = ProjectionStore.question("r1", "qb")

    # the deliverer's recovery input still lists both; the marker is what tells it to skip qa
    assert Enum.sort(
             for %{question_id: id, undelivered_reason: reason} <-
                   ProjectionStore.answered_questions(),
                 do: {id, reason}
           ) == [{"qa", "answer too long to deliver"}, {"qb", nil}]

    # only the answer with the undelivered marker counts (as `undelivered`); `qb` was
    # delivered, so nothing is waiting on the operator for it
    assert ProjectionStore.needs_you_counts(["r1"]).questions == %{
             "r1" => %{open: 0, expired: 0, undelivered: 1}
           }
  end

  test "a marker for an unknown question and a malformed marker are ignored, not fatal" do
    :ok =
      ProjectionStore.apply_events([
        ev("QuestionAnswerUndelivered", %{
          run_id: "r1",
          question_id: "ghost",
          reason: "r",
          at: "2026-10-21T00:04:00Z"
        }),
        ev("QuestionAnswerUndelivered", %{run_id: "r1", bogus: true})
      ])

    assert ProjectionStore.question("r1", "ghost") == nil
    assert ProjectionStore.answered_questions() == []
  end

  test "the limit bounds a read and replay rebuilds the same projection" do
    events = for n <- 1..5, do: requested("r1", "c#{n}", "2026-10-21T00:0#{n}:00Z")
    :ok = ProjectionStore.apply_events(events)

    assert length(ProjectionStore.project_approvals("p", limit: 2)) == 2

    before = ProjectionStore.pending_approvals("p")
    ProjectionStoreReset.reset!()

    :ok =
      ProjectionStore.apply_events([
        ev("RunStarted", %{run_id: "r1", task_id: "t1", project_id: "p"}) | events
      ])

    assert ProjectionStore.pending_approvals("p") == before
  end
end
