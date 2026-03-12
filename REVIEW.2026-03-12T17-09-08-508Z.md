# Code Review: Detect and fix seed/agent state mismatches in foreman reset

## Verdict: PASS

## Summary

The implementation correctly addresses the seed/run state mismatch problem in `foreman reset`. A new `detectAndFixMismatches` function scans terminal runs (completed, merged, pr-created, conflict, test-failed) and reconciles seed statuses that have drifted from their expected values. The function is well-structured: it deduplicates by seed_id using the most-recent-run heuristic, skips seeds already being handled by the main reset loop, respects dry-run mode, and handles edge cases (seed-not-found, API errors) gracefully. Test coverage is thorough with 22 unit tests covering all mapped statuses and key behavioral branches. TypeScript compiles cleanly. One minor duplicate-display issue exists in the output but does not affect correctness or safety.

## Issues

- **[NOTE]** `src/cli/commands/reset.ts:285-289` — When a `seeds.show` call fails with an unexpected error and there happen to also be real mismatches in the same run of `detectAndFixMismatches`, the error from `mismatchResult.errors` is printed twice: once inline in the mismatch block (lines 285-289) and again in the combined `allErrors` summary section (lines 310-316). In practice this is cosmetic since the inline block only triggers when `mismatches.length > 0`, but it is technically a duplicate output path. Removing the inline error display block (lines 285-289) and relying solely on the `allErrors` summary would simplify the logic.

## Positive Notes

- `detectAndFixMismatches` is cleanly extracted as a pure, testable function with a well-typed return value (`MismatchResult`), making it easy to unit test in isolation.
- The deduplication strategy (most-recently-created run wins per seed) is correct: it avoids false "mismatch" signals from older runs for seeds that have been redispatched.
- Skipping seeds in `resetSeedIds` avoids double-processing and potential conflicts between the main reset loop and the mismatch fixer.
- The `mapRunStatusToSeedStatus` function covers all 9 values of `Run["status"]` and includes a safe `default: return "open"` fallback.
- `store.close()` is called correctly at the end of the happy path; the early-return removal ensures mismatch detection always runs even when there are no active runs to reset.
- The dry-run summary correctly reports "Would fix N mismatch(es)" without performing any writes, and the mismatch display always shows the `(would fix)` label in dry-run mode.
- 22 new unit tests cover all run status mappings and all behavioral branches of `detectAndFixMismatches`, including error injection for both `seeds.show` and `seeds.update`.
