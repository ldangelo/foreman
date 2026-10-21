defmodule ForemanServer.Overview.Group do
  @moduledoc """
  Pure, total classifier that places a thread in one Overview group.

  `classify/1` takes an `Overview.Input` and returns `{group, reason}`. It reads
  no process, config or clock and never raises: an unknown status is
  `{:idle, :unknown_status}`. Groups and reasons are the public contract used by
  the HTTP/MCP surfaces and, later, notifications.

  Rules, first match wins:

  | # | group | reason | when |
  |---|---|---|---|
  | 1 | `:resolved` | `:resolved` | `resolved?` flag |
  |   |  | `:pr_merged` / `:pr_closed` | `pr_state` merged / closed (closed-without-merge is *classified* resolved; the disposition stays the operator's) |
  |   |  | `:cancelled` | status `cancelled`, `deleted`, `removed` |
  | 2 | `:waiting_on_you` | `:approval` | `pending_approvals > 0` |
  |   |  | `:question` | `open_questions > 0` |
  |   |  | `:blocked` | status `blocked`, `stuck`, `needs_recovery`, `unresponsive` |
  |   |  | `:failed` | status `failed` |
  |   |  | `:conflict` | `pr_state :conflicted` |
  |   |  | `:paused` | status `paused` and `paused_reason` is not `"steer"` |
  |   |  | `:review_not_met` | verdict `not_met` and `pr_state :open` |
  | 3 | `:landing` | `:merge_in_flight` | `pr_state :open` and `merge_gate :approved` |
  | 4 | `:ready_for_review` | `:pr_ready` | `pr_state :open` and `merge_gate :pending` |
  |   |  | `:review_ready` | status `completed`, verdict `met`/`partially_met`, `pr_state :open` |
  | 5 | `:working` | `:in_flight` | status `awaiting_worker`, `in_progress`, `starting`, `running` |
  |   |  | `:steering` | status `paused` with `paused_reason "steer"` |
  | 6 | `:idle` | `:review_undetermined` | completed, open PR, no usable verdict |
  |   |  | `:unknown_status` | anything not recognised |
  |   |  | `:no_pr` | everything else |

  `failure_reason`, `door` and `idle_ms` are accepted for display and future
  rules; no current rule depends on them.
  """

  alias ForemanServer.Overview.Input

  @groups [:ready_for_review, :waiting_on_you, :working, :landing, :idle, :resolved]
  @reasons [
    :resolved,
    :pr_merged,
    :pr_closed,
    :cancelled,
    :approval,
    :question,
    :blocked,
    :failed,
    :conflict,
    :paused,
    :review_not_met,
    :merge_in_flight,
    :pr_ready,
    :review_ready,
    :in_flight,
    :steering,
    :review_undetermined,
    :unknown_status,
    :no_pr
  ]

  @type group :: :ready_for_review | :waiting_on_you | :working | :landing | :idle | :resolved
  @type reason ::
          :resolved
          | :pr_merged
          | :pr_closed
          | :cancelled
          | :approval
          | :question
          | :blocked
          | :failed
          | :conflict
          | :paused
          | :review_not_met
          | :merge_in_flight
          | :pr_ready
          | :review_ready
          | :in_flight
          | :steering
          | :review_undetermined
          | :unknown_status
          | :no_pr

  @blocked ~w(blocked stuck needs_recovery unresponsive)
  @cancelled ~w(cancelled deleted removed)
  @working ~w(awaiting_worker in_progress starting running)
  @known ~w(completed failed paused) ++ @blocked ++ @cancelled ++ @working

  @doc "Groups in display order."
  @spec all() :: [group()]
  def all, do: @groups

  @doc "The closed set of reasons `classify/1` can return."
  @spec reasons() :: [reason()]
  def reasons, do: @reasons

  @spec classify(Input.t()) :: {group(), reason()}
  def classify(%Input{} = i) do
    cond do
      i.resolved? -> {:resolved, :resolved}
      i.pr_state == :merged -> {:resolved, :pr_merged}
      i.pr_state == :closed -> {:resolved, :pr_closed}
      i.status in @cancelled -> {:resolved, :cancelled}
      i.pending_approvals > 0 -> {:waiting_on_you, :approval}
      i.open_questions > 0 -> {:waiting_on_you, :question}
      i.status in @blocked -> {:waiting_on_you, :blocked}
      i.status == "failed" -> {:waiting_on_you, :failed}
      i.pr_state == :conflicted -> {:waiting_on_you, :conflict}
      i.status == "paused" and i.paused_reason != "steer" -> {:waiting_on_you, :paused}
      i.review_verdict == "not_met" and i.pr_state == :open -> {:waiting_on_you, :review_not_met}
      i.pr_state == :open and i.merge_gate == :approved -> {:landing, :merge_in_flight}
      i.pr_state == :open and i.merge_gate == :pending -> {:ready_for_review, :pr_ready}
      reviewed_open_pr?(i) -> {:ready_for_review, :review_ready}
      i.status in @working -> {:working, :in_flight}
      i.status == "paused" -> {:working, :steering}
      i.status not in @known -> {:idle, :unknown_status}
      i.status == "completed" and i.pr_state == :open -> {:idle, :review_undetermined}
      true -> {:idle, :no_pr}
    end
  end

  defp reviewed_open_pr?(%Input{status: "completed", pr_state: :open, review_verdict: verdict}),
    do: verdict in ["met", "partially_met"]

  defp reviewed_open_pr?(_), do: false
end
