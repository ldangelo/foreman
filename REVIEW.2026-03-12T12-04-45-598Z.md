# Code Review: Ink TUI causes iTerm hanging/freezing

## Verdict: PASS

## Summary

The implementation correctly addresses the root cause of iTerm hanging by replacing the React/Ink-based TUI with a simple chalk-based polling display. The double-polling race condition (React `setInterval` hook running concurrently with a manual while loop) is eliminated entirely. The new code is architecturally simpler, easier to test, and matches the patterns already established in `monitor.ts` and `status.ts`. All 49 new tests pass and cover all exported functions comprehensively. No bugs, logic errors, or missing requirements were found.

## Issues

- **[NOTE]** `src/cli/watch-ui.ts:219` — Function is still named `watchRunsInk` despite no longer using Ink. Since it is the exported public API consumed by `run.ts`, renaming would be a follow-up refactor rather than a blocker, but the name is now misleading.

- **[NOTE]** `src/cli/watch-ui.ts:18-20` — `shortModel` only strips the hardcoded `-20251001` date suffix. Future model releases with different date suffixes (e.g. `-20250620`) would display the raw suffix in the TUI. Not a bug today, but fragile as a long-term display concern.

- **[NOTE]** `src/cli/watch-ui.ts:239` — The `\x1B[2J\x1B[H` clear-screen sequence is issued on every poll cycle. On very slow or remote terminals this could produce a brief flash between clear and re-render. The atomic single `process.stdout.write` call minimises this, but an alternative (`\x1B[H` cursor-home without clearing) would produce even less flicker if any scrollback bleeding becomes an issue in practice.

## Positive Notes

- **Double-poll eliminated**: The architectural root cause (React `useEffect` setInterval + independent while-loop polling) is gone. A single while-loop with a `try/finally` cleanup is clean and correct.
- **Single atomic write**: `process.stdout.write("\x1B[2J\x1B[H" + display + "\n")` batches the clear and the full frame into one write, which is the correct approach to avoid partial-render flicker.
- **Robust SIGINT handling**: The `detached` guard prevents double-fire; `process.removeListener` in the `finally` block ensures the handler is cleaned up on all exit paths (normal completion, SIGINT detach, and thrown exceptions).
- **`allDone` edge cases handled**: Empty run lists (`runs.length === 0`) are checked alongside `allDone`, so the watch loop exits safely when no run IDs resolve.
- **Test coverage**: 49 tests covering all exported functions (`elapsed`, `shortModel`, `shortPath`, `renderAgentCard`, `poll`, `renderWatchDisplay`). Testing is now straightforward because pure functions returning strings are far easier to assert against than Ink render trees.
- **Preserves parity**: All information from the original Ink display (status icons, colours, tool breakdown bar chart, files changed list, cost summary, stuck/resume hint) is preserved in the chalk implementation.
- **Matches codebase conventions**: Chalk-only output with no terminal control beyond clear-screen matches the patterns in `monitor.ts` and `status.ts`.
