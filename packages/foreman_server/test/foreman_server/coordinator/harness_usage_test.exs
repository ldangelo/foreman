defmodule ForemanServer.Coordinator.HarnessUsageTest do
  @moduledoc """
  The coordinator's provider agent reports what a turn cost. Every run that
  returns a `RunResult` yields its usage (completed, failed or cancelled: the
  tokens were spent), on the turn or on the error; the one repair retry sums both
  runs; a start failure or a timeout has no result and so no usage. Exercised
  through `Harness.finish/1` and `Harness.merge_attempts/2` with constructed
  results, no provider.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Coordinator.Agent.Harness
  alias ForemanServer.Coordinator.{Error, Turn}
  alias ForemanServer.Usage
  alias Jido.Harness.{Event, RunResult}

  @reply ~s(Done.\n\n```json\n{"reply": "On it.", "actions": []}\n```\n)
  @malformed "no json block here"

  defp run(attrs) do
    base = %RunResult{
      run_id: "run-1",
      provider: :claude,
      status: :completed,
      text: @reply,
      usage: %{"input_tokens" => 100, "output_tokens" => 20}
    }

    struct!(base, attrs)
  end

  defp cost(cost_usd) do
    Event.new!(type: :run_completed, provider: :claude, payload: %{"cost_usd" => cost_usd})
  end

  describe "finish/1" do
    test "a completed run is the turn plus the provider's usage" do
      assert {:ok, %Turn{reply: "On it.", actions: [], usage: usage}} =
               Harness.finish(run(events: [cost(0.01)]))

      assert usage == %Usage{
               input_tokens: 100,
               output_tokens: 20,
               total_tokens: 120,
               cost_usd: 0.01
             }
    end

    test "a malformed reply is :malformed_output and still carries the usage that was spent" do
      assert {:error, %Error{code: :malformed_output, details: details}} =
               Harness.finish(run(text: @malformed))

      assert %Usage{total_tokens: 120, cost_usd: nil} = details.usage
    end

    test "a failed or cancelled run is :agent_failed with its status and the usage" do
      for status <- [:failed, :cancelled] do
        assert {:error, %Error{code: :agent_failed, details: details}} =
                 Harness.finish(run(status: status, error: :boom))

        assert details.status == status
        assert %Usage{total_tokens: 120} = details.usage
      end
    end

    test "a provider that reported nothing gives an all-nil usage, never nil" do
      assert {:ok, %Turn{usage: %Usage{} = usage}} = Harness.finish(run(usage: %{}))
      assert Usage.empty?(usage)

      assert {:error, %Error{details: %{usage: %Usage{} = failed}}} =
               Harness.finish(run(usage: %{}, text: @malformed))

      assert Usage.empty?(failed)
    end

    test "pi: the per-message usage events are summed, not just the last message" do
      message = fn input, total ->
        payload = %{"input" => input, "output" => 1, "totalTokens" => total}
        Event.new!(type: :usage, provider: :pi, payload: payload)
      end

      pi_run = run(provider: :pi, usage: %{}, events: [message.(10, 11), message.(20, 21)])

      assert {:ok, %Turn{usage: usage}} = Harness.finish(pi_run)
      assert %Usage{input_tokens: 30, output_tokens: 2, total_tokens: 32} = usage
    end
  end

  describe "merge_attempts/2 (the repair retry)" do
    test "a malformed first reply and a good second one: the turn carries both runs' usage" do
      first = Harness.finish(run(text: @malformed, events: [cost(0.01)]))
      second_usage = %{"input_tokens" => 150, "output_tokens" => 30}
      second = Harness.finish(run(usage: second_usage, events: [cost(0.02)]))

      assert {:ok, %Turn{reply: "On it.", usage: usage}} = Harness.merge_attempts(first, second)
      assert %Usage{input_tokens: 250, output_tokens: 50, total_tokens: 300} = usage
      assert_in_delta usage.cost_usd, 0.03, 1.0e-9
    end

    test "two malformed replies: the final error keeps the second reason and the summed usage" do
      first = Harness.finish(run(text: @malformed))
      second = Harness.finish(run(text: "still no json", usage: %{"input_tokens" => 5}))
      {:error, %Error{message: second_message}} = second

      assert {:error, %Error{code: :malformed_output, message: message, details: details}} =
               Harness.merge_attempts(first, second)

      assert message == second_message
      assert %Usage{input_tokens: 105, output_tokens: 20, total_tokens: 125} = details.usage
    end

    test "a second attempt that never reached the provider adds none but keeps the first run's" do
      first = Harness.finish(run(text: @malformed))
      start_failure = Error.new(:agent_failed, "provider failed to start", %{reason: ":enoent"})
      timeout = Error.new(:agent_timeout, "run did not complete", %{run_id: "run-2"})

      for second_error <- [start_failure, timeout] do
        assert {:error, %Error{code: code, details: details}} =
                 Harness.merge_attempts(first, {:error, second_error})

        assert code == second_error.code
        assert %Usage{total_tokens: 120} = details.usage
        assert Map.delete(details, :usage) == second_error.details
      end
    end

    test "unknown cost stays unknown across the sum: nil + nil is nil, nil + 0.5 is 0.5" do
      first = Harness.finish(run(text: @malformed))
      unpriced = Harness.finish(run([]))
      priced = Harness.finish(run(events: [cost(0.5)]))

      assert {:ok, %Turn{usage: %Usage{cost_usd: nil}}} = Harness.merge_attempts(first, unpriced)
      assert {:ok, %Turn{usage: %Usage{cost_usd: 0.5}}} = Harness.merge_attempts(first, priced)
    end

    test "nothing is invented when neither attempt ran the provider" do
      first = {:error, Error.new(:malformed_output, "x")}
      second = {:error, Error.new(:agent_timeout, "t")}

      assert {:error, %Error{details: details}} = merged = Harness.merge_attempts(first, second)
      assert merged == second
      refute Map.has_key?(details, :usage)
    end
  end
end
