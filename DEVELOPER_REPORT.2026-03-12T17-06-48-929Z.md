# Developer Report: Detect and fix seed/agent state mismatches in foreman reset

## Approach

The foreman system maintains two separate state machines: seed state (managed by the `sd` CLI) and run state (managed by foreman's SQLite store). These can drift out of sync when a run completes but the seed's status isn't updated to match.

The implementation adds mismatch detection and fixing directly into the `foreman reset` command:

1. **Detection**: After the main reset loop (which handles failed/stuck/pending/running runs), the command now checks all _terminal_ runs (`completed`, `merged`, `pr-created`, `conflict`, `test-failed`) for seeds whose status doesn't match the expected value for that run state.

2. **Fixing**: Each detected mismatch is fixed by calling `seeds.update()` with the correct status (e.g., `completed` → `closed`; `conflict` → `open`).

3. **Deduplication**: When a seed has multiple runs in history, only the most recently created run is used to determine the expected state.

4. **Dry-run awareness**: The `--dry-run` flag is respected — mismatches are detected and reported, but no updates are made.

The logic is extracted into two exported functions (`mapRunStatusToSeedStatus` and `detectAndFixMismatches`) so they can be independently unit-tested with mock dependencies.

## Files Changed

- `src/cli/commands/reset.ts` — Added:
  - `StateMismatch` and `MismatchResult` interfaces
  - `mapRunStatusToSeedStatus(runStatus)` — pure function mapping run status to expected seed status
  - `detectAndFixMismatches(store, seeds, projectId, resetSeedIds, opts)` — async function that detects and optionally fixes seed/run mismatches
  - Called `detectAndFixMismatches()` after the main reset loop (step 7)
  - Updated summary output to include `Mismatches fixed` count
  - Removed early-return when `runs.length === 0` so mismatch detection still runs even when there are no active runs to reset

## Tests Added/Modified

- `src/cli/__tests__/reset-mismatch.test.ts` — New test file with 22 tests covering:
  - `mapRunStatusToSeedStatus`: all run statuses mapped to correct seed statuses
  - `detectAndFixMismatches`:
    - Empty result when no terminal runs exist
    - Detects `completed` run with stale `in_progress` seed
    - Detects `merged` run with stale `in_progress` seed
    - Fixes mismatches by calling `seeds.update`
    - Respects dry-run mode (no updates)
    - Skips seeds already in the reset batch
    - No mismatch when seed status already matches
    - Silent skip for seeds that no longer exist (not-found error)
    - Records errors for unexpected failures
    - Records update failures and does not count them as fixed
    - Deduplicates multiple runs per seed (uses most recent)
    - Handles multiple seeds with different mismatch states

## Decisions & Trade-offs

- **Scope of detection**: The `detectAndFixMismatches` function only checks terminal runs not already in the reset batch (`completed`, `merged`, `pr-created`, `conflict`, `test-failed`). Failed/stuck/pending/running runs are already handled by the main reset loop which resets them to `open`.

- **Detection only during reset (not proactively)**: Per the Explorer report, mismatches are detected and fixed during `foreman reset` rather than in the monitor's continuous loop. This avoids race conditions where the monitor might detect a run mid-completion.

- **No changes to agent-worker or refinery**: The Explorer recommended Phase 3 (preventive updates in agent-worker and refinery) but that's additional scope. The reset command now acts as a safety net that can fix any accumulated mismatches on demand.

- **`Pick<>` interfaces for testability**: Using `Pick<ForemanStore, "getRunsByStatus">` and `Pick<SeedsClient, "show" | "update">` in the function signature allows test mocks to be minimal without needing full implementations.

## Known Limitations

- **Prevention not implemented**: The root cause (agent-worker and refinery not updating seed status on completion) is still present. The reset command fixes accumulated mismatches but doesn't prevent them from occurring. Future work (Phase 3 from Explorer) would add seed status updates to `agent-worker.ts` (single-agent mode completions) and `refinery.ts` (after merge).

- **No monitor reverse-sync**: The monitor still only does one-way sync (seed `closed` → run `completed`). Reverse sync (run terminal → fix seed) was not implemented.

- **Assumes `failed` and `stuck` seeds should be `open`**: This is the correct behavior for allowing re-dispatch, but if a seed was manually closed externally, the reset command would not touch it (since it only fixes terminal runs not in the reset batch).
