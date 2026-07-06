## Review

REJECTED. No edits. Did not write output file due explicit no-edit.

- Correct:
  - TRD-020 core views covered:
    - logs compact/raw: `debug_views_test.exs:29-52`
    - debug artifacts/reports: `debug_views_test.exs:54-75`
    - purge/restart summaries: `debug_views_test.exs:77-115`
  - Last fix covers many aliases + JSON-ish strings:
    - impl: `debug_views.ex:9-17`, `266-280`
    - tests: `debug_views_test.exs:118-245`, `http_router_test.exs:114-153`
  - Focused + full Elixir tests pass.

- Fixed:
  - None. Review-only.

- Blocker:
  - Inline redaction regressed hyphenated `api-key`.
  - Current regex derives exact names from `@secret_key_names`; no `api-key` variant. `debug_views.ex:9-17`, `276-279`
  - Prior regex covered `api[_-]?key`. Evidence: `git show 0d97079b^...debug_views.ex:270-273`
  - Public repro leaked: `"api-key=hyphen-secret api_key=[REDACTED]"`.
  - This violates TRD secret/log safety: `docs/TRD/...md:300`.

- Fix worth doing now:
  - Accept hyphen variants for underscore keys in inline redaction: `api-key`, `access-token`, `auth-token`, `client-secret`.
  - Add regression tests in compact/raw/debug and HTTP raw.

- Optional:
  - Add direct `DebugViews.report/1` secret assertion. Debug timeline indirectly covers failures, but report endpoint lacks a secret fixture.
  - `progress.md` missing. `plan.md` read; unrelated Postgres migration plan.

- Commands:
  - `git status --short && git rev-parse --short HEAD && git show --stat --oneline 0d97079b` → passed.
  - `git show --patch 0d97079b ...` → inspected.
  - `cd packages/foreman_server && mix test test/debug_views_test.exs test/http_router_test.exs` → passed, 16 tests.
  - `cd packages/foreman_server && mix test` → passed, 73 tests.
  - one-off `mix run` redaction repro → passed command, exposed leak.
  - `git status --short` → clean.