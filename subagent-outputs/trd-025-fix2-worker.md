Implemented TRD-025 review round 2 secret redaction fix only.

Changed files:
- packages/foreman_server/lib/foreman_server/worker_protocol.ex
- packages/foreman_server/test/security_test.exs

Commit:
- 544f089b fix: redact worker secret payloads

Validation:
- `cd packages/foreman_server && mix format && mix test test/security_test.exs test/http_router_test.exs test/worker_protocol_test.exs` exit 0; 19 tests, 0 failures.
- `cd packages/foreman_server && mix test && mix compile --warnings-as-errors` exit 0; 113 tests, 0 failures; compile clean.
- `npx tsc --noEmit` exit 0.
- `node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md` exit 0; 52 tasks, warnings [].
- `git diff --check` exit 0.

Diff summary:
- `WorkerStarted` durable payloads now persist redacted `prepared_env` values plus sorted `prepared_env_keys`, `stripped_env_keys`, and `scoped_secret_keys` metadata.
- Raw worker env/secret values are no longer stored in event payloads/projections/debug-readable persisted data.
- Security tests now assert secret keys/stripped keys remain while raw secret strings are absent from `EventStore.all()` and `ProjectionStore.snapshot()` inspection.
- Existing two-run/project non-leak test now verifies redacted metadata, not secret values.

Residual risks:
- Current protocol has no real OS worker handoff; this fix redacts durable metadata only and does not add provider execution plumbing.

Git status before writing this report:
- clean; HEAD `544f089b`.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "WorkerProtocol now writes WorkerStarted prepared_env with every value replaced by [REDACTED] and adds prepared_env_keys for metadata. Raw prepared_env values from WorkerEnvironment.prepare/1 are not persisted."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "security_test asserts PROJECT_TOKEN/RUN_TOKEN keys, stripped forbidden keys, and prepared_env_keys remain, while EventStore.all() and ProjectionStore.snapshot() inspection excludes raw values project-secret, run-secret, server-token, project-server-token, run-server-token, p1, r1, p2, and r2."
    },
    {
      "id": "criterion-3",
      "status": "satisfied",
      "evidence": "Required validation passed: focused ExUnit, full mix test plus compile warnings-as-errors, npx tsc --noEmit, TRD parser, and git diff --check."
    },
    {
      "id": "criterion-4",
      "status": "satisfied",
      "evidence": "Created one fix commit: 544f089b fix: redact worker secret payloads."
    }
  ],
  "changedFiles": [
    "packages/foreman_server/lib/foreman_server/worker_protocol.ex",
    "packages/foreman_server/test/security_test.exs"
  ],
  "testsAddedOrUpdated": [
    "packages/foreman_server/test/security_test.exs"
  ],
  "commandsRun": [
    {
      "command": "cd packages/foreman_server && mix format && mix test test/security_test.exs test/http_router_test.exs test/worker_protocol_test.exs",
      "result": "passed",
      "summary": "exit 0; focused security/router/worker protocol tests passed: 19 tests, 0 failures."
    },
    {
      "command": "cd packages/foreman_server && mix test && mix compile --warnings-as-errors",
      "result": "passed",
      "summary": "exit 0; full Elixir suite passed: 113 tests, 0 failures; compile warnings-as-errors clean."
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
      "command": "git add packages/foreman_server/lib/foreman_server/worker_protocol.ex packages/foreman_server/test/security_test.exs && git commit -m 'fix: redact worker secret payloads'",
      "result": "passed",
      "summary": "exit 0; created commit 544f089b."
    },
    {
      "command": "git status --short && git rev-parse --short HEAD",
      "result": "passed",
      "summary": "exit 0 before report write; status clean; HEAD 544f089b."
    }
  ],
  "validationOutput": [
    "Focused ExUnit: 19 tests, 0 failures",
    "Full mix test: 113 tests, 0 failures",
    "mix compile --warnings-as-errors: passed",
    "npx tsc --noEmit: passed with no output",
    "TRD parser: ok, 52 tasks, warnings []",
    "git diff --check: passed",
    "Commit: 544f089b fix: redact worker secret payloads"
  ],
  "residualRisks": [
    "Current protocol has no real OS worker handoff; this fix redacts durable WorkerStarted metadata only and does not add provider execution plumbing."
  ],
  "noStagedFiles": true,
  "diffSummary": "WorkerStarted durable payloads now redact all prepared_env values and persist only metadata keys, stripped forbidden keys, and scoped secret key names. Security tests now assert raw secret strings are absent from EventStore/projection payloads while secret key metadata remains.",
  "reviewFindings": [],
  "manualNotes": "Scoped to TRD-025 review round 2 secret redaction fix only. Removed stale untracked reviewer artifact before commit.",
  "notes": "Writing this report leaves subagent-outputs/trd-025-fix2-worker.md untracked by design."
}
```