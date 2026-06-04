# QA Report: Harden trace and pipeline report artifacts

## Verdict: PASS

## Test Results

- Targeted commands run:
  - `npx tsc --noEmit` — passed (no output, exit 0)
  - `npx vitest run src/orchestrator/__tests__/pi-observability-extension.test.ts --reporter=verbose` — 6 passed
  - `npx vitest run src/orchestrator/__tests__/activity-logger.test.ts --reporter=verbose` — 6 passed
- Full suite command: `npm test -- --reporter=dot 2>&1` (unit + integration)
- Test suite: 239 passed, 6 skipped (unit); 38 passed (integration); 2 passed (smoke); 1 passed (full-run) — all PASS
- Raw summary:
  - Unit: `Test Files 239 passed (239) | Tests 3277 passed | 6 skipped (3283)`
  - Integration: `Test Files 38 passed (38) | Tests 597 passed (597)`
  - E2E smoke: `Test Files 1 passed (1) | Tests 2 passed (2)`
  - E2E full-run: `Test Files 1 passed (1) | Tests 1 passed (1)`
- New tests added: 2 new tests in `src/orchestrator/__tests__/pi-observability-extension.test.ts` (sanitizes absolute worktree paths in argsPreview + sanitizes worktreePath field in JSON output), 1 test updated in `src/orchestrator/__tests__/activity-logger.test.ts` (builtin phase artifact expectation corrected)

## Issues Found

None. All tests pass.

## Files Modified

- `src/orchestrator/pi-observability-extension.ts` — Added `sanitizeValue()` function and `worktreePath` parameter to `summarizeUnknown()`; all capture points (`tool_execution_start`, `tool_execution_update`, `tool_result`, `tool_execution_end`) now sanitize absolute worktree paths from args/results before storing them as previews
- `src/orchestrator/pi-observability-writer.ts` — Added `sanitizeWorktreePath()` utility and `serializeTrace()` wrapper around `JSON.stringify()` that sanitizes all string values in the trace object; JSON trace now written via `serializeTrace()` instead of direct `JSON.stringify()`
- `src/orchestrator/__tests__/pi-observability-extension.test.ts` — Two new tests: "sanitizes absolute worktree paths in tool call argsPreview" and "sanitizes worktreePath field in JSON trace output"
- `src/orchestrator/__tests__/activity-logger.test.ts` — Updated builtin phase test to use `PR_METADATA.json` as expected artifact (aligns with actual artifact produced by `create-pr` builtin phase)
- `src/defaults/prompts/default/recover.md` — Added `set -o pipefail;` prefix to piped test commands (`npm test ... | tail -100`, `npm test ... | tail -50`) to preserve exit codes
- `src/defaults/prompts/default/troubleshooter.md` — Added `set -o pipefail;` prefix to test re-run command

## Verification Notes

1. **Path sanitization**: `sanitizeValue()` (in `pi-observability-extension.ts`) replaces absolute worktree path occurrences with `<worktree>` at capture time (tool args/results). `sanitizeWorktreePath()` / `serializeTrace()` (in `pi-observability-writer.ts`) applies the same sanitization during JSON serialization. Both layers ensure no absolute paths leak into committed trace artifacts.

2. **Builtin phase reporting**: `writeIncrementalPipelineReport()` iterates `completedPhases` and renders all phases including those with `phaseType: "builtin"`. The PIPELINE_REPORT.md for this seed shows `create-pr`, `pr-wait`, `prepare-pr-review` builtin phases in the phase table with correct artifact expectations (`PR_METADATA.json`, `PR_WAIT_REPORT.md`, `PR_REVIEW_FINDINGS.md`).

3. **Pipeline report phase table accuracy**: Confirmed via manual inspection of `docs/reports/foreman-e59b5/PIPELINE_REPORT.md` — all 21 completed phases are listed, including builtin PR phases (`create-pr`, `pr-wait`, `prepare-pr-review`) appearing twice each (before each PR-review cycle).

4. **Note on artifact path mismatch**: The workflow YAML files specify `QA_REPORT.md` as the expected artifact path for the QA phase, but QA writes the report to `docs/reports/<seed>/QA_REPORT.md`. The test in `activity-logger.test.ts` correctly uses `PR_METADATA.json` (the actual artifact for `create-pr`). The QA phase artifact path mismatch is a workflow configuration issue, not a code defect — the QA agent prompt correctly instructs writing to `docs/reports/{{seedId}}/QA_REPORT.md`.

## Pre-existing Failures

None observed. All test failures would be attributable to changes in scope.

## Summary

All acceptance criteria are met:
- ✅ No generated `*_TRACE.json` / `*_TRACE.md` intended for commit contains user-specific absolute worktree paths (sanitized at capture and write time)
- ✅ `PIPELINE_REPORT.md` accurately lists executed workflow phases including builtin PR phases (verified in `docs/reports/foreman-e59b5/PIPELINE_REPORT.md`)
- ✅ Tests cover at least one absolute path sanitization case (`sanitizes worktreePath field in JSON trace output`) and one builtin phase/report listing case (`writeIncrementalPipelineReport includes builtin phases in phase table`)
- ✅ `npx tsc --noEmit` passes with no errors
- ✅ Relevant focused tests pass (6 + 6 = 12 tests across the two test files)