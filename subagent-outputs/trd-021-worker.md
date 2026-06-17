Implemented TRD-021 and TRD-021-TEST.

Tasks closed:
- TRD-021 / bd-hper
- TRD-021-TEST / bd-foiw

Commits:
- 764257a8 feat: add Elixir attach recovery bridge
- 346e2e94 test: verify Elixir attach recovery bridge

Files changed:
- .beads/issues.jsonl
- .beads/last-touched
- docs/TRD/TRD-2026-014-elixir-backend-orchestration.md
- packages/foreman_server/README.md
- packages/foreman_server/lib/foreman_server/attach_bridge.ex
- packages/foreman_server/lib/foreman_server/http/router.ex
- packages/foreman_server/lib/foreman_server/projection_store.ex
- packages/foreman_server/test/attach_bridge_test.exs

Validation:
- `cd packages/foreman_server && mix format && mix test && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md ...`
  - Exit: 0
  - Mix: 77 tests, 0 failures
  - TypeScript: pass
  - TRD parser: 52 tasks, warnings []
- `git status --short && git log --oneline -4`
  - Exit: 0
  - Clean before writing this report
  - HEAD: 346e2e94

Diff summary:
- Added `ForemanServer.AttachBridge` for event-backed attach requests, unsupported attach diagnostics, and interactive interrupt/resume recovery decisions.
- Added authenticated HTTP endpoints:
  - `GET /api/v1/runs/:run_id/attach`
  - `POST /api/v1/runs/:run_id/interrupt`
  - `POST /api/v1/runs/:run_id/resume`
- Extended projections with `attach_requests` and `interactive_recovery`, plus phase/recovery next-action updates.
- Added AC-018 tests proving Pi SDK attach, unsupported provider reason/alternatives, interrupt/resume next action, and rebuild consistency.

Risks/blockers:
- None known for TRD-021 scope.

Current git status:
- No staged files before this report.
- This report file is untracked after write by design.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Claimed bd-hper in_progress before implementation edits, then claimed bd-foiw in_progress after TRD-021 was closed and the test dependency unlocked."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "Implemented only TRD-021 attach/interactive recovery bridge and matching TRD-021-TEST coverage; did not implement later TRD tasks."
    },
    {
      "id": "criterion-3",
      "status": "satisfied",
      "evidence": "Closed bd-hper and bd-foiw only after required validation commands passed."
    },
    {
      "id": "criterion-4",
      "status": "satisfied",
      "evidence": "Committed implementation separately as 764257a8 and test/bead changes separately as 346e2e94."
    },
    {
      "id": "criterion-5",
      "status": "satisfied",
      "evidence": "Validation command, exit status, and output summaries are recorded in commandsRun and validationOutput."
    }
  ],
  "changedFiles": [
    ".beads/issues.jsonl",
    ".beads/last-touched",
    "docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
    "packages/foreman_server/README.md",
    "packages/foreman_server/lib/foreman_server/attach_bridge.ex",
    "packages/foreman_server/lib/foreman_server/http/router.ex",
    "packages/foreman_server/lib/foreman_server/projection_store.ex",
    "packages/foreman_server/test/attach_bridge_test.exs"
  ],
  "testsAddedOrUpdated": [
    "packages/foreman_server/test/attach_bridge_test.exs"
  ],
  "commandsRun": [
    {
      "command": "br update bd-hper --status in_progress --json && br comment add bd-hper ... && br sync --flush-only",
      "result": "passed",
      "summary": "Claimed TRD-021 bead before editing."
    },
    {
      "command": "cd packages/foreman_server && mix format && mix test && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
      "result": "passed",
      "summary": "Implementation validation passed before closing TRD-021; 73 tests, TypeScript pass, TRD parser warnings []."
    },
    {
      "command": "br close bd-hper --reason 'Completed TRD-021 attach and interactive recovery bridge' && br sync --flush-only && git commit -m 'feat: add Elixir attach recovery bridge'",
      "result": "passed",
      "summary": "Closed TRD-021 and committed implementation as 764257a8."
    },
    {
      "command": "br update bd-foiw --status in_progress --json && br comment add bd-foiw ... && br sync --flush-only",
      "result": "passed",
      "summary": "Claimed TRD-021-TEST after dependency unlocked."
    },
    {
      "command": "cd packages/foreman_server && mix format && mix test && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
      "result": "passed",
      "summary": "Final validation passed; 77 tests, 0 failures; TypeScript pass; TRD parser pass."
    },
    {
      "command": "br close bd-foiw --reason 'Completed TRD-021-TEST; attach bridge tests pass' && br sync --flush-only && git commit -m 'test: verify Elixir attach recovery bridge'",
      "result": "passed",
      "summary": "Closed TRD-021-TEST and committed tests/bead changes as 346e2e94."
    },
    {
      "command": "git status --short && git log --oneline -4",
      "result": "passed",
      "summary": "Clean before writing report; HEAD 346e2e94."
    }
  ],
  "validationOutput": [
    "mix test: 77 tests, 0 failures",
    "npx tsc --noEmit: passed with no output",
    "TRD parser: trd parse ok tasks 52 warnings []",
    "git status --short before report: clean"
  ],
  "residualRisks": [],
  "noStagedFiles": true,
  "diffSummary": "Added event-backed ForemanServer.AttachBridge, authenticated attach/interrupt/resume HTTP endpoints, attach and interactive recovery projections, package README endpoint documentation, and AC-018 tests for Pi SDK attach, unsupported provider diagnostics, operator interrupt/resume next-action recording, and rebuild consistency.",
  "reviewFindings": [],
  "manualNotes": "Closed TRD-021 / bd-hper and TRD-021-TEST / bd-foiw. Scoped to attach and interactive recovery only.",
  "notes": "Output report file is untracked after final write by design."
}
```
