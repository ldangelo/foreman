defmodule ForemanServer.Overview.Signals do
  @moduledoc """
  Per-thread "needs you" counts that do not come from the thread read model:
  pending tool-call approvals (E8-S2), open operator questions (E8-S4) and, for a
  paused thread, the expired requests and undelivered approvals that explain why
  it is still waiting (E8-S5).

  All of them are read from `ForemanServer.ProjectionStore`, keyed by the thread's
  owning ids: a workflow thread's `run_ids`, or the jobsite id for a jobsite
  thread. `for_threads/1` serves any number of threads with ONE projection read
  (`ProjectionStore.needs_you_counts/1`), so classifying a project costs one pass
  over the tool calls and one over the questions, not two per thread. Nothing here
  dispatches a command or touches `Overview.build/2`.
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

  @no_approvals %{pending: 0, expired: 0, failed_deliveries: 0}
  @no_questions %{open: 0, expired: 0}

  @doc """
  Pending approval and open question counts for each of `threads`, as
  `%{thread.id => t()}`, from one read of the projection. A thread that is neither a
  workflow thread (`run:<id>`) nor a jobsite thread (`jobsite:<id>`) raises
  `FunctionClauseError`: it names no run or jobsite to count, and "nothing is waiting"
  would be a lie.
  """
  @spec for_threads([Thread.t()]) :: %{String.t() => t()}
  def for_threads(threads) when is_list(threads) do
    subjects = Map.new(threads, &{&1.id, subject_ids(&1)})

    %{approvals: approvals, questions: questions} =
      subjects |> Map.values() |> List.flatten() |> ProjectionStore.needs_you_counts()

    Map.new(threads, fn %Thread{} = thread ->
      ids = Map.fetch!(subjects, thread.id)

      {thread.id,
       signals(
         thread.status == "paused",
         sum(approvals, ids, @no_approvals),
         sum(questions, ids, @no_questions)
       )}
    end)
  end

  # Expired requests and undelivered approvals matter only while the thread is
  # still stuck (`paused`): once it resumes they are history, not "waiting on you".
  defp signals(stuck?, approvals, questions) do
    %{
      pending_approvals: approvals.pending,
      open_questions: questions.open,
      expired_approvals: if(stuck?, do: approvals.expired, else: 0),
      expired_questions: if(stuck?, do: questions.expired, else: 0),
      failed_approval_deliveries: if(stuck?, do: approvals.failed_deliveries, else: 0)
    }
  end

  defp sum(counts_by_subject, ids, zero) do
    Enum.reduce(ids, zero, fn id, acc ->
      case Map.fetch(counts_by_subject, id) do
        {:ok, counts} -> Map.merge(acc, counts, fn _key, a, b -> a + b end)
        :error -> acc
      end
    end)
  end

  @doc "The thread's undecided tool-call requests, oldest first (what the workspace offers approve/deny for)."
  @spec pending_approvals(Thread.t()) :: [ProjectionStore.tool_call()]
  def pending_approvals(%Thread{} = thread) do
    thread
    |> subject_ids()
    |> Enum.flat_map(&ProjectionStore.run_approvals(&1, status: :pending))
  end

  defp subject_ids(%Thread{door: :workflow, run_ids: run_ids}), do: run_ids
  defp subject_ids(%Thread{door: :jobsite, id: "jobsite:" <> jobsite_id}), do: [jobsite_id]
end
