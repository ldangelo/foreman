Implemented TRD-025 and TRD-025-TEST.

Tasks closed:
- TRD-025 / bd-rwi15
- TRD-025-TEST / bd-cwjl6

Commits:
- 8f615bcc feat: add Elixir security controls
- 208b9cbe test: verify Elixir security controls

Changed files:
- .tasks/issues.jsonl
- .tasks/last-touched
- CLAUDE.md
- README.md
- docs/cli-reference.md
- docs/user-guide.md
- packages/foreman_server/README.md
- packages/foreman_server/lib/foreman_server/command_router.ex
- packages/foreman_server/lib/foreman_server/http/endpoint.ex
- packages/foreman_server/lib/foreman_server/http/router.ex
- packages/foreman_server/lib/foreman_server/projection_store.ex
- packages/foreman_server/lib/foreman_server/security.ex
- packages/foreman_server/lib/foreman_server/worker_environment.ex
- packages/foreman_server/lib/foreman_server/worker_protocol.ex
- packages/foreman_server/test/security_test.exs

Validation:
- `cd packages/foreman_server && mix format && mix test test/security_test.exs test/worker_protocol_test.exs test/http_router_test.exs` exit 0; 17 tests, 0 failures.
- `cd packages/foreman_server && mix test` exit 0; 111 tests, 0 failures.
- `npx tsc --noEmit` exit 0.
- `node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md` exit 0; 52 tasks, warnings [].
- Final `git status --short` before this report: clean.

Diff summary:
- Added `ForemanServer.WorkerEnvironment` to prepare scoped worker env metadata with `FOREMAN_PROJECT_ID`, `FOREMAN_RUN_ID`, allowed env, explicit project/run secret maps, and stripped forbidden host secret keys.
- Wired worker env prep into `WorkerProtocol.start_phase/2`; worker start events now include prepared env metadata, stripped keys, and scoped secret key lists. Also replaced worker protocol dynamic string-to-atom normalization with a fixed key allowlist.
- Added `ForemanServer.Security` for remote access checks, destructive-command detection, and authorization/audit event appends.
- Enforced token requirement when binding HTTP endpoint beyond loopback and when `FOREMAN_SERVER_REMOTE_ACCESS=true` / app env remote access is enabled.
- Destructive command-router actions now append `AuthorizationChecked` and `AuditRecorded` events after successful execution; projections retain an `authorization_audits` timeline.
- Updated operator docs for worker secret scoping, remote token requirements, and audit events.

Residual risks:
- Destructive-command audit coverage is applied at the command-router boundary. Direct module-specific APIs outside `CommandRouter` retain their existing events unless routed through commands.
- Worker env prep is event-bound metadata for the current protocol shell; actual OS process launch integration remains wherever provider execution consumes the prepared env.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Ran `/Users/ldangelo/.local/bin/native task store update bd-rwi15 --status in_progress` before implementation edits; task moved open -> in_progress."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "Scoped work to TRD-025 security controls and, after bd-rwi15 closed/unlocked bd-cwjl6, TRD-025-TEST only. Did not implement TRD-026 or later work."
    },
    {
      "id": "criterion-3",
      "status": "satisfied",
      "evidence": "AC-023-1 implemented by WorkerEnvironment + WorkerProtocol prepared env/secret stripping; AC-023-2 by endpoint/router remote token enforcement; AC-023-3 by Security + CommandRouter AuthorizationChecked/AuditRecorded events and authorization_audits projection."
    },
    {
      "id": "criterion-4",
      "status": "satisfied",
      "evidence": "Closed bd-rwi15 and bd-cwjl6 only after validation passed: focused ExUnit, full mix test, npx tsc --noEmit, and TRD parser."
    },
    {
      "id": "criterion-5",
      "status": "satisfied",
      "evidence": "Created separate commits: 8f615bcc feat: add Elixir security controls, then 208b9cbe test: verify Elixir security controls."
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
    "packages/foreman_server/lib/foreman_server/http/endpoint.ex",
    "packages/foreman_server/lib/foreman_server/http/router.ex",
    "packages/foreman_server/lib/foreman_server/projection_store.ex",
    "packages/foreman_server/lib/foreman_server/security.ex",
    "packages/foreman_server/lib/foreman_server/worker_environment.ex",
    "packages/foreman_server/lib/foreman_server/worker_protocol.ex",
    "packages/foreman_server/test/security_test.exs"
  ],
  "testsAddedOrUpdated": [
    "packages/foreman_server/test/security_test.exs"
  ],
  "commandsRun": [
    {
      "command": "git status --short && native task store show bd-rwi15 --json && trd-cli parse ...",
      "result": "passed",
      "summary": "Verified clean start, TRD-025 task open, and TRD parser available."
    },
    {
      "command": "/Users/ldangelo/.local/bin/native task store update bd-rwi15 --status in_progress",
      "result": "passed",
      "summary": "Claimed TRD-025 before edits."
    },
    {
      "command": "cd packages/foreman_server && mix format && mix test test/security_test.exs test/worker_protocol_test.exs test/http_router_test.exs",
      "result": "passed",
      "summary": "Focused security/worker/router tests passed: 17 tests, 0 failures."
    },
    {
      "command": "cd packages/foreman_server && mix test && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
      "result": "passed",
      "summary": "Pre-close implementation validation passed: 111 ExUnit tests, TypeScript pass, TRD parser 52 tasks warnings []."
    },
    {
      "command": "/Users/ldangelo/.local/bin/native task store close bd-rwi15 --reason \"Implemented worker secret scoping, remote auth controls, and destructive command audit events\"",
      "result": "passed",
      "summary": "Closed TRD-025 after validation."
    },
    {
      "command": "git commit -m \"feat: add Elixir security controls\"",
      "result": "passed",
      "summary": "Committed implementation/docs/task state as 8f615bcc."
    },
    {
      "command": "/Users/ldangelo/.local/bin/native task store update bd-cwjl6 --status in_progress",
      "result": "passed",
      "summary": "Claimed TRD-025-TEST after TRD-025 closed and dependency unlocked."
    },
    {
      "command": "cd packages/foreman_server && mix test && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
      "result": "passed",
      "summary": "Pre-close test validation passed: 111 ExUnit tests, TypeScript pass, TRD parser 52 tasks warnings []."
    },
    {
      "command": "/Users/ldangelo/.local/bin/native task store close bd-cwjl6 --reason \"Verified worker secret scoping, remote auth controls, and destructive command audit events\"",
      "result": "passed",
      "summary": "Closed TRD-025-TEST after validation."
    },
    {
      "command": "git commit -m \"test: verify Elixir security controls\"",
      "result": "passed",
      "summary": "Committed tests/task state as 208b9cbe."
    },
    {
      "command": "git status --short && git log --oneline -4",
      "result": "passed",
      "summary": "Final git status clean before report write; HEAD 208b9cbe."
    }
  ],
  "validationOutput": [
    "Focused ExUnit: 17 tests, 0 failures",
    "Full mix test: 111 tests, 0 failures",
    "npx tsc --noEmit: passed with no output",
    "TRD parser: trd parse ok tasks 52 warnings []",
    "Commits: 8f615bcc, 208b9cbe"
  ],
  "residualRisks": [
    "Destructive-command audit coverage is applied at the command-router boundary; direct module-specific APIs outside CommandRouter retain existing events unless routed through commands.",
    "Worker env prep is event-bound metadata for the current protocol shell; actual OS process launch integration remains wherever provider execution consumes the prepared env."
  ],
  "noStagedFiles": true,
  "diffSummary": "Added Elixir security controls for TRD-025: WorkerEnvironment scopes worker env and project/run secrets while stripping forbidden host variables; WorkerProtocol records prepared env metadata and uses allowlisted key normalization; Security enforces remote token requirements and appends AuthorizationChecked/AuditRecorded events for destructive CommandRouter commands; Endpoint refuses non-loopback binding without FOREMAN_SERVER_AUTH_TOKEN; ProjectionStore exposes authorization_audits; docs and ExUnit tests updated.",
  "reviewFindings": [],
  "manualNotes": "Stopped after TRD-025 and TRD-025-TEST. Did not implement TRD-026.",
  "notes": "Writing this report leaves subagent-outputs/trd-025-worker.md untracked by design."
}
```
