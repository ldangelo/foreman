# Developer Report: Detect and fix seed/agent state mismatches in foreman reset

## Approach

The core implementation was already in place from the previous development iteration. This pass addressed reviewer feedback: a duplicate error output path in `src/cli/commands/reset.ts`.

**The issue:** When `detectAndFixMismatches` encounters an unexpected error calling `seeds.show`, it records the error in `mismatchResult.errors`. Inside the mismatch display block (which only runs when `mismatches.length > 0`), there was an inline error display loop that re-printed `mismatchResult.errors`. Since `mismatchResult.errors` is also included in the combined `allErrors` summary at the end of the command, any run where mismatches AND show-errors coexisted would display the errors twice.

**The fix:** Removed the inline error display block (old lines 285-289) inside the mismatch section. Errors from `mismatchResult.errors` are now only shown in the unified `allErrors` summary section — consistent with how all other errors are handled.

## Files Changed

- `src/cli/commands/reset.ts` — Removed the inline `mismatchResult.errors` display block that was nested inside the `if (mismatchResult.mismatches.length > 0)` block. This eliminates the duplicate error output path while preserving all error reporting via the consolidated `allErrors` summary at the end of the command.

## Tests Added/Modified

No test changes were needed. The existing test suite in `src/cli/__tests__/reset-mismatch.test.ts` tests `detectAndFixMismatches` at the function level (not CLI output level), so it was unaffected by the display logic change. All 13 existing tests continue to cover:

- `mapRunStatusToSeedStatus` mappings for all run statuses
- Empty/no-terminal-runs case
- Mismatch detection (completed/merged/conflict runs)
- Fix application via `seeds.update`
- Dry-run mode (no updates)
- Skip already-reset seeds
- No mismatch when status already matches
- Silent skip of non-existent seeds
- Error recording for unexpected `seeds.show` failures
- Error recording for `seeds.update` failures
- Deduplication by seed_id (most recent run wins)
- Multiple seeds with different mismatch states

## Decisions & Trade-offs

- **Simplification over in-place display:** The reviewer correctly noted that showing errors both inline (in the mismatch block) and in the summary was redundant. Relying solely on the summary is consistent with how the main reset loop handles errors (they are collected in `errors[]` and only shown in the summary, not re-printed inline).
- **No behavior change:** The `detectAndFixMismatches` function itself is unchanged. Errors are still captured and returned; only the duplicate display path in the CLI command was removed.

## Known Limitations

- The mismatch detection currently only runs during `foreman reset`. Preventive state updates in the dispatcher/agent-worker (so mismatches don't accumulate in the first place) are out of scope for this task.
