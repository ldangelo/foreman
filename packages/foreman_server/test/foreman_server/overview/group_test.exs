defmodule ForemanServer.Overview.GroupTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ForemanServer.Overview.{Group, Input}

  defp input(fields),
    do: struct!(Input, Keyword.merge([door: :workflow, status: "completed"], fields))

  @rows [
    {[status: "failed", pr_state: :merged], {:resolved, :pr_merged}},
    {[status: "completed", pr_state: :closed], {:resolved, :pr_closed}},
    {[resolved?: true, pending_approvals: 2, status: "in_progress"], {:resolved, :resolved}},
    {[status: "cancelled"], {:resolved, :cancelled}},
    {[status: "deleted"], {:resolved, :cancelled}},
    {[status: "in_progress", pending_approvals: 1], {:waiting_on_you, :approval}},
    {[status: "in_progress", open_questions: 1], {:waiting_on_you, :question}},
    {[status: "in_progress", pending_approvals: 1, open_questions: 1],
     {:waiting_on_you, :approval}},
    {[status: "stuck"], {:waiting_on_you, :blocked}},
    {[status: "needs_recovery"], {:waiting_on_you, :blocked}},
    {[status: "failed", failure_reason: "boom"], {:waiting_on_you, :failed}},
    {[status: "failed"], {:waiting_on_you, :failed}},
    {[status: "completed", pr_state: :conflicted], {:waiting_on_you, :conflict}},
    {[status: "paused"], {:waiting_on_you, :paused}},
    {[status: "completed", pr_state: :open, review_verdict: "not_met"],
     {:waiting_on_you, :review_not_met}},
    {[status: "completed", pr_state: :open, merge_gate: :pending, checks_state: :failing],
     {:waiting_on_you, :ci_failing}},
    {[status: "completed", pr_state: :open, merge_gate: :approved, checks_state: :failing],
     {:waiting_on_you, :ci_failing}},
    {[status: "completed", pr_state: :open, review_verdict: "met", checks_state: :failing],
     {:waiting_on_you, :ci_failing}},
    {[
       status: "completed",
       pr_state: :open,
       merge_gate: :pending,
       review_state: :threads_unresolved
     ], {:waiting_on_you, :review_threads}},
    {[
       status: "completed",
       pr_state: :open,
       merge_gate: :pending,
       review_state: :changes_requested
     ], {:waiting_on_you, :changes_requested}},
    {[
       status: "completed",
       pr_state: :open,
       merge_gate: :approved,
       review_state: :threads_unresolved
     ], {:waiting_on_you, :review_threads}},
    {[
       status: "completed",
       pr_state: :open,
       review_verdict: "met",
       review_state: :threads_unresolved
     ], {:waiting_on_you, :review_threads}},
    {[
       status: "completed",
       pr_state: :open,
       merge_gate: :pending,
       checks_state: :failing,
       review_state: :changes_requested
     ], {:waiting_on_you, :ci_failing}},
    {[status: "completed", pr_state: :open, merge_gate: :pending, review_state: :none],
     {:ready_for_review, :pr_ready}},
    {[status: "completed", pr_state: :merged, review_state: :threads_unresolved],
     {:resolved, :pr_merged}},
    {[status: "completed", pr_state: nil, review_state: :changes_requested], {:idle, :no_pr}},
    {[status: "completed", pr_state: :open, merge_gate: :pending, checks_state: :passing],
     {:ready_for_review, :pr_ready}},
    {[status: "completed", pr_state: :merged, checks_state: :failing], {:resolved, :pr_merged}},
    {[status: "completed", pr_state: :open, merge_gate: :approved], {:landing, :merge_in_flight}},
    {[status: "completed", pr_state: :open, merge_gate: :pending],
     {:ready_for_review, :pr_ready}},
    {[status: "completed", pr_state: :open, review_verdict: "met"],
     {:ready_for_review, :review_ready}},
    {[status: "completed", pr_state: :open, review_verdict: "partially_met"],
     {:ready_for_review, :review_ready}},
    {[status: "in_progress"], {:working, :in_flight}},
    {[status: "awaiting_worker"], {:working, :in_flight}},
    {[door: :jobsite, status: "starting"], {:working, :in_flight}},
    {[door: :jobsite, status: "running"], {:working, :in_flight}},
    {[status: "paused", paused_reason: "steer"], {:working, :steering}},
    {[status: "completed"], {:idle, :no_pr}},
    {[status: "completed", pr_state: :open, review_verdict: "undetermined"],
     {:idle, :review_undetermined}},
    {[status: "completed", pr_state: :open], {:idle, :review_undetermined}},
    {[status: "zzz"], {:idle, :unknown_status}},
    {[status: nil], {:idle, :unknown_status}}
  ]

  for {{fields, expected}, index} <- Enum.with_index(@rows) do
    test "row #{index}: #{inspect(fields)} -> #{inspect(expected)}" do
      assert Group.classify(input(unquote(Macro.escape(fields)))) ==
               unquote(Macro.escape(expected))
    end
  end

  test "a merged PR with an open gate is resolved, not ready for review (precedence 1 over 4)" do
    assert {:resolved, :pr_merged} =
             Group.classify(input(pr_state: :merged, merge_gate: :pending))
  end

  test "a failed thread with an approved gate waits on you rather than landing (2 over 3)" do
    assert {:waiting_on_you, :failed} =
             Group.classify(input(status: "failed", pr_state: :open, merge_gate: :approved))
  end

  test "all/0 is the display order and reasons/0 the closed set" do
    assert Group.all() == [
             :ready_for_review,
             :waiting_on_you,
             :working,
             :landing,
             :idle,
             :resolved
           ]

    assert length(Group.reasons()) == length(Enum.uniq(Group.reasons()))
  end

  property "classify is total and only returns documented groups and reasons" do
    statuses = ~w(awaiting_worker in_progress starting running paused blocked stuck needs_recovery
                  unresponsive failed completed cancelled deleted removed zzz)

    check all(
            status <-
              StreamData.one_of([StreamData.member_of(statuses), StreamData.constant(nil)]),
            pr_state <- StreamData.member_of([nil, :open, :merged, :closed, :conflicted]),
            gate <- StreamData.member_of([:none, :pending, :approved]),
            verdict <-
              StreamData.member_of([nil, "met", "partially_met", "not_met", "undetermined", "?"]),
            approvals <- StreamData.integer(0..2),
            questions <- StreamData.integer(0..2),
            resolved? <- StreamData.boolean(),
            paused_reason <- StreamData.member_of([nil, "steer"]),
            door <- StreamData.member_of([:workflow, :jobsite])
          ) do
      {group, reason} =
        Group.classify(
          input(
            door: door,
            status: status,
            pr_state: pr_state,
            merge_gate: gate,
            review_verdict: verdict,
            pending_approvals: approvals,
            open_questions: questions,
            resolved?: resolved?,
            paused_reason: paused_reason
          )
        )

      assert group in Group.all()
      assert reason in Group.reasons()
    end
  end
end
