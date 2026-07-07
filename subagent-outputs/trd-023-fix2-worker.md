Implemented TRD-023 review round 2 importer validation fix only.

Changed files:
- packages/foreman_server/lib/foreman_server/migration_importer.ex
- packages/foreman_server/test/migration_importer_test.exs

Commit:
- 90a7a524 fix: validate migration run fields

Validation:
- `cd packages/foreman_server && mix format && mix test test/migration_importer_test.exs` exit 0; 9 tests, 0 failures.
- `cd packages/foreman_server && mix test && mix compile --warnings-as-errors` exit 0; 102 tests, 0 failures; compile clean.
- `npx vitest run src/cli/__tests__/import-server.test.ts src/cli/__tests__/legacy-coexistence.test.ts --reporter=dot` exit 0; 2 files, 6 tests passed.
- `npx tsc --noEmit` exit 0; no output.
- `node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md` exit 0; parse ok, 52 tasks, warnings [].
- `git diff --check` exit 0; no whitespace errors.

Diff summary:
- MigrationImporter now pre-validates run optional fields before `execute_import/3` appends any events: `phase_order` must be absent or a binary list, `current_phase` must be absent or binary, and `retry_history` must be absent or list.
- Added regression coverage for a malformed later run with `phase_order: "bad"`; the import returns `{:missing_or_invalid, :phase_order}` and leaves `EventStore.all()` unchanged.
- Failed terminal run imports now pass the computed fallback phase into `RunFailed`, so a failed/blocked terminal run with `phase_order` but no `current_phase` keeps the fallback current phase in projections.

Residual risks:
- Importer still consumes normalized migration JSON only; no migration JSON scope broadening.
- `retry_history` is validated as a list, not deeply schema-validated, because the import path treats it as an opaque projection payload.

Git status after report write:
- Expected untracked artifacts only: `subagent-outputs/review2-trd-023-correctness.md` (pre-existing reviewer artifact) and this report file.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "validate_runs/1 now checks optional run fields before execute_import/3: current_phase absent/binary, phase_order absent/list with binary elements, retry_history absent/list. Validation happens in validate_input/1 before MigrationImportStarted or record events are appended."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "Added test `malformed run optional fields fail before side effects`, using a payload with a valid earlier run and a later run with phase_order: \"bad\". It asserts {:missing_or_invalid, :phase_order} and EventStore.all() unchanged via assert_validation_without_events/2."
    },
    {
      "id": "criterion-3",
      "status": "satisfied",
      "evidence": "Required validation passed: focused migration importer tests, full mix test plus compile warnings-as-errors, relevant Vitest import/legacy tests, npx tsc --noEmit, and TRD parser."
    },
    {
      "id": "criterion-4",
      "status": "satisfied",
      "evidence": "Created one fix commit: 90a7a524 fix: validate migration run fields."
    }
  ],
  "changedFiles": [
    "packages/foreman_server/lib/foreman_server/migration_importer.ex",
    "packages/foreman_server/test/migration_importer_test.exs"
  ],
  "testsAddedOrUpdated": [
    "packages/foreman_server/test/migration_importer_test.exs"
  ],
  "commandsRun": [
    {
      "command": "cd packages/foreman_server && mix format && mix test test/migration_importer_test.exs",
      "result": "passed",
      "summary": "exit 0; focused migration importer tests passed: 9 tests, 0 failures."
    },
    {
      "command": "cd packages/foreman_server && mix test && mix compile --warnings-as-errors",
      "result": "passed",
      "summary": "exit 0; full Elixir suite passed: 102 tests, 0 failures; compile warnings-as-errors clean."
    },
    {
      "command": "npx vitest run src/cli/__tests__/import-server.test.ts src/cli/__tests__/legacy-coexistence.test.ts --reporter=dot",
      "result": "passed",
      "summary": "exit 0; relevant TS import/legacy tests passed: 2 files, 6 tests."
    },
    {
      "command": "npx tsc --noEmit",
      "result": "passed",
      "summary": "exit 0; TypeScript typecheck passed with no output."
    },
    {
      "command": "node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
      "result": "passed",
      "summary": "exit 0; TRD parse ok: 52 tasks, warnings []."
    },
    {
      "command": "git diff --check",
      "result": "passed",
      "summary": "exit 0; no whitespace errors."
    },
    {
      "command": "git add packages/foreman_server/lib/foreman_server/migration_importer.ex packages/foreman_server/test/migration_importer_test.exs && git commit -m 'fix: validate migration run fields'",
      "result": "passed",
      "summary": "exit 0; created commit 90a7a524."
    },
    {
      "command": "git status --short",
      "result": "passed",
      "summary": "exit 0 after commit; only pre-existing untracked review artifact before this report write."
    }
  ],
  "validationOutput": [
    "Focused migration_importer_test: 9 tests, 0 failures",
    "Full mix test: 102 tests, 0 failures",
    "mix compile --warnings-as-errors: passed",
    "Relevant Vitest: 2 files passed, 6 tests passed",
    "npx tsc --noEmit: passed with no output",
    "TRD parser: ok, 52 tasks, warnings []",
    "Commit: 90a7a524 fix: validate migration run fields"
  ],
  "residualRisks": [
    "Importer still consumes normalized migration JSON only; migration JSON scope unchanged.",
    "retry_history is validated as a list but not deeply schema-validated because import/projection treat it as opaque payload."
  ],
  "noStagedFiles": true,
  "diffSummary": "Hardened TRD-023 MigrationImporter run pre-validation by checking current_phase, phase_order, and retry_history before any events are appended; added regression coverage proving malformed later phase_order leaves EventStore unchanged; passed computed fallback phase to failed terminal run events.",
  "reviewFindings": [],
  "manualNotes": "Scoped to parent-synthesized TRD-023 review round 2 fix only. No task state or migration JSON scope changes. One earlier combined shell command was rerun correctly from repo root for TS/TRD validation after a cwd mistake.",
  "notes": "Report file is untracked by design. Pre-existing untracked reviewer artifact remains: subagent-outputs/review2-trd-023-correctness.md."
}
```
