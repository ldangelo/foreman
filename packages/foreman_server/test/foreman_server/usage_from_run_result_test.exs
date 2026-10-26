defmodule ForemanServer.UsageFromRunResultTest do
  @moduledoc """
  `Usage.from_run_result/1`: the one place a harness `RunResult` is turned into
  `%Usage{}`: the provider's usage map, its `:usage` events and the cost of the
  last `:run_completed` event, nil-preserving, whatever the run's status.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Usage
  alias Jido.Harness.{Event, RunResult}

  @claude_usage %{
    "input_tokens" => 10,
    "output_tokens" => 5,
    "cache_read_input_tokens" => 100,
    "cache_creation_input_tokens" => 20
  }

  # `pi` reports usage per assistant message (`message_end`), so a run has several.
  @pi_first %{
    "input" => 100,
    "output" => 10,
    "cacheRead" => 50,
    "cacheWrite" => 0,
    "totalTokens" => 160,
    "cost" => %{"total" => 0.01}
  }
  @pi_second %{
    "input" => 200,
    "output" => 20,
    "cacheRead" => 150,
    "cacheWrite" => 5,
    "totalTokens" => 375,
    "cost" => %{"total" => 0.02}
  }

  defp run(provider, attrs) do
    struct!(%RunResult{run_id: "run-1", provider: provider, status: :completed}, attrs)
  end

  defp event(type, payload) do
    %Event{type: type, provider: :claude, payload: payload, timestamp: "2026-01-01T00:00:00Z"}
  end

  defp completed(payload), do: event(:run_completed, payload)

  defp claude_cost(events) do
    result = run(:claude, usage: @claude_usage, events: events)
    Usage.from_run_result(result).cost_usd
  end

  describe "claude" do
    test "reads the usage map and the cost of the run_completed event" do
      events = [event(:output_text_final, %{"text" => "hi"}), completed(%{"cost_usd" => 0.0123})]
      usage = Usage.from_run_result(run(:claude, usage: @claude_usage, events: events))

      assert usage == %Usage{
               input_tokens: 10,
               output_tokens: 5,
               cache_read_tokens: 100,
               cache_write_tokens: 20,
               total_tokens: 135,
               cost_usd: 0.0123
             }
    end

    test "without a run_completed cost the cost is unknown (nil), never 0.0" do
      usage = Usage.from_run_result(run(:claude, usage: @claude_usage))
      assert usage.total_tokens == 135
      assert usage.cost_usd == nil

      assert claude_cost([completed(%{})]) == nil
    end

    test "the cost comes from the LAST run_completed event, and only when it is a number" do
      earlier_and_last = [completed(%{"cost_usd" => 0.1}), completed(%{"cost_usd" => 0.5})]
      assert claude_cost(earlier_and_last) == 0.5
      assert claude_cost([completed(%{"cost_usd" => 0.5}), completed(%{})]) == nil
      assert claude_cost([completed(%{"cost_usd" => "free"})]) == nil
    end

    test "claude reports cumulative usage once: streamed usage events are not summed" do
      streamed = [event(:usage, @claude_usage), event(:usage, @claude_usage)]
      usage = Usage.from_run_result(run(:claude, usage: @claude_usage, events: streamed))
      assert usage.input_tokens == 10
      assert usage.total_tokens == 135
    end
  end

  describe "pi" do
    test "sums the per-message usage events instead of keeping the last one" do
      first = event(:usage, @pi_first)
      second = event(:usage, @pi_second)
      events = [first, event(:output_text_final, %{}), second]
      usage = Usage.from_run_result(run(:pi, usage: @pi_second, events: events))

      assert %Usage{
               input_tokens: 300,
               output_tokens: 30,
               cache_read_tokens: 200,
               cache_write_tokens: 5,
               total_tokens: 535
             } = usage

      assert_in_delta usage.cost_usd, 0.03, 1.0e-9
    end

    test "a model that reports cost 0 stays 0.0 (free as reported), an absent cost stays nil" do
      zero = %{"input" => 7, "output" => 3, "totalTokens" => 10, "cost" => %{"total" => 0}}
      unpriced = %{"input" => 7, "output" => 3, "totalTokens" => 10}

      free = run(:pi, usage: zero, events: [event(:usage, zero), event(:usage, zero)])
      assert Usage.from_run_result(free).cost_usd == 0.0

      without_cost = run(:pi, usage: unpriced, events: [event(:usage, unpriced)])
      usage = Usage.from_run_result(without_cost)
      assert usage.total_tokens == 10
      assert usage.cost_usd == nil
    end

    test "falls back to the aggregate usage map when the run streamed no usage events" do
      usage = Usage.from_run_result(run(:pi, usage: @pi_second))
      assert %Usage{input_tokens: 200, output_tokens: 20, total_tokens: 375} = usage
    end

    test "usage events without a map payload are ignored" do
      broken = struct!(event(:usage, %{}), payload: nil)
      events = [broken, event(:usage, @pi_first)]
      usage = Usage.from_run_result(run(:pi, usage: %{}, events: events))
      assert usage.input_tokens == 100
    end
  end

  describe "nothing to read" do
    test "an unknown provider is all nil, whatever it sent" do
      events = [event(:usage, %{"input" => 3}), completed(%{})]
      usage = Usage.from_run_result(run(:mystery, usage: %{"input_tokens" => 1}, events: events))

      assert usage == %Usage{}
      assert Usage.empty?(usage)
    end

    test "a result that reported no usage is an empty usage, not nil" do
      for provider <- [:claude, :pi] do
        usage = Usage.from_run_result(run(provider, []))
        assert %Usage{} = usage
        assert Usage.empty?(usage)
      end
    end
  end

  test "a failed or cancelled run spent its tokens too" do
    for status <- [:failed, :cancelled] do
      failed = run(:claude, status: status, usage: @claude_usage, error: :boom)
      assert Usage.from_run_result(failed).total_tokens == 135, "status #{status}"
    end
  end
end
