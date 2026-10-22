defmodule ForemanServer.Overview.ThreadCard do
  @moduledoc """
  One Overview card: a thread plus its classification and the operator actions
  that already exist for it.

  `actions` names existing operator commands only (`run.pause`, `run.cancel`,
  `run.resume`, `thread.steer`, `thread.resolve`, `thread.reopen`). Merging is
  deliberately absent: `hint` carries the text `"operator: foreman run
  approve-merge/merge"` on PR-bearing groups and is not a command link.

  `pr_actions` (see `ForemanServer.Overview.PrActions`) is the workspace's PR
  fix/create buttons with their disabled reasons; it is not part of the HTTP/MCP DTO.
  """

  alias ForemanServer.Overview.{Group, PrActions}
  alias ForemanServer.Threads.Thread

  @enforce_keys [:thread_id, :group, :reason]
  @type t :: %__MODULE__{
          thread_id: String.t(),
          door: Thread.door(),
          title: String.t(),
          status: String.t() | nil,
          branch: String.t() | nil,
          pr_url: String.t() | nil,
          pr_state: atom() | nil,
          merge_gate: atom(),
          last_report: Thread.last_report() | nil,
          failure_reason: String.t() | nil,
          group: Group.group(),
          reason: Group.reason(),
          steering: String.t(),
          actions: [String.t()],
          pr_actions: [PrActions.t()],
          hint: String.t() | nil,
          updated_at: integer() | nil
        }
  defstruct [
    :thread_id,
    :door,
    :title,
    :status,
    :branch,
    :pr_url,
    :pr_state,
    :last_report,
    :failure_reason,
    :group,
    :reason,
    :steering,
    :hint,
    :updated_at,
    merge_gate: :none,
    actions: [],
    pr_actions: []
  ]

  @merge_hint "operator: foreman run approve-merge/merge"

  @doc "Build a card from a thread, its PR/failure view (or nil), its classification and the head run's PR-watch records."
  @spec build(Thread.t(), map() | nil, {Group.group(), Group.reason()}, [map()]) :: t()
  def build(%Thread{} = thread, pr, {group, reason}, watch) do
    %__MODULE__{
      thread_id: thread.id,
      door: thread.door,
      title: thread.title,
      status: thread.status,
      branch: thread.branch,
      pr_url: thread.pr_url,
      pr_state: pr && pr.pr_state,
      merge_gate: (pr && pr.merge_gate) || :none,
      last_report: thread.last_report,
      failure_reason: pr && pr.failure_reason,
      group: group,
      reason: reason,
      steering: thread.steering,
      actions: actions(thread, group, reason),
      pr_actions: if(group == :resolved, do: [], else: PrActions.build(thread, pr, watch)),
      hint: if(group in [:ready_for_review, :landing], do: @merge_hint),
      updated_at: thread.updated_at
    }
  end

  @spec to_dto(t()) :: %{String.t() => term()}
  def to_dto(%__MODULE__{} = card) do
    %{
      "thread_id" => card.thread_id,
      "door" => Atom.to_string(card.door),
      "title" => card.title,
      "status" => card.status,
      "branch" => card.branch,
      "pr_url" => card.pr_url,
      "pr_state" => card.pr_state && Atom.to_string(card.pr_state),
      "merge_gate" => Atom.to_string(card.merge_gate),
      "last_report" => report_dto(card.last_report),
      "failure_reason" => card.failure_reason,
      "group" => Atom.to_string(card.group),
      "reason" => Atom.to_string(card.reason),
      "steering" => card.steering,
      "actions" => card.actions,
      "hint" => card.hint,
      "updated_at" => card.updated_at
    }
  end

  defp report_dto(nil), do: nil

  defp report_dto(report) do
    %{"verdict" => report.verdict, "summary" => report.summary, "at" => report.at}
  end

  defp actions(%Thread{door: :workflow}, :working, _),
    do: ["thread.steer", "run.pause", "run.cancel"]

  defp actions(%Thread{door: :jobsite}, :working, _), do: ["thread.steer"]
  defp actions(_thread, :waiting_on_you, :paused), do: ["run.resume", "thread.resolve"]
  defp actions(_thread, :waiting_on_you, _), do: ["thread.resolve"]
  defp actions(_thread, :idle, _), do: ["thread.resolve"]
  defp actions(_thread, :resolved, _), do: ["thread.reopen"]
  defp actions(_thread, _group, _), do: []
end
