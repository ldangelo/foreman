## Review

REJECTED. Security/API hardening still has blockers.

- Correct:
  - AC-017 core covered:
    - compact/raw logs: `packages/foreman_server/test/debug_views_test.exs:29-51`
    - artifact/report refs: `.../debug_views_test.exs:54-74`
    - post-purge + restart summaries: `.../debug_views_test.exs:77-115`
  - Review-round-1 API gaps mostly covered:
    - auth on log/report/debug endpoints: `packages/foreman_server/test/http_router_test.exs:60-75`
    - compact/raw/invalid view: `.../http_router_test.exs:78-112`
    - report/debug endpoint envelopes: `.../http_router_test.exs:114-138`
  - Assistant `message` now persisted: `packages/foreman_server/lib/foreman_server/worker_protocol.ex:65-79`; tested at `debug_views_test.exs:183-206`.
  - README documents endpoints + redaction/truncation: `packages/foreman_server/README.md:26`.
  - `cd packages/foreman_server && mix test` passed: 71 tests, 0 failures.

- Fixed:
  - None. No edits per review-only/no-edit. Did not write requested output file.

- Blocker:
  - Redaction leaks common `key: value` secret strings.
    - Regex only handles optional `=` then whitespace, so `token: abc123` redacts `:` and leaves `abc123`.
    - Code: `packages/foreman_server/lib/foreman_server/debug_views.ex:260-265`.
    - Repro command output: `token=[REDACTED] abc123 ...`
    - Existing tests only cover `api_key=abc123` / `password=hunter2`: `debug_views_test.exs:130-143`, `158-180`.

- Blocker:
  - Truncation can split UTF-8 and make HTTP JSON encoding fail.
    - Code uses byte slicing: `binary_part(value, 0, keep)`: `debug_views.ex:268-272`.
    - Repro with 1100 emoji stdout produced invalid UTF-8 and `Jason.EncodeError`.
    - Existing truncation test uses ASCII only: `debug_views_test.exs:118-127`, `170`.

- Worth doing now:
  - Add regression tests for `token: abc`, `password: hunter2`, `Authorization: Bearer abc`, and long Unicode output through HTTP `/logs?view=raw`.
  - Replace byte truncation with UTF-8-safe truncation.
  - Consider redacting `ProjectionStore.logs_by_run`; it currently stores raw payloads: `packages/foreman_server/lib/foreman_server/projection_store.ex:720-722`.

- Optional:
  - `DebugViews.run_events/1` still scans `EventStore.all()`: `debug_views.ex:117-120`. OK for TRD-020, but weak for bursty logs.
  - `progress.md` missing: `ENOENT`.

- Commands:
  - `git show --stat --patch 3125f93d`
  - `grep/read/nl` on PRD/TRD, DebugViews, Router, WorkerProtocol, tests.
  - `cd packages/foreman_server && mix test` → passed, 71 tests.
  - Unicode truncation repro → failed with `Jason.EncodeError`.
  - Regex repro → command ran; showed leaked `abc123`.