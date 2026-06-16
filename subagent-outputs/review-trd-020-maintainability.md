## Review

REJECTED. Security blocker.

- Correct:
  - REQ/AC match scope: PRD AC-017-1..3 require compact/raw logs, artifact/report debug refs, post-purge summaries (`docs/PRD/PRD-2026-014-elixir-backend-orchestration.md:430-441`).
  - HTTP read endpoints call `authorize/1` before reading logs/report/debug (`packages/foreman_server/lib/foreman_server/http/router.ex:67-105`).
  - Tests cover core ACs directly: compact/raw logs, artifact/report refs, purge survival (`packages/foreman_server/test/debug_views_test.exs:29-104`).
  - `mix test` passes: 66 tests, 0 failures.
  - Git status clean after review.

- Fixed:
  - None. No edits per review-only/no-edit. Output file not written due same constraint.

- Blocker:
  - Sensitive data + unbounded log exposure.
    - Raw logs return full `payload` and `metadata` (`debug_views.ex:118-127`).
    - Compact logs return full stdout/stderr/assistant output, no redaction/truncation (`debug_views.ex:162-166`).
    - Worker ingest stores arbitrary `output`/`details` (`worker_protocol.ex:65-77`).
    - TRD quality req says secrets must be redacted from events/logs/projections/debug timelines (`docs/TRD/TRD-2026-014-elixir-backend-orchestration.md:291-300`).
    - Need shared redaction + size caps + regression tests before exposing these views.

- Note / fix worth doing now:
  - View scalability weak: `DebugViews.run_events/1` calls `EventStore.all()` then filters every request (`debug_views.ex:110-113`; `event_store.ex:41-44,84-85`). For bursty worker logs, add per-run query/projection use, pagination/limit, and truncation.
  - `ProjectionStore.logs_by_run` was added but not used by `DebugViews`; either use it as read model or remove to avoid drift (`projection_store.ex:430-456,717-720`).
  - HTTP contract tests missing for new read routes. Existing AC tests call `DebugViews` directly; add router tests for 401, compact/raw shape, and invalid `view`.
  - Docs thin: package README only names `ForemanServer.DebugViews` (`packages/foreman_server/README.md:26`). Add endpoint paths, auth, `view=raw`, redaction/truncation behavior once fixed.
  - `progress.md` missing (`ENOENT`).

- Commands:
  - `git status --short`, `git log --oneline -n 20`
  - `git show --stat a5d04a11 b5492c11 64ca5955`
  - `grep` PRD/TRD REQ-017/AC-017/docs
  - `cd packages/foreman_server && mix test` → passed, 66 tests.