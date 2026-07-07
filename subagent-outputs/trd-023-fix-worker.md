Implemented TRD-023 review fixes only.

Changed files:
- packages/foreman_server/lib/foreman_server/migration_importer.ex
- packages/foreman_server/test/migration_importer_test.exs
- src/cli/__tests__/import-server.test.ts

Commit:
- e5445a54 fix: harden Elixir migration importer validation

Validation:
- `cd packages/foreman_server && mix format && mix test test/migration_importer_test.exs` exit 0; 8 tests, 0 failures.
- `cd packages/foreman_server && mix test && mix compile --warnings-as-errors` exit 0; 101 tests, 0 failures; compile clean.
- `npx vitest run src/cli/__tests__/import-server.test.ts src/cli/__tests__/legacy-coexistence.test.ts --reporter=dot` exit 0; 2 files, 6 tests passed.
- `npx tsc --noEmit` exit 0.
- `node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md` exit 0; 52 tasks, warnings [].

Diff summary:
- MigrationImporter now normalizes and pre-validates the full payload before appending any events.
- Invalid list records, required ids, run status enum values, config shape, and duplicate ids per record collection are rejected before side effects.
- Unknown run status no longer silently imports as completed; allowed terminal statuses are completed/failed/blocked.
- Completed migration_id retries still return the existing completed import result without appending duplicate events.
- Added ExUnit coverage for atomic malformed later records, idempotent retry, invalid item/no crash, unknown status, duplicates, and failed/blocked run projection.
- Added Vitest coverage for `foreman import --to-elixir --file` dispatching `migration.import` to the Elixir server.

Residual risks:
- Importer still consumes normalized migration JSON only; direct scraping of arbitrary TS stores remains intentionally out of scope.
- Duplicate detection is per record collection/type, not cross-type, because streams/projections are typed separately.

Git status before writing this report: clean.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "MigrationImporter.import/1 now calls validate_input/1 before execute_import/3; validation normalizes all collections, validates config/ids/statuses, and checks duplicates before MigrationImportStarted or any record events are appended. Test `malformed later records fail before side effects and can be retried after correction` asserts EventStore.all() is unchanged."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "Invalid list items return {:missing_or_invalid, {collection, index}}, unknown run statuses return {:invalid_status, :runs}, duplicate IDs return {:duplicate_id, collection, id}; tests assert no events and no crashes for these cases."
    },
    {
      "id": "criterion-3",
      "status": "satisfied",
      "evidence": "Completed migration_id retry still uses existing_completed_import/1 and returns existing: true; test asserts event count is unchanged on retry."
    },
    {
      "id": "criterion-4",
      "status": "satisfied",
      "evidence": "Added src/cli/__tests__/import-server.test.ts verifying `foreman import --to-elixir --file migration.json --command-id ...` sends command_type `migration.import` with payload and metadata via ElixirServerClient."
    },
    {
      "id": "criterion-5",
      "status": "satisfied",
      "evidence": "Required validation passed and one fix commit was created: e5445a54 fix: harden Elixir migration importer validation."
    }
  ],
  "changedFiles": [
    "packages/foreman_server/lib/foreman_server/migration_importer.ex",
    "packages/foreman_server/test/migration_importer_test.exs",
    "src/cli/__tests__/import-server.test.ts"
  ],
  "testsAddedOrUpdated": [
    "packages/foreman_server/test/migration_importer_test.exs",
    "src/cli/__tests__/import-server.test.ts"
  ],
  "commandsRun": [
    {
      "command": "cd packages/foreman_server && mix format && mix test test/migration_importer_test.exs",
      "result": "passed",
      "summary": "exit 0; focused migration importer tests passed: 8 tests, 0 failures."
    },
    {
      "command": "npx vitest run src/cli/__tests__/import-server.test.ts src/cli/__tests__/legacy-coexistence.test.ts --reporter=dot",
      "result": "failed",
      "summary": "initial run failed because a full node:path mock omitted join; fixed by partial-mocking path."
    },
    {
      "command": "npx vitest run src/cli/__tests__/import-server.test.ts src/cli/__tests__/legacy-coexistence.test.ts --reporter=dot",
      "result": "passed",
      "summary": "exit 0; relevant import/legacy Vitest tests passed: 2 files, 6 tests."
    },
    {
      "command": "cd packages/foreman_server && mix test && mix compile --warnings-as-errors",
      "result": "passed",
      "summary": "exit 0; full Elixir suite passed: 101 tests, 0 failures; compile warnings-as-errors clean."
    },
    {
      "command": "npx tsc --noEmit",
      "result": "passed",
      "summary": "exit 0; TypeScript typecheck passed with no output."
    },
    {
      "command": "node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
      "result": "passed",
      "summary": "exit 0; TRD parser passed: 52 tasks, warnings []."
    },
    {
      "command": "git diff --check",
      "result": "passed",
      "summary": "exit 0; no whitespace errors."
    },
    {
      "command": "git commit -m \"fix: harden Elixir migration importer validation\"",
      "result": "passed",
      "summary": "exit 0; created commit e5445a54."
    },
    {
      "command": "git status --short",
      "result": "passed",
      "summary": "exit 0; clean before writing this report."
    }
  ],
  "validationOutput": [
    "Focused migration importer tests: 8 tests, 0 failures",
    "Relevant Vitest import/legacy tests: 2 files passed, 6 tests passed",
    "Full mix test: 101 tests, 0 failures",
    "mix compile --warnings-as-errors: passed",
    "npx tsc --noEmit: passed with no output",
    "TRD parser: trd parse ok tasks 52 warnings []",
    "Commit: e5445a54 fix: harden Elixir migration importer validation"
  ],
  "residualRisks": [
    "Importer consumes normalized migration JSON only; direct scraping of arbitrary TS store files remains out of scope.",
    "Duplicate detection is per collection/type, not cross-type, because migrated streams/projections are typed separately."
  ],
  "noStagedFiles": true,
  "diffSummary": "Hardened TRD-023 migration import by validating the full normalized payload before appending events, rejecting malformed records, unknown run statuses, invalid config, and duplicate ids without side effects; preserved completed migration retry idempotency; added ExUnit edge coverage and a CLI server-dispatch Vitest for `foreman import --to-elixir --file`.",
  "reviewFindings": [],
  "manualNotes": "Scoped to TRD-023 review fixes only. No task state changes made.",
  "notes": "Writing this report leaves subagent-outputs/trd-023-fix-worker.md untracked by design."
}
```
