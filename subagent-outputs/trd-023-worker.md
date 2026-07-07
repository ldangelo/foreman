Implemented TRD-023 and TRD-023-TEST.

Tasks closed:
- TRD-023 / bd-6uc4d
- TRD-023-TEST / bd-xie58

Commits:
- bdda5936 feat: add Elixir migration importer
- d71cdb7b test: verify Elixir migration importer

Changed files:
- .tasks/issues.jsonl
- .tasks/last-touched
- CLAUDE.md
- README.md
- docs/cli-reference.md
- docs/user-guide.md
- packages/foreman_server/README.md
- packages/foreman_server/lib/foreman_server/command_router.ex
- packages/foreman_server/lib/foreman_server/http/router.ex
- packages/foreman_server/lib/foreman_server/migration_importer.ex
- packages/foreman_server/lib/foreman_server/projection_store.ex
- packages/foreman_server/test/migration_importer_test.exs
- src/cli/__tests__/legacy-coexistence.test.ts
- src/cli/commands/import.ts
- src/cli/index.ts
- src/cli/legacy-coexistence.ts

Validation:
- `cd packages/foreman_server && mix test` exit 0; 97 tests, 0 failures.
- `npx vitest run src/cli/__tests__/legacy-coexistence.test.ts --reporter=dot` exit 0; 1 file, 5 tests passed.
- `npx tsc --noEmit` exit 0; no output.
- `node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md` exit 0; 52 tasks, warnings [].

Diff summary:
- Added `ForemanServer.MigrationImporter` and routed `MigrationImportCommand` / `migration.import` through command API + HTTP command boundary.
- Importer maps legacy projects, tasks, runs, workflows, inbox messages, and config into durable events/projections; historical runs remain readable after rebuild.
- Added migration projections for import summaries and retained workflow/config records.
- Added `foreman import --to-elixir --file migration.json` server-backed CLI path.
- Added legacy coexistence delegation guard for `run`, `status`, `watch`, `reset`, `retry`, `stop`, `merge`, `pr`, `attach`, `inbox`, `task`, `plan`, `sling`, and `doctor` when `FOREMAN_LEGACY_COMPATIBILITY_MODE` is enabled and migration is incomplete.
- Updated docs for migration import and compatibility delegation.

Residual risks:
- Migration importer accepts normalized JSON payload shape; it does not scrape arbitrary existing TS database files directly.
- Legacy delegation requires operator-provided `FOREMAN_LEGACY_TS_BIN` and intentionally refuses recursive self-delegation.

Current git status before writing this report: clean.
After writing this report: `subagent-outputs/trd-023-worker.md` is expected untracked output artifact.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Claimed bd-6uc4d via `native task store update bd-6uc4d --status in_progress` before implementation edits; claimed bd-xie58 via `native task store update bd-xie58 --status in_progress` before test commit."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "Scoped changes to TRD-023 migration importer/coexistence and TRD-023-TEST coverage only; stopped after closing bd-6uc4d and bd-xie58."
    },
    {
      "id": "criterion-3",
      "status": "satisfied",
      "evidence": "Closed bd-6uc4d and bd-xie58 only after validation commands passed: mix test, focused Vitest, npx tsc --noEmit, and TRD parser."
    },
    {
      "id": "criterion-4",
      "status": "satisfied",
      "evidence": "Created separate commits: bdda5936 for implementation + bd-6uc4d task state; d71cdb7b for tests + bd-xie58 task state."
    },
    {
      "id": "criterion-5",
      "status": "satisfied",
      "evidence": "Validation command list includes exact commands and exit code 0 summaries."
    }
  ],
  "changedFiles": [
    ".tasks/issues.jsonl",
    ".tasks/last-touched",
    "CLAUDE.md",
    "README.md",
    "docs/cli-reference.md",
    "docs/user-guide.md",
    "packages/foreman_server/README.md",
    "packages/foreman_server/lib/foreman_server/command_router.ex",
    "packages/foreman_server/lib/foreman_server/http/router.ex",
    "packages/foreman_server/lib/foreman_server/migration_importer.ex",
    "packages/foreman_server/lib/foreman_server/projection_store.ex",
    "packages/foreman_server/test/migration_importer_test.exs",
    "src/cli/__tests__/legacy-coexistence.test.ts",
    "src/cli/commands/import.ts",
    "src/cli/index.ts",
    "src/cli/legacy-coexistence.ts"
  ],
  "testsAddedOrUpdated": [
    "packages/foreman_server/test/migration_importer_test.exs",
    "src/cli/__tests__/legacy-coexistence.test.ts"
  ],
  "commandsRun": [
    {
      "command": "/Users/ldangelo/.local/bin/native task store update bd-6uc4d --status in_progress",
      "result": "passed",
      "summary": "exit 0; TRD-023 task claimed before implementation edits."
    },
    {
      "command": "cd packages/foreman_server && mix format && mix test test/migration_importer_test.exs",
      "result": "failed",
      "summary": "initial run found migration projection record_counts and test stringify issues; fixed before final validation."
    },
    {
      "command": "npx vitest run src/cli/__tests__/legacy-coexistence.test.ts --reporter=dot && npx tsc --noEmit",
      "result": "passed",
      "summary": "exit 0; focused TS coexistence tests passed and TypeScript compile passed."
    },
    {
      "command": "cd packages/foreman_server && mix test && cd ../.. && npx vitest run src/cli/__tests__/legacy-coexistence.test.ts --reporter=dot && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
      "result": "passed",
      "summary": "exit 0 before closing implementation task; 97 ExUnit tests, 5 focused Vitest tests, TypeScript pass, TRD parser 52 tasks warnings []."
    },
    {
      "command": "/Users/ldangelo/.local/bin/native task store close bd-6uc4d --reason \"Implemented migration importer and legacy TS coexistence delegation\"",
      "result": "passed",
      "summary": "exit 0; closed TRD-023 after validation."
    },
    {
      "command": "git commit -m \"feat: add Elixir migration importer\"",
      "result": "passed",
      "summary": "exit 0; created bdda5936 with implementation/docs and TRD-023 task state."
    },
    {
      "command": "/Users/ldangelo/.local/bin/native task store update bd-xie58 --status in_progress",
      "result": "passed",
      "summary": "exit 0; TRD-023-TEST task claimed after implementation task closed."
    },
    {
      "command": "cd packages/foreman_server && mix test && cd ../.. && npx vitest run src/cli/__tests__/legacy-coexistence.test.ts --reporter=dot && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
      "result": "passed",
      "summary": "exit 0 before closing test task; 97 ExUnit tests, 5 focused Vitest tests, TypeScript pass, TRD parser 52 tasks warnings []."
    },
    {
      "command": "/Users/ldangelo/.local/bin/native task store close bd-xie58 --reason \"Verified TRD-023 migration importer and legacy compatibility\"",
      "result": "passed",
      "summary": "exit 0; closed TRD-023-TEST after validation."
    },
    {
      "command": "git commit -m \"test: verify Elixir migration importer\"",
      "result": "passed",
      "summary": "exit 0; created d71cdb7b with tests and TRD-023-TEST task state."
    },
    {
      "command": "git status --short",
      "result": "passed",
      "summary": "exit 0; clean before writing this report."
    }
  ],
  "validationOutput": [
    "cd packages/foreman_server && mix test: 97 tests, 0 failures, exit 0",
    "npx vitest run src/cli/__tests__/legacy-coexistence.test.ts --reporter=dot: 1 file passed, 5 tests passed, exit 0",
    "npx tsc --noEmit: exit 0, no output",
    "TRD parser: trd parse ok tasks 52 warnings [], exit 0",
    "Final git status before report: clean"
  ],
  "residualRisks": [
    "Migration importer consumes a normalized migration JSON payload; it does not directly scrape arbitrary legacy TS database files.",
    "Legacy delegation requires FOREMAN_LEGACY_TS_BIN and refuses recursive self-delegation."
  ],
  "noStagedFiles": true,
  "diffSummary": "Added Elixir migration import command/API path and projection support for legacy projects, tasks, runs, workflows, inbox messages, and config; added server-backed `foreman import --to-elixir --file`; added legacy compatibility delegation for the PRD-listed TS command surface; documented migration/coexistence; added ExUnit and Vitest coverage.",
  "reviewFindings": [],
  "manualNotes": "TRD-023 / bd-6uc4d and TRD-023-TEST / bd-xie58 are closed. Commits: bdda5936, d71cdb7b.",
  "notes": "Writing this report leaves subagent-outputs/trd-023-worker.md untracked as requested."
}
```
