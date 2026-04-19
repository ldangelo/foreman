# QA Report: Refinery Agent

## Verdict: PASS

## Test Results

- **Targeted command(s) run:**
  - `npx vitest run src/orchestrator/__tests__/refinery-agent.test.ts 2>&1`
  - `npx tsc --noEmit 2>&1` (type check)

- **Refinery agent tests:** 11 passed (1 test file)
  ```
  Test Files  1 passed (1)
       Tests  11 passed (11)
    Duration  438ms
  ```

- **Full suite command:** `npx vitest run src/orchestrator/ --reporter=dot 2>&1`
  ```
  Test Files  1 failed | 103 passed (104)
       Tests  1 failed | 1785 passed (1786)
    Duration  9.91s
  ```

- **Pre-existing failure check:** `git stash && npx vitest run src/orchestrator/__tests__/auto-merge.test.ts` confirmed the failing test (`auto-merge.test.ts:613`) also fails without my changes — it is a **pre-existing failure** unrelated to the Refinery Agent implementation. Error message mismatch: expected `"error": "git rebase failed"` but got `"error": "Merge failed (PR also failed): vcs.push is not a function. Original: git rebase failed"`.

- **TypeScript compilation:** Clean — no type errors.

## Issues Found

- **Pre-existing test failure** (not caused by Refinery Agent):
  - `src/orchestrator/__tests__/auto-merge.test.ts:613` — One test in `auto-merge.test.ts` fails with an error message assertion mismatch. The error message changed between test runs (likely due to different environment conditions or mocking state). This is not caused by the Refinery Agent changes — it fails on `HEAD` as well as on the branch.
  - The test expects `{ error: "git rebase failed" }` but receives `{ error: "Merge failed (PR also failed): vcs.push is not a function. Original: git rebase failed" }`, indicating the `auto-merge.ts` code is wrapping the original error with additional context when a PR merge also fails.

## Files Modified (Inspected)

| File | Purpose |
|------|---------|
| `src/orchestrator/refinery-agent.ts` | Main agent daemon with Pi SDK integration |
| `src/orchestrator/refinery-agent-cli.ts` | CLI wrapper for `foreman refine` |
| `src/orchestrator/prompts/refinery-agent.md` | System prompt with fix patterns |
| `src/orchestrator/__tests__/refinery-agent.test.ts` | 11 unit tests for the agent |
| `src/defaults/prompts/default/qa.md` | Minor qa prompt clarification |
| `docs/TRD/TRD-2026-010-refinery-agent.md` | TRD document |
| `docs/reports/foreman-dba6d/DEVELOPER_REPORT.md` | Developer report |

## Implementation Verification

The implementation covers all TRD acceptance criteria:

- **AC-1** (Queue entry processing): `RefineryAgent.processOnce()` polls pending entries, uses `dequeue()` for atomic lock acquisition, and skips locked entries.
- **AC-2** (Fix iterations): `runAgent()` runs up to `maxFixIterations` fix attempts with build/test verification between each.
- **AC-3** (Escalation): Returns `action: "escalated"` when budget is exhausted or unrecoverable errors occur.
- **AC-4** (Action logging): `logAction()` appends timestamped entries to `AGENT_LOG.md`.
- **AC-5** (Queue ordering): Processes entries in FIFO order (oldest first via `mergeQueue.list('pending')`).
- **AC-6** (Branch validation): `checkCiStatus()` and PR state reading ensure only viable PRs are processed.

## Test Recommendations

1. **Edge case — worktree does not exist**: The `runAgent()` method falls back to a default path that may not exist. Add a test that verifies the agent handles a missing worktree gracefully (escalates with a clear error message rather than hanging or crashing).

2. **Edge case — CI never passes**: Add a test for the scenario where `checkCiStatus()` always returns `false` (e.g., GitHub API timeout). The agent should reset the entry for retry rather than escalating immediately.

3. **Edge case — mail client not initialized**: The agent has a `mailInitialized` flag for lazy initialization. Add a test that verifies escalation mail works even when the mail client was not pre-initialized.

4. **Fix iteration feedback loop**: The Developer Report notes that `feedback` is set in the fix loop but the task prompt is not updated with it for the next attempt. This is a known limitation — consider adding a test that verifies the agent receives previous error context when retrying.

## Notes

- The `RefineryAgent` uses the `VcsBackend` interface correctly (for `detectDefaultBranch()`) but merge is done via `gh pr merge` rather than `vcsBackend.merge()`, matching the system prompt instructions.
- The agent respects the `FOREMAN_USE_REFINERY_AGENT` feature flag via the CLI.
- New tests added: 3 (`refinery-agent.test.ts` grew from 8 to 11 tests).