# QA Report: Ink TUI causes iTerm hanging/freezing

## Verdict: PASS

## Test Results
- Test suite: 216 passed, 9 failed (failures are pre-existing worktree infrastructure issues unrelated to this change)
- New tests added: 49 (src/cli/__tests__/watch-ui.test.ts)
- New watch-ui tests: 49 passed, 0 failed

## Summary of Changes

The developer replaced the Ink/React-based TUI (`watch-ui.ts`) with a chalk-based polling display. Key changes:

- Removed React, Ink, and ink-spinner imports entirely
- Rewrote `watchRunsInk()` as a simple while-loop that clears the screen and re-renders with chalk on each poll cycle (every 3 seconds)
- Eliminated the double-polling bug (React hook setInterval + manual while loop both running concurrently)
- Extracted helper functions (`elapsed`, `shortModel`, `shortPath`) as exports so they can be tested
- Added `renderAgentCard()` and `renderWatchDisplay()` as pure functions returning strings
- Single `SIGINT` handler with proper `detached` guard to prevent double-fire
- `process.removeListener` in a `finally` block ensures cleanup on all exit paths

## Pre-existing Test Failures (Unrelated to Change)

All 9 failures are due to `tsx` binary not being available in the worktree's `node_modules/.bin/` directory. This affects tests that spawn the CLI or agent worker as a child process via `tsx`:

- `src/cli/__tests__/commands.test.ts` — 4 failures (`ENOENT` on tsx spawn)
- `src/orchestrator/__tests__/agent-worker.test.ts` — 2 failures (`ENOENT` on tsx spawn)
- `src/orchestrator/__tests__/detached-spawn.test.ts` — 2 failures (`ENOENT` on tsx spawn)
- `src/orchestrator/__tests__/worker-spawn.test.ts` — 1 failure (tsx binary existence check)

These same tests pass on the main branch where `tsx` is properly installed. The worktree's `node_modules` directory contains only `.vite` cache folders; full packages are resolved from the main repo. This is not caused by the developer's changes.

## New Tests Coverage (watch-ui.test.ts)

The 49 new tests provide comprehensive coverage across all exported functions:

| Function | Tests |
|---|---|
| `elapsed()` | 4 tests — null, seconds, minutes, hours |
| `shortModel()` | 3 tests — prefix stripping, suffix stripping, no prefix |
| `shortPath()` | 3 tests — absolute path, relative path, no slash |
| `renderAgentCard()` | 18 tests — all statuses, progress display, tool breakdown, files, log hint |
| `poll()` | 10 tests — empty store, aggregation, allDone logic, counters, null progress |
| `renderWatchDisplay()` | 11 tests — empty state, header, Ctrl+C hint, summary bar, completion banner, multiple agents |

## Issues Found

No issues found with the new implementation. The refactor correctly:
1. Eliminates the double-polling race condition
2. Removes all Ink/React dependencies that caused iTerm hangs
3. Preserves all display information (status icons, colors, tool breakdown, files changed, cost summary)
4. Maintains backward-compatible SIGINT handling (detach behavior preserved)
5. Adds proper cleanup via `process.removeListener` in a `finally` block

## Files Modified

- `/Users/ldangelo/Development/Fortium/foreman/.foreman-worktrees/foreman-34e/src/cli/__tests__/watch-ui.test.ts` — New test file created by developer (49 tests, all passing)
- No source files were modified by QA
