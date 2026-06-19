Implemented TRD-024 review auth/test/docs fixes only.

Changed files:
- README.md
- docs/cli-reference.md
- docs/user-guide.md
- packages/foreman_server/test/http_router_test.exs
- src/lib/__tests__/elixir-server-manager.test.ts
- src/lib/elixir-server-manager.ts

Commit:
- eb22fb0b fix: authenticate Elixir server doctor reads

Validation:
- `cd packages/foreman_server && mix format && mix test test/operations_test.exs test/http_router_test.exs` exit 0; 16 tests, 0 failures.
- `cd packages/foreman_server && mix test && mix compile --warnings-as-errors` exit 0; 108 tests, 0 failures; compile clean.
- `npx vitest run src/lib/__tests__/elixir-server-manager.test.ts --reporter=dot` exit 0; 1 file, 5 tests passed.
- `npx tsc --noEmit` exit 0 after fixing test tuple typing.
- `node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md` exit 0; 52 tasks, warnings [].
- `git diff --check` exit 0.

Diff summary:
- `ElixirServerManager` now accepts `authToken` or reads `FOREMAN_SERVER_AUTH_TOKEN`, and sends `Authorization: Bearer <token>` for protected `doctor()` and new `metrics()` reads.
- Manager tests now cover no-token doctor behavior and token-bearing doctor/metrics requests.
- HTTP router tests now verify `/api/v1/doctor` and `/api/v1/metrics` reject missing and invalid bearer tokens.
- README, CLI reference, and user guide now name `FOREMAN_SERVER_AUTH_TOKEN` for authenticated server doctor/metrics calls.

Residual risks:
- None for scoped TRD-024 auth/test/docs fixes.

Git status before report write:
- Clean; HEAD `eb22fb0b`.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "src/lib/elixir-server-manager.ts stores opts.authToken or FOREMAN_SERVER_AUTH_TOKEN and passes Authorization: Bearer <token> for authenticated protected reads; doctor() and metrics() call getJson(..., { authenticated: true })."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "src/lib/__tests__/elixir-server-manager.test.ts asserts doctor() calls /api/v1/doctor without RequestInit when no token is configured and asserts doctor()/metrics() send Authorization: Bearer manager-secret when FOREMAN_SERVER_AUTH_TOKEN is set."
    },
    {
      "id": "criterion-3",
      "status": "satisfied",
      "evidence": "packages/foreman_server/test/http_router_test.exs adds `doctor and metrics endpoints require valid bearer token`, covering missing and invalid auth for /api/v1/doctor and /api/v1/metrics with 401 UNAUTHORIZED."
    },
    {
      "id": "criterion-4",
      "status": "satisfied",
      "evidence": "Required validation passed: focused ExUnit, full ExUnit plus compile warnings-as-errors, manager Vitest, TypeScript, and TRD parser."
    },
    {
      "id": "criterion-5",
      "status": "satisfied",
      "evidence": "Created one fix commit: eb22fb0b fix: authenticate Elixir server doctor reads."
    }
  ],
  "changedFiles": [
    "README.md",
    "docs/cli-reference.md",
    "docs/user-guide.md",
    "packages/foreman_server/test/http_router_test.exs",
    "src/lib/__tests__/elixir-server-manager.test.ts",
    "src/lib/elixir-server-manager.ts"
  ],
  "testsAddedOrUpdated": [
    "packages/foreman_server/test/http_router_test.exs",
    "src/lib/__tests__/elixir-server-manager.test.ts"
  ],
  "commandsRun": [
    {
      "command": "cd packages/foreman_server && mix format && mix test test/operations_test.exs test/http_router_test.exs",
      "result": "passed",
      "summary": "exit 0; focused operations/router tests passed: 16 tests, 0 failures."
    },
    {
      "command": "cd packages/foreman_server && mix test && mix compile --warnings-as-errors",
      "result": "passed",
      "summary": "exit 0; full Elixir suite passed: 108 tests, 0 failures; compile warnings-as-errors clean."
    },
    {
      "command": "npx vitest run src/lib/__tests__/elixir-server-manager.test.ts --reporter=dot",
      "result": "passed",
      "summary": "exit 0; manager tests passed: 1 file, 5 tests."
    },
    {
      "command": "npx tsc --noEmit",
      "result": "failed",
      "summary": "initial exit 2 due tuple type assertion in updated Vitest; fixed before final validation."
    },
    {
      "command": "npx vitest run src/lib/__tests__/elixir-server-manager.test.ts --reporter=dot && npx tsc --noEmit",
      "result": "passed",
      "summary": "exit 0; manager tests still passed and TypeScript typecheck passed with no output."
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
      "command": "git add README.md docs/cli-reference.md docs/user-guide.md packages/foreman_server/test/http_router_test.exs src/lib/__tests__/elixir-server-manager.test.ts src/lib/elixir-server-manager.ts && git commit -m 'fix: authenticate Elixir server doctor reads'",
      "result": "passed",
      "summary": "exit 0; created commit eb22fb0b."
    },
    {
      "command": "git status --short && git rev-parse --short HEAD",
      "result": "passed",
      "summary": "exit 0; clean before report write; HEAD eb22fb0b."
    }
  ],
  "validationOutput": [
    "Focused ExUnit: 16 tests, 0 failures",
    "Full mix test: 108 tests, 0 failures",
    "mix compile --warnings-as-errors: passed",
    "Manager Vitest: 1 file passed, 5 tests passed",
    "npx tsc --noEmit: passed with no output after tuple typing fix",
    "TRD parser: ok, 52 tasks, warnings []",
    "Commit: eb22fb0b fix: authenticate Elixir server doctor reads"
  ],
  "residualRisks": [],
  "noStagedFiles": true,
  "diffSummary": "Added FOREMAN_SERVER_AUTH_TOKEN bearer auth support to ElixirServerManager protected doctor/metrics reads, added manager tests for token and no-token behavior, added HTTP negative auth coverage for /api/v1/doctor and /api/v1/metrics, and documented the token in README, CLI reference, and user guide.",
  "reviewFindings": [],
  "manualNotes": "Scoped to parent-synthesized TRD-024 auth/test/docs fixes only. Did not redesign metrics/doctor and did not run subagents.",
  "notes": "Writing this report leaves subagent-outputs/trd-024-fix-worker.md untracked by design."
}
```
