## Review

- Correct:
  - TRD/PRD scope matches REQ-017 / AC-017. Docs require compact/raw logs, artifact refs, and summaries after log purge.
  - `DebugViews` is event-backed via `EventStore.all()` and not raw log files: `packages/foreman_server/lib/foreman_server/debug_views.ex:110-113`.
  - Compact/raw log rendering covers stdout/stderr/assistant/tool: `debug_views.ex:6-18`, `118-183`.
  - Report/debug collect artifact/report refs from events: `debug_views.ex:70-80`, `97-104`, `186-190`.
  - Worker protocol maps durable log event types: `worker_protocol.ex:115-121`.
  - Projection updates worker log sequence for tool/stdout/stderr/assistant events: `projection_store.ex:435-463`, `713-715`.
  - HTTP endpoints exist and auth-wrap views: `http/router.ex:67-105`.
  - Purged external log behavior tested: `debug_views_test.exs:77-104`.
  - Sequence rejection already tested: `worker_protocol_test.exs:64-76`.
  - `cd packages/foreman_server && mix test` passed: 66 tests, 0 failures.
  - Git status clean.

- Fixed:
  - None. Review-only/no-edit honored. Did not write requested output file due explicit no-edit instruction.

- Blocker:
  - None found.

- Worth doing now:
  - Add router-level tests for new GET endpoints. Routes exist at `http/router.ex:67-105`, but TRD-020 tests call `DebugViews` directly (`debug_views_test.exs:32`, `48`, `70`, `97`, `102`). This misses auth/envelope/query-param coverage for `/logs?view=raw`, `/report`, `/debug`.
  - Preserve `message` in worker ingest payloads or document `output` as required. `compact_message/2` supports `:message` for `AssistantMessage` (`debug_views.ex:165-166`), but `WorkerProtocol.ingest_event/1` only stores `:output` (`worker_protocol.ex:65-77`). Assistant events sent with `message` would render blank.

- Optional:
  - `ProjectionStore.logs_by_run` is populated (`projection_store.ex:720-722`) but `DebugViews` reads `EventStore` directly. Fine for event-backed semantics; consider removing/using later to avoid drift.

- Commands:
  - `git status --short --branch` → clean.
  - `git show --stat a5d04a11 b5492c11 64ca5955` → inspected.
  - `cd packages/foreman_server && mix test` → passed, 66 tests, 0 failures.
  - Reads/greps: PRD/TRD, DebugViews, Router, ProjectionStore, WorkerProtocol, tests.