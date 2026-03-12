# QA Report: Interactive expandable agent status with summary/detail toggle

## Verdict: PASS

## Test Results
- Test suite (watch-ui): 73 passed, 0 failed
- New tests added: 24 (by Developer; verified passing)
- Full suite: 254 passed, 9 failed (all 9 failures are **pre-existing environment issues** — missing `tsx` binary in the worktree's `node_modules/.bin/tsx`; the same tests pass on the main repo)

## Issues Found
None related to this task. Pre-existing failures in orchestrator tests:
- `src/orchestrator/__tests__/agent-worker.test.ts` — 2 failures: tsx binary not found in worktree
- `src/orchestrator/__tests__/detached-spawn.test.ts` — 2 failures + 2 unhandled errors: tsx binary not found
- `src/orchestrator/__tests__/worker-spawn.test.ts` — 1 failure: tsx binary existence check fails

These failures exist because the f18c worktree's `node_modules` is missing `tsx` (the symlink present in the main repo at `node_modules/.bin/tsx -> ../tsx/dist/cli.mjs` is absent here). Not caused by the f18c changes.

## Test Coverage Verified
All new functionality has test coverage:

| Feature | Tests | Result |
|---------|-------|--------|
| `renderAgentCardSummary` — seed_id, status, model, initializing, cost, last tool, phase, turns/tools, ▶ indicator, index | 13 tests | ✅ All pass |
| `renderAgentCard` with `isExpanded=false` — delegates to summary, indicators, single-line, backward compat | 5 tests | ✅ All pass |
| `renderWatchDisplay` with `expandedRunIds` — collapsed/expanded per-run, toggle hint, mixed state, default all-expanded, index numbers | 6 tests | ✅ All pass |

## Implementation Notes
- `renderAgentCard` backward compatibility is preserved: `isExpanded` defaults to `true`, so all existing callers work unchanged
- `renderWatchDisplay` backward compatibility is preserved: `expandedRunIds` defaults to `undefined` which shows all agents expanded
- Raw stdin keyboard handling in `watchRunsInk` is properly guarded by `process.stdin.isTTY` with try/catch
- Cleanup in `finally` block correctly removes the `data` listener, resets raw mode, and pauses stdin
- Index numbers only displayed for multi-agent runs (`state.runs.length > 1`)
- Summary view is correctly single-line (tests confirm `lines.length === 1` for collapsed cards)

## Files Modified
- None (all changes were made by the Developer; tests verified as-is)
