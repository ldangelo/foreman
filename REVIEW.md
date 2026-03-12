# Code Review: Unify agent status display between status and run commands

## Verdict: PASS

## Summary

The implementation is minimal, correct, and achieves the stated goal. The 40-line custom agent-rendering block in `status.ts` was replaced with a 3-line loop delegating to the already-tested `renderAgentCard()` from `watch-ui.ts`. The approach correctly calls `store.getRunProgress(run.id)` to obtain parsed progress data (avoiding re-parsing the JSON stored on `run.progress`) and passes it directly to the shared renderer. Nine new tests were added to `watch-ui.test.ts` verifying non-interactive rendering behaviour. TypeScript compiles without errors and no pre-existing tests were broken by this change.

## Issues

- **[NOTE]** `src/cli/watch-ui.ts:57-120` — `renderAgentCard` does not display `currentPhase` from `RunProgress`. The previous `status.ts` implementation rendered pipeline phase with colour-coded labels (`Phase: explorer  last: Bash`). The new code silently drops this feature; only the last tool call appears in the `Tools` line. The developer report acknowledges this in "Known Limitations" and the EXPLORER_REPORT listed it as a potential pitfall. For single-agent runs this is a no-op, but for multi-phase pipeline runs (explorer → developer → qa → reviewer → finalize) the phase progress is no longer visible anywhere in `foreman status`. This is a functional regression worth addressing in a follow-up, but it is pre-existing in `watch-ui.ts` (not introduced by this PR), so it is noted rather than blocking.

- **[NOTE]** `src/cli/__tests__/status-display.test.ts` — The file re-implements and tests `parsePipelinePhase()` and `formatAgentActivity()`, logic that was removed from `status.ts` by this change. These tests now verify dead code (the functions they mirror no longer exist in production). They are harmless but will mislead future readers. Cleaning them up in a follow-up would improve clarity.

- **[NOTE]** `src/cli/commands/status.ts:100` — An extra blank `console.log()` is emitted after each agent card. When only one agent is active, this creates a dangling blank line before the closing of the "Active Agents" section. The `renderWatchDisplay` function separates cards with empty strings internally when used in the run-command context, but the status command adds another one on top. This is a minor cosmetic issue.

## Positive Notes

- The diff is impressively small: the net change in `status.ts` is a 3-line replacement of 40 lines of custom rendering logic, with a single added import. This is exactly the right scope for a "unify display" task.
- Using `store.getRunProgress(run.id)` rather than `JSON.parse(run.progress)` is the correct approach — it reuses the existing store method which handles the null-check and JSON parsing safely.
- The old code re-implemented elapsed time, status badges, tool formatting, and file display with inconsistent formatting. The new code inherits all future improvements to `renderAgentCard` for free.
- The 9 new tests are well-targeted: they document the specific improvements gained (uppercase status, status icons, detailed elapsed time, short model name) rather than just exercising code paths.
- No changes were made to `watch-ui.ts` itself — the function was already general-purpose, so the implementation required zero modifications to the shared module.
- TypeScript compilation is clean and the `RunProgress` import that became unused in `status.ts` was properly removed.
