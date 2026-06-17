Implemented TRD-022 review fixes only.

Changed files:
- packages/foreman_server/lib/foreman_server/command_router.ex
- packages/foreman_server/lib/foreman_server/planning_flow.ex
- packages/foreman_server/lib/foreman_server/projection_store.ex
- packages/foreman_server/test/planning_flow_test.exs

Commit:
- ea138dfd fix: harden Elixir planning flow completion

Validation:
- `cd packages/foreman_server && mix format && mix test test/planning_flow_test.exs` exit 0; 8 tests, 0 failures.
- `cd packages/foreman_server && mix test && mix compile --warnings-as-errors && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md ...` exit 0; 93 tests, 0 failures; compile clean; TypeScript pass; TRD parser 52 tasks, warnings [].
- `git status --short` before writing this report: clean.

Diff summary:
- Planning flows now append existing `RunStarted` and `RunCompleted` events around the worker-backed planning phases, so projections mark planning runs completed, clear `current_phase`, keep status counts terminal, and mark phase workers completed from `PhaseCompleted` payloads.
- `plan.prd` and `plan.trd` aliases now force their command kind instead of allowing conflicting payload `kind` to override the alias.
- Planning runs now use explicit `run_id` when provided, deterministic command-id run ids when `command_id` is supplied, and unique run ids for repeated direct calls without explicit ids. Completed explicit/command-id reruns return the existing flow result instead of duplicate-idempotency errors.
- Added focused tests for run/projection/status consistency, alias conflict handling, repeated input behavior, restart projection replay, HTTP command path, and invalid input no-side-effect cases.

Residual risks:
- Real external provider/subprocess execution remains outside this scoped fix. Current planning flow continues to use the existing WorkerProtocol event bridge simulation.

Git status after report write:
- This report file is untracked by design; no staged files expected.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "PlanningFlow now appends RunStarted before planning worker events and RunCompleted after PlanningFlowCompleted; ProjectionStore marks PhaseCompleted workers as completed. planning_flow_test asserts run.status == completed, current_phase nil, worker statuses completed, status_counts.active == 0, and status_counts.completed == 1."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "CommandRouter planning_payload now uses Map.put for plan.prd/plan.trd kinds. Tests pass conflicting payload kind values and assert plan.prd projects prd and plan.trd projects trd."
    },
    {
      "id": "criterion-3",
      "status": "satisfied",
      "evidence": "PlanningFlow now generates unique run ids when no run_id/command_id is supplied and uses deterministic planning-command-<command_id> run ids when command_id is supplied; completed reruns return existing:true. Tests assert same direct input creates distinct run ids and same command_id rerun returns same run id with existing true."
    },
    {
      "id": "criterion-4",
      "status": "satisfied",
      "evidence": "Focused tests added/updated in packages/foreman_server/test/planning_flow_test.exs for projection terminal state, aliases, reruns, restart replay, HTTP command boundary, and invalid input no-side-effect behavior."
    },
    {
      "id": "criterion-5",
      "status": "satisfied",
      "evidence": "Required validation passed and one fix commit was created: ea138dfd fix: harden Elixir planning flow completion."
    }
  ],
  "changedFiles": [
    "packages/foreman_server/lib/foreman_server/command_router.ex",
    "packages/foreman_server/lib/foreman_server/planning_flow.ex",
    "packages/foreman_server/lib/foreman_server/projection_store.ex",
    "packages/foreman_server/test/planning_flow_test.exs"
  ],
  "testsAddedOrUpdated": [
    "packages/foreman_server/test/planning_flow_test.exs"
  ],
  "commandsRun": [
    {
      "command": "cd packages/foreman_server && mix format && mix test test/planning_flow_test.exs",
      "result": "failed",
      "summary": "Initial focused run failed because command-router planning payload normalization dropped run_id; fixed known planning keys before final validation."
    },
    {
      "command": "cd packages/foreman_server && mix format && mix test test/planning_flow_test.exs",
      "result": "passed",
      "summary": "Focused planning tests passed: 8 tests, 0 failures."
    },
    {
      "command": "cd packages/foreman_server && mix test && mix compile --warnings-as-errors && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
      "result": "passed",
      "summary": "Required validation passed: 93 tests, 0 failures; compile warnings-as-errors clean; TypeScript pass; TRD parser warnings []."
    },
    {
      "command": "git add packages/foreman_server/lib/foreman_server/command_router.ex packages/foreman_server/lib/foreman_server/planning_flow.ex packages/foreman_server/lib/foreman_server/projection_store.ex packages/foreman_server/test/planning_flow_test.exs && git commit -m 'fix: harden Elixir planning flow completion'",
      "result": "passed",
      "summary": "Committed scoped TRD-022 fix as ea138dfd."
    },
    {
      "command": "git status --short",
      "result": "passed",
      "summary": "Clean before writing this report."
    }
  ],
  "validationOutput": [
    "Focused planning tests: 8 tests, 0 failures",
    "Full mix test: 93 tests, 0 failures",
    "mix compile --warnings-as-errors: passed",
    "npx tsc --noEmit: passed with no output",
    "TRD parser: trd parse ok tasks 52 warnings []",
    "Commit: ea138dfd fix: harden Elixir planning flow completion"
  ],
  "residualRisks": [
    "PlanningFlow still uses the existing WorkerProtocol event bridge simulation; real external provider/subprocess execution was intentionally not broadened in this scoped fix."
  ],
  "noStagedFiles": true,
  "diffSummary": "Hardened TRD-022 planning flow completion and command routing. PlanningFlow appends RunStarted/RunCompleted events, returns existing completed command-id runs idempotently, and generates unique run ids for direct calls without explicit ids. CommandRouter plan.prd/plan.trd aliases force the alias kind and preserve planning keys such as run_id/provider. ProjectionStore marks worker status completed on PhaseCompleted. planning_flow_test adds terminal projection/status-count, alias conflict, rerun, restart, HTTP command, and invalid-input coverage.",
  "reviewFindings": [],
  "manualNotes": "Scoped to TRD-022 planning flow bridge correctness fixes only. No bead state changes made.",
  "notes": "Output report file is untracked after final write by design."
}
```
