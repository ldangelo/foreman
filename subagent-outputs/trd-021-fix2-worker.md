Implemented TRD-021 review round 2 fixes only.

Changed files:
- packages/foreman_server/lib/foreman_server/attach_bridge.ex
- packages/foreman_server/test/attach_bridge_test.exs

Commit:
- 81504283 fix: harden Elixir attach idempotency

Validation:
- `cd packages/foreman_server && mix format && mix test test/attach_bridge_test.exs` exit 0; 12 tests, 0 failures.
- `cd packages/foreman_server && mix test && mix compile --warnings-as-errors && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md ...` exit 0; 85 tests, 0 failures; compile clean; TypeScript pass; TRD parse 52 tasks warnings [].
- `git commit -m "fix: harden Elixir attach idempotency"` exit 0; commit 81504283.
- `git status --short && git rev-parse --short HEAD` exit 0 after commit; no staged/tracked changes, untracked subagent output artifact(s) only.

Diff summary:
- Duplicate attach idempotency now returns the original event payload matching the stream/idempotency key instead of the latest run-level attach projection.
- Resume validation now requires active/non-terminal runs before appending `InteractiveRecoveryResumed`.
- Added regression coverage for multi-worker attach retry, unsupported interleaving retry, and direct + HTTP terminal-run resume rejection for completed/failed/blocked runs with no side effects.

Residual risks:
- CLI `foreman run attach` bridge coverage remains deferred per instruction; this pass stayed scoped to the Elixir attach/recovery bridge and HTTP boundary.

Git status after report write:
- No staged files expected.
- Untracked subagent output artifacts remain by design.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "AttachBridge duplicate-idempotency handling now looks up the matching event payload from attach:<run_id> by metadata idempotency_key. Tests retry worker-1 after worker-2 and after an unsupported missing-worker attach, and retry unsupported missing-worker after ready attach; all return the original matching result."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "validate_resumable/2 now calls active_run/1 before interrupted_phase/3. Direct and HTTP tests assert completed, failed, and blocked runs return conflict and do not append resume events or mutate phase_status to resume_requested."
    },
    {
      "id": "criterion-3",
      "status": "satisfied",
      "evidence": "packages/foreman_server/test/attach_bridge_test.exs adds multi-worker idempotency, unsupported interleaving, and terminal resume direct/HTTP regression tests."
    },
    {
      "id": "criterion-4",
      "status": "satisfied",
      "evidence": "Required validation passed: focused attach tests, full mix suite, mix compile --warnings-as-errors, npx tsc --noEmit, and TRD parser."
    },
    {
      "id": "criterion-5",
      "status": "satisfied",
      "evidence": "Created one scoped commit: 81504283 fix: harden Elixir attach idempotency."
    }
  ],
  "changedFiles": [
    "packages/foreman_server/lib/foreman_server/attach_bridge.ex",
    "packages/foreman_server/test/attach_bridge_test.exs"
  ],
  "testsAddedOrUpdated": [
    "packages/foreman_server/test/attach_bridge_test.exs"
  ],
  "commandsRun": [
    {
      "command": "cd packages/foreman_server && mix format && mix test test/attach_bridge_test.exs",
      "result": "passed",
      "summary": "Focused attach bridge tests passed: 12 tests, 0 failures."
    },
    {
      "command": "cd packages/foreman_server && mix test && mix compile --warnings-as-errors && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
      "result": "passed",
      "summary": "Required validation passed: 85 tests, 0 failures; compile warnings-as-errors clean; TypeScript pass; TRD parser warnings []."
    },
    {
      "command": "git add packages/foreman_server/lib/foreman_server/attach_bridge.ex packages/foreman_server/test/attach_bridge_test.exs && git commit -m 'fix: harden Elixir attach idempotency'",
      "result": "passed",
      "summary": "Committed scoped fix as 81504283."
    },
    {
      "command": "git status --short && git rev-parse --short HEAD",
      "result": "passed",
      "summary": "No staged/tracked changes after commit before report write; HEAD 81504283; untracked subagent output artifacts remain."
    }
  ],
  "validationOutput": [
    "Focused attach tests: 12 tests, 0 failures",
    "Full mix test: 85 tests, 0 failures",
    "mix compile --warnings-as-errors: passed",
    "npx tsc --noEmit: passed with no output",
    "TRD parser: trd parse ok tasks 52 warnings []",
    "Commit: 81504283 fix: harden Elixir attach idempotency"
  ],
  "residualRisks": [
    "CLI attach coverage remains deferred per instruction; no TypeScript CLI attach plumbing was added."
  ],
  "noStagedFiles": true,
  "diffSummary": "AttachBridge duplicate-idempotency now returns the original matching attach event payload by stream/idempotency key instead of the latest run-level projection, and resume validation rejects terminal runs before side effects. attach_bridge_test.exs adds multi-worker/unsupported interleaving idempotency and completed/failed/blocked terminal-resume direct + HTTP regressions.",
  "reviewFindings": [],
  "manualNotes": "Scoped to TRD-021 attach/recovery bridge correctness fixes only. Existing recent-completed attach, stale metadata rejection, interrupt validation, HTTP 404/409 mapping, and restart/replay behavior were preserved.",
  "notes": "Output report file and previous review output artifact are untracked after final write by design."
}
```
