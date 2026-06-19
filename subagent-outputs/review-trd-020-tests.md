## Review

- Correct:
  - AC-017 reqs located: `docs/PRD/PRD-2026-014-elixir-backend-orchestration.md:430-441`.
  - TRD maps TRD-020/TEST to AC-017-1/2/3: `docs/TRD/...md:669-681`, trace table `:1003-1005`.
  - Tests cover direct read-view behavior:
    - Compact/raw logs: `packages/foreman_server/test/debug_views_test.exs:29-52`.
    - Artifact/report refs in debug timeline: `:54-75`.
    - Purged external log file still allows event-backed logs/report summary: `:77-105`.
  - Impl is event-backed: `DebugViews.run_events/1` reads `EventStore.all()` at `packages/foreman_server/lib/foreman_server/debug_views.ex:110-113`.
  - Full Elixir suite passed: `66 tests, 0 failures`.

- Blocker:
  - Test gap: HTTP boundary not proved though new endpoints exist.
    - Routes added: `packages/foreman_server/lib/foreman_server/http/router.ex:67-106`.
    - `http_router_test.exs:32-166` covers commands only; no `/api/v1/runs/:id/logs|report|debug`.
    - Add authorized + unauthorized + raw/compact HTTP tests.

- Fix worth doing now:
  - Strengthen AC-017-3 durability proof.
    - Current test deletes external log, then immediately uses same in-memory `EventStore` process: `debug_views_test.exs:94-104`.
    - Add restart/replay after purge, then assert logs/report/debug summary from event log.
  - Assert debug summary/status after purge.
    - Current AC-017-3 test checks `report.summary.event_count`, not `debug.summary` nor `report.status`: `debug_views_test.exs:102-104`.

- Optional:
  - Add validation/error tests for empty/invalid run ids at direct function level, if desired.
  - Add worker HTTP event ingestion-to-log test for `/worker/v1/events` + `/api/v1/runs/:id/logs`.

- Commands:
  - `git status --short --untracked-files=all` → clean.
  - `git diff --name-status a5d04a11^..b5492c11`
  - `git diff --name-status b5492c11..HEAD`
  - `cd packages/foreman_server && mix test test/debug_views_test.exs test/http_router_test.exs` → passed, 9 tests.
  - `cd packages/foreman_server && mix test` → passed, 66 tests.

Note: did not write `subagent-outputs/review-trd-020-tests.md`; task also said “Do not edit,” so no-edit won.