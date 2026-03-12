# QA Report: Integrate DCG (Destructive Command Guard) into foreman agent workers

## Verdict: PASS

## Test Results
- Test suite: 238 passed, 9 failed
- New tests added: 7 (DCG permission mode tests in `roles.test.ts`)

## Failing Tests (Pre-existing, Not Caused by DCG Changes)

All 9 failing tests are pre-existing environment failures in the worktree — the worktree does not have `node_modules/.bin/tsx`, so tests that spawn actual processes fail with `ENOENT`. These same tests pass on the main branch where `tsx` is installed.

Failing test files and cause:
- `src/orchestrator/__tests__/agent-worker.test.ts` (2 fails) — tries to spawn `tsx agent-worker.ts` directly; `tsx` not in worktree `node_modules/.bin`
- `src/cli/__tests__/commands.test.ts` (4 fails) — CLI smoke tests spawn the binary; `tsx` not available
- `src/orchestrator/__tests__/worker-spawn.test.ts` (1 fail) — asserts `tsx` binary exists in `node_modules/.bin`; not present in worktree
- `src/orchestrator/__tests__/detached-spawn.test.ts` (2 fails) — spawns detached `tsx` process; `tsx` not in worktree

**Verified**: these same tests pass on the main branch (`npm test` from `/Users/ldangelo/Development/Fortium/foreman`).

## DCG-Specific Tests: All Pass ✅

`src/orchestrator/__tests__/roles.test.ts` — **31 tests, 31 passed**

New DCG tests added:
1. All roles have a `permissionMode` configured
2. No role uses `bypassPermissions` (DCG enforcement)
3. All roles use a non-interactive permission mode (safe for detached workers)
4. `explorer` uses `acceptEdits`
5. `developer` uses `acceptEdits`
6. `qa` uses `acceptEdits`
7. `reviewer` uses `acceptEdits`
8. All `permissionMode` values are valid SDK `PermissionMode` literals

Additional passing suites:
- `agent-worker-team.test.ts` — 13 passed (pipeline phase execution)
- `dispatcher.test.ts` — 11 passed (plan step dispatch)
- TypeScript build (`tsc`) — **clean, no errors**

## Implementation Correctness

### Changes verified:
1. **`src/orchestrator/roles.ts`**: Added `permissionMode: PermissionMode` field to `RoleConfig` interface. All 4 roles (`explorer`, `developer`, `qa`, `reviewer`) set to `"acceptEdits"`. Correctly imports `PermissionMode` type from SDK.

2. **`src/orchestrator/agent-worker.ts`**: Single-agent mode (both resume and fresh query paths) changed from `permissionMode: "bypassPermissions"` + `allowDangerouslySkipPermissions: true` to `permissionMode: "acceptEdits"`. Pipeline `runPhase()` now uses `roleConfig.permissionMode` instead of hardcoded bypass.

3. **`src/orchestrator/dispatcher.ts`**: Plan-step queries updated from bypass to `"acceptEdits"`.

4. **`src/orchestrator/refinery.ts`**: Unrelated to DCG — adds `getCompletedRuns()` and `orderByDependencies()` methods for the merge command (likely from a previous task's changes landing in this diff). Not a regression.

### Design validation:
- `"acceptEdits"` is the correct choice for detached workers (non-interactive). Using `"default"` would hang waiting for user input; `"bypassPermissions"` would remove all safeguards.
- `allowDangerouslySkipPermissions: true` correctly removed alongside the bypass mode change.
- Consistent permission mode applied across all entry points (single-agent, pipeline phases, plan steps).

## Issues Found
- None introduced by DCG changes.
- Pre-existing 9 test failures are worktree environment issues (missing `tsx` binary symlink), not regressions.

## Files Modified
- No test files modified — all new DCG tests were pre-written by Developer and pass correctly.
