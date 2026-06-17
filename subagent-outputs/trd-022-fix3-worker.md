Implemented TRD-022 final CLI option/docs fix only.

Changed files:
- docs/user-guide.md
- src/cli/commands/plan.ts
- src/cli/__tests__/plan-server.test.ts

Commit:
- 78084f40 fix: parse CLI planning trailing options

Validation:
- `npx vitest run src/cli/__tests__/plan-server.test.ts src/cli/__tests__/commands.test.ts -t "plan" --reporter=dot` exit 0; 2 files passed, 3 tests passed, 8 skipped.
- `npx tsc --noEmit` exit 0.
- `cd packages/foreman_server && mix test test/planning_flow_test.exs` exit 0; 8 tests, 0 failures.
- `cd packages/foreman_server && mix test && mix compile --warnings-as-errors` exit 0; 93 tests, 0 failures; compile clean.
- `node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md` exit 0; TRD parse 52 tasks, warnings [].
- `git status --short && git rev-parse --short HEAD` exit 0 before writing this report; no tracked changes; HEAD 78084f40.

Diff summary:
- `foreman plan prd|trd` now merges child command options with parent-parsed planning options so `--project` and `--output-dir` work when placed after the description.
- Updated plan server tests to pass `--project` and `--output-dir` after the description and assert project resolver/payload values use those flags.
- Added a surgical `docs/user-guide.md` planning section documenting `foreman plan prd` and `foreman plan trd` with `--project` and `--output-dir`.

Residual risks:
- Real provider/artifact execution remains the known TRD-022 residual and was intentionally not addressed.

Git status after report write:
- This report file is untracked by design; no staged files expected.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "src/cli/commands/plan.ts now merges parent-parsed --project/--output-dir values for plan prd/trd subcommands when those options are provided after the description; plan-server tests exercise trailing option placement."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "src/cli/__tests__/plan-server.test.ts now asserts resolver receives { project: \"foreman\" } and payload output_dir is /repo/docs/PRD or /repo/docs/TRD for trailing --project/--output-dir."
    },
    {
      "id": "criterion-3",
      "status": "satisfied",
      "evidence": "docs/user-guide.md now documents foreman plan prd and foreman plan trd usage with --project and --output-dir."
    },
    {
      "id": "criterion-4",
      "status": "satisfied",
      "evidence": "Required Vitest, TypeScript, focused planning_flow_test, full mix test plus compile warnings-as-errors, and TRD parser validation all passed."
    },
    {
      "id": "criterion-5",
      "status": "satisfied",
      "evidence": "Created one scoped fix commit: 78084f40 fix: parse CLI planning trailing options."
    }
  ],
  "changedFiles": [
    "docs/user-guide.md",
    "src/cli/commands/plan.ts",
    "src/cli/__tests__/plan-server.test.ts"
  ],
  "testsAddedOrUpdated": [
    "src/cli/__tests__/plan-server.test.ts"
  ],
  "commandsRun": [
    {
      "command": "npx vitest run src/cli/__tests__/plan-server.test.ts --reporter=verbose",
      "result": "passed",
      "summary": "Baseline current plan-server tests passed before edits."
    },
    {
      "command": "npx vitest run src/cli/__tests__/plan-server.test.ts src/cli/__tests__/commands.test.ts -t \"plan\" --reporter=dot",
      "result": "passed",
      "summary": "Required focused CLI planning validation passed: 2 files passed, 3 tests passed, 8 skipped."
    },
    {
      "command": "npx tsc --noEmit",
      "result": "passed",
      "summary": "TypeScript typecheck passed with no output."
    },
    {
      "command": "cd packages/foreman_server && mix test test/planning_flow_test.exs",
      "result": "passed",
      "summary": "Focused Elixir planning tests passed: 8 tests, 0 failures."
    },
    {
      "command": "cd packages/foreman_server && mix test && mix compile --warnings-as-errors",
      "result": "passed",
      "summary": "Full Elixir suite passed: 93 tests, 0 failures; compile warnings-as-errors clean."
    },
    {
      "command": "node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
      "result": "passed",
      "summary": "TRD parser passed: 52 tasks, warnings []."
    },
    {
      "command": "git add docs/user-guide.md src/cli/commands/plan.ts src/cli/__tests__/plan-server.test.ts && git commit -m \"fix: parse CLI planning trailing options\"",
      "result": "passed",
      "summary": "Committed scoped fix as 78084f40."
    },
    {
      "command": "git status --short && git rev-parse --short HEAD",
      "result": "passed",
      "summary": "No tracked changes before writing report; HEAD 78084f40."
    }
  ],
  "validationOutput": [
    "Focused Vitest: 2 files passed; 3 tests passed; 8 skipped",
    "npx tsc --noEmit: passed with no output",
    "Focused planning_flow_test: 8 tests, 0 failures",
    "Full mix test: 93 tests, 0 failures",
    "mix compile --warnings-as-errors: passed",
    "TRD parser: trd parse ok tasks 52 warnings []",
    "Commit: 78084f40 fix: parse CLI planning trailing options"
  ],
  "residualRisks": [
    "PlanningFlow still uses the existing WorkerProtocol event bridge simulation; provider/artifact execution architecture was intentionally not changed in this scoped pass."
  ],
  "noStagedFiles": true,
  "diffSummary": "Fixed TRD-022 CLI planning option parsing by merging parent-parsed --project/--output-dir values into plan prd/trd subcommands, updated plan-server tests to assert trailing options affect project resolution and output_dir payloads, and documented foreman plan prd/trd in docs/user-guide.md.",
  "reviewFindings": [],
  "manualNotes": "Scoped to parent-approved TRD-022 final CLI option/docs fix only. Did not run subagents or implement provider execution architecture.",
  "notes": "Output report file is untracked after final write by design."
}
```
