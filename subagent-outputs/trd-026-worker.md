Implemented TRD-026 and TRD-026-TEST.

Tasks closed:
- TRD-026 / bd-lxhto
- TRD-026-TEST / bd-0asyf

Commits:
- 0b196164 docs: document Elixir backend architecture
- 707676a5 test: verify Elixir backend docs

Changed files:
- .tasks/issues.jsonl
- .tasks/last-touched
- CLAUDE.md
- README.md
- docs/cli-reference.md
- docs/guides/elixir-backend-architecture.md
- docs/troubleshooting.md
- docs/user-guide.md
- src/cli/__tests__/trd-2026-014-docs.test.ts

Validation:
- `npx vitest run src/cli/__tests__/trd-2026-014-docs.test.ts --reporter=dot` exit 0; 1 file, 3 tests passed.
- `npx tsc --noEmit` exit 0.
- `node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md` exit 0; 52 tasks, warnings [].
- No Elixir files touched; `mix test` not run.
- Final task count: 52/52 TRD tasks closed.
- Final git status before writing this report: clean.

Diff summary:
- Added `docs/guides/elixir-backend-architecture.md` documenting the Node CLI, Elixir server, and Node/Pi worker responsibility split; command/event flow; deprecated/renamed command replacements; migration delegation; and event/projection/recovery troubleshooting examples.
- Updated README, User Guide, CLI Reference, CLAUDE, and troubleshooting docs to link and summarize the architecture split, deprecation warnings/replacements, server doctor/metrics auth, projection lag, debug anomaly timelines, and recovery event model.
- Added a focused Vitest doc coverage test verifying AC-024-1/2/3 across README, User Guide, CLI Reference, architecture guide, and troubleshooting guide.

Residual risks:
- None for TRD-026 docs scope.

Current git status after report write:
- This report file is untracked by design; no staged files expected.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Claimed TRD-026 with `/Users/ldangelo/.local/bin/native task store update bd-lxhto --status in_progress` before editing docs."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "Implemented only TRD-026 documentation scope, then claimed and implemented TRD-026-TEST after bd-lxhto closed/unlocked bd-0asyf. No Elixir/runtime behavior was changed."
    },
    {
      "id": "criterion-3",
      "status": "satisfied",
      "evidence": "Docs now cover Node CLI / Elixir server / Node-Pi worker responsibilities, deprecated command replacements and legacy delegation, plus event/projection/recovery troubleshooting examples. Added Vitest coverage for AC-024-1, AC-024-2, AC-024-3."
    },
    {
      "id": "criterion-4",
      "status": "satisfied",
      "evidence": "Closed bd-lxhto only after docs test, TypeScript, and TRD parse validation passed; closed bd-0asyf only after the same validation passed again."
    },
    {
      "id": "criterion-5",
      "status": "satisfied",
      "evidence": "Created separate commits: 0b196164 docs: document Elixir backend architecture; 707676a5 test: verify Elixir backend docs."
    }
  ],
  "changedFiles": [
    ".tasks/issues.jsonl",
    ".tasks/last-touched",
    "CLAUDE.md",
    "README.md",
    "docs/cli-reference.md",
    "docs/guides/elixir-backend-architecture.md",
    "docs/troubleshooting.md",
    "docs/user-guide.md",
    "src/cli/__tests__/trd-2026-014-docs.test.ts"
  ],
  "testsAddedOrUpdated": [
    "src/cli/__tests__/trd-2026-014-docs.test.ts"
  ],
  "commandsRun": [
    {
      "command": "/Users/ldangelo/.local/bin/native task store update bd-lxhto --status in_progress",
      "result": "passed",
      "summary": "Claimed TRD-026 before documentation edits."
    },
    {
      "command": "npx vitest run src/cli/__tests__/trd-2026-014-docs.test.ts --reporter=dot && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
      "result": "passed",
      "summary": "Pre-close implementation validation passed: docs test 3 passed, TypeScript passed, TRD parser warnings []."
    },
    {
      "command": "/Users/ldangelo/.local/bin/native task store close bd-lxhto --reason \"Updated operator and architecture docs for Elixir backend migration\"",
      "result": "passed",
      "summary": "Closed TRD-026 after validation."
    },
    {
      "command": "git commit -m \"docs: document Elixir backend architecture\"",
      "result": "passed",
      "summary": "Created implementation/docs commit 0b196164."
    },
    {
      "command": "/Users/ldangelo/.local/bin/native task store update bd-0asyf --status in_progress",
      "result": "passed",
      "summary": "Claimed TRD-026-TEST after TRD-026 closed."
    },
    {
      "command": "npx vitest run src/cli/__tests__/trd-2026-014-docs.test.ts --reporter=dot && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md",
      "result": "passed",
      "summary": "Pre-close test validation passed: docs test 3 passed, TypeScript passed, TRD parser warnings []."
    },
    {
      "command": "/Users/ldangelo/.local/bin/native task store close bd-0asyf --reason \"Verified TRD-026 operator docs cover responsibilities, deprecations, and troubleshooting\"",
      "result": "passed",
      "summary": "Closed TRD-026-TEST after validation."
    },
    {
      "command": "git commit -m \"test: verify Elixir backend docs\"",
      "result": "passed",
      "summary": "Created test/task commit 707676a5."
    },
    {
      "command": "git status --short && native task store list --all --limit 0 --title-contains '[trd:trd-2026-014-elixir-backend-orchestration:task:' --json",
      "result": "passed",
      "summary": "Clean before report write; all 52 TRD tasks closed."
    }
  ],
  "validationOutput": [
    "Docs Vitest: 1 file passed, 3 tests passed",
    "npx tsc --noEmit: passed with no output",
    "TRD parser: ok, 52 tasks, warnings []",
    "mix test: not run because no Elixir files were touched",
    "TRD task tasks: 52 closed / 52 total",
    "Commits: 0b196164, 707676a5"
  ],
  "residualRisks": [],
  "noStagedFiles": true,
  "diffSummary": "Added a dedicated Elixir backend architecture guide and updated README, User Guide, CLI Reference, CLAUDE, and troubleshooting docs so operators can understand Node CLI vs Elixir server vs Node/Pi worker responsibilities, deprecated command replacements/legacy delegation, and event/projection/recovery troubleshooting. Added a focused Vitest doc coverage test for AC-024-1/2/3 and closed both TRD-026 tasks.",
  "reviewFindings": [],
  "manualNotes": "No subagents run. Scope limited to TRD-026 docs and matching docs test. No Elixir runtime files touched.",
  "notes": "Writing this report leaves subagent-outputs/trd-026-worker.md untracked by design."
}
```
