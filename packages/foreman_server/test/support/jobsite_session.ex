defmodule ForemanServer.TestSupport.JobsiteSession do
  @moduledoc """
  A jobsite can only be resumed or steered once its agent has reported a provider session and the
  executor has recorded it (`jobsite.session.bind`, foreman-cm8nv); a resume with none on record is
  refused (`:no_session`) rather than run against a blank agent.

  A test that pauses or kills a jobsite mid-iteration and then resumes it must therefore run an
  agent that reports its session BEFORE it sleeps (`FAKE_AGENT_SESSION_FIRST`, see
  `test/foreman_server/jobsite/support/fake_agent.sh`) and wait here until that session is recorded.
  """

  alias ForemanServer.Jobsite

  @doc "Blocks until the jobsite's projection carries a provider session id; raises on timeout."
  @spec await!(String.t(), pos_integer()) :: :ok
  def await!(jobsite_id, timeout_ms \\ 15_000) when is_binary(jobsite_id) do
    do_await(jobsite_id, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp do_await(jobsite_id, deadline) do
    cond do
      match?(%{session_id: session} when is_binary(session), Jobsite.get(jobsite_id)) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "jobsite #{jobsite_id} never recorded a provider session"

      true ->
        Process.sleep(25)
        do_await(jobsite_id, deadline)
    end
  end
end
