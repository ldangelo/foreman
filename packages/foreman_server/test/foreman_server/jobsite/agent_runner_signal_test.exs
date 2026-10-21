defmodule ForemanServer.Jobsite.AgentRunnerSignalTest do
  # The stream consumer and the result awaiter message the runner from separate processes, so a
  # run's result can arrive before the consumer's `{:signal, _}`. `resolve_run_result/5` is where
  # that lost signal is recovered from the result's own text; without it the iteration comes back
  # unsignalled and the loop pays for another agent run.
  use ExUnit.Case, async: true

  alias ForemanServer.Jobsite.{AgentRunner, Error}
  alias Jido.Harness.RunResult

  @signal "<promise>COMPLETE</promise>"

  defp result(status, text) do
    RunResult.new!(run_id: "run-x", provider: :pi, status: status, text: text)
  end

  test "a signal the stream consumer never reported is found in the result text" do
    assert {:ok, iteration} =
             AgentRunner.resolve_run_result(
               result(:completed, "done #{@signal}"),
               1,
               nil,
               "",
               [@signal]
             )

    assert iteration.signalled?
    assert iteration.status == :signalled
    assert iteration.matched_signal == @signal
  end

  test "a signal already matched on the stream is kept as is" do
    assert {:ok, iteration} =
             AgentRunner.resolve_run_result(result(:completed, "done"), 1, @signal, "done", [
               @signal
             ])

    assert iteration.signalled?
    assert iteration.matched_signal == @signal
  end

  test "no signal in the text keeps the iteration unsignalled" do
    assert {:ok, iteration} =
             AgentRunner.resolve_run_result(result(:completed, "still working"), 1, nil, "", [
               @signal
             ])

    refute iteration.signalled?
    assert iteration.status == :completed
  end

  test "with no completion signals configured nothing is searched for" do
    assert {:ok, iteration} =
             AgentRunner.resolve_run_result(result(:completed, @signal), 1, nil, "", [])

    refute iteration.signalled?
  end

  test "a failed run that never signalled is still an agent failure" do
    assert {:error, %Error{code: :agent_failed}} =
             AgentRunner.resolve_run_result(result(:failed, "crashed"), 1, nil, "", [@signal])
  end

  test "a failed run whose text carries the signal logically finished" do
    assert {:ok, iteration} =
             AgentRunner.resolve_run_result(
               result(:failed, "#{@signal} then exit 1"),
               1,
               nil,
               "",
               [@signal]
             )

    assert iteration.signalled?
  end
end
