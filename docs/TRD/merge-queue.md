# TRD: Merge Queue Epic

**Document ID:** TRD-MERGE-QUEUE
**Version:** 1.2
**Created:** 2026-03-12
**Last Updated:** 2026-03-13
**PRD Reference:** PRD-MERGE-QUEUE v5.0
**Epic ID:** bd-uba
**Status:** Implementation Ready

---

## 1. System Architecture

### 1.1 Architecture Overview

The merge queue system converts the existing `Refinery` class into a thin wrapper that delegates to new purpose-built modules. The `Refinery` class is preserved (minimizing blast radius for callers) but its internals are gutted and replaced with delegation to `MergeQueue`, `ConflictResolver`, and related modules. The system introduces five new modules that integrate with the existing SQLite store, git operations layer, and agent worker pipeline.

```
foreman merge (CLI)
  |
  v
Refinery (thin wrapper -- preserves public API, delegates internally)
  |
  v
MergeQueue (SQLite-backed persistent queue)
  |-- reconcile(): scan completed runs, validate branches, enqueue missing
  |-- dequeue(): atomic claim of next pending entry
  |
  v
ConflictCluster (overlap graph)
  |-- buildOverlapGraph(): files_modified overlap detection
  |-- findClusters(): connected components
  |-- reCluster(): after each merge commit
  |
  v
ConflictResolver (per-file 4-tier cascade)
  |-- Tier 1: git merge --no-commit --no-ff
  |-- Tier 2: 3-way diff hunk verification + safety check (per-file)
  |-- Tier 3: Claude Sonnet AI resolve + validation
  |-- Tier 4: Claude Opus reimagine + validation
  |-- Fallback: git merge --abort + git town propose
  |
  v
MergeValidator (output validation)
  |-- proseDetection(): language-aware first-line heuristic
  |-- syntaxCheck(): configurable checker map
  |-- conflictMarkerCheck(): residual marker detection
  |-- markdownFencingCheck(): fencing detection
  |
  v
ConflictPatterns (learning, FR-7)
  |-- recordOutcome(): per-file tier result
  |-- shouldSkipTier(): historical failure analysis
  |-- getSuccessContext(): past resolution examples
```

### 1.2 New Module Structure

| File | Purpose | Dependencies |
|------|---------|-------------|
| `src/orchestrator/merge-queue.ts` | MergeQueue class: SQLite queue CRUD, reconciliation, dequeue atomics | `store.ts`, `git.ts` |
| `src/orchestrator/conflict-resolver.ts` | Per-file 4-tier cascade logic, cost tracking, Anthropic Messages API calls | `merge-validator.ts`, `merge-queue.ts`, `conflict-patterns.ts`, `git.ts`, `@anthropic-ai/sdk` |
| `src/orchestrator/conflict-cluster.ts` | Graph-based overlap clustering, connected components, re-clustering | `merge-queue.ts` |
| `src/orchestrator/merge-validator.ts` | Prose detection, syntax checking, conflict marker detection, markdown fencing | `config.ts` |
| `src/orchestrator/conflict-patterns.ts` | Pattern learning SQLite table, tier skip logic, success context | `store.ts` |
| `src/orchestrator/merge-config.ts` | Config loader for `.foreman/config.json` merge queue settings | -- |
| `src/cli/commands/worktree.ts` | Worktree list/clean CLI commands | `git.ts`, `store.ts` |

### 1.3 Data Architecture

#### 1.3.1 New SQLite Tables

**merge_queue** -- Persistent merge queue entries

```sql
CREATE TABLE IF NOT EXISTS merge_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  branch_name TEXT NOT NULL,
  seed_id TEXT NOT NULL,
  run_id TEXT NOT NULL,
  agent_name TEXT,
  files_modified TEXT DEFAULT '[]',
  enqueued_at TEXT NOT NULL,
  started_at TEXT,
  completed_at TEXT,
  status TEXT DEFAULT 'pending'
    CHECK (status IN ('pending', 'merging', 'merged', 'conflict', 'failed')),
  resolved_tier INTEGER,
  error TEXT,
  FOREIGN KEY (run_id) REFERENCES runs(id)
);

CREATE INDEX IF NOT EXISTS idx_merge_queue_status
  ON merge_queue (status, enqueued_at);
```

**conflict_patterns** -- Resolution outcome history (FR-7)

```sql
CREATE TABLE IF NOT EXISTS conflict_patterns (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  file_path TEXT NOT NULL,
  file_extension TEXT NOT NULL,
  tier INTEGER NOT NULL,
  success INTEGER NOT NULL,
  failure_reason TEXT,
  merge_queue_id INTEGER,
  seed_id TEXT,
  recorded_at TEXT NOT NULL,
  FOREIGN KEY (merge_queue_id) REFERENCES merge_queue(id)
);

CREATE INDEX IF NOT EXISTS idx_conflict_patterns_file
  ON conflict_patterns (file_extension, tier);

CREATE INDEX IF NOT EXISTS idx_conflict_patterns_merge
  ON conflict_patterns (merge_queue_id);
```

**merge_costs** -- AI resolution cost tracking

```sql
CREATE TABLE IF NOT EXISTS merge_costs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  merge_queue_id INTEGER,
  file_path TEXT NOT NULL,
  tier INTEGER NOT NULL,
  model TEXT NOT NULL,
  input_tokens INTEGER NOT NULL,
  output_tokens INTEGER NOT NULL,
  estimated_cost_usd REAL NOT NULL,
  actual_cost_usd REAL NOT NULL,
  recorded_at TEXT NOT NULL,
  FOREIGN KEY (merge_queue_id) REFERENCES merge_queue(id)
);

CREATE INDEX IF NOT EXISTS idx_merge_costs_session
  ON merge_costs (session_id);

CREATE INDEX IF NOT EXISTS idx_merge_costs_date
  ON merge_costs (recorded_at);
```

#### 1.3.2 Configuration Schema

File: `.foreman/config.json` (project-level)

```json
{
  "mergeQueue": {
    "tier2SafetyCheck": {
      "maxDiscardedLines": 20,
      "maxDiscardedPercent": 30
    },
    "costControls": {
      "maxFileLines": 1000,
      "maxSessionBudgetUsd": 5.00
    },
    "syntaxCheckers": {
      ".ts": "tsc --noEmit",
      ".js": "node --check"
    },
    "proseDetection": {
      ".ts": ["^import\\b", "^export\\b", "^const\\b", "..."],
      ".js": ["..."],
      ".py": ["..."],
      ".go": ["..."]
    },
    "testAfterMerge": "ai-only"
  }
}
```

### 1.4 Integration Points

| Integration | Direction | Mechanism |
|------------|-----------|-----------|
| Agent worker finalize -> MergeQueue | Outbound | `mergeQueue.enqueue()` after successful git push in `finalize()` |
| `foreman merge` -> MergeQueue | Inbound | `reconcile()` then `dequeue()` loop |
| ConflictResolver -> Anthropic SDK | Outbound | `messages.create()` for Tier 3 (Sonnet) and Tier 4 (Opus) -- single-turn, no tools |
| ConflictResolver -> MergeValidator | Internal | Validate AI output before accepting |
| ConflictResolver -> ConflictPatterns | Internal | Record outcomes, check skip conditions |
| MergeQueue -> ConflictCluster | Internal | Overlap-aware sequential ordering before dequeue |
| Normal PR creation -> git-town | Outbound | `git town propose` for happy-path PR creation (normal flow, `Refinery.createPRs()`) |
| Conflict PR creation -> gh CLI | Outbound | `gh pr create` with custom title/body for conflict PRs needing tier attempts, error details |
| Doctor -> MergeQueue | Inbound | Health checks for stale/orphaned/duplicate entries |

### 1.5 Error Code System

All merge queue errors use structured codes `MQ-001` through `MQ-020`. See PRD Section 11 for the complete reference. Error codes appear in:
- `merge_queue.error` column
- `events.details` JSON
- CLI stderr output
- Worker log files

---

## 2. Master Task List

### Legend

- `[ ]` Not started
- `[~]` In progress
- `[x]` Completed

### 2.1 Sprint 1: Foundation (FR-2, FR-4) -- Quick Wins

#### Story 1.1: Auto-Commit State Files Before Merge

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| MQ-T001 | Implement `autoCommitStateFiles()` in refinery.ts -- detect uncommitted changes in `.seeds/` and `.foreman/` via `git status --porcelain`, stage and commit with descriptive message | 3h | -- | `src/orchestrator/refinery.ts` | [ ] |
| MQ-T002 | Wire `autoCommitStateFiles()` into `mergeCompleted()` before each merge attempt, applying to both target branch and feature branch | 2h | MQ-T001 | `src/orchestrator/refinery.ts` | [ ] |
| MQ-T003 | Write unit tests for `autoCommitStateFiles()` -- test no-op when clean, commit when dirty, correct commit message, both target and feature branch | 3h | MQ-T001 | `src/orchestrator/__tests__/refinery-state-files.test.ts` | [ ] |

#### Story 1.2: Safe Branch Deletion

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| MQ-T004 | Refactor `deleteBranch()` in git.ts -- add `options?: { force?: boolean; targetBranch?: string }` parameter. Check merge status with `git merge-base --is-ancestor`. Use `-d` for merged, `-D` only with `force: true` for unmerged. Return `{ deleted: boolean; wasFullyMerged: boolean }` | 3h | -- | `src/lib/git.ts` | [ ] |
| MQ-T005 | Update all callers of `deleteBranch()` in refinery.ts and reset.ts to use new API. Refinery uses `force: false` (safe default), reset uses `force: true` | 2h | MQ-T004 | `src/orchestrator/refinery.ts`, `src/cli/commands/reset.ts` | [ ] |
| MQ-T006 | Write unit tests for safe `deleteBranch()` -- merged branch deletes safely, unmerged without force warns and skips, unmerged with force deletes, not-found graceful | 3h | MQ-T004 | `src/lib/__tests__/git-delete-branch.test.ts` | [ ] |

### 2.2 Sprint 2: Merge Queue Core (FR-3)

#### Story 2.1: MergeQueue SQLite Backend

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| MQ-T007 | Add `merge_queue` table migration to store.ts using existing idempotent migration pattern (`CREATE TABLE IF NOT EXISTS`, add to `MIGRATIONS` array) | 2h | -- | `src/lib/store.ts` | [ ] |
| MQ-T008 | Implement `MergeQueue` class with `enqueue()`, `dequeue()`, `peek()`, `list()`, `updateStatus()`, `remove()` methods. Dequeue uses atomic `UPDATE ... WHERE status='pending' ORDER BY enqueued_at LIMIT 1 RETURNING *` | 4h | MQ-T007 | `src/orchestrator/merge-queue.ts` | [ ] |
| MQ-T009 | Implement `reconcile()` method -- cross-reference `runs` table (status=completed) with `merge_queue` entries. Validate branch existence via `git rev-parse --verify`. Enqueue missing entries. Log reconciliation actions | 3h | MQ-T008 | `src/orchestrator/merge-queue.ts` | [ ] |
| MQ-T010 | Add 5-second busy timeout configuration for concurrent SQLite access (`this.db.pragma('busy_timeout = 5000')`) | 1h | MQ-T007 | `src/lib/store.ts` | [ ] |
| MQ-T011 | Write unit tests for MergeQueue CRUD -- enqueue, dequeue atomicity, peek, list with status filter, idempotent enqueue, reconciliation with branch validation | 4h | MQ-T008, MQ-T009 | `src/orchestrator/__tests__/merge-queue.test.ts` | [ ] |

#### Story 2.2: Merge Queue Configuration

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| MQ-T012 | Implement `MergeConfig` loader -- read `.foreman/config.json`, validate schema, provide defaults for all merge queue settings. Export typed config interface | 4h | -- | `src/orchestrator/merge-config.ts` | [ ] |
| MQ-T013 | Write unit tests for config loader -- defaults when no file, partial config merging, invalid values fallback to defaults | 2h | MQ-T012 | `src/orchestrator/__tests__/merge-config.test.ts` | [ ] |

#### Story 2.3: Agent Finalize Auto-Enqueue

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| MQ-T016 | Update agent-worker.ts `finalize()` function to call `mergeQueue.enqueue()` after successful git push. Collect `files_modified` from `git diff --name-only main...HEAD`. Fire-and-forget: enqueue errors logged but do not fail finalization | 3h | MQ-T008 | `src/orchestrator/agent-worker.ts` | [ ] |
| MQ-T017 | Write tests for auto-enqueue integration -- successful enqueue after push, graceful failure on enqueue error, files_modified populated | 3h | MQ-T016 | `src/orchestrator/__tests__/agent-worker-enqueue.test.ts` | [ ] |

#### Story 2.4: Merge CLI Queue Integration

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| MQ-T018 | Refactor `foreman merge` to use queue-based flow: run `reconcile()`, then process via `dequeue()` loop. Convert `Refinery` to thin wrapper that delegates to `MergeQueue` and `ConflictResolver` internally -- preserve `Refinery` public API (`mergeCompleted()`, `resolveConflict()`, `createPRs()`, `getCompletedRuns()`, `orderByDependencies()`) but gut internals. No legacy path | 5h | MQ-T008, MQ-T009 | `src/cli/commands/merge.ts`, `src/orchestrator/refinery.ts` | [ ] |
| MQ-T018b | Migrate Refinery helper methods to appropriate new modules: `isReportFile()` and `removeReportFiles()` -> ConflictResolver, `archiveReportsPostMerge()` -> MergeQueue post-merge hook, `autoResolveRebaseConflicts()` -> ConflictResolver pre-merge step. Ensure Refinery delegates to these new locations | 3h | MQ-T018 | `src/orchestrator/refinery.ts`, `src/orchestrator/conflict-resolver.ts`, `src/orchestrator/merge-queue.ts` | [ ] |
| MQ-T019 | Update `foreman merge --list` to read from `merge_queue` table instead of filtering completed runs. Show status, branch, seed, age, and files_modified count | 2h | MQ-T008 | `src/cli/commands/merge.ts` | [ ] |
| MQ-T020 | Write integration tests for queue-based merge flow -- reconcile detects missing entries, dequeue processes in order, status transitions correct | 4h | MQ-T018 | `src/cli/__tests__/merge-queue-flow.test.ts` | [ ] |

### 2.3 Sprint 3a: Deterministic Resolution (FR-1, Tier 1-2)

**Quality gate:** Sprint 3a must be complete and passing before Sprint 3b begins. This ensures the deterministic resolution foundation is solid before adding AI-powered tiers.

#### Story 3.1: Merge Validator

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| MQ-T021 | Implement `MergeValidator` class with `proseDetection(content, fileExtension)` -- language-aware first-line heuristic using built-in patterns for .ts/.js, .py, .go plus generic fallback. Patterns loaded from MergeConfig | 4h | MQ-T012 | `src/orchestrator/merge-validator.ts` | [ ] |
| MQ-T022 | Implement `syntaxCheck(filePath, content)` -- configurable syntax checker map lookup by extension, execute checker command, return pass/fail with error details. Accept unmapped extensions. Error code MQ-002 | 3h | MQ-T012 | `src/orchestrator/merge-validator.ts` | [ ] |
| MQ-T023 | Implement `conflictMarkerCheck(content)` -- detect residual `<<<<<<<`, `=======`, `>>>>>>>` markers. Error code MQ-004 | 1h | -- | `src/orchestrator/merge-validator.ts` | [ ] |
| MQ-T024 | Implement `markdownFencingCheck(content)` -- detect triple-backtick fencing wrapping entire content. Error code MQ-005 | 1h | -- | `src/orchestrator/merge-validator.ts` | [ ] |
| MQ-T025 | Write comprehensive tests for MergeValidator -- prose detection per language, syntax check with mock commands, conflict markers, markdown fencing, config override of patterns | 5h | MQ-T021, MQ-T022, MQ-T023, MQ-T024 | `src/orchestrator/__tests__/merge-validator.test.ts` | [ ] |

#### Story 3.2: Tier 1-2 Resolution

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| MQ-T026 | Implement `ConflictResolver` class with Tier 1: `git merge --no-commit --no-ff`. Identify all conflicted files via `git diff --name-only --diff-filter=U`. If no conflicts, `git commit` and return success | 3h | -- | `src/orchestrator/conflict-resolver.ts` | [ ] |
| MQ-T027 | Implement Tier 2 per-file resolution using 3-way diff hunk verification with dual-check gate: for each conflicted file, extract discarded hunks from the target branch using `git diff`, verify each hunk is already present in the branch version (i.e., the branch incorporated those changes). If any target-side hunk is genuinely missing from the branch version (true semantic conflict), that file cascades to Tier 3. BOTH checks must pass for Tier 2 to succeed: (1) hunk verification -- all target-side hunks present in branch version, AND (2) threshold guard -- configurable hybrid threshold (>20 lines OR >30% of file discarded triggers cascade). Uses `git checkout --theirs` only after BOTH checks pass | 5h | MQ-T026, MQ-T012 | `src/orchestrator/conflict-resolver.ts` | [ ] |
| MQ-T028 | Write tests for Tier 1 -- clean merge succeeds, conflicts detected and listed, merge topology preserved (two parents) | 3h | MQ-T026 | `src/orchestrator/__tests__/conflict-resolver-t1.test.ts` | [ ] |
| MQ-T029 | Write tests for Tier 2 dual-check gate -- hunk verification passes when branch incorporates all target hunks, fails when target hunks are missing (true semantic conflict always cascades), threshold guard fails when >20 lines or >30% discarded even if hunks verify, BOTH checks must pass for Tier 2 success, files cascade independently to Tier 3, configurable thresholds from MergeConfig | 5h | MQ-T027 | `src/orchestrator/__tests__/conflict-resolver-t2.test.ts` | [ ] |

### 2.3b Sprint 3b: AI-Powered Resolution (FR-1, Tier 3-4)

**Prerequisite:** Sprint 3a complete. All deterministic resolution tests passing.

#### Story 3.3: Tier 3 AI Resolution (Sonnet)

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| MQ-T030 | Implement Tier 3 resolution: read file with conflict markers, apply file size gate (default 1000 lines, MQ-013), build system prompt instructing code-only output, call Anthropic `messages.create()` with `claude-sonnet-4-6` (single-turn, no tools), 60s timeout. Cost tracked directly from `response.usage` | 4h | MQ-T026 | `src/orchestrator/conflict-resolver.ts` | [ ] |
| MQ-T031 | Wire MergeValidator into Tier 3 output validation pipeline: prose detection (MQ-003) -> markdown fencing (MQ-005) -> conflict marker check (MQ-004) -> syntax check (MQ-002). On any validation failure, mark file for Tier 4 cascade | 3h | MQ-T030, MQ-T021, MQ-T022, MQ-T023, MQ-T024 | `src/orchestrator/conflict-resolver.ts` | [ ] |
| MQ-T032 | Implement cost tracking for Tier 3 calls: pre-call estimate (4 chars/token), post-call actual from `response.usage` (`input_tokens`, `output_tokens`). Soft budget enforcement: check estimate against remaining budget, update session total with actuals. Direct from Messages API response -- no SDK overhead | 3h | MQ-T030 | `src/orchestrator/conflict-resolver.ts` | [ ] |
| MQ-T033 | Write tests for Tier 3 -- successful AI resolution, validation rejection scenarios (prose, markers, fencing, syntax), file size gate skip, budget exhaustion skip, cost tracking accuracy | 5h | MQ-T030, MQ-T031, MQ-T032 | `src/orchestrator/__tests__/conflict-resolver-t3.test.ts` | [ ] |

#### Story 3.4: Tier 4 AI Resolution (Opus)

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| MQ-T034 | Implement Tier 4 resolution: read canonical (`git show {target}:{filepath}`), branch version (`git show {branch}:{filepath}`), and diff (`git diff {target}...{branch} -- {filepath}`). Apply file size gate. Call Anthropic `messages.create()` with `claude-opus-4-6` (single-turn, no tools), 120s timeout. Prompt: "Apply these changes from the branch onto the canonical version". Cost tracked directly from `response.usage` | 4h | MQ-T026 | `src/orchestrator/conflict-resolver.ts` | [ ] |
| MQ-T035 | Wire MergeValidator into Tier 4 (same validation pipeline as Tier 3). On validation failure, mark file for Fallback | 2h | MQ-T034, MQ-T031 | `src/orchestrator/conflict-resolver.ts` | [ ] |
| MQ-T036 | Implement cost tracking for Tier 4 calls (same `response.usage` mechanism as Tier 3 but with Opus pricing) | 2h | MQ-T034, MQ-T032 | `src/orchestrator/conflict-resolver.ts` | [ ] |
| MQ-T037 | Write tests for Tier 4 -- successful reimagination, validation rejection, file size gate, Opus model used, cost tracking | 4h | MQ-T034, MQ-T035, MQ-T036 | `src/orchestrator/__tests__/conflict-resolver-t4.test.ts` | [ ] |

### 2.4 Sprint 4: Resolution Orchestration (FR-1, Part 2)

#### Story 4.1: Per-File Tier Cascade Orchestration

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| MQ-T038 | Implement per-file cascade orchestrator in `ConflictResolver.resolveConflicts()`: after Tier 1 identifies conflicted files, iterate each file through Tier 2 -> 3 -> 4 -> Fallback independently. Track per-file tier resolution in `resolvedTiers: Map<string, number>`. If any file reaches Fallback, `git merge --abort` entire merge | 5h | MQ-T027, MQ-T030, MQ-T034 | `src/orchestrator/conflict-resolver.ts` | [ ] |
| MQ-T039 | Implement Fallback handler: `git merge --abort`, create conflict PR via `gh pr create` with custom title/body (includes per-file tier attempts, error codes, conflict details). Update queue entry to `conflict` status with error code MQ-018. Log all per-file tier attempts. Note: uses `gh pr create` (not `git town propose`) because conflict PRs require structured title/body with resolution metadata | 3h | MQ-T038 | `src/orchestrator/conflict-resolver.ts` | [ ] |
| MQ-T040 | Extend `MergeReport` type with `resolvedTiers?: Map<string, number>` field (filepath -> tier number). Update `MergedRun` to include per-file resolution detail | 2h | MQ-T038 | `src/orchestrator/types.ts` | [ ] |
| MQ-T041 | Write integration tests for per-file cascade -- multi-file conflict where file A resolves at Tier 2, file B at Tier 3, file C at Tier 4; single file reaching Fallback aborts all; `resolvedTiers` map populated correctly | 5h | MQ-T038, MQ-T039 | `src/orchestrator/__tests__/conflict-resolver-cascade.test.ts` | [ ] |

#### Story 4.2: Post-Merge Validation

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| MQ-T042 | Implement post-merge test runner in ConflictResolver: run test suite via `runTestCommand()` only when AI resolution was used (Tier 3/4) -- skip tests for clean merges (Tier 1) and auto-resolved merges (Tier 2). On failure: record AI-resolved files to conflict_patterns with `post_merge_test_failure`, `git reset --hard HEAD~1`, escalate to PR via `git town propose`, update queue entry to `conflict` with MQ-007. `--no-tests` flag overrides to skip entirely | 4h | MQ-T038 | `src/orchestrator/conflict-resolver.ts` | [ ] |
| MQ-T043 | Write tests for post-merge validation -- tests skipped for Tier 1/2 merges, tests run for Tier 3/4 merges, test pass continues, test fail triggers reset + PR + pattern recording, reset is safe (local unpushed commit), `--no-tests` override works | 4h | MQ-T042 | `src/orchestrator/__tests__/conflict-resolver-postmerge.test.ts` | [ ] |

#### Story 4.3: Event Logging with Error Codes

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| MQ-T044 | Add `EventType` entries for merge queue events: `merge-queue-enqueue`, `merge-queue-dequeue`, `merge-queue-resolve`, `merge-queue-fallback`. Update store.ts `EventType` union | 2h | -- | `src/lib/store.ts`, `src/orchestrator/types.ts` | [ ] |
| MQ-T045 | Wire structured error codes (MQ-001 through MQ-020) into all ConflictResolver and MergeQueue error paths. Log to events table with `details` JSON containing `errorCode`, `filePath`, `tier`, `reason` | 3h | MQ-T044, MQ-T038 | `src/orchestrator/conflict-resolver.ts`, `src/orchestrator/merge-queue.ts` | [ ] |
| MQ-T046 | Write tests for event logging -- each error code path produces correct event with structured details | 3h | MQ-T045 | `src/orchestrator/__tests__/merge-events.test.ts` | [ ] |

### 2.5 Sprint 5: Overlap Clustering for Sequential Ordering (FR-3 Part 2)

#### Story 5.1: Conflict Clustering

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| MQ-T047 | Implement `ConflictCluster` module: `buildOverlapGraph(entries)` creates adjacency list from `files_modified` overlap. `findClusters(graph)` returns connected components using BFS/DFS. Each cluster is a set of queue entry IDs. Used for smart sequential ordering: process entries within the same cluster consecutively to minimize re-merge conflicts | 4h | -- | `src/orchestrator/conflict-cluster.ts` | [ ] |
| MQ-T048 | Implement `reCluster(entries, mergedFiles)` -- after a merge commit, re-evaluate remaining entries for new overlaps with the merged files. Return updated cluster assignments for the sequential dequeue loop | 2h | MQ-T047 | `src/orchestrator/conflict-cluster.ts` | [ ] |
| MQ-T049 | Wire cluster ordering into MergeQueue dequeue: before processing, build overlap graph and order entries so that entries within the same cluster are processed consecutively (reducing conflict likelihood). Re-cluster after each merge commit | 2h | MQ-T047, MQ-T048, MQ-T018 | `src/orchestrator/merge-queue.ts` | [ ] |
| MQ-T050 | Write tests for clustering -- independent entries in separate clusters, overlapping entries in same cluster, re-clustering after merge creates new overlaps, empty queue, single entry, cluster-ordered sequential dequeue | 4h | MQ-T047, MQ-T048, MQ-T049 | `src/orchestrator/__tests__/conflict-cluster.test.ts` | [ ] |

### 2.6 Sprint 6: Worktree Commands, Dry-Run, Seeds Preservation (FR-5, FR-8, FR-6)

#### Story 6.1: Worktree CLI Commands

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| MQ-T054 | Implement `foreman worktree list` -- list all `foreman/*` worktrees with branch, path, run status (from store), seed ID, age. Support `--json` for structured output | 3h | -- | `src/cli/commands/worktree.ts` | [ ] |
| MQ-T055 | Implement `foreman worktree clean` -- remove worktrees for completed/merged/failed runs (default). `--all` removes active worktrees too. `--force` uses safe branch deletion with force. Show summary with count and freed space | 3h | MQ-T004, MQ-T054 | `src/cli/commands/worktree.ts` | [ ] |
| MQ-T056 | Register worktree subcommand in main CLI entry point | 1h | MQ-T054 | `src/cli/index.ts` |  [ ] |
| MQ-T057 | Write tests for worktree commands -- list with various run states, clean respects active agents, force deletion, JSON output valid | 4h | MQ-T054, MQ-T055 | `src/cli/__tests__/worktree.test.ts` | [ ] |

#### Story 6.2: Merge Dry-Run Mode

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| MQ-T058 | Implement `foreman merge --dry-run`: for each queued/completed branch, show branch name, seed ID, `git diff --stat` output, conflict detection via `git merge-tree`. Support `--seed <id>` filter. No git state modification | 4h | MQ-T008 | `src/cli/commands/merge.ts`, `src/orchestrator/merge-queue.ts` | [ ] |
| MQ-T058b | Retrofit `Refinery.createPRs()` (happy-path PRs) to use `git town propose` instead of `gh pr create`. Keep `createPrForConflict()` using `gh pr create` since conflict PRs need custom title/body with resolution metadata. Add `MQ-T058d` investigation results for URL parsing | 3h | MQ-T058d | `src/orchestrator/refinery.ts` | [ ] |
| MQ-T058c | Write tests for dual PR creation strategy -- `git town propose` called for normal PRs, `gh pr create` called for conflict PRs with custom title/body, error handling for git-town failures, PR URL correctly extracted from both paths | 3h | MQ-T058b | `src/orchestrator/__tests__/refinery-git-town.test.ts` | [ ] |
| MQ-T058d | Investigate `git town propose` stdout format for PR URL extraction: run `git town propose` on a test branch, capture output, determine if URL is reliably parseable. If not, implement fallback via `gh pr list --head <branch> --json url` after propose. Document findings in code comments | 1h | -- | `src/orchestrator/refinery.ts` | [ ] |
| MQ-T059 | Add estimated resolution tier column when FR-7 conflict_patterns data is available. Gracefully omit column when no pattern data exists (no errors, no empty columns) | 2h | MQ-T058 | `src/cli/commands/merge.ts` | [ ] |
| MQ-T060 | Write tests for dry-run -- no git state modified, conflict detection accurate, `--seed` filter works, graceful degradation without FR-7 data | 3h | MQ-T058, MQ-T059 | `src/cli/__tests__/merge-dryrun.test.ts` | [ ] |

#### Story 6.3: Seeds Preservation

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| MQ-T061 | Implement `preserveSeedChanges(branchName, targetBranch)` in refinery.ts: extract `.seeds/` changes via `git diff {target}...{branch} -- .seeds/`, write temp patch, `git apply --index`, commit with descriptive message. Cleanup temp file in `finally` block. Error code MQ-019 on patch failure | 3h | -- | `src/orchestrator/refinery.ts` | [ ] |
| MQ-T062 | Wire seed preservation into branch cleanup paths (refinery merge failure, worktree clean) -- call before branch deletion | 2h | MQ-T061 | `src/orchestrator/refinery.ts`, `src/cli/commands/worktree.ts` | [ ] |
| MQ-T063 | Write tests for seeds preservation -- changes applied, only .seeds/ preserved, patch failure logs warning but does not block, temp file always cleaned | 3h | MQ-T061 | `src/orchestrator/__tests__/refinery-seeds-preserve.test.ts` | [ ] |

### 2.7 Sprint 7: Pattern Learning and Cost Tracking (FR-7, Cost Tracking)

#### Story 7.1: Conflict Pattern Learning

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| MQ-T064 | Add `conflict_patterns` table migration to store.ts | 1h | -- | `src/lib/store.ts` | [ ] |
| MQ-T065 | Implement `ConflictPatterns` class: `recordOutcome(filePath, extension, tier, success, failureReason?, mergeQueueId?, seedId?)` -- fire-and-forget recording. `shouldSkipTier(extension, tier)` -- return true if >= 2 failures AND 0 successes. `getSuccessContext(extension, tier)` -- return past successful resolution examples as AI context | 4h | MQ-T064 | `src/orchestrator/conflict-patterns.ts` | [ ] |
| MQ-T066 | Implement post-merge test failure pattern recording: when test fails, record all AI-resolved files with `failure_reason='post_merge_test_failure'`. `shouldPreferFallback(filePath)` returns true if file has >= 2 post-merge test failures with AI resolution | 3h | MQ-T065 | `src/orchestrator/conflict-patterns.ts` | [ ] |
| MQ-T067 | Wire ConflictPatterns into ConflictResolver: before each tier attempt call `shouldSkipTier()` (MQ-015), before AI calls check `shouldPreferFallback()` (MQ-016), after each attempt call `recordOutcome()`, pass `getSuccessContext()` to Tier 3/4 prompts | 3h | MQ-T065, MQ-T066, MQ-T038 | `src/orchestrator/conflict-resolver.ts` | [ ] |
| MQ-T068 | Write tests for pattern learning -- outcome recording, tier skip after threshold, success context provided, test failure recording, fallback preference, fire-and-forget (errors do not block) | 5h | MQ-T065, MQ-T066, MQ-T067 | `src/orchestrator/__tests__/conflict-patterns.test.ts` | [ ] |

#### Story 7.2: Cost Tracking and Stats

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| MQ-T069 | Add `merge_costs` table migration to store.ts | 1h | -- | `src/lib/store.ts` | [ ] |
| MQ-T070 | Implement cost recording in ConflictResolver: after each Tier 3/4 SDK call, insert row to `merge_costs` with session_id, file, tier, model, tokens, estimated and actual cost. Fire-and-forget | 3h | MQ-T069, MQ-T032 | `src/orchestrator/conflict-resolver.ts` | [ ] |
| MQ-T071 | Implement `foreman merge --stats`: query `merge_costs` for daily, weekly, monthly, all-time summaries with tier and model breakdowns. Support `--json` output | 4h | MQ-T069 | `src/cli/commands/merge.ts`, `src/orchestrator/merge-queue.ts` | [ ] |
| MQ-T072 | Implement running success rate display after each `foreman merge` invocation: "AI resolution rate: X/Y conflicts (Z%) over last 30 days" with tier breakdown and session cost | 2h | MQ-T070 | `src/cli/commands/merge.ts` | [ ] |
| MQ-T073 | Write tests for cost tracking -- recording accuracy, stats query aggregation, JSON output valid, running success rate calculation | 4h | MQ-T070, MQ-T071, MQ-T072 | `src/orchestrator/__tests__/merge-costs.test.ts` | [ ] |

### 2.8 Sprint 8: Health Checks, Edge Cases, Polish (FR-9, FR-10)

#### Story 8.1: Untracked File Conflict Prevention

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| MQ-T074 | Implement untracked file detection before merge: get added files via `git diff --name-only --diff-filter=A`, check for untracked overlap. Default: delete with warning. `--stash-untracked` moves to `.foreman/stashed/`. `--abort-on-untracked` aborts with error. Error code MQ-014 | 3h | -- | `src/orchestrator/conflict-resolver.ts` | [ ] |
| MQ-T075 | Write tests for untracked file handling -- detection, default delete, stash to recovery dir, abort mode with clear listing | 3h | MQ-T074 | `src/orchestrator/__tests__/conflict-resolver-untracked.test.ts` | [ ] |

#### Story 8.2: Merge Queue Health Checks

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| MQ-T076 | Extend `Doctor` class with merge queue checks: stale pending entries (>24h, MQ-008), duplicate branch entries (MQ-009), orphaned entries referencing non-existent runs (MQ-010) | 3h | MQ-T008 | `src/orchestrator/doctor.ts` | [ ] |
| MQ-T077 | Implement `--fix` auto-resolution for merge queue health issues: delete stale entries and reset run status, keep max(id) for duplicates, delete orphaned entries | 2h | MQ-T076 | `src/orchestrator/doctor.ts` | [ ] |
| MQ-T078 | Write tests for merge queue health checks -- detection and fix for each condition, integration with existing DoctorReport format | 3h | MQ-T076, MQ-T077 | `src/orchestrator/__tests__/doctor-merge-queue.test.ts` | [ ] |

#### Story 8.3: Auto-Commit State Files Hardening (MQ-020)

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| MQ-T079 | Add error code MQ-020 handling to `autoCommitStateFiles()` -- log structured error when auto-commit fails, do not block merge | 1h | MQ-T001 | `src/orchestrator/refinery.ts` | [ ] |

---

## 3. Sprint Planning Summary

| Sprint | Focus | Tasks | Est. Hours | Key Deliverables |
|--------|-------|-------|-----------|-----------------|
| 1 | Foundation | MQ-T001 to MQ-T006 | 16h | Auto-commit state files, safe branch deletion |
| 2 | Merge Queue Core | MQ-T007 to MQ-T020 (excl. MQ-T014/T015), MQ-T018b | 37h | SQLite queue, config loader, auto-enqueue, CLI integration, Refinery thin-wrapper migration |
| 3a | Deterministic Resolution | MQ-T021 to MQ-T029 | 30h | MergeValidator, Tier 1-2 resolution with dual-check gate |
| 3b | AI-Powered Resolution | MQ-T030 to MQ-T037 | 26h | Tier 3 (Sonnet) and Tier 4 (Opus) via Messages API, cost tracking |
| 4 | Resolution Orchestration | MQ-T038 to MQ-T046 | 31h | Per-file cascade orchestration, post-merge validation (AI-only), event logging |
| 5 | Overlap Clustering | MQ-T047 to MQ-T050 | 12h | Conflict clustering for smart sequential ordering |
| 6 | Worktree/DryRun/Seeds/git-town | MQ-T054 to MQ-T063, MQ-T058b/c/d | 37h | Worktree CLI, dry-run preview, seeds preservation, dual PR strategy retrofit |
| 7 | Learning and Costs | MQ-T064 to MQ-T073 | 27h | Pattern learning, cost tracking, stats command |
| 8 | Polish | MQ-T074 to MQ-T079 | 15h | Untracked file prevention, queue health checks |

**Total: 79 tasks, ~231 estimated hours across 9 sprints**

---

## 4. Dependency Graph

```
Sprint 1 (Foundation)
  MQ-T001 -> MQ-T002 -> MQ-T003
  MQ-T004 -> MQ-T005 -> MQ-T006

Sprint 2 (Queue Core + Refinery Migration) -- depends on Sprint 1 for safe deletion
  MQ-T007 -> MQ-T008 -> MQ-T009 -> MQ-T011
  MQ-T007 -> MQ-T010
  MQ-T012 -> MQ-T013
  MQ-T008 -> MQ-T016 -> MQ-T017
  MQ-T008, MQ-T009 -> MQ-T018 -> MQ-T018b -> MQ-T020
  MQ-T008 -> MQ-T019

Sprint 3a (Deterministic Resolution) -- depends on MQ-T012
  MQ-T012 -> MQ-T021 -> MQ-T025
  MQ-T012 -> MQ-T022 -> MQ-T025
  MQ-T023 -> MQ-T025
  MQ-T024 -> MQ-T025
  MQ-T026 -> MQ-T027 -> MQ-T029
  MQ-T026 -> MQ-T028

  *** QUALITY GATE: Sprint 3a complete before 3b starts ***

Sprint 3b (AI-Powered Resolution) -- depends on Sprint 3a
  MQ-T026 -> MQ-T030 -> MQ-T031 -> MQ-T033
  MQ-T030 -> MQ-T032 -> MQ-T033
  MQ-T026 -> MQ-T034 -> MQ-T035 -> MQ-T037
  MQ-T034 -> MQ-T036 -> MQ-T037

Sprint 4 (Resolution Orchestration) -- depends on Sprint 3b
  MQ-T027, MQ-T030, MQ-T034 -> MQ-T038 -> MQ-T039 -> MQ-T041
  MQ-T038 -> MQ-T040
  MQ-T038 -> MQ-T042 -> MQ-T043
  MQ-T044 -> MQ-T045 -> MQ-T046

Sprint 5 (Clustering) -- depends on MQ-T018
  MQ-T047 -> MQ-T048 -> MQ-T049 -> MQ-T050
  MQ-T049 depends on MQ-T018

Sprint 6 (Worktree/DryRun/Seeds/git-town) -- independent, can parallelize with Sprint 5
  MQ-T054 -> MQ-T055 -> MQ-T057
  MQ-T054 -> MQ-T056
  MQ-T008 -> MQ-T058 -> MQ-T059 -> MQ-T060
  MQ-T058d -> MQ-T058b -> MQ-T058c (git-town investigation then retrofit)
  MQ-T061 -> MQ-T062 -> MQ-T063

Sprint 7 (Patterns/Costs) -- depends on Sprint 4
  MQ-T064 -> MQ-T065 -> MQ-T066 -> MQ-T067 -> MQ-T068
  MQ-T069 -> MQ-T070 -> MQ-T071 -> MQ-T073
  MQ-T070 -> MQ-T072 -> MQ-T073

Sprint 8 (Polish) -- depends on Sprint 2
  MQ-T074 -> MQ-T075
  MQ-T008 -> MQ-T076 -> MQ-T077 -> MQ-T078
  MQ-T001 -> MQ-T079
```

### Parallelization Opportunities

- Sprint 1: Stories 1.1 and 1.2 can run in parallel (no dependencies between them)
- Sprint 3a: Story 3.1 (Validator) and Story 3.2 (Tier 1-2) can start in parallel since validator is only needed for Tier 3+
- Sprint 3b: Stories 3.3 (Tier 3) and 3.4 (Tier 4) can start in parallel since they are independent resolution paths
- Sprint 5 and Sprint 6 can run in parallel (independent feature sets)
- Sprint 6: git-town investigation (MQ-T058d) should start early as it may affect MQ-T058b implementation
- Sprint 7 and Sprint 8 can run in parallel after Sprint 4 is complete

---

## 5. Acceptance Criteria (Technical Validation)

### 5.1 FR-1: AI-Powered Conflict Resolution

- [ ] AC-1.1: Clean merges complete without invoking any resolution tier
- [ ] AC-1.2: Tier 2 per-file auto-resolve succeeds only when BOTH checks pass: hunk verification AND threshold guard
- [ ] AC-1.3: Tier 2 dual-check gate applies per-file; true semantic conflicts (missing target hunks) always cascade to Tier 3; files exceeding threshold (>20 lines OR >30%) cascade independently even if hunk verification passes
- [ ] AC-1.4: Tier 3 resolves non-overlapping changes in same file
- [ ] AC-1.5: Tier 3/4 rejects prose output using language-aware heuristic
- [ ] AC-1.6: Syntax validation uses configurable checker map; unmapped extensions accepted
- [ ] AC-1.7: Tier 4 reimplements branch changes onto canonical
- [ ] AC-1.8: Tier 3 uses Sonnet; Tier 4 uses Opus
- [ ] AC-1.9: Each tier outcome recorded per-file in events table
- [ ] AC-1.10: MergeReport extended with per-file `resolvedTiers` map
- [ ] AC-1.11: All Tier 3/4 AI calls use Anthropic `messages.create()` (single-turn, no tools) -- not the Agent SDK `query()`
- [ ] AC-1.12: Files exceeding size gate skip AI resolution
- [ ] AC-1.13: AI stops when per-session budget exhausted (soft enforcement)
- [ ] AC-1.14: Full test suite runs after merge commits involving AI resolution (Tier 3/4); skipped for clean merges (Tier 1) and auto-resolved merges (Tier 2); failure triggers reset + PR
- [ ] AC-1.15: Fallback/conflict PR creation uses `gh pr create` with custom title/body containing tier attempts and error details; normal-flow PRs use `git town propose`
- [ ] AC-1.16: Each file independently progresses through tiers
- [ ] AC-1.17: If any file reaches Fallback, entire merge escalates to PR
- [ ] AC-1.18: Merge commits preserve two-parent topology
- [ ] AC-1.19: Actual AI costs tracked from SDK response metadata
- [ ] AC-1.20: Syntax checker map configurable in `.foreman/config.json`
- [ ] AC-1.21: Prose detection uses language-aware first-line heuristic
- [ ] AC-1.22: Prose detection patterns extensible via config
- [ ] AC-1.23: All failures produce structured error codes (MQ-xxx)

### 5.2 FR-2: Auto-Commit State Files

- [ ] AC-2.1: Uncommitted `.seeds/` changes auto-committed before merge
- [ ] AC-2.2: Uncommitted `.foreman/` changes auto-committed before merge
- [ ] AC-2.3: No commit when state files have no changes
- [ ] AC-2.4: Auto-commit uses distinguishable commit message
- [ ] AC-2.5: Works on both target branch and feature branch

### 5.3 FR-3: Persistent Merge Queue

- [ ] AC-3.1: Queue persists across CLI invocations
- [ ] AC-3.2: Concurrent agents enqueue without conflicts (WAL + busy timeout)
- [ ] AC-3.3: Dequeue is atomic (no double-processing)
- [ ] AC-3.4: Queue entries record resolution tier
- [ ] AC-3.5: `--list` shows entries with status, branch, seed, age
- [ ] AC-3.6: Migration adds table without affecting existing data
- [ ] AC-3.7: Agent finalize auto-enqueues completed branches
- [ ] AC-3.8: Reconciliation detects and enqueues missed runs (validates branch existence)
- [ ] AC-3.9: Enqueue is idempotent
- [ ] AC-3.10: Overlap-aware ordering groups entries by file overlap into conflict clusters for smart sequential processing
- [ ] AC-3.11: Reconciliation skips deleted branches with log message
- [ ] AC-3.12: Entries within the same conflict cluster are processed consecutively in FIFO order
- [ ] AC-3.13: After each merge, remaining entries re-evaluated for new overlaps with merged files
- [ ] AC-3.14: Queue is the only merge path -- no legacy mode, `reconcile()` handles backward compatibility
- [ ] AC-3.15: `Refinery` class preserved as thin wrapper -- public API unchanged, internals delegate to `MergeQueue` and `ConflictResolver`
- [ ] AC-3.16: All existing callers of `Refinery` methods continue to work without modification

### 5.4 FR-4: Safe Branch Deletion

- [ ] AC-4.1: Merged branches deleted with `git branch -d`
- [ ] AC-4.2: Unmerged branches NOT deleted without `--force`
- [ ] AC-4.3: Warning logged for unmerged delete attempt without force
- [ ] AC-4.4: Force-deleted unmerged branches produce warning
- [ ] AC-4.5: Not-found branches handled gracefully
- [ ] AC-4.6: Refinery and reset updated to use new API

### 5.5 FR-5: Worktree Commands

- [ ] AC-5.1: `worktree list` shows all foreman/* worktrees with metadata
- [ ] AC-5.2: `worktree list --json` outputs valid JSON
- [ ] AC-5.3: `worktree clean` removes only completed/merged/failed worktrees
- [ ] AC-5.4: `worktree clean --all` removes all foreman worktrees
- [ ] AC-5.5: `worktree clean` respects safe branch deletion
- [ ] AC-5.6: Active agent worktrees not cleaned unless `--all`

### 5.6 FR-6: Seeds Preservation

- [ ] AC-6.1: Seed changes from non-merged branches applied to target
- [ ] AC-6.2: Only `.seeds/` changes preserved
- [ ] AC-6.3: Failed patch logs warning, does not block cleanup
- [ ] AC-6.4: Temp patch file always cleaned up

### 5.7 FR-7: Conflict Pattern Learning

- [ ] AC-7.1: Each resolution attempt recorded with file, tier, outcome
- [ ] AC-7.2: Tiers with >= 2 failures and 0 successes skipped
- [ ] AC-7.3: Past successful resolutions provided as AI context
- [ ] AC-7.4: Pattern recording never blocks merge
- [ ] AC-7.5: Pattern data persists in SQLite
- [ ] AC-7.6: Post-merge test failures record all AI-resolved files
- [ ] AC-7.7: Files with >= 2 test failure records prefer Fallback

### 5.8 FR-8: Dry-Run Mode

- [ ] AC-8.1: `--dry-run` shows branch, files, conflict status without modifying tree
- [ ] AC-8.2: Conflict detection accurate
- [ ] AC-8.3: Works with `--seed <id>` filter
- [ ] AC-8.4: No git state modified during dry-run
- [ ] AC-8.5: Shows estimated tier when FR-7 data available
- [ ] AC-8.6: Gracefully degrades when FR-7 unavailable

### 5.9 FR-9: Untracked File Prevention

- [ ] AC-9.1: Untracked file conflicts detected before merge
- [ ] AC-9.2: Default behavior removes with warning
- [ ] AC-9.3: Stash option preserves to `.foreman/stashed/`
- [ ] AC-9.4: Abort option provides clear error listing

### 5.10 FR-10: Queue Health Checks

- [ ] AC-10.1: Detects stale pending/merging entries >24h
- [ ] AC-10.2: Detects duplicate branch entries
- [ ] AC-10.3: `--fix` auto-resolves stale and duplicate entries
- [ ] AC-10.4: Integrates into existing DoctorReport format

### 5.11 Cost Tracking

- [ ] AC-COST.1: Every AI call records actual cost to `merge_costs`
- [ ] AC-COST.2: `--stats` shows daily/weekly/monthly/all-time summaries
- [ ] AC-COST.3: Cost breakdown by tier and model available
- [ ] AC-COST.4: `--stats --json` outputs valid JSON
- [ ] AC-COST.5: Cost tracking is fire-and-forget

---

## 6. Quality Requirements

### 6.1 Testing Standards

| Type | Target | Notes |
|------|--------|-------|
| Unit test coverage | >= 80% | All new modules must have co-located `__tests__/` |
| Integration test coverage | >= 70% | Queue flow, cascade resolution, CLI commands |
| Test framework | Vitest | Co-located in `__tests__/` subdirectories per CLAUDE.md |

### 6.2 Code Quality

- TypeScript strict mode -- no `any` escape hatches
- ESM only -- all imports use `.js` extensions
- TDD methodology -- RED-GREEN-REFACTOR for all coding tasks
- Non-interactive commands -- all git/shell commands must be non-interactive (`cp -f`, `mv -f`, etc.)
- Input validation at boundaries only

### 6.3 Performance Targets

| Operation | Target | Task Reference |
|-----------|--------|----------------|
| Queue enqueue | < 50ms | MQ-T008 |
| Queue dequeue (atomic) | < 100ms | MQ-T008 |
| Tier 1-2 resolution | < 5s per branch | MQ-T026, MQ-T027 |
| Tier 3 AI resolution | < 60s per file | MQ-T030 |
| Tier 4 AI reimagine | < 120s per file | MQ-T034 |
| Syntax check | < 15s per file | MQ-T022 |
| Dry-run preview | < 10s for 10 branches | MQ-T058 |

### 6.4 Security

- No secrets in code -- Claude API keys via env vars
- Non-interactive shell commands only (agent constraint)
- SQLite WAL mode with busy timeout for concurrent access
- Cost controls prevent runaway AI spending (per-session budget cap)

### 6.5 Compatibility

- Backward compatible with existing `store.ts` migration pattern
- `reconcile()` provides backward compatibility by detecting completed runs not yet in the queue
- New merge queue tables use `CREATE TABLE IF NOT EXISTS`
- All new column migrations use idempotent `ALTER TABLE ... ADD COLUMN`
- git-town integration for branch lifecycle and PR creation

---

## 7. Risk Register

| Risk | Likelihood | Impact | Mitigation | Tasks Affected |
|------|-----------|--------|------------|---------------|
| AI produces invalid code | Medium | High | Multi-layer validation (MergeValidator), full test suite post-merge | MQ-T030 to MQ-T037 |
| Cost escalation | Low | Medium | Per-session budget cap, per-file size gate, pattern learning skips | MQ-T032, MQ-T052, MQ-T067 |
| Concurrent merge corruption | Low | High | SQLite WAL + atomic dequeue, sequential processing | MQ-T008, MQ-T010 |
| Migration breaks existing store | Low | High | Idempotent migrations, no destructive changes | MQ-T007, MQ-T064, MQ-T069 |
| Post-merge test failure blocks pipeline | Medium | Medium | `git reset --hard HEAD~1` + PR escalation, continue with next entry | MQ-T042 |
| `tsc --noEmit` slow on large projects | Medium | Low | 15s timeout per file, configurable checker map | MQ-T022 |

---

## 8. Files Modified/Created Summary

### New Files

| File | Sprint | Tasks |
|------|--------|-------|
| `src/orchestrator/merge-queue.ts` | 2 | MQ-T008, MQ-T009 |
| `src/orchestrator/merge-config.ts` | 2 | MQ-T012 |
| `src/orchestrator/conflict-resolver.ts` | 3-4 | MQ-T026 to MQ-T042 |
| `src/orchestrator/merge-validator.ts` | 3 | MQ-T021 to MQ-T024 |
| `src/orchestrator/conflict-cluster.ts` | 5 | MQ-T047, MQ-T048 |
| `src/orchestrator/conflict-patterns.ts` | 7 | MQ-T065, MQ-T066 |
| `src/cli/commands/worktree.ts` | 6 | MQ-T054, MQ-T055 |

### Modified Files

| File | Sprint | Tasks | Changes |
|------|--------|-------|---------|
| `src/lib/store.ts` | 2, 7 | MQ-T007, MQ-T010, MQ-T044, MQ-T064, MQ-T069 | Schema migrations for merge_queue, conflict_patterns, merge_costs tables; EventType additions; busy timeout |
| `src/lib/git.ts` | 1 | MQ-T004 | `deleteBranch()` API change to safe deletion with options |
| `src/orchestrator/refinery.ts` | 1, 2, 6 | MQ-T001, MQ-T002, MQ-T005, MQ-T018, MQ-T018b, MQ-T058b, MQ-T061, MQ-T062 | Auto-commit state files, safe deletion calls, thin-wrapper migration, git-town PR retrofit, seed preservation |
| `src/orchestrator/agent-worker.ts` | 2 | MQ-T016 | Auto-enqueue in finalize phase |
| `src/orchestrator/types.ts` | 4 | MQ-T040, MQ-T044 | Extended MergeReport, new EventType values |
| `src/cli/commands/merge.ts` | 2, 6, 7 | MQ-T018, MQ-T019, MQ-T058, MQ-T071, MQ-T072 | Queue-based flow, dry-run, stats |
| `src/cli/commands/reset.ts` | 1 | MQ-T005 | Safe deletion API update |
| `src/orchestrator/doctor.ts` | 8 | MQ-T076, MQ-T077 | Merge queue health checks |
| `src/cli/index.ts` | 6 | MQ-T056 | Register worktree subcommand |

### Test Files (all new)

| File | Sprint | Tasks |
|------|--------|-------|
| `src/orchestrator/__tests__/refinery-state-files.test.ts` | 1 | MQ-T003 |
| `src/lib/__tests__/git-delete-branch.test.ts` | 1 | MQ-T006 |
| `src/orchestrator/__tests__/merge-queue.test.ts` | 2 | MQ-T011 |
| `src/orchestrator/__tests__/merge-config.test.ts` | 2 | MQ-T013 |
| `src/orchestrator/__tests__/agent-worker-enqueue.test.ts` | 2 | MQ-T017 |
| `src/cli/__tests__/merge-queue-flow.test.ts` | 2 | MQ-T020 |
| `src/orchestrator/__tests__/merge-validator.test.ts` | 3 | MQ-T025 |
| `src/orchestrator/__tests__/conflict-resolver-t1.test.ts` | 3 | MQ-T028 |
| `src/orchestrator/__tests__/conflict-resolver-t2.test.ts` | 3 | MQ-T029 |
| `src/orchestrator/__tests__/conflict-resolver-t3.test.ts` | 3 | MQ-T033 |
| `src/orchestrator/__tests__/conflict-resolver-t4.test.ts` | 3 | MQ-T037 |
| `src/orchestrator/__tests__/conflict-resolver-cascade.test.ts` | 4 | MQ-T041 |
| `src/orchestrator/__tests__/conflict-resolver-postmerge.test.ts` | 4 | MQ-T043 |
| `src/orchestrator/__tests__/merge-events.test.ts` | 4 | MQ-T046 |
| `src/orchestrator/__tests__/conflict-cluster.test.ts` | 5 | MQ-T050 |
| `src/cli/__tests__/worktree.test.ts` | 6 | MQ-T057 |
| `src/cli/__tests__/merge-dryrun.test.ts` | 6 | MQ-T060 |
| `src/orchestrator/__tests__/refinery-seeds-preserve.test.ts` | 6 | MQ-T063 |
| `src/orchestrator/__tests__/refinery-git-town.test.ts` | 6 | MQ-T058c |
| `src/orchestrator/__tests__/conflict-patterns.test.ts` | 7 | MQ-T068 |
| `src/orchestrator/__tests__/merge-costs.test.ts` | 7 | MQ-T073 |
| `src/orchestrator/__tests__/conflict-resolver-untracked.test.ts` | 8 | MQ-T075 |
| `src/orchestrator/__tests__/doctor-merge-queue.test.ts` | 8 | MQ-T078 |

---

## 9. Definition of Done

A task is considered complete when:

1. Implementation follows TypeScript strict mode (no `any`)
2. All imports use `.js` extensions (ESM)
3. TDD cycle completed (test written first, implementation makes it pass, refactored)
4. Unit tests pass with >= 80% coverage for the touched module
5. `npx tsc --noEmit` passes with zero errors
6. `npm test` passes (full suite)
7. Non-interactive commands only (no `-i` flags)
8. Error codes used for all failure paths (MQ-xxx)
9. Events logged for observable operations
10. Git commit with descriptive message referencing task ID

---

## 10. Future Work

The following items were considered for v1.0 but deferred to reduce scope and complexity. They can be implemented as follow-up epics once the core merge queue is stable.

### 10.1 Parallel Merge Processing (`--parallel N`)

Enable concurrent processing of independent conflict clusters to speed up batch merges with AI resolution.

**Deferred tasks:**

| ID | Task | Est. | Description |
|----|------|------|-------------|
| FW-T001 | Add `--parallel N` flag to `foreman merge` CLI. Default N=1 (sequential). Implement worker pool that processes independent clusters concurrently, with sequential git commit via mutex | 5h | Requires cluster module from Sprint 5 |
| FW-T002 | Implement re-clustering cancellation: when a merge commit triggers re-clustering that invalidates an in-progress AI resolution, cancel the work and re-queue the entry | 4h | Ensures correctness under concurrent cluster changes |
| FW-T003 | Implement optimistic budget tracking for parallel mode: each worker tracks independently, session total may slightly exceed cap | 2h | Trades precision for simplicity |
| FW-T004 | Write tests for parallel processing -- independent clusters processed concurrently, sequential commit ordering, re-clustering cancellation, budget tracking approximate | 5h | Integration tests for parallel paths |

**Estimated total: 16h**

**Prerequisites:** Sprint 5 (conflict clustering) must be complete. The sequential cluster ordering implemented in v1.0 provides the foundation for parallel processing -- clusters that are already identified can be farmed out to parallel workers instead of processed sequentially.

**Design notes:**
- AI resolution work (Tier 3/4) runs in parallel across entries in different clusters
- Git merge commits are strictly sequential via mutex -- only one merge commit at a time on the target branch
- Within a cluster, entries are processed sequentially in FIFO order
- Recommended max: `--parallel 4` (diminishing returns beyond this due to sequential commit bottleneck)
- Budget tracking in parallel mode is optimistic/approximate to avoid shared-lock latency on every AI call
- Add `"parallel": 1` to `.foreman/config.json` `mergeQueue` section as configurable default

---

## 11. Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-03-12 | Initial TRD creation from PRD-MERGE-QUEUE v5.0 |
| 1.1 | 2026-03-12 | Refinement pass incorporating user interview feedback: (1) All PR creation paths use `git town propose` instead of `gh pr create`, including retrofit of existing `refinery.ts` -- added MQ-T058b/MQ-T058c; (2) Tier 2 replaced blanket `git checkout --theirs` with 3-way diff hunk verification that confirms target-side hunks are already incorporated in branch version before accepting -- updated MQ-T027/MQ-T029; (3) Parallel worker pool (4 tasks, 16h) deferred to Future Work section, conflict clustering retained for smart sequential ordering -- Sprint 5 restructured; (4) Tier 3/4 AI calls changed from Claude Agent SDK `query()` to Anthropic Messages API `messages.create()` for single-turn, no-tool conflict resolution -- updated MQ-T030/MQ-T032/MQ-T034/MQ-T036; (5) Legacy mode gate removed entirely (MQ-T014/MQ-T015 deleted) -- queue path is the only path from day one with `reconcile()` handling backward compatibility; (6) Post-merge test execution limited to AI-resolved merges (Tier 3/4) only, skipped for clean merges (Tier 1) and auto-resolved merges (Tier 2) -- updated MQ-T042/MQ-T043; (7) Worktree commands confirmed for v1.0 scope. Net result: 75 tasks, ~212 estimated hours (reduced from 79 tasks, ~225h). |
| 1.2 | 2026-03-13 | Second refinement pass (polish): (1) Tier 2 dual-check gate clarified -- BOTH hunk verification AND threshold guard must pass for Tier 2 success; true semantic conflicts (missing target hunks) always cascade to Tier 3 -- updated MQ-T027/MQ-T029/AC-1.2/AC-1.3; (2) PR creation strategy refined to dual approach -- `git town propose` for happy-path PRs, `gh pr create` for conflict PRs needing custom title/body with resolution metadata -- updated MQ-T039/MQ-T058b/AC-1.15, added MQ-T058d for git-town URL investigation; (3) Sprint 3 split into Sprint 3a (deterministic resolution: Validator + Tier 1-2) and Sprint 3b (AI-powered resolution: Tier 3-4) with explicit quality gate between them -- creates natural validation checkpoint before adding AI complexity; (4) Refinery transition strategy: preserve as thin wrapper delegating to MergeQueue and ConflictResolver -- minimizes blast radius for existing callers -- updated MQ-T018, added MQ-T018b for method migration, added AC-3.15/AC-3.16; (5) Architecture overview updated to show Refinery as wrapper in module diagram. Net result: 79 tasks, ~231 estimated hours across 9 sprints. |
