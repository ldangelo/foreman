defmodule ForemanServer.Overview.SignalsTest do
  @moduledoc """
  `Overview.Signals`: the per-thread needs-you counts (pending and expired tool-call
  requests, undelivered approvals, open and expired questions), read for all of a project's
  threads together instead of once per thread.

  Driven by durable events folded into the real `ProjectionStore`.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.{Overview, ProjectionStore}
  alias ForemanServer.Overview.Signals
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Threads.Thread

  @project "p-signals"
  @at "2026-10-21T00:01:00Z"

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  defp ev(type, payload), do: %{event_type: type, payload: payload}

  defp run(run_id, extra \\ []) do
    [ev("RunStarted", %{run_id: run_id, task_id: "t-" <> run_id, project_id: @project}) | extra]
  end

  defp paused(run_id), do: ev("RunPaused", %{run_id: run_id})

  defp requested(run_id, id) do
    ev("ToolCallRequested", %{
      run_id: run_id,
      tool_call_id: id,
      tool_name: "Write",
      requested_at: @at
    })
  end

  defp approved(run_id, id),
    do: ev("ToolCallApproved", %{run_id: run_id, tool_call_id: id, decided_at: @at})

  defp finished(run_id, id, outcome) do
    ev("ToolCallFinished", %{
      worker_id: "approvals",
      run_id: run_id,
      tool_call_id: id,
      outcome: outcome
    })
  end

  defp expired(run_id, id),
    do: ev("ToolCallExpired", %{run_id: run_id, tool_call_id: id, reason: "timeout", at: @at})

  defp asked(run_id, id),
    do: ev("QuestionOpened", %{run_id: run_id, question_id: id, text: "which?", at: @at})

  defp question_expired(run_id, id),
    do: ev("QuestionExpired", %{run_id: run_id, question_id: id, reason: "timeout", at: @at})

  defp answered(run_id, id) do
    ev("QuestionAnswered", %{
      run_id: run_id,
      question_id: id,
      text: "a",
      answered_by: "me",
      at: @at
    })
  end

  defp undelivered(run_id, id) do
    ev("QuestionAnswerUndelivered", %{
      run_id: run_id,
      question_id: id,
      reason: "answer too long to deliver",
      at: @at
    })
  end

  defp workflow(run_ids, status) do
    %Thread{
      id: "run:" <> hd(run_ids),
      door: :workflow,
      project_id: @project,
      title: "thread",
      status: status,
      run_ids: run_ids
    }
  end

  defp jobsite(jobsite_id) do
    %Thread{
      id: "jobsite:" <> jobsite_id,
      door: :jobsite,
      project_id: @project,
      title: "jobsite",
      status: "running"
    }
  end

  defp zero do
    %{
      pending_approvals: 0,
      open_questions: 0,
      expired_approvals: 0,
      expired_questions: 0,
      undelivered_answers: 0,
      failed_approval_deliveries: 0
    }
  end

  describe "for_threads/1" do
    setup do
      :ok =
        ProjectionStore.apply_events(
          # r1 and its older run r1b are one thread: their counts add up
          # r2 is stuck: an expired request, a decision that was never settled, a delivery
          # that failed, an expired question, and one request that was delivered
          # a jobsite thread is counted under its jobsite id
          run("r1") ++
            run("r1b") ++
            [requested("r1", "a"), requested("r1b", "b"), asked("r1", "q1")] ++
            run("r2", [paused("r2")]) ++
            [
              requested("r2", "e"),
              expired("r2", "e"),
              requested("r2", "u"),
              approved("r2", "u"),
              requested("r2", "f"),
              approved("r2", "f"),
              finished("r2", "f", "delivery_failed: :no_live_request"),
              requested("r2", "ok"),
              approved("r2", "ok"),
              finished("r2", "ok", "delivered"),
              asked("r2", "q2"),
              question_expired("r2", "q2"),
              # an answer that never reached the agent, and one that did
              asked("r2", "q3"),
              answered("r2", "q3"),
              undelivered("r2", "q3"),
              asked("r2", "q4"),
              answered("r2", "q4")
            ] ++
            [requested("js1", "j"), asked("js1", "qj")]
        )

      :ok
    end

    test "counts each thread from its own run ids, or its jobsite id" do
      threads = [workflow(["r1", "r1b"], "in_progress"), jobsite("js1")]

      assert Signals.for_threads(threads) == %{
               "run:r1" => %{zero() | pending_approvals: 2, open_questions: 1},
               "jobsite:js1" => %{zero() | pending_approvals: 1, open_questions: 1}
             }
    end

    test "expired requests and undelivered approvals explain a PAUSED thread only" do
      stuck = Signals.for_threads([workflow(["r2"], "paused")])

      assert stuck["run:r2"] == %{
               zero()
               | expired_approvals: 1,
                 expired_questions: 1,
                 undelivered_answers: 1,
                 failed_approval_deliveries: 2
             }

      running = Signals.for_threads([workflow(["r2"], "in_progress")])
      assert running["run:r2"] == zero()
    end

    test "a thread nothing was asked of has all-zero counts" do
      assert Signals.for_threads([workflow(["nobody"], "in_progress")]) == %{
               "run:nobody" => zero()
             }

      assert Signals.for_threads([]) == %{}
    end
  end

  describe "a malformed thread" do
    # `Thread` has two doors and builds the id prefix of each; a value that is neither is a bug
    # upstream, so it must fail here instead of counting as "nothing is waiting".
    test "is a FunctionClauseError, never an all-zero count" do
      unknown_door = %Thread{id: "x", door: :other, project_id: nil, title: "t", status: nil}

      unprefixed_jobsite = %Thread{
        id: "js1",
        door: :jobsite,
        project_id: nil,
        title: "t",
        status: nil
      }

      for thread <- [unknown_door, unprefixed_jobsite] do
        assert_raise FunctionClauseError, fn -> Signals.for_threads([thread]) end
      end
    end
  end

  describe "classifying a project" do
    test "reads the needs-you counts once, not once per thread" do
      :ok =
        ProjectionStore.apply_events(
          [ev("ProjectRegistered", %{project_id: @project, path: "/tmp/" <> @project})] ++
            Enum.flat_map(1..5, fn n ->
              run("r#{n}", [requested("r#{n}", "c#{n}"), asked("r#{n}", "q#{n}")])
            end)
        )

      store = Process.whereis(ProjectionStore)
      1 = :erlang.trace(store, true, [:receive, {:tracer, self()}])

      try do
        assert {:ok, overview} = Overview.build(@project)
        assert overview.counts.waiting_on_you == 5
      after
        :erlang.trace(store, false, [:receive])
      end

      # Whatever the read is called, two per thread (approvals, then questions) is the cost
      # this finding removed: ten for five threads.
      assert count_reads(store) == 1
    end
  end

  # The counting calls the ProjectionStore received while it was traced.
  defp count_reads(store, acc \\ 0) do
    receive do
      {:trace, ^store, :receive, {:"$gen_call", _from, {kind, _ids}}}
      when kind in [:approval_counts, :question_counts, :needs_you_counts] ->
        count_reads(store, acc + 1)

      {:trace, ^store, :receive, _other} ->
        count_reads(store, acc)
    after
      0 -> acc
    end
  end
end
