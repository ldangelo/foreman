# Developer Report: Fix task status after PR creation and merge

## Root Cause

The finalize-bug.md prompt unconditionally wrote SKIPPED for Target Integration without checking if the target branch actually changed after QA. This violated the finalize integration contract:

- When the target branch changed after QA, the prompt should run integration and write SUCCESS
- When the target branch didn't change, the prompt should write SKIPPED
- The bug workflow was missing the target drift detection logic that the regular finalize.md prompt had

## Fix

Updated `src/defaults/prompts/default/finalize-bug.md` to:

1. **Added Step 1: Detect target drift and integrate if needed**
   - Compare `{{qaValidatedTargetRef}}` with `{{currentTargetRef}}`
   - If refs differ (target changed), run `{{vcsIntegrateTargetCommand}}`
   - If refs match (target unchanged), skip integration

2. **Updated Step 2: Write FINALIZE_VALIDATION.md with appropriate status**
   - SUCCESS when integration was run (target changed)
   - SKIPPED when integration was skipped (target unchanged)

3. **Renumbered subsequent steps** (was 1-6, now 1-7 with new Step 1)

4. **Updated Rules section** to mention integration requirement when drift detected

## Files Changed

- `src/defaults/prompts/default/finalize-bug.md` — Added target drift detection and conditional integration logic

## Tests Added/Modified

No new tests were required for this specific fix since the existing test `pipeline-verdict-retry.test.ts` already covers the finalize validation contract:
- "fails finalize when target drifted but integration was marked skipped"

The existing tests verify the pipeline executor validation logic correctly catches when integration is skipped but target changed.

## Verification

```bash
# All tests pass
npx vitest run src/orchestrator/__tests__/  # 1728 tests passed

# TypeScript compiles cleanly
npx tsc --noEmit  # No errors
```

## Decisions & Trade-offs

- The fix aligns the bug workflow finalize prompt with the expected validation behavior
- The regular finalize.md prompt already had proper target drift detection via `shouldRunFinalizeValidation`
- The bug workflow was the only one missing this logic, causing the specific violation reported

## Known Limitations

- None identified - the fix directly addresses the feedback about the integration contract violation