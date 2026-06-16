Implemented TRD-019 review fixes only.

Changed files:
- packages/foreman_server/README.md
- packages/foreman_server/lib/foreman_server/command_router.ex
- packages/foreman_server/lib/foreman_server/integration_ingestion.ex
- packages/foreman_server/test/http_router_test.exs
- packages/foreman_server/test/integration_ingestion_test.exs

Commit:
- 64bc7512 fix: route Elixir integration commands

Validation:
- `cd packages/foreman_server && mix format && mix test && mix compile --warnings-as-errors && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md ...`
  - Exit: 0
  - Mix: 61 tests, 0 failures
  - Compile warnings-as-errors: pass
  - TypeScript: pass
  - TRD parser: 52 tasks, warnings []
- `git status --short && git rev-parse --short HEAD`
  - Exit: 0
  - Clean before writing this report; HEAD 64bc7512

Diff summary:
- Routed `ExternalTriggerCommand` / `external.trigger` through `ForemanServer.CommandRouter` into `ForemanServer.IntegrationIngestion` so `/api/v1/commands` now creates/dedupes integration tasks.
- Aligned fallback dedupe keys with TRD for GitHub (`github:<repo>:<eventId>`) and sentinel (`sentinel:<project>:<fingerprint-or-external_id>`), preserving explicit idempotency/dedupe override.
- Required Jira/GitHub external links via `external_link` or `url`.
- Made dedupe-only partial state retry-safe: if dedupe exists but task projection is missing, retry dispatches task creation instead of returning duplicate/no-op.
- Replaced command-router dynamic `String.to_atom` normalization with whitelisted top-level key normalization.
- Added command-router and HTTP boundary tests for ExternalTriggerCommand happy path, duplicate behavior, validation, missing link rejection, unsupported/missing fields, and dedupe-without-task recovery.

Residual risks:
- None known for scoped TRD-019 fixes.

Git status after report write:
- The report file itself is untracked by design.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "CommandRouter handles ExternalTriggerCommand/external.trigger via IntegrationIngestion.ingest/1; HTTP /api/v1/commands test creates and dedupes a GitHub integration task."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "IntegrationIngestion fallback keys now use github:<repo>:<eventId> and sentinel:<project>:<fingerprint-or-external_id>; tests assert github:fortium/foreman:evt-17 and sentinel:foreman:mix-test:flaky."
    },
    {
      "id": "criterion-3",
      "status": "satisfied",
      "evidence": "Jira/GitHub external_link/url is required; integration and HTTP tests assert missing link returns {:missing_or_invalid, :external_link}."
    },
    {
      "id": "criterion-4",
      "status": "satisfied",
      "evidence": "dedupe_state checks whether the projected task exists; if dedupe exists without task it dispatches task.create with recovered: true; test pre-seeds IntegrationCommandIngested without TaskCreated and verifies retry creates the task."
    },
    {
      "id": "criterion-5",
      "status": "satisfied",
      "evidence": "Focused integration and HTTP tests added; full required validation passed: mix test 61 tests, compile warnings-as-errors, npx tsc --noEmit, and TRD parser."
    }
  ],
  "changedFiles": [
    "packages/foreman_server/README.md",
    "packages/foreman_server/lib/foreman_server/command_router.ex",
    "packages/foreman_server/lib/foreman_server/integration_ingestion.ex",
    "packages/foreman_server/test/http_router_test.exs",
    "packages/foreman_server/test/integration_ingestion_test.exs"
  ],
  "testsAddedOrUpdated": [
    "packages/foreman_server/test/http_router_test.exs",
    "packages/foreman_server/test/integration_ingestion_test.exs"
  ],
  "commandsRun": [
    {
      "command": "cd packages/foreman_server && mix format && mix test test/integration_ingestion_test.exs test/http_router_test.exs",
      "result": "passed",
      "summary": "Focused integration ingestion and HTTP command boundary tests passed: 12 tests, 0 failures after fix."
    },
    {
      "command": "cd packages/foreman_server && mix format && mix test && mix compile --warnings-as-errors && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
      "result": "passed",
      "summary": "Required validation passed: 61 tests, 0 failures; compile warnings-as-errors clean; TypeScript passed; TRD parser passed."
    },
    {
      "command": "git add ... && git commit -m 'fix: route Elixir integration commands'",
      "result": "passed",
      "summary": "Committed fix as 64bc7512."
    },
    {
      "command": "git status --short && git rev-parse --short HEAD",
      "result": "passed",
      "summary": "Clean before writing report; HEAD 64bc7512."
    }
  ],
  "validationOutput": [
    "mix test: 61 tests, 0 failures",
    "mix compile --warnings-as-errors: passed",
    "npx tsc --noEmit: passed with no output",
    "TRD parser: trd parse ok tasks 52 warnings []",
    "git status --short before report: clean"
  ],
  "residualRisks": [],
  "noStagedFiles": true,
  "diffSummary": "Routed ExternalTriggerCommand through CommandRouter to IntegrationIngestion, added HTTP command coverage, aligned GitHub/sentinel fallback dedupe keys with TRD, required Jira/GitHub links, made dedupe-only partial state retry-safe, and replaced unsafe command-router string-to-atom key normalization with a whitelist.",
  "reviewFindings": [],
  "manualNotes": "Scoped to TRD-019 review fixes only. Did not reopen beads.",
  "notes": "Output report file is untracked after final write by design."
}
```
