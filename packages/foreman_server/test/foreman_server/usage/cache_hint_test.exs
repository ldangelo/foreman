defmodule ForemanServer.Usage.CacheHintTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Usage
  alias ForemanServer.Usage.{CacheHint, Rollup}

  @now ~U[2026-01-01 12:00:00Z]
  @ttls %{"claude" => 300}

  defp thread(events, provider \\ "claude") do
    records =
      for {at, usage} <- events do
        %{
          thread_kind: "workflow",
          thread_id: "t1",
          role: "thread",
          model: "m",
          provider: provider,
          at: at,
          usage: usage
        }
      end

    Rollup.from_records(records).by_thread["t1"]
  end

  defp usage(input, read, write),
    do: %Usage{
      input_tokens: input,
      cache_read_tokens: read,
      cache_write_tokens: write,
      total_tokens: 1
    }

  test "ratio is cache_read over input + cache_read + cache_write" do
    hint = CacheHint.compute(thread([{"2026-01-01T11:59:00Z", usage(10, 90, 0)}]), @now, @ttls)
    assert hint.cache_read_ratio == 0.9
    assert hint.idle_seconds == 60
  end

  test "299 idle seconds is warm, 301 is cold, with a 300s claude ttl" do
    warm = CacheHint.compute(thread([{"2026-01-01T11:55:01Z", usage(1, 1, 0)}]), @now, @ttls)
    cold = CacheHint.compute(thread([{"2026-01-01T11:54:59Z", usage(1, 1, 0)}]), @now, @ttls)
    assert warm.idle_seconds == 299 and warm.likely_cold? == false
    assert cold.idle_seconds == 301 and cold.likely_cold? == true
  end

  test "a provider without a TTL is unknown (nil), not warm" do
    hint =
      CacheHint.compute(thread([{"2026-01-01T00:00:00Z", usage(1, 1, 0)}], "pi"), @now, @ttls)

    assert hint.likely_cold? == nil
  end

  test "no cache figures at all means a nil ratio, not 0.0" do
    hint =
      CacheHint.compute(
        thread([{"2026-01-01T11:59:00Z", %Usage{input_tokens: 5, total_tokens: 5}}]),
        @now,
        @ttls
      )

    assert hint.cache_read_ratio == nil
  end

  test "only the last #{Rollup.recent_window()} events are used" do
    old = {"2026-01-01T01:00:00Z", usage(1000, 0, 0)}
    recent = for m <- 10..14, do: {"2026-01-01T11:#{m}:00Z", usage(0, 10, 0)}
    hint = CacheHint.compute(thread([old | recent]), @now, @ttls)
    assert hint.cache_read_ratio == 1.0
  end
end
