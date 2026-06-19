Implemented TRD-020 security blocker fix only.

Changed files:
- packages/foreman_server/lib/foreman_server/debug_views.ex
- packages/foreman_server/test/debug_views_test.exs
- packages/foreman_server/test/http_router_test.exs

Commit:
- 0d97079b fix: redact Elixir debug secret aliases

Validation:
- `cd packages/foreman_server && mix format && mix test test/debug_views_test.exs test/http_router_test.exs` exit 0; 16 tests, 0 failures.
- `cd packages/foreman_server && mix test && mix compile --warnings-as-errors && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md ...` exit 0; 73 tests, 0 failures; compile clean; TypeScript pass; TRD parse 52 tasks warnings [].
- `git commit -m "fix: redact Elixir debug secret aliases"` exit 0; commit 0d97079b.
- `git status --short` after commit: untracked subagent output artifacts only, no staged files.

Diff summary:
- Expanded `ForemanServer.DebugViews` inline redaction to derive its regex from all configured secret key names, including `access_token`, `auth_token`, and `client_secret`.
- Added support for quoted JSON-ish key/value redaction such as `{"token":"..."}` and `{"client_secret": "..."}` while preserving bearer/authorization and UTF-8-safe truncation behavior.
- Added focused direct debug view and HTTP raw log regression coverage for configured secret aliases and quoted JSON-ish secrets.

Residual risks:
- None known for scoped TRD-020 redaction fix.

Git status after report write:
- This report and existing review output artifacts are untracked; no staged files expected.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Inline redaction now builds its key pattern from @secret_key_names, covering access_token, auth_token, client_secret, authorization, api_key/apikey, password, secret, and token. Debug view tests assert access_token=atok, auth_token: authv, client_secret=csec, plus assistant/debug variants do not appear."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "Redaction regex accepts optional quoted keys and quoted/unquoted values. Tests assert {\"token\":\"jsonsecret\"}, {\"client_secret\": \"json-client-secret\"}, and HTTP JSON-ish secret strings are removed from compact/raw/debug/HTTP output."
    },
    {
      "id": "criterion-3",
      "status": "satisfied",
      "evidence": "Existing bearer, colon, equal, and UTF-8 truncation tests still pass; focused debug/http tests passed with 16 tests and full suite passed with 73 tests."
    },
    {
      "id": "criterion-4",
      "status": "satisfied",
      "evidence": "Focused and full validation passed: mix focused tests, full mix test, mix compile --warnings-as-errors, npx tsc --noEmit, and TRD parser."
    },
    {
      "id": "criterion-5",
      "status": "satisfied",
      "evidence": "Created one scoped fix commit: 0d97079b fix: redact Elixir debug secret aliases."
    }
  ],
  "changedFiles": [
    "packages/foreman_server/lib/foreman_server/debug_views.ex",
    "packages/foreman_server/test/debug_views_test.exs",
    "packages/foreman_server/test/http_router_test.exs"
  ],
  "testsAddedOrUpdated": [
    "packages/foreman_server/test/debug_views_test.exs",
    "packages/foreman_server/test/http_router_test.exs"
  ],
  "commandsRun": [
    {
      "command": "cd packages/foreman_server && mix format && mix test test/debug_views_test.exs test/http_router_test.exs",
      "result": "failed",
      "summary": "Initial focused run exposed a bad module attribute assignment and failing redaction coverage; fixed before final validation."
    },
    {
      "command": "cd packages/foreman_server && mix format && mix test test/debug_views_test.exs test/http_router_test.exs",
      "result": "passed",
      "summary": "Final focused debug view and HTTP route tests passed: 16 tests, 0 failures."
    },
    {
      "command": "cd packages/foreman_server && mix test && mix compile --warnings-as-errors && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
      "result": "passed",
      "summary": "Required validation passed: 73 tests, 0 failures; compile clean; TypeScript pass; TRD parser warnings []."
    },
    {
      "command": "git add packages/foreman_server/lib/foreman_server/debug_views.ex packages/foreman_server/test/debug_views_test.exs packages/foreman_server/test/http_router_test.exs && git commit -m 'fix: redact Elixir debug secret aliases'",
      "result": "passed",
      "summary": "Committed scoped fix as 0d97079b."
    },
    {
      "command": "git status --short && git rev-parse --short HEAD",
      "result": "passed",
      "summary": "No staged files after commit; HEAD 0d97079b; untracked subagent output artifacts remain."
    }
  ],
  "validationOutput": [
    "Focused tests: 16 tests, 0 failures",
    "Full mix test: 73 tests, 0 failures",
    "mix compile --warnings-as-errors: passed",
    "npx tsc --noEmit: passed with no output",
    "TRD parser: trd parse ok tasks 52 warnings []",
    "Commit: 0d97079b fix: redact Elixir debug secret aliases"
  ],
  "residualRisks": [],
  "noStagedFiles": true,
  "diffSummary": "ForemanServer.DebugViews now redacts inline secrets using all configured secret key names, including snake_case aliases and quoted JSON-ish key/value strings, while preserving authorization/bearer redaction and UTF-8-safe truncation. Debug view and HTTP route tests now cover access_token, auth_token, client_secret, quoted token/client_secret, and previous redaction/truncation behavior.",
  "reviewFindings": [],
  "manualNotes": "Scoped to TRD-020 debug view redaction fix only. Did not alter bead state or broader debug view behavior.",
  "notes": "Output report file and prior review output artifact are untracked after final write by design."
}
```
