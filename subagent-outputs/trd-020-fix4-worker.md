Implemented TRD-020 hyphenated redaction regression fix only.

Changed files:
- packages/foreman_server/lib/foreman_server/debug_views.ex
- packages/foreman_server/test/debug_views_test.exs
- packages/foreman_server/test/http_router_test.exs

Commit:
- 500f3ca7 fix: redact Elixir debug hyphen secrets

Validation:
- `cd packages/foreman_server && mix format && mix test test/debug_views_test.exs test/http_router_test.exs` exit 0; 16 tests, 0 failures.
- `(cd packages/foreman_server && mix test && mix compile --warnings-as-errors)` exit 0; 73 tests, 0 failures; compile clean.
- `npx tsc --noEmit` exit 0.
- `node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md` exit 0; TRD parse 52 tasks, warnings [].
- `git status --short` after commit showed no staged files; untracked subagent output artifacts remain.

Diff summary:
- Expanded `ForemanServer.DebugViews` inline secret regex generation so every configured underscore secret key also matches a hyphen alias.
- Added compact/raw/debug regression coverage for `api-key`, `access-token`, `auth-token`, and `client-secret` forms.
- Added HTTP raw log regression coverage for hyphenated secret aliases before long Unicode output so redaction is proven, not hidden by truncation.
- Preserved existing bearer, colon/equal, JSON-ish quoted secret, and UTF-8 safe truncation behavior.

Residual risks:
- None known for this scoped fix.

Git status after report write:
- No staged files expected.
- Untracked subagent output artifacts remain.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "DebugViews now expands each configured secret key with an underscore-to-hyphen alias before building the inline regex; tests assert api-key, access-token, auth-token, and client-secret values are absent from compact/raw/debug and HTTP raw outputs."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "Focused debug/http tests passed with existing bearer, colon/equal, JSON-ish quoted secrets, and UTF-8 truncation tests still active."
    },
    {
      "id": "criterion-3",
      "status": "satisfied",
      "evidence": "Focused tests, full mix suite, mix compile --warnings-as-errors, npx tsc --noEmit, and TRD parser all passed."
    },
    {
      "id": "criterion-4",
      "status": "satisfied",
      "evidence": "Created one scoped commit: 500f3ca7 fix: redact Elixir debug hyphen secrets."
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
      "summary": "Initial focused run found test value collisions with redacted key names; adjusted test secret values to avoid false positives."
    },
    {
      "command": "cd packages/foreman_server && mix format && mix test test/debug_views_test.exs test/http_router_test.exs",
      "result": "passed",
      "summary": "Focused debug/http tests passed: 16 tests, 0 failures."
    },
    {
      "command": "(cd packages/foreman_server && mix test && mix compile --warnings-as-errors)",
      "result": "passed",
      "summary": "Full Elixir suite passed: 73 tests, 0 failures; compile warnings-as-errors clean."
    },
    {
      "command": "npx tsc --noEmit",
      "result": "passed",
      "summary": "TypeScript typecheck passed with no output."
    },
    {
      "command": "node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
      "result": "passed",
      "summary": "TRD parser passed: 52 tasks, warnings []."
    },
    {
      "command": "git add ... && git commit -m 'fix: redact Elixir debug hyphen secrets'",
      "result": "passed",
      "summary": "Committed scoped fix as 500f3ca7."
    },
    {
      "command": "git status --short && git rev-parse --short HEAD",
      "result": "passed",
      "summary": "No staged files after commit; HEAD 500f3ca7; untracked subagent output artifacts remain."
    }
  ],
  "validationOutput": [
    "Focused tests: 16 tests, 0 failures",
    "Full mix test: 73 tests, 0 failures",
    "mix compile --warnings-as-errors: passed",
    "npx tsc --noEmit: passed with no output",
    "TRD parser: trd parse ok tasks 52 warnings []",
    "Commit: 500f3ca7 fix: redact Elixir debug hyphen secrets"
  ],
  "residualRisks": [],
  "noStagedFiles": true,
  "diffSummary": "ForemanServer.DebugViews now redacts inline hyphen aliases for configured underscore secret keys by adding underscore-to-hyphen variants to the generated secret-key regex. Debug view and HTTP tests now cover api-key, access-token, auth-token, and client-secret forms while preserving prior redaction and UTF-8 truncation coverage.",
  "reviewFindings": [],
  "manualNotes": "Scoped to TRD-020 debug view inline redaction only. Did not alter task state or broader behavior.",
  "notes": "Untracked subagent output artifacts remain by design."
}
```
