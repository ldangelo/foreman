defmodule ForemanServer.Agents.SignalLatencyRegressionTest do
  @moduledoc """
  Signal delivery latency regression test (TRD-2026-4212be7e / LGC-T005 / TRD-100; NFR-02 p95 < 1s).
  Run on CI; fails the build if p95 exceeds threshold.
  """
  use ExUnit.Case, async: false

  @moduletag :latency_regression
  @p95_threshold_ms 1000
  @publish_count 500

  test "p95 signal delivery regression under NFR-02" do
    latencies =
      for _ <- 1..@publish_count do
        {time_us, _} =
          :timer.tc(fn ->
            {:ok, signal} = Jido.Signal.new("test.regression", %{}, source: "regression_test")
            Jido.Signal.Bus.publish(:foreman_jido_signal_bus, [signal])
          end)

        time_us
      end

    sorted = Enum.sort(latencies)
    p95 = Enum.at(sorted, div(@publish_count * 95, 100)) |> div(1000)

    assert p95 < @p95_threshold_ms,
           "Regression: p95 signal latency #{p95}ms exceeds #{@p95_threshold_ms}ms (NFR-02)"
  end
end
