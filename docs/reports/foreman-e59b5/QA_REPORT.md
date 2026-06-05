# QA Report: Harden trace and pipeline report artifacts

## Verdict: PASS

## Test Results
- Targeted command(s) run: `npx vitest run -c vitest.unit.config.ts --reporter=verbose src/orchestrator/__tests__/pi-observability-extension.test.ts`
- TypeScript compilation: `npx tsc --noEmit` — no errors
- Full suite NOT run (narrow task; targeted verification sufficient)
- Test suite (pi-observability-extension.test.ts): 6 passed, 0 failed
- Raw summary: `Test Files 1 passed (1) | Tests 6 passed (6)`
- New tests added: 2 (path sanitization test + builtin PR phase report test)

## Issues Found
- None. All acceptance criteria verified.

## Implementation Review

### Changes Verified

**1. Path Sanitization (`src/orchestrator/pi-observability-writer.ts`)**
- Added `sanitizePhaseTrace()` function that replaces `worktreePath` with `<worktree>` placeholder in all string fields
- Applied before writing both JSON and Markdown trace artifacts
- Correctly handles nested fields: `rawPrompt`, `resolvedCommand`, `systemPromptPreview`, `finalMessage`, `error`, `toolCalls[].argsPreview`, `toolCalls[].resultPreview`
- Test passes: creates trace with real host-specific path `/Users/ldangelo/.foreman/worktrees/...`, verifies path is absent from written files and `<worktree>` appears

**2. Builtin PR Phase Reporting (`src/orchestrator/__tests__/pi-observability-extension.test.ts`)**
- New test "pipeline report includes builtin PR workflow phases" creates phase records for `create-pr`, `pr-wait`, `prepare-pr-review`, `pr-review` (all `phaseType: "builtin"`), writes pipeline report, and verifies all 4 phases appear with `builtin` type label
- Test passes

**3. `pr-review` Phase Git Blocking Fix (`src/orchestrator/pi-observability-extension.ts`)**
- Changed `getForbiddenVcsAction` to return `undefined` only for `finalize` phase (removed `pr-review` from allowed list)
- `pr-review` prompt was also updated to be read-only (no commits/pushes) in `pr-review.md`
- This is a semantic correction — `pr-review` was incorrectly treated as allowing git mutations; now correctly restricted to `finalize`
- Updated test assertion names and expectations to match: now expects `git commit` and `git push` to be blocked during `pr-review`

**4. QA Prompt Pipe Pattern (`src/defaults/prompts/default/qa.md`)**
- No `| tail` pipe patterns found in the current qa.md template
- Template uses `2>&1` for stderr redirection, preserving exit codes

## Acceptance Criteria Status

| Criterion | Status |
|-----------|--------|
| No absolute worktree paths in committed `*_TRACE.json/md` | ✅ `sanitizePhaseTrace()` replaces all occurrences with `<worktree>` |
| Pipeline report includes builtin PR phases | ✅ New test verifies `create-pr`, `pr-wait`, `prepare-pr-review`, `pr-review` appear with `builtin` type |
| Artifact paths align with actual `docs/reports/<seed>/` layout | ✅ `getPhaseTracePaths()` correctly places artifacts under `docs/reports/<seedId>/` |
| Avoid pipe patterns that mask exit codes | ✅ No `| tail` patterns in qa.md; existing `2>&1` preserves exit codes |
| `npx tsc --noEmit` passes | ✅ No TypeScript errors |
| Tests cover sanitization and builtin phase listing | ✅ 2 new tests added and passing |

## Files Modified
- `src/orchestrator/pi-observability-writer.ts` — added `sanitizePhaseTrace()` and applied before write
- `src/orchestrator/pi-observability-extension.ts` — fixed `getForbiddenVcsAction` to exclude `pr-review` from allowed git mutations
- `src/orchestrator/__tests__/pi-observability-extension.test.ts` — added 2 new tests
- `src/defaults/prompts/default/pr-review.md` — updated to read-only (no file edits, commits, or pushes)

## Additional Test Recommendations
- Consider adding a test for `sanitizePhaseTrace` with multiple occurrences of `worktreePath` in a single string field to verify all are replaced
- Consider adding a test for empty/null `worktreePath` edge case in `sanitizePhaseTrace`
- Consider verifying that the `sanitizePhaseTrace` function does not mutate the original trace object (pure function)