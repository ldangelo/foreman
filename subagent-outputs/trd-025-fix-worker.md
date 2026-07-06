Implemented TRD-025 review fixes only.

Changed files:
- packages/foreman_server/test/security_test.exs
- packages/foreman_server/test/http_router_test.exs
- packages/foreman_server/test/worker_protocol_test.exs

Commit:
- 47cf8f08 test: harden Elixir security controls

Validation:
- `cd packages/foreman_server && mix format && mix test test/security_test.exs test/http_router_test.exs test/worker_protocol_test.exs` exit 0; 19 tests, 0 failures.
- `cd packages/foreman_server && mix test && mix compile --warnings-as-errors` exit 0; 113 tests, 0 failures; compile clean.
- `npx tsc --noEmit` exit 0; no output.
- `node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md` exit 0; 52 tasks, warnings [].
- `git diff --check` exit 0.
- `git status --short && git rev-parse --short HEAD` exit 0 before writing this report; clean, HEAD 47cf8f08.

Diff summary:
- Strengthened destructive command audit test to rebuild projections via `EventStore.rebuild_projections/0` and assert `AuthorizationChecked` / `AuditRecorded` replay into `authorization_audits` in order with complete command, actor, decision, target, and resulting event data.
- Extended command API auth negative coverage so invalid bearer token returns 401 and leaves `EventStore.all()` unchanged.
- Added worker phase-start invalid bearer token coverage for `/worker/v1/phases/:phase_id/start`, asserting 401 and no side effects.
- Made `FOREMAN_SERVER_AUTH_TOKEN` stripping meaningful by injecting it into env/project secrets/run secrets and asserting it is stripped from prepared env.
- Added a two-run/project secret scoping fixture proving project/run secrets from one worker start do not appear in another prepared env.

Residual risks:
- None for scoped TRD-025 review fixes.

Git status after report write:
- This report file is untracked by design; no staged files expected.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "security_test now executes destructive task.close through CommandRouter, asserts live authorization_audits, calls EventStore.rebuild_projections(), and asserts rebuilt AuthorizationChecked/AuditRecorded audits remain ordered and complete."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "http_router_test covers invalid bearer token on /api/v1/commands with EventStore.all() unchanged; worker_protocol_test covers invalid bearer token on /worker/v1/phases/developer/start with EventStore.all() unchanged."
    },
    {
      "id": "criterion-3",
      "status": "satisfied",
      "evidence": "security_test includes FOREMAN_SERVER_AUTH_TOKEN in env, project_secrets, and run_secrets and asserts it is stripped; added two-run/project fixture proving secrets do not leak between prepared worker envs."
    },
    {
      "id": "criterion-4",
      "status": "satisfied",
      "evidence": "Required validation passed: focused ExUnit, full mix test plus compile warnings-as-errors, npx tsc --noEmit, TRD parser, and git diff --check."
    },
    {
      "id": "criterion-5",
      "status": "satisfied",
      "evidence": "Created one fix commit: 47cf8f08 test: harden Elixir security controls."
    }
  ],
  "changedFiles": [
    "packages/foreman_server/test/security_test.exs",
    "packages/foreman_server/test/http_router_test.exs",
    "packages/foreman_server/test/worker_protocol_test.exs"
  ],
  "testsAddedOrUpdated": [
    "packages/foreman_server/test/security_test.exs",
    "packages/foreman_server/test/http_router_test.exs",
    "packages/foreman_server/test/worker_protocol_test.exs"
  ],
  "commandsRun": [
    {
      "command": "cd packages/foreman_server && mix format && mix test test/security_test.exs test/http_router_test.exs test/worker_protocol_test.exs",
      "result": "failed",
      "summary": "Initial run failed because the rebuild assertion expected correlation_id in authorization_audits payload; adjusted test to assert persisted payload fields instead."
    },
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
      "command": "git add packages/foreman_server/test/security_test.exs packages/foreman_server/test/http_router_test.exs packages/foreman_server/test/worker_protocol_test.exs && git commit -m 'test: harden Elixir security controls'",
      "result": "passed",
      "summary": "exit 0; created commit 47cf8f08."
    },
    {
      "command": "git status --short && git rev-parse --short HEAD",
      "result": "passed",
      "summary": "exit 0 before report write; no status output, HEAD 47cf8f08."
    }
  ],
  "validationOutput": [
    "Focused ExUnit: 19 tests, 0 failures",
    "Full mix test: 113 tests, 0 failures",
    "mix compile --warnings-as-errors: passed",
    "npx tsc --noEmit: passed with no output",
    "TRD parser: ok, 52 tasks, warnings []",
    "git diff --check: passed",
    "Commit: 47cf8f08 test: harden Elixir security controls"
  ],
  "residualRisks": [],
  "noStagedFiles": true,
  "diffSummary": "Added TRD-025 security validation coverage only: destructive audit projection rebuild/replay assertions, invalid bearer no-side-effect tests for command API and worker phase start, meaningful FOREMAN_SERVER_AUTH_TOKEN stripping assertion, and two-run/project secret non-leakage fixture. No production changes were needed.",
  "reviewFindings": [],
  "manualNotes": "Scoped to parent-synthesized TRD-025 review fixes only. No subagents run. Removed stale untracked review artifact before committing.",
  "notes": "Report file is untracked by design after final write."
}
```
