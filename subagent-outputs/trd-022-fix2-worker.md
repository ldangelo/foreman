Implemented TRD-022 review round 2 fixes only.

Changed files:
- CLAUDE.md
- README.md
- docs/cli-reference.md
- packages/foreman_server/test/planning_flow_test.exs
- src/cli/commands/plan.ts
- src/cli/__tests__/plan-server.test.ts

Commit:
- d8294217 fix: route CLI planning to Elixir server

Validation:
- `npx vitest run src/cli/__tests__/plan-server.test.ts src/cli/__tests__/commands.test.ts -t "plan" --reporter=dot` passed; 2 files, 3 tests passed, 8 skipped.
- `cd packages/foreman_server && mix format && mix test test/planning_flow_test.exs` passed; 8 tests, 0 failures.
- `cd packages/foreman_server && mix test && mix compile --warnings-as-errors` passed; 93 tests, 0 failures; compile clean.
- `npx tsc --noEmit` passed.
- TRD parser passed; 52 tasks, warnings [].
- `git status --short` clean before writing this report.

Diff summary:
- Added `foreman plan prd <description>` and `foreman plan trd <description>` CLI subcommands that submit `plan.prd` / `plan.trd` command envelopes through `ElixirServerManager` + `ElixirServerClient` to the local Elixir server, preserving the existing legacy `foreman plan <description>` pipeline.
- Added focused Vitest coverage proving the new CLI subcommands dispatch the correct server command types and payloads.
- Fixed `planning_flow_test.exs` auth token cleanup by restoring/deleting `:auth_token` in `on_exit`.
- Updated CLI docs to mention server-backed planning subcommands.

Residual risks:
- PlanningFlow still uses the existing WorkerProtocol event bridge simulation; no existing provider/subprocess adapter hook was obvious enough for a minimal scoped wire-up, and no new provider architecture was invented.

Git status after report write:
- This report file is untracked by design; no staged files expected.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "src/cli/commands/plan.ts now defines server-backed `plan prd` and `plan trd` subcommands that send `plan.prd` / `plan.trd` via ElixirServerClient; src/cli/__tests__/plan-server.test.ts asserts both command envelopes and payloads. Real provider/subprocess execution remains reported as residual because no minimal existing adapter hook was identified."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "packages/foreman_server/test/planning_flow_test.exs setup captures previous :auth_token and restores/deletes it in on_exit."
    },
    {
      "id": "criterion-3",
      "status": "satisfied",
      "evidence": "Focused planning_flow_test passed: 8 tests, 0 failures."
    },
    {
      "id": "criterion-4",
      "status": "satisfied",
      "evidence": "Required validation passed: relevant Vitest, focused planning tests, full mix test, compile warnings-as-errors, npx tsc --noEmit, and TRD parser."
    },
    {
      "id": "criterion-5",
      "status": "satisfied",
      "evidence": "Created one fix commit: d8294217 fix: route CLI planning to Elixir server."
    }
  ],
  "changedFiles": [
    "CLAUDE.md",
    "README.md",
    "docs/cli-reference.md",
    "packages/foreman_server/test/planning_flow_test.exs",
    "src/cli/commands/plan.ts",
    "src/cli/__tests__/plan-server.test.ts"
  ],
  "testsAddedOrUpdated": [
    "src/cli/__tests__/plan-server.test.ts",
    "packages/foreman_server/test/planning_flow_test.exs"
  ],
  "commandsRun": [
    {
      "command": "npx vitest run src/cli/__tests__/plan-server.test.ts --reporter=dot",
      "result": "failed",
      "summary": "Initial new test run failed due mock constructor/test expectation issues; fixed before final validation."
    },
    {
      "command": "npx vitest run src/cli/__tests__/plan-server.test.ts src/cli/__tests__/commands.test.ts -t \"plan\" --reporter=dot",
      "result": "passed",
      "summary": "Relevant CLI planning tests passed: 2 files, 3 tests passed, 8 skipped."
    },
    {
      "command": "cd packages/foreman_server && mix format && mix test test/planning_flow_test.exs",
      "result": "passed",
      "summary": "Focused Elixir planning tests passed: 8 tests, 0 failures."
    },
    {
      "command": "cd packages/foreman_server && mix test && mix compile --warnings-as-errors",
      "result": "passed",
      "summary": "Full Elixir suite passed: 93 tests, 0 failures; compile warnings-as-errors clean."
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
      "command": "git add ... && git commit -m 'fix: route CLI planning to Elixir server'",
      "result": "passed",
      "summary": "Committed scoped fix as d8294217."
    },
    {
      "command": "git status --short",
      "result": "passed",
      "summary": "Clean before writing this report."
    }
  ],
  "validationOutput": [
    "Relevant Vitest: 2 files passed; 3 tests passed; 8 skipped",
    "Focused planning_flow_test: 8 tests, 0 failures",
    "Full mix test: 93 tests, 0 failures",
    "mix compile --warnings-as-errors: passed",
    "npx tsc --noEmit: passed with no output",
    "TRD parser: trd parse ok tasks 52 warnings []",
    "Commit: d8294217 fix: route CLI planning to Elixir server"
  ],
  "residualRisks": [
    "PlanningFlow still uses the existing WorkerProtocol event bridge simulation; no obvious minimal provider/subprocess adapter hook was available, so no new provider execution architecture was invented."
  ],
  "noStagedFiles": true,
  "diffSummary": "Added server-backed `foreman plan prd` and `foreman plan trd` CLI subcommands that route to Elixir `plan.prd` / `plan.trd` commands via ElixirServerManager and ElixirServerClient while preserving legacy `foreman plan <description>` behavior; added Vitest coverage for both subcommands; fixed planning_flow_test auth_token env restoration; updated CLAUDE.md, README.md, and docs/cli-reference.md for the new command surface.",
  "reviewFindings": [],
  "manualNotes": "Scoped to TRD-022 review round 2 fixes only. Bead state was not changed.",
  "notes": "Output report file is untracked after final write by design."
}
```
