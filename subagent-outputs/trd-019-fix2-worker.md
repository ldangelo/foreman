Implemented TRD-019 review round 2 API-contract fix only.

Changed files:
- packages/foreman_server/lib/foreman_server/command_router.ex
- packages/foreman_server/lib/foreman_server/http/router.ex
- packages/foreman_server/test/integration_ingestion_test.exs
- packages/foreman_server/test/http_router_test.exs

Commit:
- 7bc0d086 fix: accept top-level integration commands

Validation:
- `cd packages/foreman_server && mix format && mix test test/integration_ingestion_test.exs test/http_router_test.exs` exit 0; 14 tests, 0 failures.
- `cd packages/foreman_server && mix test && mix compile --warnings-as-errors && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md ...` exit 0; 63 tests, 0 failures; compile clean; TypeScript pass; TRD parse 52 tasks warnings [].
- `git commit -m "fix: accept top-level integration commands"` exit 0; commit 7bc0d086.
- `git status --short` after commit showed only untracked subagent output artifacts.

Diff summary:
- CommandRouter now accepts TRD-shaped top-level `ExternalTriggerCommand` / `external.trigger` without requiring a `command_id` or payload envelope.
- HTTP `/api/v1/commands` now permits that documented top-level shape and passes it through to CommandRouter.
- Existing envelope-style external trigger commands still route through the same ingestion path.
- Added direct CommandRouter regression coverage for top-level atom/string commands and duplicate dedupe.
- Added HTTP regression coverage for top-level JSON command shape and duplicate dedupe.

Residual risks:
- None known for scoped TRD-019 API contract fix.

Git status after report write:
- No staged files expected.
- Untracked subagent output artifacts remain.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "CommandRouter has ExternalTriggerCommand/external.trigger top-level clauses and tests accept top-level source/project_id/external_id/event_type/url fields without command_id or payload envelope."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "Existing envelope-style ExternalTriggerCommand test remains and passed; external_trigger_payload preserves nested payload behavior."
    },
    {
      "id": "criterion-3",
      "status": "satisfied",
      "evidence": "Added direct CommandRouter top-level regression test and HTTP /api/v1/commands top-level JSON regression test; both assert duplicate dedupe."
    },
    {
      "id": "criterion-4",
      "status": "satisfied",
      "evidence": "Required validation passed: mix test 63 tests, compile warnings-as-errors, npx tsc --noEmit, and TRD parser warnings []."
    },
    {
      "id": "criterion-5",
      "status": "satisfied",
      "evidence": "Created one fix commit: 7bc0d086 fix: accept top-level integration commands."
    }
  ],
  "changedFiles": [
    "packages/foreman_server/lib/foreman_server/command_router.ex",
    "packages/foreman_server/lib/foreman_server/http/router.ex",
    "packages/foreman_server/test/integration_ingestion_test.exs",
    "packages/foreman_server/test/http_router_test.exs"
  ],
  "testsAddedOrUpdated": [
    "packages/foreman_server/test/integration_ingestion_test.exs",
    "packages/foreman_server/test/http_router_test.exs"
  ],
  "commandsRun": [
    {
      "command": "cd packages/foreman_server && mix format && mix test test/integration_ingestion_test.exs test/http_router_test.exs",
      "result": "passed",
      "summary": "Focused command/http integration tests passed: 14 tests, 0 failures."
    },
    {
      "command": "cd packages/foreman_server && mix test && mix compile --warnings-as-errors && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
      "result": "passed",
      "summary": "Required validation passed: 63 tests, 0 failures; compile clean; TypeScript pass; TRD parse pass."
    },
    {
      "command": "git add ... && git commit -m 'fix: accept top-level integration commands'",
      "result": "passed",
      "summary": "Committed scoped fix as 7bc0d086."
    },
    {
      "command": "git status --short",
      "result": "passed",
      "summary": "No staged files after commit; only untracked subagent output artifacts."
    }
  ],
  "validationOutput": [
    "Focused mix tests: 14 tests, 0 failures",
    "Full mix test: 63 tests, 0 failures",
    "mix compile --warnings-as-errors: passed",
    "npx tsc --noEmit: passed with no output",
    "TRD parser: trd parse ok tasks 52 warnings []"
  ],
  "residualRisks": [],
  "noStagedFiles": true,
  "diffSummary": "Accepted TRD-shaped top-level ExternalTriggerCommand at CommandRouter and HTTP /api/v1/commands while preserving existing envelope-style behavior; added direct and HTTP regression tests proving top-level command acceptance and duplicate dedupe.",
  "reviewFindings": [],
  "manualNotes": "Scoped to TRD-019 API contract fix only. Did not alter bead state or broader integration behavior.",
  "notes": "Output report file is untracked after final write by design."
}
```
