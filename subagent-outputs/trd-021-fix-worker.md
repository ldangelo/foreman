Implemented TRD-021 review fixes only.

Changed files:
- packages/foreman_server/lib/foreman_server/attach_bridge.ex
- packages/foreman_server/lib/foreman_server/http/router.ex
- packages/foreman_server/test/attach_bridge_test.exs

Commit:
- b1a7c372 fix: harden Elixir attach recovery bridge

Validation:
- `cd packages/foreman_server && mix format && mix test test/attach_bridge_test.exs` exit 0; 8 tests, 0 failures.
- `cd packages/foreman_server && mix test && mix compile --warnings-as-errors && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md ...` exit 0; 81 tests, 0 failures; compile clean; TypeScript pass; TRD parse 52 tasks warnings [].
- `git commit -m "fix: harden Elixir attach recovery bridge"` exit 0; commit b1a7c372.
- `git status --short && git rev-parse --short HEAD` exit 0; no tracked changes before this report; HEAD b1a7c372.

Diff summary:
- Allows Pi SDK attach for active and recently completed runs when worker attach/session metadata is recent.
- Rejects stale attach metadata with operator-visible unsupported reason and alternatives.
- Makes attach GET idempotent for same run/provider/worker via deterministic idempotency keys and duplicate-result reuse.
- Validates interrupt/resume run, phase, active/interrupted state before append to avoid phantom run projections.
- Maps attach/recovery not-found/conflict errors to HTTP 404/409.
- Adds HTTP negative/boundary coverage and restart/replay durability test for attach/recovery projections.

Residual risks:
- CLI `foreman run attach` was not broadened here; this fix remains scoped to the Elixir attach/recovery bridge and HTTP boundary per instruction.

Git status after report write:
- This report is untracked by design; no staged files expected.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "AttachBridge now permits completed runs by removing completed from unsupported terminal states, requires recent worker metadata within 60 seconds, and tests cover active attach, recently completed attach, and stale metadata rejection with reason 'worker attach metadata is stale'."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "interrupt_phase/1 and resume_after_interrupt/1 validate run existence, known phase, active run for interrupt, and prior interruption for resume before EventStore.append; direct tests assert unknown run/phase/not-interrupted failures do not append side effects."
    },
    {
      "id": "criterion-3",
      "status": "satisfied",
      "evidence": "AttachRequested uses deterministic idempotency key AttachRequested:<run_id>:<worker_id>; duplicate append returns the existing projection result, and test verifies two GET attach calls create exactly one AttachRequested event."
    },
    {
      "id": "criterion-4",
      "status": "satisfied",
      "evidence": "HTTP tests cover unauthorized attach, unsupported provider via HTTP, worker_id selection and missing worker diagnostics, plus interrupt/resume 404 for unknown run/phase and 409 for resume before interruption."
    },
    {
      "id": "criterion-5",
      "status": "satisfied",
      "evidence": "Restart/replay test stops and restarts the application with the same event_log_path, then asserts attach_requests and interactive_recovery projections are replayed from durable events."
    },
    {
      "id": "criterion-6",
      "status": "satisfied",
      "evidence": "Required validation passed and one fix commit was created: b1a7c372 fix: harden Elixir attach recovery bridge."
    }
  ],
  "changedFiles": [
    "packages/foreman_server/lib/foreman_server/attach_bridge.ex",
    "packages/foreman_server/lib/foreman_server/http/router.ex",
    "packages/foreman_server/test/attach_bridge_test.exs"
  ],
  "testsAddedOrUpdated": [
    "packages/foreman_server/test/attach_bridge_test.exs"
  ],
  "commandsRun": [
    {
      "command": "cd packages/foreman_server && mix format && mix test test/attach_bridge_test.exs",
      "result": "passed",
      "summary": "Focused attach bridge tests passed: 8 tests, 0 failures."
    },
    {
      "command": "cd packages/foreman_server && mix test && mix compile --warnings-as-errors && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
      "result": "passed",
      "summary": "Required validation passed: 81 tests, 0 failures; compile warnings-as-errors clean; TypeScript pass; TRD parser warnings []."
    },
    {
      "command": "git add packages/foreman_server/lib/foreman_server/attach_bridge.ex packages/foreman_server/lib/foreman_server/http/router.ex packages/foreman_server/test/attach_bridge_test.exs && git commit -m 'fix: harden Elixir attach recovery bridge'",
      "result": "passed",
      "summary": "Committed scoped TRD-021 fix as b1a7c372."
    },
    {
      "command": "git status --short && git rev-parse --short HEAD",
      "result": "passed",
      "summary": "No tracked changes before writing this report; HEAD b1a7c372."
    }
  ],
  "validationOutput": [
    "Focused attach tests: 8 tests, 0 failures",
    "Full mix test: 81 tests, 0 failures",
    "mix compile --warnings-as-errors: passed",
    "npx tsc --noEmit: passed with no output",
    "TRD parser: trd parse ok tasks 52 warnings []",
    "Commit: b1a7c372 fix: harden Elixir attach recovery bridge"
  ],
  "residualRisks": [
    "CLI attach command coverage was not added; scoped fix stayed within TRD-021 Elixir attach/recovery bridge and HTTP boundary as instructed."
  ],
  "noStagedFiles": true,
  "diffSummary": "Hardened ForemanServer.AttachBridge to support recent completed-session attach, reject stale metadata, prevent phantom interrupt/resume projections through run/phase/state validation, make attach GET non-duplicating with deterministic idempotency keys, map HTTP not-found/conflict responses, and add focused direct/HTTP/restart tests.",
  "reviewFindings": [],
  "manualNotes": "Scoped to TRD-021 attach/interactive recovery fixes only. Did not alter task state or implement CLI attach plumbing.",
  "notes": "Output report file is untracked after final write by design."
}
```
