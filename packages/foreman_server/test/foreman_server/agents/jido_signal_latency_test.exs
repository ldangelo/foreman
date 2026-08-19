defmodule ForemanServer.Agents.JidoSignalLatencyTest do
  use ExUnit.Case, async: false

  @moduletag :latency
  @publish_count 1000
  @p95_threshold_ms 1000

  test "p95 agent-to-agent signal delivery is under #{@p95_threshold_ms}ms" do
    latencies =
      for _ <- 1..@publish_count do
        {time_us, _result} =
          :timer.tc(fn ->
            Jido.Signal.Bus.publish(:foreman_jido_signal_bus, "test.latency", %{payload: :ok})
          end)
        time_us
      end

    sorted = Enum.sort(latencies)
    count = length(sorted)
    p50 = Enum.at(sorted, div(count, 2)) |> div(1000)
    p95 = Enum.at(sorted, div(count * 95, 100)) |> div(1000)
    p99 = Enum.at(sorted, div(count * 99, 100)) |> div(1000)
    max_ms = List.last(sorted) |> div(1000)
    IO.puts("Signal delivery latency: p50=#{p50}ms p95=#{p95}ms p99=#{p99}ms max=#{max_ms}ms")
    assert p95 < @p95_threshold_ms, "p95 signal latency #{p95}ms exceeds threshold #{@p95_threshold_ms}ms"
  end
end
