defmodule ForemanServer.Overview.Input do
  @moduledoc """
  Plain inputs to `ForemanServer.Overview.Group.classify/1`.

    * `door` - `:workflow | :jobsite`
    * `status` - raw run/jobsite status string (nil is allowed)
    * `resolved?` - the operator disposition flag
    * `pr_state` - `:open | :merged | :closed | :conflicted | nil`
    * `merge_gate` - `:none | :pending | :approved`
    * `checks_state` - `:none | :pending | :failing | :passing`, the PR watcher's
      folded CI rollup of the open PR (`:none` when unwatched)
    * `review_state` - `:none | :changes_requested | :threads_unresolved`, the PR
      watcher's review rollup of the open PR: `:changes_requested` while the review
      decision is CHANGES_REQUESTED, else `:threads_unresolved` while any review
      thread is unresolved (`:none` when unwatched). Conversation comments are not
      part of it: they have no resolved state, so they could never clear.
    * `pending_approvals`, `open_questions` - counts of requests / questions waiting
      for the operator (E8)
    * `expired_approvals`, `expired_questions` - requests / questions that timed out
      undecided while the thread is still paused
    * `failed_approval_deliveries` - approved calls whose decision never reached
      the agent
    * `undelivered_answers` - answered questions whose answer can never reach the
      agent (`QuestionAnswerUndelivered`) while the thread is still paused
    * `failure_reason` - run failure detail, nil when none
    * `review_verdict` - `"met" | "partially_met" | "not_met" | "undetermined" | nil`
    * `paused_reason` - `"steer"` when a pause is only an operator steer, else nil
    * `idle_ms` - milliseconds since the thread last moved (an input, never read
      from a clock inside the classifier)
  """

  @enforce_keys [:door, :status]
  @type t :: %__MODULE__{
          door: :workflow | :jobsite,
          status: String.t() | nil,
          resolved?: boolean(),
          pr_state: :open | :merged | :closed | :conflicted | nil,
          merge_gate: :none | :pending | :approved,
          checks_state: :none | :pending | :failing | :passing,
          review_state: :none | :changes_requested | :threads_unresolved,
          pending_approvals: non_neg_integer(),
          open_questions: non_neg_integer(),
          expired_approvals: non_neg_integer(),
          expired_questions: non_neg_integer(),
          undelivered_answers: non_neg_integer(),
          failed_approval_deliveries: non_neg_integer(),
          failure_reason: String.t() | nil,
          review_verdict: String.t() | nil,
          paused_reason: String.t() | nil,
          idle_ms: non_neg_integer()
        }
  defstruct [
    :door,
    :status,
    :failure_reason,
    :review_verdict,
    :paused_reason,
    :pr_state,
    resolved?: false,
    merge_gate: :none,
    checks_state: :none,
    review_state: :none,
    pending_approvals: 0,
    open_questions: 0,
    expired_approvals: 0,
    expired_questions: 0,
    undelivered_answers: 0,
    failed_approval_deliveries: 0,
    idle_ms: 0
  ]
end
