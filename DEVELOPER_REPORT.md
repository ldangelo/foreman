# Developer Report: 4-tier merge conflict resolution

## Approach

Implemented a 4-tier escalating merge conflict resolution system. When a merge is attempted, the system automatically tries increasingly permissive strategies before requiring human intervention:

- **Tier 1 (recursive)**: Default `git merge --no-ff` — handles auto-resolvable conflicts
- **Tier 2 (ours)**: `git merge --no-ff -X ours` — prefer target-branch (main) changes on conflict
- **Tier 3 (theirs)**: `git merge --no-ff -X theirs` — prefer agent-branch changes on conflict
- **Tier 4 (manual)**: All automatic strategies exhausted — flags for human review

Between each failed tier attempt, the in-progress merge is aborted cleanly so the repo is in a valid state for the next attempt. Tiers 2 and 3 use git's `-X` extended strategy options which force resolution of all textual conflicts (binary and structural conflicts may still reach tier 4 as a safety net).

## Files Changed

- `src/lib/git.ts` — Extended `MergeResult` with `tier?` and `strategy?` fields; added optional `strategy?: "ours" | "theirs"` parameter to `mergeWorktree()`; added private `abortMerge()` helper; exported new `mergeWorktreeWithTiers()` function implementing the full 4-tier escalation logic

- `src/orchestrator/types.ts` — Extended `MergedRun` with optional `tier?: number` and `strategy?: string` to track how conflicts were resolved; extended `ConflictRun` with `requiresManualReview: boolean` to distinguish tier-4 escalations from the previous conflict model

- `src/orchestrator/refinery.ts` — Replaced `mergeWorktree` import with `mergeWorktreeWithTiers`; updated `mergeCompleted()` to use tier-based merging, removed the manual inline `git merge --abort` call (now handled internally), passes `tier`/`strategy` to merged run records and log events, sets `requiresManualReview: true` for tier-4 conflicts

- `src/cli/commands/merge.ts` — Shows `[tier N: strategy]` annotation in merged output when tier > 1; updated conflict help text to explain automatic strategies were exhausted before requiring manual resolution

## Tests Added/Modified

- `src/lib/__tests__/git.test.ts` — Added 4 new test cases:
  - `mergeWorktree with ours strategy resolves conflicts preferring main` — verifies `-X ours` succeeds and keeps main's file content
  - `mergeWorktree with theirs strategy resolves conflicts preferring agent` — verifies `-X theirs` succeeds and keeps agent's file content
  - `mergeWorktreeWithTiers succeeds at tier 1 for clean merge` — verifies tier=1, strategy="recursive" on a non-conflicting merge
  - `mergeWorktreeWithTiers escalates to tier 3 for conflicts` — verifies tier escalation beyond 1 when conflicts exist

All 11 tests pass (7 pre-existing + 4 new).

## Decisions & Trade-offs

- **Tier logic in git.ts vs refinery.ts**: Placed `mergeWorktreeWithTiers()` in `git.ts` to keep all git operations co-located and testable independently of the refinery/store infrastructure.

- **Backwards compatibility**: Kept `resolveConflict()` in `refinery.ts` unchanged. Users with existing `foreman merge --resolve` workflows continue to work. The method is now less frequently needed since tier 2/3 handle most conflicts automatically.

- **Tier 2 vs Tier 3 ordering**: Tier 2 (`ours`) prefers main-branch changes, which is more conservative. Tier 3 (`theirs`) prefers agent changes. This ordering means we first try to preserve human-committed code before accepting the agent's version wholesale.

- **`requiresManualReview` field**: Added as non-optional on `ConflictRun` (always `true` now since only tier-4 conflicts reach that list) for forward-compatibility — future tiers or partial-conflict cases could set it to `false`.

## Known Limitations

- **Binary and submodule conflicts**: `-X ours` / `-X theirs` do not resolve binary file conflicts or submodule conflicts. These will still reach Tier 4. Currently logged as `strategy: "manual"` but no automated PR creation is implemented for Tier 4.

- **Test validity after tier 2/3**: If tier 2 or 3 forces a resolution that breaks tests, the merge is reverted and recorded as a test failure. The system does not attempt a different tier after a test failure — this could be a future enhancement.

- **Tier 4 PR creation**: The EXPLORER_REPORT suggested optional PR-based tier 4 escalation. This is deferred — tier 4 currently just marks the run as `conflict` with `requiresManualReview: true` and preserves the existing `foreman merge --resolve` workflow.
