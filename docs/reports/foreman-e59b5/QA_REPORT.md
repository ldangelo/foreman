# QA Report: Harden trace and pipeline report artifacts

## Verdict: PASS

## Test Results

- **TypeScript check:** `npx tsc --noEmit` → clean (no output, no errors)
- **Targeted test run:** `npx vitest run src/orchestrator/__tests__/pi-observability-extension.test.ts src/orchestrator/__tests__/activity-logger.test.ts --reporter=dot 2>&1`
- **Test suite:** 2 test files, 11 tests passed, 0 failed | SKIPPED
- **Raw summary:**
  ```
  Test Files  2 passed (2)
       Tests  11 passed (11)
  ```
- **New tests added:** 3 (1 sanitization test in pi-observability-extension.test.ts, 2 builtin phase tests in activity-logger.test.ts)

## Acceptance Criteria Verification

| Criterion | Status | Evidence |
|-----------|--------|----------|
| No committed `*_TRACE.json` contains absolute worktree paths | ✅ PASS | New test "sanitizes absolute worktreePath in committed JSON trace" passes; verifies `json.worktreePath` is undefined and `json.relativeWorktreePath` is defined and does not start with "/" or contain ".foreman/worktrees" |
| `PIPELINE_REPORT.md` accurately lists builtin PR phases | ✅ PASS | PIPELINE_REPORT.md shows `create-pr \| builtin \| pass`, `pr-wait \| builtin \| pass`, `prepare-pr-review \| builtin \| pass` |
| QA/report trace artifact expectations match actual report paths | ✅ PASS | `smoke/qa.md` now writes to `docs/reports/{{seedId}}/QA_REPORT.md`; `smoke.yaml` artifact path updated to `docs/reports/{{seedId}}/QA_REPORT.md` |
| Tests cover at least one path sanitization case | ✅ PASS | "sanitizes absolute worktreePath in committed JSON trace" test added |
| Tests cover at least one builtin phase/report listing case | ✅ PASS | "records builtin phase type with workflow metadata" and "finalizePhaseRecord carries builtin phase type and workflow info through to result" tests added |
| `npx tsc --noEmit` passes | ✅ PASS | Clean compilation |

## Issues Found

- None

## Files Modified (inspected by QA)

| File | Change |
|------|--------|
| `src/orchestrator/pi-observability-types.ts` | Added `relativeWorktreePath?: string` field with documentation comment |
| `src/orchestrator/pi-observability-writer.ts` | Added `sanitizeTrace()` function that replaces `worktreePath` with `relativeWorktreePath` before JSON serialization; applied in `writePhaseTrace()` |
| `src/orchestrator/pipeline-executor.ts` | Added `workflowName: workflowConfig.name` and `workflowPath: workflowConfig.sourcePath` to builtin phase records (line ~1194) |
| `src/orchestrator/__tests__/pi-observability-extension.test.ts` | Added test for path sanitization in committed JSON trace |
| `src/orchestrator/__tests__/activity-logger.test.ts` | Added 2 tests for builtin phase type and workflow metadata |
| `src/defaults/prompts/smoke/qa.md` | Fixed QA report path from `QA_REPORT.md` to `docs/reports/{{seedId}}/QA_REPORT.md`; added step to create directory |
| `src/defaults/workflows/smoke.yaml` | Updated qa phase artifact from `QA_REPORT.md` to `docs/reports/{{seedId}}/QA_REPORT.md` |

## Implementation Quality

The implementation follows the explorer report's implementation plan correctly:

1. **Path sanitization** — `sanitizeTrace()` creates a copy of the trace, computes `relativeWorktreePath = path.relative(".", trace.worktreePath) || "."`, and deletes `worktreePath` from the copy before serialization. Original trace object is not mutated. ✅

2. **Builtin phase records** — `pipeline-executor.ts` now includes `workflowName` and `workflowPath` in builtin phase records, addressing the missing metadata for builtin phases. ✅

3. **smoke/qa.md path fix** — Changed from `QA_REPORT.md` to `docs/reports/{{seedId}}/QA_REPORT.md` and added directory creation step. ✅

4. **Tests** — All new tests pass and directly verify the acceptance criteria. ✅

## Recommendations for Future Improvements (not blocking)

- Consider adding an integration test that writes a trace and then reads it back to verify `relativeWorktreePath` is stable and usable
- Consider adding a test for the markdown trace rendering to verify it doesn't expose absolute paths either (currently the markdown rendering uses the original `trace.worktreePath` for internal operations but shows `relativeJsonPath` in the output)
