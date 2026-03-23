# Session Log: foreman status should show retry count and previous attempt outcomes

## Metadata
- Date: 2026-03-23
- Phase: reviewer
- Seed: bd-38i1
- Run ID: 861bae55-f7ef-4b4c-adfc-ff2355c07723

## Key Activities
- Read TASK.md, EXPLORER_REPORT.md, and QA_REPORT.md for context
- Read full implementation in `src/cli/watch-ui.ts` (renderAgentCard, renderAgentCardSummary changes)
- Read full implementation in `src/cli/commands/status.ts` (renderStatus loop changes)
- Read test file `src/cli/__tests__/status-display.test.ts` (11 new retry-info tests)
- Verified `store.getRunsForSeed` ordering in `src/lib/store.ts`
- Checked `renderWatchDisplay` call sites in watch-ui.ts for the watch-mode gap
- Assessed JSON output path for missing attempt fields

## Findings
- Implementation for `foreman status` is correct and well-tested
- `foreman run --watch` does NOT show retry info — `renderWatchDisplay` calls `renderAgentCard` without `attemptNumber`/`previousStatus` because `WatchState` doesn't carry that data
- JSON `--json` output path doesn't include attempt fields
- These are the only issues found; no bugs, logic errors, or security issues

## Artifacts Created
- REVIEW.md — code review with verdict FAIL (1 WARNING, 2 NOTEs)
- SESSION_LOG.md — this file

## Notes
- The WARNING (watch-mode gap) is fixable: `poll()` already has store access; WatchState just needs per-run attempt fields populated there
- Core requirement (foreman status showing retry info) is fully implemented and correct
