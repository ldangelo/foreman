Implemented TRD-024 and TRD-024-TEST.

Tasks closed:
- TRD-024 / bd-0fdng
- TRD-024-TEST / bd-epjpd

Commits:
- 1b7a25bd feat: add Elixir operational observability
- 38dbc17c test: verify Elixir operational observability

Changed files:
- .tasks/issues.jsonl
- .tasks/last-touched
- CLAUDE.md
- README.md
- docs/cli-reference.md
- docs/user-guide.md
- packages/foreman_server/README.md
- packages/foreman_server/lib/foreman_server/debug_views.ex
- packages/foreman_server/lib/foreman_server/http/router.ex
- packages/foreman_server/lib/foreman_server/operations.ex
- packages/foreman_server/test/http_router_test.exs
- packages/foreman_server/test/operations_test.exs
- src/cli/commands/server.ts
- src/lib/__tests__/elixir-server-manager.test.ts
- src/lib/elixir-server-manager.ts

Validation:
- `cd packages/foreman_server && mix test && mix compile --warnings-as-errors` exit 0; 107 tests, 0 failures.
- `npx vitest run src/lib/__tests__/elixir-server-manager.test.ts --reporter=dot` exit 0; 1 file, 4 tests passed.
- `npx tsc --noEmit` exit 0.
- `node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md` exit 0; 52 tasks, warnings [].

Diff summary:
- Added `ForemanServer.Operations` for server doctor checks and operational metrics.
- Added authenticated HTTP `GET /api/v1/doctor` and `GET /api/v1/metrics`.
- `foreman server doctor` now calls the doctor endpoint instead of only health.
- Metrics include phase duration timers, retry/failure/recovery counters, worker restart counts, and projection lag.
- Debug timeline now returns anomaly entries and identifies the first inconsistent transition.
- Added ExUnit and Vitest coverage plus docs for operator-visible behavior.

Residual risks:
- Metrics are derived from event-store/projection state at read time; no external metrics sink/exporter was introduced in this TRD-024 scope.

Final git status before report write: clean.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Claimed TRD-024 task with `/Users/ldangelo/.local/bin/native task store update bd-0fdng --status in_progress` before implementation edits."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "Implemented TRD-024 only, then after bd-0fdng closed and bd-epjpd unlocked claimed and implemented TRD-024-TEST only. Did not edit TRD-025 or later-task scope."
    },
    {
      "id": "criterion-3",
      "status": "satisfied",
      "evidence": "AC-022 behavior implemented: server doctor validates DB/projections/workers/VCS/provider adapters/integrations; metrics report phase duration/retries/failures/recoveries/worker restarts/projection lag; debug timeline reports first anomaly."
    },
    {
      "id": "criterion-4",
      "status": "satisfied",
      "evidence": "Closed bd-0fdng and bd-epjpd only after validation passed: mix test, TypeScript, and TRD parser."
    },
    {
      "id": "criterion-5",
      "status": "satisfied",
      "evidence": "Created separate commits: 1b7a25bd for implementation/docs/task close and 38dbc17c for tests/test task close."
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
    "packages/foreman_server/lib/foreman_server/debug_views.ex",
    "packages/foreman_server/lib/foreman_server/http/router.ex",
    "packages/foreman_server/lib/foreman_server/operations.ex",
    "packages/foreman_server/test/http_router_test.exs",
    "packages/foreman_server/test/operations_test.exs",
    "src/cli/commands/server.ts",
    "src/lib/__tests__/elixir-server-manager.test.ts",
    "src/lib/elixir-server-manager.ts"
  ],
  "testsAddedOrUpdated": [
    "packages/foreman_server/test/operations_test.exs",
    "packages/foreman_server/test/http_router_test.exs",
    "src/lib/__tests__/elixir-server-manager.test.ts"
  ],
  "commandsRun": [
    {
      "command": "git status --short && native task store show bd-0fdng --json && native task store show bd-rwi15 --json",
      "result": "passed",
      "summary": "Verified clean start and parent-selected TRD-024 task open; TRD-025 also ready but not selected."
    },
    {
      "command": "/Users/ldangelo/.local/bin/native task store update bd-0fdng --status in_progress",
      "result": "passed",
      "summary": "Claimed TRD-024 before implementation edits."
    },
    {
      "command": "cd packages/foreman_server && mix format && mix test test/operations_test.exs test/http_router_test.exs",
      "result": "failed",
      "summary": "Initial focused run exposed projection lag calculation using per-stream version; fixed lag calculation to compare checkpoint event id against event-store order."
    },
    {
      "command": "cd packages/foreman_server && mix format && mix test test/operations_test.exs test/http_router_test.exs",
      "result": "passed",
      "summary": "Focused ExUnit ops/router tests passed: 15 tests, 0 failures."
    },
    {
      "command": "npx vitest run src/lib/__tests__/elixir-server-manager.test.ts --reporter=dot && npx tsc --noEmit",
      "result": "passed",
      "summary": "Manager doctor Vitest passed: 4 tests; TypeScript passed."
    },
    {
      "command": "cd packages/foreman_server && mix test && mix compile --warnings-as-errors && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
      "result": "passed",
      "summary": "Pre-close implementation validation passed: 107 tests, compile clean, TypeScript pass, TRD parser warnings []."
    },
    {
      "command": "/Users/ldangelo/.local/bin/native task store close bd-0fdng --reason \"Implemented operational doctor, metrics, projection lag, and debug anomaly views\"",
      "result": "passed",
      "summary": "Closed TRD-024 after validation."
    },
    {
      "command": "git add ... && git commit -m \"feat: add Elixir operational observability\"",
      "result": "passed",
      "summary": "Committed implementation/docs and TRD-024 task close as 1b7a25bd."
    },
    {
      "command": "/Users/ldangelo/.local/bin/native task store update bd-epjpd --status in_progress",
      "result": "passed",
      "summary": "Claimed TRD-024-TEST after TRD-024 closed and dependency unlocked."
    },
    {
      "command": "cd packages/foreman_server && mix test && mix compile --warnings-as-errors && cd ../.. && npx vitest run src/lib/__tests__/elixir-server-manager.test.ts --reporter=dot && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
      "result": "passed",
      "summary": "Pre-close test validation passed: 107 tests, 4 Vitest tests, TypeScript pass, TRD parser warnings []."
    },
    {
      "command": "/Users/ldangelo/.local/bin/native task store close bd-epjpd --reason \"Verified operational doctor, metrics, projection lag, and debug anomaly behavior\"",
      "result": "passed",
      "summary": "Closed TRD-024-TEST after validation."
    },
    {
      "command": "git add ... && git commit -m \"test: verify Elixir operational observability\"",
      "result": "passed",
      "summary": "Committed tests and TRD-024-TEST task close as 38dbc17c."
    },
    {
      "command": "git status --short",
      "result": "passed",
      "summary": "Clean before writing this report."
    }
  ],
  "validationOutput": [
    "Full mix test: 107 tests, 0 failures",
    "mix compile --warnings-as-errors: passed",
    "Focused Vitest: src/lib/__tests__/elixir-server-manager.test.ts passed, 4 tests",
    "npx tsc --noEmit: passed with no output",
    "TRD parser: trd parse ok tasks 52 warnings []",
    "Commits: 1b7a25bd, 38dbc17c"
  ],
  "residualRisks": [
    "Metrics are read-time derived from event/projection state; no external metrics sink/exporter was introduced in this TRD-024 scope."
  ],
  "noStagedFiles": true,
  "diffSummary": "Added Elixir operational observability: ForemanServer.Operations exposes doctor checks for DB/projections/workers/VCS/provider adapters/integrations plus metrics for phase duration, retries, failures, recoveries, worker restarts, and projection lag; HTTP exposes authenticated /api/v1/doctor and /api/v1/metrics; CLI server doctor now calls the doctor endpoint; debug timelines include anomaly detection and first inconsistent transition; docs and tests updated.",
  "reviewFindings": [],
  "manualNotes": "Stopped after TRD-024 and TRD-024-TEST. Did not implement TRD-025.",
  "notes": "Writing this report leaves subagent-outputs/trd-024-worker.md untracked by design."
}
```
