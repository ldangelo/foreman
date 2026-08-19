# Operator → Inbox Latency Methodology (LGC-T006)

TRD: TRD-2026-4212be7e / LGC-T006 / TRD-101
Bead: foreman-zomp
Authored: 2026-08-19
NFR-02: p95 < 1 second

## Approach
- Use `:timer.tc/1` to capture wall-clock time around the HTTP POST that delivers an operator question to the inbox ingest endpoint.
- Endpoint: `POST /webhooks/operator/ingest` (per `ForemanServerWeb.Router` scope `"/webhooks"`).
- N=500 sequential POSTs, single operator client (avoids Postgres connection-pool contention from concurrent clients — that is measured by LGC-T007 regression runs).
- Per-iteration latency covers: HTTP parse → `WebhookController.operator_ingest/2` → `OperatorQuestionDispatcher.dispatch/1` → `SharedInbox.ingest/2` → `InboxItemStarted` event written.
- Compute p50, p95, p99, max in milliseconds.
- Threshold: p95 < 1000ms (PASS) or p95 ≥ 1000ms (FAIL).

## Environment
- Single-node BEAM
- Postgres for jido_ecto (inbox persistence)
- `:inbox_dedupe_window_seconds` configured (default 60s)
- `OperatorQuestionDispatcher` and `SharedInbox` running
- HTTP wire: `application/json` content-type, payload shape `{question_id, question, agent_id, options}`

## Test scaffold
- File: `packages/foreman_server/test/foreman_server_web/operator_inbox_latency_test.exs`
- Module: `ForemanServerWeb.OperatorInboxLatencyTest`
- Pattern: `Plug.Test` direct controller invocation (matches `webhook_controller_test.exs`; this repo has no `ForemanServerWeb.ConnCase`).
- Tag: `:latency` (opt-in via `mix test --only latency`).

## Reporting
- Test prints p50/p95/p99/max to stdout for trend capture.
- Latency regression test (LGC-T007) will reference this measurement and assert p95 stays below threshold across runs.

## Source files reviewed
- `packages/foreman_server/lib/foreman_server_web/router.ex`
- `packages/foreman_server/lib/foreman_server_web/controllers/webhook_controller.ex`
- `packages/foreman_server/lib/foreman_server/agents/operator_question_dispatcher.ex`
- `packages/foreman_server/lib/foreman_server/agents/operator_question_source.ex`
- `packages/foreman_server/test/foreman_server_web/controllers/webhook_controller_test.exs`

## Verdict
Methodology defined; actual measurement pending runtime (out of scope for this bead — scaffold + method only).
