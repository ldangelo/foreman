defmodule ForemanServerWeb.OperatorInboxLatencyTest do
  @moduledoc """
  Latency measurement scaffold for operator-question → inbox API ingest
  (TRD-2026-4212be7e / LGC-T006 / TRD-101; NFR-02 p95 < 1s).

  Pattern matches `ForemanServerWeb.WebhookControllerTest`: direct
  controller invocation via `Plug.Test` (no `Phoenix.ConnTest`/endpoint
  boot required). Each iteration POSTs a unique question to
  `/webhooks/operator/ingest` so the dedupe table does not collapse
  successive probes into a single `:deduped` path.
  """
  use ExUnit.Case, async: false

  use Plug.Test

  alias ForemanServer.Inbox.{DedupeTable, Poller}
  alias ForemanServerWeb.WebhookController

  @moduletag :latency
  @post_count 500
  @p95_threshold_ms 1000

  setup_all do
    # Bootstrap poller + dedupe table (mirrors webhook_controller_test.exs).
    case Process.whereis(DedupeTable) do
      nil -> :ok
      pid -> _ = pid
    end

    case Process.whereis(Poller) do
      nil -> :ok
      pid -> _ = pid
    end

    :ok
  end

  setup do
    DedupeTable.clear()
    Application.put_env(:foreman_server, :inbox_dedupe_window_seconds, 60)
    :ok
  end

  test "p95 operator question → inbox API is under #{@p95_threshold_ms}ms" do
    latencies =
      for i <- 1..@post_count do
        payload = %{
          "question_id" => "latency-probe-#{System.unique_integer([:positive])}-#{i}",
          "question" => "latency probe #{i}",
          "agent_id" => "agent-#{i}",
          "options" => %{}
        }

        {time_us, _conn} =
          :timer.tc(fn ->
            conn(:post, "/webhooks/operator/ingest", payload)
            |> put_req_header("content-type", "application/json")
            |> WebhookController.operator_ingest(payload)
          end)

        time_us
      end

    sorted = Enum.sort(latencies)
    count = length(sorted)
    p50 = Enum.at(sorted, div(count, 2)) |> div(1000)
    p95 = Enum.at(sorted, div(count * 95, 100)) |> div(1000)
    p99 = Enum.at(sorted, div(count * 99, 100)) |> div(1000)
    max_ms = List.last(sorted) |> div(1000)

    IO.puts(
      "Operator→inbox latency: p50=#{p50}ms p95=#{p95}ms p99=#{p99}ms max=#{max_ms}ms"
    )

    assert p95 < @p95_threshold_ms,
           "p95 latency #{p95}ms exceeds threshold #{@p95_threshold_ms}ms"
  end
end
