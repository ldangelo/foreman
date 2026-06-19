## Review
- Correct:
  - Hyphen aliases covered: `api-key`, `access-token`, `auth-token`, `client-secret` via underscore→hyphen expansion in `debug_views.ex:13-23`.
  - Prior behavior preserved: bearer redaction `debug_views.ex:273-280`; quoted/colon/equal generic redaction `debug_views.ex:282-285`; map key normalization `debug_views.ex:311-316`.
  - Tests cover hyphen + prior snake/JSON/bearer/UTF-8 paths: `debug_views_test.exs:118-255`, `http_router_test.exs:114-157`.
  - AC-017/log safety supported: TRD requires secret redaction from logs/projections/debug timelines at `docs/TRD/TRD-2026-014-elixir-backend-orchestration.md:300`.

- Fixed:
  - None. Review-only. No edits.

- Blocker:
  - None found.

- Fixes worth doing now:
  - None.

- Optional:
  - `progress.md` missing (`ENOENT`); not a blocker.
  - Did not write requested output file due explicit no-edit/artifact-write conflict.

- Commands:
  - `mix test test/debug_views_test.exs test/http_router_test.exs` → passed, 16 tests.
  - `mix test` in `packages/foreman_server` → passed, 73 tests.
  - `git status --short` → clean.