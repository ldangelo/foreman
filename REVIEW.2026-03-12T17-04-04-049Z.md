# Code Review: Agent observability: dashboard command with live TUI

## Verdict: FAIL

## Summary

The implementation is well-structured, follows existing codebase patterns closely, and delivers a functional TUI dashboard with good test coverage. However, there are two fixable bugs that must be addressed before shipping. The most significant is a misuse of `getProjectByPath` instead of the available `getProject(id)` method in `pollDashboard`, which causes the `--project <id>` filter to silently produce an empty dashboard when run from any directory other than the project's registered path. A secondary resource-leak exists in `--no-watch` mode if `pollDashboard` throws. Both are straightforward one-line fixes.

## Issues

- **[WARNING]** `src/cli/commands/dashboard.ts:207-209` — `pollDashboard` uses `store.getProjectByPath(resolve("."))` when a `projectId` is given, then filters by `.id === projectId`. The store already exposes `store.getProject(id: string): Project | null` (store.ts:187). The current code works only when the user's CWD matches the project's registered path **and** the ID matches — i.e., it silently returns an empty dashboard for any cross-directory invocation of `foreman dashboard --project <id>`. Fix: replace the expression with `store.getProject(projectId)` and filter out `null`.

- **[WARNING]** `src/cli/commands/dashboard.ts:263-267` — In `--no-watch` (single-shot) mode, `store.close()` is only called in the happy path. If `pollDashboard()` or `renderDashboard()` throws, the store is never closed (SQLite file handle / WAL lock leaked). Wrap the snapshot block in try/finally to guarantee `store.close()`.

- **[NOTE]** `src/cli/__tests__/dashboard.test.ts` — `pollDashboard` test suite has no test for the `projectId` filter path (the only test that would have caught the bug above). Adding a test case that provides a `projectId` and verifies the correct project is returned would be valuable.

- **[NOTE]** `src/cli/commands/dashboard.ts:297` — `store.close()` in the `finally` block is unreachable in practice: `onSigint` calls `process.exit(0)` before the `finally` can run, and there is no other way out of the `while (!detached)` loop. This is harmless (acts as belt-and-suspenders), but could be confusing to future maintainers. A comment explaining the intent would help.

## Positive Notes

- Pattern consistency is excellent: chalk coloring, SIGINT teardown, cursor hide/restore, `--no-watch` toggle, and `renderAgentCard` reuse all follow the existing `watch-ui.ts`/`status.ts` conventions faithfully.
- `renderEventLine` handles JSON-parse failure gracefully with a catch-and-fallback to raw string slice — good defensive coding.
- Interval and events-count bounds (`Math.max(1000, ...)`, `Math.max(1, ...)`) protect against obviously bad user input.
- 30 tests cover all four exported functions with realistic fixtures; the mock-store pattern mirrors the rest of the test suite.
- TypeScript compiles cleanly with no errors.
- `store.getProjectByPath` is imported and already tested, so the correct fix (`store.getProject(id)`) is a drop-in replacement — no API changes needed.
