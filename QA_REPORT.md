# QA Report: Unify agent status display between status and run commands

## Verdict: PASS

## Test Results
- **PR-relevant test suite: 75 passed, 0 failed**
  - `src/cli/__tests__/status-display.test.ts`: 17/17 passed
  - `src/cli/__tests__/watch-ui.test.ts`: 58/58 passed
- **Full worktree suite: 233 passed, 9 failed** (9 failures are pre-existing environment issues, unrelated to PR — see below)
- **New tests added: 17** (status-display.test.ts) + **15** new tests in watch-ui.test.ts (non-interactive mode coverage)

## Issues Found

### Pre-existing environment failures (NOT caused by this PR)
The following 9 test failures exist because the worktree's `node_modules/.bin/tsx` symlink is absent (the worktree does not have a full `node_modules` installation — tsx binary is missing). These tests pass on the main branch (21 files, 271 tests all green).

- `src/orchestrator/__tests__/agent-worker.test.ts`:
  - `exits with error when no config file argument given` — expected exit code 1, got null (can't spawn tsx)
  - `reads and deletes the config file on startup` — expected config file deleted, tsx spawn fails
- `src/orchestrator/__tests__/detached-spawn.test.ts`:
  - `detached child process writes a file after parent exits` — ENOENT spawning tsx
  - `detached child continues after SIGINT to process group` — ENOENT spawning tsx
- `src/orchestrator/__tests__/worker-spawn.test.ts`:
  - `tsx binary exists in node_modules` — tsx symlink missing in worktree
- `src/cli/__tests__/commands.test.ts`:
  - `--version prints version number` — CLI smoke test uses tsx
  - `decompose with nonexistent file shows error` — CLI smoke test uses tsx
  - `plan --dry-run shows pipeline steps` — CLI smoke test uses tsx

None of these files were modified by this PR. They fail identically whether or not the PR changes are present.

### No regressions introduced
- All 75 tests in the two directly affected test files pass
- `renderAgentCard` correctly shows `Phase` row for all 5 pipeline roles (explorer/developer/qa/reviewer/finalize), colour-coded
- `renderAgentCard` correctly omits Phase row when `currentPhase` is undefined
- `status.ts` correctly separates agent cards with blank lines between (not after the last one)
- `renderWatchDisplay` non-interactive mode (`showDetachHint=false`) shows status icons, uppercase status, detailed elapsed time, tool breakdowns, file lists, and log hints — all consistent with `foreman run` output

## Files Modified
- None — all 75 tests pass without any source or test changes needed.
  The developer's implementation is correct and complete.
