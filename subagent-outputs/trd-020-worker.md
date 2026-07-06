Implemented TRD-020 and TRD-020-TEST.

Tasks closed:
- TRD-020 / bd-sg6d
- TRD-020-TEST / bd-13ga

Commits:
- a5d04a11 feat: add Elixir debug views
- b5492c11 test: verify Elixir debug views

Files changed:
- .beads/issues.jsonl
- .beads/last-touched
- docs/TRD/TRD-2026-014-elixir-backend-orchestration.md
- packages/foreman_server/README.md
- packages/foreman_server/lib/foreman_server/debug_views.ex
- packages/foreman_server/lib/foreman_server/http/router.ex
- packages/foreman_server/lib/foreman_server/projection_store.ex
- packages/foreman_server/lib/foreman_server/worker_protocol.ex
- packages/foreman_server/test/debug_views_test.exs

Validation:
- `cd packages/foreman_server && mix test && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md ...`
  - Exit: 0
  - Mix: 66 tests, 0 failures
  - TypeScript: pass
  - TRD parser: 52 tasks, warnings []
- Additional compile check during implementation: `cd packages/foreman_server && mix compile --warnings-as-errors && mix test`
  - Exit: 0
  - Compile clean, tests passed
- `git status --short`
  - Exit: 0 before writing this report; clean output

Diff summary:
- Added `ForemanServer.DebugViews` for event-backed compact/raw log rendering, run reports, and debug timelines derived from `EventStore` events.
- Added HTTP read endpoints for `/api/v1/runs/:run_id/logs`, `/report`, and `/debug`.
- Mapped worker `stdout`, `stderr`, and `assistant_message` protocol events to durable worker event types.
- Added log projection state and sequence advancement for worker log events.
- Added AC-017 tests for compact/raw logs, artifact/report references, and historical summaries after external log files are purged.

Risks/blockers:
- None known for TRD-020 scope.

Current git status:
- No staged files before writing this report.
- Writing this report leaves `subagent-outputs/trd-020-worker.md` as an output artifact.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Claimed bd-sg6d in_progress before implementation edits, then claimed bd-13ga in_progress after TRD-020 closed/unlocked."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "Implemented only TRD-020 event-backed logs/reports/debug views and matching TRD-020-TEST coverage; did not implement later TRD tasks."
    },
    {
      "id": "criterion-3",
      "status": "satisfied",
      "evidence": "Closed bd-sg6d and bd-13ga only after required validation commands passed."
    },
    {
      "id": "criterion-4",
      "status": "satisfied",
      "evidence": "Committed implementation separately as a5d04a11 and test/bead changes separately as b5492c11."
    },
    {
      "id": "criterion-5",
      "status": "satisfied",
      "evidence": "Exact validation commands and exit-code summaries are listed in commandsRun and validationOutput."
    }
  ],
  "changedFiles": [
    ".beads/issues.jsonl",
    ".beads/last-touched",
    "docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
    "packages/foreman_server/README.md",
    "packages/foreman_server/lib/foreman_server/debug_views.ex",
    "packages/foreman_server/lib/foreman_server/http/router.ex",
    "packages/foreman_server/lib/foreman_server/projection_store.ex",
    "packages/foreman_server/lib/foreman_server/worker_protocol.ex",
    "packages/foreman_server/test/debug_views_test.exs"
  ],
  "testsAddedOrUpdated": [
    "packages/foreman_server/test/debug_views_test.exs"
  ],
  "commandsRun": [
    {
      "command": "br update bd-sg6d --status in_progress --json && br comment add bd-sg6d ... && br sync --flush-only",
      "result": "passed",
      "summary": "Claimed TRD-020 bead before editing."
    },
    {
      "command": "cd packages/foreman_server && mix format && mix compile --warnings-as-errors && mix test",
      "result": "passed",
      "summary": "Implementation compile/check passed cleanly; 63 tests passed at that point."
    },
    {
      "command": "cd packages/foreman_server && mix test && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
      "result": "passed",
      "summary": "Implementation validation passed before closing TRD-020; 63 tests, TypeScript pass, TRD parser warnings []."
    },
    {
      "command": "br close bd-sg6d --reason 'Completed TRD-020 event-backed log/report/debug views' && br sync --flush-only && git commit -m 'feat: add Elixir debug views'",
      "result": "passed",
      "summary": "Closed TRD-020 and committed implementation as a5d04a11."
    },
    {
      "command": "br update bd-13ga --status in_progress --json && br comment add bd-13ga ... && br sync --flush-only",
      "result": "passed",
      "summary": "Claimed TRD-020-TEST after dependency unlocked."
    },
    {
      "command": "cd packages/foreman_server && mix format && mix test && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
      "result": "passed",
      "summary": "Final validation passed; 66 tests, 0 failures; TypeScript pass; TRD parser pass."
    },
    {
      "command": "br close bd-13ga --reason 'Completed TRD-020-TEST; debug view tests pass' && br sync --flush-only && git commit -m 'test: verify Elixir debug views'",
      "result": "passed",
      "summary": "Closed TRD-020-TEST and committed tests/bead changes as b5492c11."
    },
    {
      "command": "git status --short",
      "result": "passed",
      "summary": "Clean before writing this output artifact."
    }
  ],
  "validationOutput": [
    "mix compile --warnings-as-errors: passed during implementation check",
    "mix test: 66 tests, 0 failures",
    "npx tsc --noEmit: passed with no output",
    "TRD parser: trd parse ok tasks 52 warnings []",
    "git status --short: clean before output artifact"
  ],
  "residualRisks": [],
  "noStagedFiles": true,
  "diffSummary": "Added event-backed debug/log/report read views via ForemanServer.DebugViews, HTTP read endpoints for run logs/report/debug, durable worker stdout/stderr/assistant event typing, log sequence projection support, and AC-017 tests proving compact/raw logs, artifact/report timeline references, and summaries after external log file purge.",
  "reviewFindings": [],
  "manualNotes": "Closed TRD-020 / bd-sg6d and TRD-020-TEST / bd-13ga. Current TRD task progress from br list: 40 closed, 12 open.",
  "notes": "Output file itself is untracked after final write by design."
}
```
