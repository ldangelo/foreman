defmodule ForemanServer.Agents.SignalLatencyRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :latency_regression
  # Run on CI; fails the build if p95 exceeds NFR-02 threshold
  @p95_threshold_ms 1000
  @publish_count 500  # smaller than LGC-T005 for CI speed

  test "p95 signal delivery regression under NFR-02" do
    latencies =
      for _ <- 1..@publish_count do
        {time_us, _} = :timer.tc(fn -> Jido.Signal.Bus.publish(:foreman_jido_signal_bus, "test.regression", %{}) end)
        time_us
      end
    sorted = Enum.sort(latencies)
    p95 = Enum.at(sorted, div(@publish_count * 95, 100)) |> div(1000)
    assert p95 < @p95_threshold_ms, "Regression: p95 signal latency #{p95}ms exceeds #{@p95_threshold_ms}ms (NFR-02)"
  end
end