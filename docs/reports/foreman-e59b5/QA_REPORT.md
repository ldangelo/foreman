# QA Report: Harden trace and pipeline report artifacts

## Verdict: PASS

## Test Results
- Targeted command(s) run: `npx vitest run -c vitest.unit.config.ts src/orchestrator/__tests__/pi-observability-extension.test.ts src/orchestrator/__tests__/activity-logger.test.ts`
- TypeScript compilation: `npx tsc --noEmit` — passed (no output = no errors)
- Test suite (unit only, targeted): 2 test files, 12 passed
- Raw summary:
  ```
  Test Files  2 passed (2)
      Tests  12 passed (12)
  ```

## Issues Found
- None. All targeted tests pass.
- Note: The task requirement mentioned updating `src/defaults/prompts/default/qa.md` to remove piped test evidence patterns (e.g., `npm test ... | tail`). The current qa.md already does not contain such patterns (confirmed via grep), so no change was needed there. This is acceptable — the requirement is satisfied by absence.

## Files Modified
- `src/orchestrator/__tests__/activity-logger.test.ts` — inspected (read-only QA verification)
- `src/orchestrator/__tests__/pi-observability-extension.test.ts` — inspected (read-only QA verification)
- `src/orchestrator/pi-observability-extension.ts` — inspected (read-only QA verification)
- `src/orchestrator/pi-observability-writer.ts` — inspected (read-only QA verification)
- `src/defaults/prompts/default/qa.md` — inspected (read-only QA verification)

## Implementation Verification

### 1. Path Sanitization in Trace Artifacts
The implementation adds `sanitizeValue()` in `pi-observability-extension.ts` (line 62–69) and `sanitizeWorktreePath()` in `pi-observability-writer.ts` (line 26–30). These replace the absolute worktree path with `<worktree>` placeholder in:
- `argsPreview` captured during tool call start events (line 204, 213)
- `resultPreview` captured during partial result, content, and final result events (lines 222, 243, 245)
- The JSON serialization itself via `serializeTrace()` (line 38–45) which uses `JSON.stringify` with a replacer function

The tests in `pi-observability-extension.test.ts` verify:
- `sanitizes absolute worktree paths in tool call argsPreview` — argsPreview in JSON trace does not contain the worktree path, replaced with `<worktree>`
- `sanitizes worktreePath field in JSON trace output` — the JSON file itself does not contain the raw worktree path

### 2. Pipeline Report Builtin Phase Inclusion
The test in `activity-logger.test.ts` (`writeIncrementalPipelineReport includes builtin phases in phase table`) verifies that builtin phases appear in `PIPELINE_REPORT.md` and that their `phaseType: "builtin"` is shown. The test passes 12/12 on the targeted unit tests.

### 3. QA Prompt Pipe Patterns
The current `qa.md` prompt does not contain piped test evidence patterns (e.g., `| tail`). Confirmed via grep search for `| tail` and `pipefail` — no matches. No change needed; requirement satisfied by existing clean state.

## New Tests Added
3 new tests across 2 test files:
- `pi-observability-extension.test.ts`: 2 new tests for path sanitization
- `activity-logger.test.ts`: 1 new test for builtin phase reporting

## Test Coverage Gaps (Recommendations)
- The markdown rendering in `renderTraceMarkdown()` also emits `argsPreview`/`resultPreview` but currently those values are already sanitized at capture time in `pi-observability-extension.ts`. A direct test of markdown output path sanitization would provide additional confidence.
- The `serializeTrace()` replacer in `pi-observability-writer.ts` sanitizes all string values including nested ones. A test with deeply nested paths (e.g., nested JSON in tool args) could be added.
- Integration-level test covering end-to-end trace file generation with real pipeline execution would validate the full artifact pipeline, though this is covered by existing integration tests.