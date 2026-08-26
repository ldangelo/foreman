# Signal Delivery Latency Methodology (LGC-T005)
TRD: TRD-2026-4212be7e / LGC-T005 / TRD-100
Bead: foreman-5qpy
Authored: 2026-08-19
NFR-02: p95 < 1 second

## Approach
- Use :timer.tc/1 to capture wall-clock time around Bus.publish → subscriber handler entry
- Run N=1000 publishes under steady load (10 concurrent publishers)
- Compute p50, p95, p99, max from per-iteration latencies
- Threshold: p95 < 1000ms (PASS) or ≥ 1000ms (FAIL)

## Environment
- Single-node BEAM
- Postgres for jido_ecto checkpointing
- Local Jido.Signal bus (`:foreman_jido_signal_bus`)
- Subscribers attached BEFORE publishers fire (warm path)

## Test scaffold
File: packages/foreman_server/test/foreman_server/agents/jido_signal_latency_test.exs
Tag: :latency (opt-in via `mix test --only latency`)

## Reporting
- Test output prints p50/p95/p99/max in ms
- Latency regression test (LGC-T007) references this measurement

## Source files reviewed
- packages/foreman_server/lib/foreman_server/agents/signal_agent_publisher.ex
- packages/foreman_server/deps/jido_signal/lib/jido_signal/bus.ex
- packages/foreman_server/test/foreman_server/agents/jido_signal_topics_test.exs

## Verdict
Methodology defined; actual measurement pending runtime.
