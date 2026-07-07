Implemented TRD-020 review round 2 fix only.

Changed files:
- packages/foreman_server/lib/foreman_server/debug_views.ex
- packages/foreman_server/test/debug_views_test.exs
- packages/foreman_server/test/http_router_test.exs

Commit:
- e24e445a fix: harden Elixir debug truncation

Validation:
- `cd packages/foreman_server && mix format && mix test test/debug_views_test.exs test/http_router_test.exs` exit 0; 16 tests, 0 failures.
- `cd packages/foreman_server && mix test && mix compile --warnings-as-errors && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md ...` exit 0; 73 tests, 0 failures; compile clean; TypeScript pass; TRD parse 52 tasks warnings [].
- `git commit -m "fix: harden Elixir debug truncation"` exit 0; commit e24e445a.

Diff summary:
- Fixed debug view redaction for `key=value`, `key: value`, and bearer auth strings without leaking values.
- Replaced byte truncation with grapheme-safe truncation bounded by UTF-8 byte size and preserving the truncation suffix.
- Added direct debug view tests for colon-form secrets, bearer secrets, compact/raw Unicode truncation, valid JSON encoding.
- Added HTTP raw log regression proving long Unicode output encodes as JSON and redacts colon/bearer secrets.

Residual risks:
- None known for scoped TRD-020 redaction/truncation fix.

Git status after report write:
- Expected untracked/modified subagent output artifacts only.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Regex redaction now handles authorization key with ':' or '=', bare Bearer tokens, and token/password/secret/api_key with ':' or '='; tests assert token: colon-token, password: colon-password/hunter2, Authorization: Bearer auth-token/bearer-token, api_key: colon-key, and Bearer loose-token do not appear in compact/raw/debug/HTTP output."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "truncate_string/1 now truncates by String.graphemes while enforcing byte budget before appending suffix; direct DebugViews and HTTP raw log tests assert String.valid?/1 and Jason decode/encode success for 2,000 emoji logs."
    },
    {
      "id": "criterion-3",
      "status": "satisfied",
      "evidence": "Updated packages/foreman_server/test/debug_views_test.exs and packages/foreman_server/test/http_router_test.exs with colon/bearer redaction and long Unicode compact/raw/HTTP log regressions."
    },
    {
      "id": "criterion-4",
      "status": "satisfied",
      "evidence": "Required validation passed: full mix test 73 tests 0 failures; mix compile --warnings-as-errors passed; npx tsc --noEmit passed; TRD parser passed with 52 tasks and warnings []."
    },
    {
      "id": "criterion-5",
      "status": "satisfied",
      "evidence": "Created one scoped fix commit e24e445a fix: harden Elixir debug truncation."
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
      "summary": "Initial focused test run exited 2 due incorrect Regex.replace argument order; fixed immediately."
    },
    {
      "command": "cd packages/foreman_server && mix format && mix test test/debug_views_test.exs test/http_router_test.exs",
      "result": "passed",
      "summary": "Focused debug view and HTTP route tests passed: 16 tests, 0 failures."
    },
    {
      "command": "cd packages/foreman_server && mix test && mix compile --warnings-as-errors && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
      "result": "passed",
      "summary": "Required validation passed: 73 tests, 0 failures; compile clean; TypeScript pass; TRD parser warnings []."
    },
    {
      "command": "git add packages/foreman_server/lib/foreman_server/debug_views.ex packages/foreman_server/test/debug_views_test.exs packages/foreman_server/test/http_router_test.exs && git commit -m 'fix: harden Elixir debug truncation'",
      "result": "passed",
      "summary": "Committed scoped fix as e24e445a."
    },
    {
      "command": "git status --short",
      "result": "passed",
      "summary": "After commit, no staged files; only subagent output artifact(s) remain outside scoped code changes."
    }
  ],
  "validationOutput": [
    "Focused tests: 16 tests, 0 failures",
    "Full mix test: 73 tests, 0 failures",
    "mix compile --warnings-as-errors: passed",
    "npx tsc --noEmit: passed with no output",
    "TRD parser: trd parse ok tasks 52 warnings []",
    "Commit: e24e445a fix: harden Elixir debug truncation"
  ],
  "residualRisks": [],
  "noStagedFiles": true,
  "diffSummary": "Hardened ForemanServer.DebugViews redaction to cover colon/equal secret assignments and bearer authorization forms, replaced byte slicing with UTF-8/grapheme-safe truncation, and added direct + HTTP regression tests for secret redaction and long Unicode log JSON encoding.",
  "reviewFindings": [],
  "manualNotes": "Scoped to TRD-020 review round 2 redaction/truncation fix only. Did not alter task state or broader debug view behavior.",
  "notes": "Output artifact itself may appear in git status after this report write."
}
```
