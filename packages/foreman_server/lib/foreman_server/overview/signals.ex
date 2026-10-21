defmodule ForemanServer.Overview.Signals do
  @moduledoc """
  Per-thread "needs you" counts that do not come from the thread read model:
  pending tool-call approvals (E8-S2), open operator questions (E8-S4) and, for a
  paused thread, the expired requests and undelivered approvals that explain why
  it is still waiting (E8-S5).

  Both are read from `ForemanServer.ProjectionStore`, keyed by the thread's
  owning ids: a workflow thread's `run_ids`, or the jobsite id for a jobsite
  thread. Nothing here dispatches a command or touches `Overview.build/2`.
  """

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Threads.Thread

  @type t :: %{
          pending_approvals: non_neg_integer(),
          open_questions: non_neg_integer(),
          expired_approvals: non_neg_integer(),
          expired_questions: non_neg_integer(),
          failed_approval_deliveries: non_neg_integer()
        }

  @doc "Pending approval and open question counts for a thread."
  @spec for_thread(Thread.t()) :: t()
  def for_thread(%Thread{} = thread) do
    subject_ids = subject_ids(thread)
    approvals = ProjectionStore.approval_counts(subject_ids)
    questions = ProjectionStore.question_counts(subject_ids)

    # Expired requests and undelivered approvals matter only while the thread is
    # still stuck (`paused`): once it resumes they are history, not "waiting on you".
    stuck? = thread.status == "paused"

    %{
      pending_approvals: approvals.pending,
      open_questions: questions.open,
      expired_approvals: if(stuck?, do: approvals.expired, else: 0),
      expired_questions: if(stuck?, do: questions.expired, else: 0),
      failed_approval_deliveries: if(stuck?, do: approvals.failed_deliveries, else: 0)
    }
  end

  defp subject_ids(%Thread{door: :workflow, run_ids: run_ids}), do: run_ids
  defp subject_ids(%Thread{door: :jobsite, id: "jobsite:" <> jobsite_id}), do: [jobsite_id]
  defp subject_ids(%Thread{}), do: []
end
