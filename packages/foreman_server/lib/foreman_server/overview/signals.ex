defmodule ForemanServer.Overview.Signals do
  @moduledoc """
  Per-thread "needs you" counts that do not come from the thread read model.

  Pending approvals and open questions are produced by E8, which has not landed.
  Until it does this module reports zero for every thread - an honest "no
  data", not a stub of random values. E8 replaces the body (reading the
  projection once per project) without touching `Overview.build/2`.
  """

  @type t :: %{pending_approvals: non_neg_integer(), open_questions: non_neg_integer()}

  @spec for_thread(ForemanServer.Threads.Thread.t()) :: t()
  def for_thread(%ForemanServer.Threads.Thread{}), do: %{pending_approvals: 0, open_questions: 0}
end
