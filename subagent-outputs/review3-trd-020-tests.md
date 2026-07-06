## Review

APPROVED for TRD-020 / AC-017 test sufficiency.

- Correct:
  - AC-017-1 covered: compact/raw logs via `DebugViews.logs/2` and tests.  
    Evidence: `debug_views.ex:54-67`, `125-149`; `debug_views_test.exs:29-52`.
  - AC-017-2 covered: debug timeline/report refs artifacts + reports.  
    Evidence: `debug_views.ex:83-85`, `104-111`, `193-199`; `debug_views_test.exs:54-75`.
  - AC-017-3 covered incl restart/replay after external log purge.  
    Evidence: `event_store.ex:57-62`, `135-149`; `debug_views_test.exs:77-115`.
  - Redaction/truncation fixed and tested:
    - Redaction: `debug_views.ex:241-257`, `260-274`; tests `debug_views_test.exs:118-209`.
    - UTF-8-safe truncation: `debug_views.ex:277-297`; tests `debug_views_test.exs:211-235`.
    - HTTP Unicode/raw regression: `http_router_test.exs:114-144`.
  - HTTP endpoint coverage adequate: auth, compact/raw, invalid view, report/debug envelopes.  
    Evidence: `router.ex:67-107`, `217-221`; `http_router_test.exs:60-170`.
  - `assistant_message.message` preserved/rendered.  
    Evidence: `worker_protocol.ex:73-74`, `debug_views.ex:172-173`; test `debug_views_test.exs:237-260`.

- Fixed:
  - None by me. No edits per review-only/no-edit.
  - Did not write `subagent-outputs/review3-trd-020-tests.md` because user also said no edits.

- Blocker:
  - None found.

- Fixes worth doing now:
  - Optional security hardening: inline redaction only covers `key[:=]value` and bearer forms (`debug_views.ex:260-274`). JSON-quoted log text like `"token":"x"` is not covered by that regex. Structured maps are covered by `secret_key?/1`.

- Optional:
  - `ProjectionStore.logs_by_run` stores raw payloads (`projection_store.ex:720-722`). Not exposed by `DebugViews`, but broader “secrets in projections” wording may need future hardening.
  - `DebugViews.run_events/1` scans `EventStore.all()` (`debug_views.ex:117-120`). OK for TRD-020; scale later.
  - `progress.md` missing: ENOENT.
  - `plan.md` appears unrelated Postgres migration plan.

- Commands:
  - `git log --oneline -12` / `git show --stat e24e445a` inspected.
  - `cd packages/foreman_server && mix test test/debug_views_test.exs test/http_router_test.exs` → passed, 16 tests.
  - `cd packages/foreman_server && mix test` → passed, 73 tests.
  - `cd packages/foreman_server && mix compile --warnings-as-errors` → passed.
  - `git status --short` → clean.