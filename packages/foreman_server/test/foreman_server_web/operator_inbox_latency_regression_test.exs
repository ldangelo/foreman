defmodule ForemanServerWeb.OperatorInboxLatencyRegressionTest do
  use ForemanServerWeb.ConnCase, async: false
  @moduletag :latency_regression
  @p95_threshold_ms 1000
  @post_count 200

  test "p95 operator->inbox regression under NFR-02" do
    latencies =
      for i <- 1..@post_count do
        {time_us, _} =
          :timer.tc(fn ->
            build_conn()
            |> post("/webhooks/operator/ingest", %{question: "reg #{i}", workflow_id: "test"})
          end)

        time_us
      end

    sorted = Enum.sort(latencies)
    p95 = Enum.at(sorted, div(@post_count * 95, 100)) |> div(1000)

    assert p95 < @p95_threshold_ms,
           "Regression: p95 operator->inbox #{p95}ms exceeds #{@p95_threshold_ms}ms (NFR-02)"
  end
end
