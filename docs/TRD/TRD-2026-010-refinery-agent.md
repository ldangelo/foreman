---
document_id: TRD-2026-010
prd_reference: docs/PRD/refinery-agent-prd.md
version: 1.0.0
status: Draft
date: 2026-04-19
design_readiness_score: 3.5
---

# TRD-2026-010: Refinery Agent

## Overview

The **Refinery** is the merge-orchestration component of the Foreman pipeline. It takes completed agent branches from the merge queue, rebases them onto the target branch, resolves conflicts using a tiered cascade (deterministic → AI-powered), runs optional post-merge tests, and closes the corresponding bead in the task tracker.

Refinery is invoked in two distinct contexts:

| Context | Trigger | VcsBackend Source |
|---------|---------|-------------------|
| **Immediate** | `agent-worker` calls `autoMerge()` after `finalize` phase succeeds | From agent-worker's `projectPath` |
| **Deferred** | `foreman run` dispatch loop drains merge queue between agent batches | From dispatcher's `projectPath` |

Both paths use the same `Refinery.mergeCompleted()` method; the difference is only in invocation timing.

---

## Architecture

### Component Map

```
auto-merge.ts
  └─ autoMerge()              — top-level trigger, reconciles queue, drains entries
       │
       ├─ MergeQueue.reconcile()   — enqueue completed runs not yet in queue
       │
       └─ Refinery.mergeCompleted() — per-run merge flow
            │
            ├─ scanForConflictMarkers()     — committed-content scan
            ├─ autoCommitStateFiles()        — commit dirty .seeds/.foreman/
            ├─ removeReportFiles()           — pre-merge cleanup
            ├─ VcsBackend.rebase()           — rebase onto target
            ├─ autoResolveRebaseConflicts()   — report-file rebase auto-resolve
            ├─ VcsBackend.mergeWithoutCommit() — squash merge attempt
            ├─ ConflictResolver (via ConflictResolver.handleFallback)
            │    ├─ Tier 1: git merge (deterministic)
            │    ├─ Tier 2: dual-check hunk + threshold guard
            │    ├─ Tier 3: Pi Sonnet conflict-marker resolution
            │    ├─ Tier 4: Pi Opus reimagination
            │    └─ Fallback: gh pr create
            ├─ MergeValidator (post-AI resolution validation)
            ├─ archiveReportsPostMerge()      — post-merge cleanup
            ├─ enqueueCloseSeed()             — close bead after success
            ├─ closeNativeTaskPostMerge()     — REQ-018 native task update
            ├─ rebaseStackedBranches()        — rebase dependents onto target
            └─ sendMail()                     — lifecycle notifications
```

### Files and Responsibilities

| File | Class/Fn | Responsibility |
|------|----------|----------------|
| `src/orchestrator/refinery.ts` | `Refinery` | Main merge orchestrator. Rebase → squash merge → conflict cascade → cleanup → bead closure |
| `src/orchestrator/refinery.ts` | `preserveBeadChanges()` | Extract `.seeds/` changes from a branch via patch, apply to target branch before deletion |
| `src/orchestrator/auto-merge.ts` | `autoMerge()` | Top-level trigger. Reconciles completed runs into queue, drains entries, handles strategy routing (`auto`/`pr`/`none`) |
| `src/orchestrator/auto-merge.ts` | `syncBeadStatusAfterMerge()` | Syncs bead status from run status to br after merge outcome (immediate post-merge sync) |
| `src/orchestrator/merge-queue.ts` | `MergeQueue` | SQLite-backed FIFO queue. `enqueue`, `dequeue`, `reconcile`, `resetForRetry`, `getOrderedPending` (cluster-aware) |
| `src/orchestrator/conflict-resolver.ts` | `ConflictResolver` | Tier cascade (Tiers 1–4 + fallback), rebase conflict auto-resolve, post-merge tests |
| `src/orchestrator/conflict-resolver.ts` | `REPORT_FILES` | Constants: report filenames that can be auto-resolved |
| `src/orchestrator/merge-validator.ts` | `MergeValidator` | Post-AI resolution validation: conflict markers, prose detection, markdown fencing, syntax check |
| `src/orchestrator/merge-config.ts` | `MergeQueueConfig` / `loadMergeConfig()` | Tier thresholds, cost limits, syntax checkers, prose detection patterns |
| `src/orchestrator/task-backend-ops.ts` | `enqueueCloseSeed()`, `enqueueResetSeedToOpen()`, etc. | Enqueue br write operations via ForemanStore bead_write_queue (serialized by dispatcher) |
| `src/orchestrator/task-backend-ops.ts` | `syncBeadStatusOnStartup()` | Reconcile br status from SQLite on foreman startup (dry-run mode supported) |
| `src/orchestrator/types.ts` | `MergeReport`, `MergedRun`, `ConflictRun`, `FailedRun`, `CreatedPr`, `PrReport` | Result types for merge operations |

---

## Key Design Decisions

### 1. VcsBackend Abstraction

Refinery uses `VcsBackend` for all VCS operations. `gitSpecial()` is a private helper only for commands not yet in the `VcsBackend` interface:

| Command | Method | Notes |
|---------|--------|-------|
| `git diff` | `vcs.diff()` | Committed content diff |
| `git log` | `gitSpecial()` | Not in VcsBackend |
| `git merge --squash` | `vcs.mergeWithoutCommit()` | Core merge operation |
| `git commit` | `vcs.commit()` | Squash merge commit |
| `git rebase` | `vcs.rebase()` / `gitSpecial()` | `gitSpecial` for 2-arg form (`rebase upstream branch`) and `--onto` form |
| `git merge --abort` | `vcs.abortMerge()` | On conflict abort |
| `git checkout --theirs` | `vcs.checkoutFile()` | Per-file conflict resolution |
| `git merge -X theirs` | `gitSpecial()` | Not in VcsBackend |
| `git stash push/pop` | `gitSpecial()` | Not in VcsBackend |
| `git apply --index` | `gitSpecial()` | Patch application |
| `git worktree remove` | `vcs.removeWorkspace()` | TRD-012 replacement for `removeWorktree()` shim |

Jujutsu-specific behavior: For jj backends, rebase runs inside the workspace directory (`run.worktree_path`) rather than the main repo to avoid jj's raw git rebase semantics in colocated repos.

### 2. Squash Merge Strategy

Refinery always uses `--squash` merges so each feature branch becomes a single commit on the target branch. This:
- Prevents empty or noisy intermediate commits from polluting the target
- Makes rollback trivial (`git reset --hard HEAD~1`)
- Produces a clean `git log` with one entry per feature

The squash commit message uses the bead title if available, otherwise `foreman/<seedId>: squash merge`.

### 3. Conflict Marker Scanning (Committed Content Only)

`scanForConflictMarkers()` reads `git diff <target>...<branch>` (committed content only). It intentionally **ignores** working-tree conflict markers because those don't exist in the commits being merged.

### 4. Report File Auto-Resolution

Report files (`QA_REPORT.md`, `REVIEW.md`, `TASK.md`, `SESSION_LOG.md`, etc.) are:
1. **Removed pre-merge** via `removeReportFiles()` — prevents conflicts
2. **Archived post-merge** to `.foreman/reports/<name>-<seedId>.md` — preserves the artifact

`ConflictResolver.isReportFile()` determines which files are auto-resolvable (includes `.beads/` files — latest bead state wins).

### 5. Bead Write Queue (SQLite Contention Avoidance)

Multiple `agent-worker` processes can call `autoMerge()` concurrently after `finalize`, all writing to the shared `.beads/beads.db`. Direct `br` CLI calls cause `SQLITE_BUSY` contention.

**Solution**: All br write operations are enqueued via `ForemanStore.enqueueBeadWrite()`:
- `enqueueCloseSeed()` — close after successful merge
- `enqueueResetSeedToOpen()` — reset on failure
- `enqueueAddNotesToBead()` — annotate failure reasons
- `enqueueAddLabelsToBead()` — phase-tracking labels
- `enqueueSetBeadStatus()` — arbitrary status transitions
- `enqueueMarkBeadFailed()` — permanent failure marker

The **dispatcher** (single process) drains the queue sequentially, eliminating SQLite lock contention.

### 6. Bead Closure Timing

The bead is closed **after** the code lands in the target branch (`enqueueCloseSeed()` called after `vcs.commit()`). This ensures:
- Bead shows `review` (awaiting merge) during the merge window
- Bead shows `closed` only after code is on the target

### 7. Stacked Branch Rebasing

After a successful merge of `mergedBranch` into `targetBranch`, `rebaseStackedBranches()` finds all active runs whose `base_branch` is `mergedBranch` and rebases them onto `targetBranch`. This maintains stacked PR workflows where dependent branches build on each other.

### 8. Branch Label Routing

Target branch is resolved from the bead's `branch:<name>` label (via `extractBranchLabel()`). Fallback is the auto-detected default branch. This enables per-bead target specification rather than hardcoding `dev`/`main`.

### 9. Merge Strategy Routing

`autoMerge()` checks `run.merge_strategy` from the run record:
- **`auto`** (default): Refinery rebases and merges
- **`pr`**: Create a GitHub PR for manual review
- **`none`**: Mark as merged without any merge operation (for manual workflows)

### 10. `.seeds/` Preservation

`preserveBeadChanges()` extracts `.seeds/` changes from a branch before it's deleted, applies them as a patch to the target branch, and commits them. This ensures task tracker state from completed branches isn't lost when worktrees are removed.

---

## Tier Cascade Detail

```
Tier 1: git merge
  └─ On conflict → Tier 2

Tier 2: Deterministic per-file
  ├─ Hunk verification: every target-unique line must appear in branch version
  ├─ Threshold guard: discarded lines ≤ maxDiscardedLines AND ≤ maxDiscardedPercent
  └─ On fail → Tier 3

Tier 3: AI Sonnet (conflict-marker resolution)
  ├─ File size gate: ≤ maxFileLines (default 1000)
  ├─ Budget gate: estimated cost ≤ remaining session budget
  ├─ Pi Sonnet resolves conflict markers, writes file
  ├─ MergeValidator checks: conflict markers, markdown fencing, prose, syntax
  └─ On fail → Tier 4

Tier 4: AI Opus (reimagination)
  ├─ Reads canonical (target), branch, and diff
  ├─ Pi Opus applies branch changes onto canonical
  ├─ MergeValidator checks
  └─ On fail → Fallback

Fallback: gh pr create
  └─ Push branch, create PR with MQ-018 error code and per-file tier attempts
```

---

## Error Codes

| Code | Source | Meaning |
|------|--------|---------|
| MQ-002 | `merge-validator.ts` | Syntax check failed |
| MQ-003 | `merge-validator.ts` | AI output is prose, not code |
| MQ-004 | `merge-validator.ts` | Residual conflict markers in resolved content |
| MQ-005 | `merge-validator.ts` | Resolved content wrapped in markdown fencing |
| MQ-007 | `conflict-resolver.ts` | Post-merge tests failed after AI resolution |
| MQ-012 | `conflict-resolver.ts` | Session budget exhausted before AI call |
| MQ-013 | `conflict-resolver.ts` | File exceeds max file line limit |
| MQ-014 | `conflict-resolver.ts` | Untracked working-tree file conflicts with added file |
| MQ-018 | `conflict-resolver.ts` | All tiers exhausted — conflict PR created |
| MQ-019 | `refinery.ts` | `.seeds/` patch application failed |
| MQ-020 | `refinery.ts` | Auto-commit of state files failed (non-fatal) |

---

## Data Types

### MergeReport (returned by Refinery.mergeCompleted)

```typescript
interface MergeReport {
  merged: MergedRun[];           // Successful merges
  conflicts: ConflictRun[];       // Code conflicts (PR created or manual)
  testFailures: FailedRun[];     // Post-merge test failures
  unexpectedErrors: FailedRun[]; // Git/shell failures (not test runner exit)
  prsCreated: CreatedPr[];       // PRs created for conflicts
}
```

### MergeQueueEntry (SQLite-backed)

```typescript
interface MergeQueueEntry {
  id: number;
  branch_name: string;
  seed_id: string;
  run_id: string;
  agent_name: string | null;
  files_modified: string[];
  enqueued_at: string;
  started_at: string | null;
  completed_at: string | null;
  status: "pending" | "merging" | "merged" | "conflict" | "failed";
  resolved_tier: number | null;
  error: string | null;
  retry_count: number;
  last_attempted_at: string | null;
}
```

---

## Configuration

### MergeQueueConfig (`.foreman/config.json`)

```json
{
  "mergeQueue": {
    "tier2SafetyCheck": {
      "maxDiscardedLines": 20,
      "maxDiscardedPercent": 30
    },
    "costControls": {
      "maxFileLines": 1000,
      "maxSessionBudgetUsd": 5.0
    },
    "syntaxCheckers": {
      ".ts": "tsc --noEmit",
      ".js": "node --check"
    },
    "proseDetection": {
      ".ts": ["^import\\b", "^export\\b", "^const\\b", ...],
      ".py": ["^import\\b", "^from\\b", "^def\\b", ...]
    },
    "testAfterMerge": "ai-only"
  }
}
```

Defaults are defined in `DEFAULT_MERGE_CONFIG` in `merge-config.ts`.

---

## Non-Fatal Error Philosophy

Refinery follows a strict **non-fatal** philosophy for auxiliary operations:
- Mail failures: silently ignored (mail is optional infrastructure)
- Bead annotation failures: logged as warnings, never propagate
- Worktree removal failures: logged, doesn't block merge completion
- Archive failures: best-effort, doesn't block merge

Only **core merge failures** (conflicts, test failures, unexpected errors) are reported as such. These update the run status and bead notes but still allow the queue to continue processing other entries.

---

## Testing Strategy

| Test File | Coverage |
|-----------|----------|
| `refinery-vcs.test.ts` | VcsBackend injection, squash merge, conflict cascade, PR creation |
| `refinery-branch-label.test.ts` | Branch label target routing |
| `refinery-git-town.test.ts` | `gh pr create` vs `git town propose` |
| `merge-dry-run.test.ts` | `dryRunMerge()` preview function |
| `merge-validator.test.ts` | Prose detection, conflict markers, markdown fencing, syntax check |
| `merge-config.test.ts` | JSON config loading, deep merge of overrides |
| `merge-queue.test.ts` | enqueue, dequeue, reconcile, cluster ordering |

---

## Known Limitations

1. **Jujutsu rebase in colocated repos**: The `gitSpecial` 2-arg rebase form (`rebase upstream branch`) operates from the main repo context, which jj's colocated mode intercepts. Rebase inside the workspace directory is used as mitigation.
2. **Conflict cluster ordering**: `MergeQueue.getOrderedPending()` uses file overlap to order merges, but this is approximate — two branches modifying the same file in different ways will still conflict regardless of merge order.
3. **Stacked branch base tracking**: `base_branch` is cleared after rebase but if the rebase itself fails, the old `base_branch` value persists. `rebaseStackedBranches()` skips inactive runs, so stale bases don't cause incorrect behavior.
4. **`.seeds/` preservation on merge conflict**: If a branch has conflicts, `preserveBeadChanges()` is not called. The `.seeds/` changes on the conflicting branch require manual extraction.

---

## Future Enhancements

| ID | Description | Priority |
|----|-------------|----------|
| F1 | Parallel merge of non-conflicting branches | Medium |
| F2 | Configurable squash merge message template | Low |
| F3 | Merge preview UI (`foreman merge --dry-run --preview`) | Medium |
| F4 | Automatic `.seeds/` preservation on conflict | High |
| F5 | Jujutsu-native rebase-all-stacked operation | Low |

---

## Dependencies

- `src/orchestrator/refinery.ts` → `src/lib/vcs/` (VcsBackend interface)
- `src/orchestrator/refinery.ts` → `src/orchestrator/conflict-resolver.ts`
- `src/orchestrator/refinery.ts` → `src/orchestrator/task-backend-ops.ts`
- `src/orchestrator/refinery.ts` → `src/orchestrator/merge-config.ts`
- `src/orchestrator/auto-merge.ts` → `src/orchestrator/merge-queue.ts`
- `src/orchestrator/auto-merge.ts` → `src/orchestrator/refinery.ts`
- `src/orchestrator/auto-merge.ts` → `src/lib/project-config.ts`
- `src/orchestrator/conflict-resolver.ts` → `src/orchestrator/merge-config.ts`
- `src/orchestrator/conflict-resolver.ts` → `src/orchestrator/merge-validator.ts`
- `src/orchestrator/conflict-resolver.ts` → `src/orchestrator/pi-sdk-runner.ts`
- `src/orchestrator/task-backend-ops.ts` → `src/lib/store.ts` (bead_write_queue)
- `src/orchestrator/task-backend-ops.ts` → `src/lib/run-status.ts` (mapRunStatusToSeedStatus)

---

## Interfaces

### IRefineryTaskClient

Minimal interface for the task-tracking backend used by Refinery:

```typescript
interface IRefineryTaskClient {
  show(id: string): Promise<{
    title?: string;
    description?: string | null;
    status: string;
    labels?: string[];
  }>;
  getGraph?(): Promise<BeadGraph>;  // Used for topological merge ordering
  update?(id: string, opts: UpdateOptions): Promise<void>;
}
```

`BeadsRustClient` satisfies this interface. The `getGraph()` method is optional — `orderByDependencies()` falls back to insertion order when unavailable.

### AutoMergeOpts

```typescript
interface AutoMergeOpts {
  store: ForemanStore;
  taskClient: ITaskClient;
  projectPath: string;
  targetBranch?: string;       // Auto-detected if omitted
  runId?: string;              // Direct ID lookup (most reliable)
  overrideRun?: Run;           // Pre-fetched run (bypasses getRun query)
}
```

`runId` is preferred over `overrideRun` for immediate auto-merge calls because it fetches by ID directly without status filtering, eliminating SQLite WAL timing issues where the `completed` status hasn't been committed/visible to a query yet.
