defmodule ForemanServer.Overview.Signals do
  @moduledoc """
  Per-thread "needs you" counts that do not come from the thread read model:
  pending tool-call approvals (E8-S2) and open operator questions (E8-S4).

  Both are read from `ForemanServer.ProjectionStore`, keyed by the thread's
  owning ids: a workflow thread's `run_ids`, or the jobsite id for a jobsite
  thread. Nothing here dispatches a command or touches `Overview.build/2`.
  """

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Threads.Thread

  @type t :: %{pending_approvals: non_neg_integer(), open_questions: non_neg_integer()}

  @doc "Pending approval and open question counts for a thread."
  @spec for_thread(Thread.t()) :: t()
  def for_thread(%Thread{} = thread) do
    subject_ids = subject_ids(thread)
    approvals = ProjectionStore.approval_counts(subject_ids)

    %{pending_approvals: approvals.pending, open_questions: 0}
  end

  defp subject_ids(%Thread{door: :workflow, run_ids: run_ids}), do: run_ids
  defp subject_ids(%Thread{door: :jobsite, id: "jobsite:" <> jobsite_id}), do: [jobsite_id]
  defp subject_ids(%Thread{}), do: []
end
