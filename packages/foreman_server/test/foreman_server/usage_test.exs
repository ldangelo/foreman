defmodule ForemanServer.UsageTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Usage

  @claude_usage %{
    "input_tokens" => 10,
    "output_tokens" => 5,
    "cache_read_input_tokens" => 100,
    "cache_creation_input_tokens" => 20
  }

  # Real shape from a `pi 1.3.0` run (minimax/MiniMax-M2.7-highspeed): one
  # assistant message_end `usage` payload.
  @pi_usage %{
    "input" => 40_940,
    "output" => 3,
    "cacheRead" => 128,
    "cacheWrite" => 0,
    "totalTokens" => 41_071,
    "cost" => %{
      "input" => 0.024564,
      "output" => 0.0000072,
      "cacheRead" => 0.00000768,
      "cacheWrite" => 0,
      "total" => 0.02457888
    },
    "cacheWrite1h" => 0
  }

  describe "normalize/3" do
    test "claude: maps every field, derives the total, cost only from the event cost" do
      assert %Usage{
               input_tokens: 10,
               output_tokens: 5,
               cache_read_tokens: 100,
               cache_write_tokens: 20,
               total_tokens: 135,
               cost_usd: 0.0123
             } == Usage.normalize(:claude, @claude_usage, 0.0123)
    end

    test "claude: an unreported cost is nil, NOT 0.0 (unknown is not free)" do
      assert %Usage{cost_usd: nil, total_tokens: 135} =
               Usage.normalize(:claude, @claude_usage, nil)
    end

    test "claude: a provider total wins over the derived sum" do
      assert %Usage{total_tokens: 999} =
               Usage.normalize(:claude, Map.put(@claude_usage, "total_tokens", 999), nil)
    end

    test "pi: real key names, provider totalTokens and cost.total" do
      assert %Usage{
               input_tokens: 40_940,
               output_tokens: 3,
               cache_read_tokens: 128,
               cache_write_tokens: 0,
               total_tokens: 41_071,
               cost_usd: 0.02457888
             } == Usage.normalize(:pi, @pi_usage, nil)
    end

    test "pi without a cost map has nil cost" do
      assert %Usage{cost_usd: nil} = Usage.normalize(:pi, Map.delete(@pi_usage, "cost"), nil)
    end

    test "an explicit event cost wins over the cost inside the usage map" do
      assert %Usage{cost_usd: 1.5} = Usage.normalize(:pi, @pi_usage, 1.5)
    end

    test "an empty map is all nil" do
      assert %Usage{
               input_tokens: nil,
               output_tokens: nil,
               cache_read_tokens: nil,
               cache_write_tokens: nil,
               total_tokens: nil,
               cost_usd: nil
             } == Usage.normalize(:claude, %{}, nil)
    end

    test "unknown provider and garbage values give nils without raising" do
      garbage = %{"input_tokens" => "10", "output_tokens" => -4, "input" => 1.5}

      assert %Usage{input_tokens: nil, output_tokens: nil, total_tokens: nil} =
               Usage.normalize(:mystery, garbage, nil)

      assert %Usage{input_tokens: nil, output_tokens: nil, total_tokens: nil, cost_usd: nil} =
               Usage.normalize(:claude, garbage, "free")

      assert %Usage{input_tokens: nil} = Usage.normalize(:claude, nil, nil)
    end

    test "a negative event cost is rejected, zero is kept" do
      assert %Usage{cost_usd: nil} = Usage.normalize(:claude, @claude_usage, -1)
      assert %Usage{cost_usd: +0.0} = Usage.normalize(:claude, @claude_usage, 0)
    end
  end

  describe "from_run/4" do
    test "pi: per-message usage events are summed, not last-write-wins" do
      second =
        @pi_usage
        |> Map.merge(%{"input" => 60, "output" => 7, "totalTokens" => 195})
        |> put_in(["cost", "total"], 0.01)

      usage = Usage.from_run(:pi, second, [@pi_usage, second], nil)

      assert usage.input_tokens == 41_000
      assert usage.output_tokens == 10
      assert usage.total_tokens == 41_071 + 195
      assert_in_delta usage.cost_usd, 0.02457888 + 0.01, 1.0e-9
    end

    test "pi with no usage events falls back to the aggregate map" do
      assert Usage.from_run(:pi, @pi_usage, [], nil) == Usage.normalize(:pi, @pi_usage, nil)
    end

    test "claude uses the cumulative aggregate and ignores streamed usage events" do
      assert Usage.from_run(:claude, @claude_usage, [@claude_usage, @claude_usage], 0.5) ==
               Usage.normalize(:claude, @claude_usage, 0.5)
    end
  end

  describe "merge/2" do
    test "is nil-preserving" do
      assert %Usage{input_tokens: nil, cost_usd: nil} = Usage.merge(%Usage{}, %Usage{})
      assert %Usage{input_tokens: 3} = Usage.merge(%Usage{}, %Usage{input_tokens: 3})

      assert %Usage{input_tokens: 5} =
               Usage.merge(%Usage{input_tokens: 2}, %Usage{input_tokens: 3})

      assert %Usage{cost_usd: 0.5} = Usage.merge(%Usage{}, %Usage{cost_usd: 0.5})
    end

    test "nil is the identity and merge is associative" do
      a = %Usage{input_tokens: 1, cost_usd: 0.25}
      b = %Usage{input_tokens: 2, output_tokens: 4}
      c = %Usage{cost_usd: 0.5}

      assert Usage.merge(nil, a) == a
      assert Usage.merge(a, nil) == a
      assert Usage.merge(Usage.merge(a, b), c) == Usage.merge(a, Usage.merge(b, c))
    end
  end

  describe "from_fields/1 and to_event_fields/1" do
    test "round-trip and revalidate" do
      usage = Usage.normalize(:claude, @claude_usage, 0.0123)
      assert usage == usage |> Usage.to_event_fields() |> Usage.from_fields()

      assert %Usage{input_tokens: nil, cost_usd: nil} =
               Usage.from_fields(%{input_tokens: "7", cost_usd: -1})
    end
  end
end
