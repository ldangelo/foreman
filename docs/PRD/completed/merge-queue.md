# PRD: Merge Queue Epic

**Document ID:** PRD-MERGE-QUEUE
**Version:** 5.0
**Created:** 2026-03-12
**Last Updated:** 2026-03-12
**Status:** Draft (Final Quality Pass)
**Author:** Product Management
**Epic ID:** bd-uba

---

## 1. Product Summary

### 1.1 Overview

The Merge Queue epic transforms Foreman's merge pipeline from a fragile, inline process into a robust, persistent, AI-powered merge system. The current merge implementation in `src/orchestrator/refinery.ts` handles conflict resolution as a binary choice: auto-resolve report files OR create a PR for manual review. This leaves a wide gap where AI-assisted resolution could automatically handle the majority of code conflicts that currently require human intervention.

This epic introduces a persistent, overlap-aware merge queue backed by SQLite, a 4-tier cascading AI conflict resolution system with per-file tier progression, safe branch lifecycle management, dedicated worktree commands, and conflict pattern learning -- closing the most significant feature gap identified in the Overstory comparison analysis.

### 1.2 Problem Statement

The current Foreman merge pipeline has the following deficiencies:

1. **No persistent queue.** Merge is inline in the Refinery class (`mergeCompleted`). If the process dies mid-merge, state is lost. There is no way to resume or inspect the merge backlog across CLI invocations.

2. **Binary conflict resolution.** The refinery either auto-resolves report files (via `isReportFile` + `checkout --theirs`) or creates a PR for manual review. There is no intermediate AI-assisted resolution step, meaning every real code conflict requires human intervention.

3. **Unsafe branch deletion.** `git.ts:deleteBranch()` unconditionally uses `git branch -D` (force delete), risking loss of unmerged work. There is no merge-status check before deletion.

4. **Incomplete pre-merge state handling.** `mergeWorktree()` stashes uncommitted changes but does not auto-commit known state files (`.seeds/`, `.foreman/`). Uncommitted state file changes cause merge failures or are lost.

5. **No dedicated worktree management.** Worktree cleanup is buried in `doctor --fix` and `reset` commands. Users have no first-class way to inspect or clean worktrees.

6. **No learning from conflicts.** The system retries the same failing strategies on repeated merge attempts. There is no historical record of which resolution tiers succeeded or failed for given file patterns.

7. **No dry-run mode.** Users cannot preview what a merge would do before executing it.

8. **No seed preservation.** When agent branches are not merged (e.g., coordinator/lead branches), seed status changes from those branches are lost.

9. **Untracked file conflicts.** Untracked files in the working tree that overlap with incoming merge files cause git errors and aborts with no recovery.

### 1.3 Current Architecture

```
Refinery.mergeCompleted()
  for each completed run:
    1. removeReportFiles()          -- delete report files pre-merge
    2. git rebase targetBranch      -- rebase branch onto target
       autoResolveRebaseConflicts() -- resolve report-file conflicts only
    3. mergeWorktree()              -- git merge --no-ff
       if conflicts:
         report-only? -> checkout --theirs + commit
         code conflicts? -> merge --abort + createPrForConflict()
    4. archiveReportsPostMerge()    -- move reports to .foreman/reports/
    5. runTestCommand()             -- optional post-merge tests
    6. removeWorktree()             -- cleanup
    7. store.updateRun(merged)      -- mark complete
```

**Key files:**
- `src/orchestrator/refinery.ts` -- Merge logic (706 lines)
- `src/lib/git.ts` -- Git operations including `mergeWorktree`, `deleteBranch`, `removeWorktree`
- `src/lib/store.ts` -- SQLite state store (WAL mode, better-sqlite3)
- `src/cli/commands/merge.ts` -- CLI command
- `src/orchestrator/types.ts` -- MergeReport, ConflictRun, etc.

---

## 2. User Analysis

### 2.1 User Personas

**Persona 1: Solo Developer (Primary)**
- Uses Foreman to parallelize work across 3-8 Claude agents simultaneously
- Runs `foreman merge` after agents complete, expects most merges to "just work"
- Has limited time for manual conflict resolution; wants AI to handle routine conflicts
- Typical workflow: `foreman run` -> wait -> `foreman merge` -> `foreman run` (next batch)

**Persona 2: Team Lead (Secondary)**
- Orchestrates AI-assisted development across a small team (2-5 developers)
- Needs visibility into merge queue state and conflict patterns
- Wants confidence that branch deletion is safe and no work is lost
- Runs merge in batches, reviews results, adjusts priorities

**Persona 3: CI/CD Pipeline (Tertiary)**
- Runs Foreman in automated pipelines (GitHub Actions, Jenkins)
- Requires non-interactive operation (critical constraint: no prompts)
- Needs deterministic behavior: dry-run for validation, clear exit codes
- Merge failures must be surfaced as structured output, not interactive prompts

### 2.2 User Journey (Current vs. Target)

**Current journey (code conflict):**
1. Agent completes work on branch `foreman/abc123`
2. User runs `foreman merge`
3. Merge hits code conflict -> PR created for manual resolution
4. User switches to GitHub, reviews PR, resolves conflicts manually
5. User merges PR on GitHub
6. User returns to terminal, runs `foreman merge` for next batch

**Target journey (code conflict with AI resolution):**
1. Agent completes work on branch `foreman/abc123`
2. Agent finalize phase auto-enqueues branch into merge queue
3. User runs `foreman merge`
4. Reconciliation scan detects any completed runs not yet enqueued (safety net)
5. Merge hits code conflict -> Tier 2 auto-resolve attempted -> fails
6. Tier 3 sends conflict to Claude (Sonnet) for resolution -> succeeds, syntax validated
7. Post-merge test suite passes
8. User sees "Merged 1 task(s), 1 resolved via AI (Tier 3) | AI resolution rate: 12/15 (80%) over last 30 days"

---

## 3. Goals and Non-Goals

### 3.1 Goals

| Goal | Metric | Target |
|------|--------|--------|
| Reduce manual conflict resolution | % of code conflicts resolved without PR | >= 80% |
| Eliminate state file merge failures | Merge failures caused by uncommitted state files | 0 |
| Survive process restarts | Merge queue persists across CLI invocations | 100% |
| Prevent accidental work loss | Unmerged branches deleted without --force | 0 |
| First-class worktree management | Dedicated CLI commands for worktree inspection/cleanup | Available |
| Improve merge observability | Users can preview, inspect, and understand merge operations | Dry-run available |
| Cost-controlled AI resolution | AI resolution cost per merge session stays within budget | Configurable per-session cap |

### 3.2 Non-Goals

- **Real-time collaborative editing / live merge** -- Out of scope; Foreman is batch-oriented
- **Supporting non-git VCS** -- Git is the only supported VCS
- **Replacing git-town** -- Foreman uses git-town for branch management workflow; merge queue complements it (git-town used for ship step and branch lifecycle, direct git for merge internals)
- **Multi-repo merge orchestration** -- Single-repo only for this epic
- **Interactive conflict resolution UI** -- All operations must be non-interactive (agent constraint)
- **Merge across different base branches** -- All merges target a single branch (default: main)

---

## 4. Functional Requirements

### 4.1 P1 -- Critical

#### FR-1: AI-Powered Conflict Resolution (bd-uba.1)

**Description:** Implement a 4-tier cascading conflict resolution system that attempts increasingly sophisticated strategies before falling back to PR creation.

**Tier Cascade (Per-File):**

Each conflicted file independently progresses through the tier cascade. A single merge commit can contain files resolved by different tiers. This maximizes the AI resolution rate by not wasting successful resolutions when one file in a multi-file conflict fails a tier.

| Tier | Strategy | Model | Description | Per-File Fallback Condition |
|------|----------|-------|-------------|-------------------|
| 1 | Clean merge | N/A | `git merge --no-ff --no-edit` | Any conflict |
| 2 | Per-file auto-resolve | N/A | `git checkout --theirs` per file with safety check | Safety check fails for that file |
| 3 | AI resolve | Sonnet | Send conflict markers to Claude SDK, validate output | Validation fails (prose detection, syntax check) |
| 4 | Reimagine | Opus | Get canonical + branch versions, ask Claude to reimplement | Validation fails OR Claude errors |
| Fallback | PR creation | N/A | Push branch, create GitHub PR via git-town | (terminal -- if ANY file reaches fallback, entire merge escalates to PR) |

**Per-File Tier Progression:**
1. Tier 1 attempts a clean merge. If conflicts arise, identify all conflicted files.
2. For each conflicted file independently:
   a. Attempt Tier 2 (auto-resolve with safety check) for that file
   b. If Tier 2 fails for that file, attempt Tier 3 (AI resolve with Sonnet)
   c. If Tier 3 fails for that file, attempt Tier 4 (reimagine with Opus)
   d. If Tier 4 fails for that file, the entire merge escalates to Fallback (PR creation)
3. If all files are resolved (potentially by different tiers), stage all resolutions and create a single merge commit.

**Tier 2 Per-File Safety Check (Configurable Hybrid Threshold):**
- After `git checkout --theirs {filepath}` for a conflicted file, compare the result against the canonical (target branch) version
- Fail the safety check for that file if auto-resolve discarded content exceeding EITHER threshold (whichever triggers first):
  - **Line threshold:** more than N lines of canonical content discarded (default: 20 lines)
  - **Percentage threshold:** more than X% of canonical file content discarded (default: 30%)
- Both thresholds are configurable via `.foreman/config.json`:
  ```json
  {
    "mergeQueue": {
      "tier2SafetyCheck": {
        "maxDiscardedLines": 20,
        "maxDiscardedPercent": 30
      }
    }
  }
  ```
- If safety check fails for a file, that file cascades to Tier 3 (other files that passed Tier 2 remain resolved)

**Tier 3 AI Resolve (Sonnet):**
- Extract conflict markers from each conflicted file using `git diff --name-only --diff-filter=U`
- **File size gate:** Skip AI resolution for files exceeding the configured size limit (default: 1000 lines). Files exceeding the gate cascade directly to Tier 4 or Fallback
- Read the full file content with conflict markers
- Send to Claude SDK (`claude-sonnet-4-6`) with system prompt instructing resolution (code only, no prose)
- Validate output:
  - **Prose detection (language-aware heuristic):** Instead of a hardcoded prefix list, use a language-aware heuristic that checks whether the first non-empty line of output matches a valid code pattern for the file's language. For each file extension, maintain a set of expected first-line patterns:
    - `.ts`/`.js`: Must start with `import`, `export`, `const`, `let`, `var`, `function`, `class`, `interface`, `type`, `enum`, `//`, `/*`, `"use`, `'use`, `{`, `(`, or a valid identifier assignment
    - `.py`: Must start with `import`, `from`, `def`, `class`, `#`, `@`, `if`, `try`, `with`, `"""`, `'''`, or a valid identifier assignment
    - `.go`: Must start with `package`, `import`, `func`, `type`, `var`, `const`, `//`, `/*`
    - Other/unmapped extensions: Fall back to a generic heuristic -- reject if the first line matches common prose patterns (starts with "I ", "Here's", "Let me", "Sure", "The ", "This ", "Below", "Certainly", "Of course", "Note:", "To ", "In order")
    - The language pattern map is extensible via `.foreman/config.json` under `mergeQueue.proseDetection` (see Configuration Reference)
  - **Markdown detection:** Reject if output contains markdown fencing (triple backticks) wrapping the entire content
  - **Conflict marker detection:** Reject if output still contains conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`)
  - **Syntax check:** Run syntax validation per resolved file using the configurable syntax checker map (see Configuration Reference). Default checkers: `tsc --noEmit` for .ts (full type checking), `node --check` for .js. Files with unmapped extensions are accepted without syntax check (prose/marker detection still applies).
- Write resolved content, `git add`, continue to next conflicted file or finalize merge

**Tier 4 Reimagine (Opus):**
- Tier 4 operates on individual files that failed Tier 3 while a merge is in progress (via `git merge --no-commit --no-ff`)
- **File size gate:** Skip AI resolution for files exceeding the configured size limit (default: 1000 lines). Files exceeding the gate cascade directly to Fallback (PR creation)
- For the conflicted file, read:
  - Canonical version: `git show {targetBranch}:{filepath}`
  - Branch version: `git show {branchName}:{filepath}`
  - Diff of branch changes: `git diff {targetBranch}...{branchName} -- {filepath}`
- Send to Claude SDK (`claude-opus-4-6`) with prompt: "Apply these changes from the branch onto the canonical version"
- Validate output (same language-aware prose detection heuristic + syntax check as Tier 3, using configurable syntax checker map)
- Write resolved file content and `git add {filepath}`

**Merge Commit Strategy (Tier 2-4):**
- The initial merge attempt uses `git merge --no-commit --no-ff {branchName}` to keep the merge state open
- This preserves proper merge topology (two-parent merge commit) in git history
- Individual conflicted files are resolved through their respective tiers while the merge remains in progress
- After all files are resolved, `git commit` creates the merge commit with both parents
- If any file reaches Fallback, `git merge --abort` is called and the entire merge escalates to PR creation

**Post-Merge Validation:**
- After each successful merge commit, run the full test suite (`runTestCommand()`) before processing the next queue entry
- If tests fail:
  1. Record which files were AI-resolved and by which tier in the `conflict_patterns` table (FR-7) with `success=0` and a `post_merge_test_failure` flag, enabling pattern learning to track which file combinations lead to test failures
  2. Remove the failed merge commit (`git reset --hard HEAD~1`). This is safe because the merge is local and unpushed -- using reset instead of revert avoids the "anti-merge" pitfall where `git revert` of a merge commit causes git to consider the branch's changes as already merged, preventing future re-merge attempts
  3. Escalate to PR creation (push branch, create GitHub PR via `git town propose`)
  4. Update queue entry status to `conflict` with error code `MQ-007` noting "post-merge test failure" and listing all AI-resolved files with their tiers
  5. Proceed to next queue entry

**Cost Controls:**
- **Per-file size gate:** Skip AI resolution (Tier 3/4) for files exceeding the configured line count (default: 1000 lines). These files cascade directly to Fallback (PR creation)
- **Per-session budget:** Set a maximum total estimated cost per `foreman merge` invocation (default: $5.00). Once the budget is exhausted, remaining conflicts escalate to PR creation without AI attempts
- Both are configurable via `.foreman/config.json`:
  ```json
  {
    "mergeQueue": {
      "costControls": {
        "maxFileLines": 1000,
        "maxSessionBudgetUsd": 5.00
      }
    }
  }
  ```
- **Cost tracking (estimated + actuals):**
  - **Pre-call:** Estimate cost using token count approximation (4 chars per token) to check against remaining budget
  - **Post-call:** Update session cost with actual token usage from Claude SDK response metadata (`input_tokens`, `output_tokens`) and model-specific pricing
  - Budget enforcement is soft on the current file: if the pre-call estimate fits within the remaining budget, the call proceeds. If actual cost pushes the session over budget, the current file's resolution is kept but subsequent files/entries skip AI resolution and escalate to PR
  - Actual cost data is recorded per-file in the events table for reporting accuracy

**Acceptance Criteria:**
- AC-1.1: Clean merges (no conflicts) complete without invoking any resolution tier
- AC-1.2: Tier 2 per-file auto-resolve succeeds when branch changes do not discard significant canonical content for that file
- AC-1.3: Tier 2 safety check is applied per-file; files failing the hybrid threshold (>20 lines OR >30% of file, configurable) cascade to Tier 3 independently
- AC-1.4: Tier 3 successfully resolves conflicts where both sides make non-overlapping changes to the same file
- AC-1.5: Tier 3/4 rejects Claude output using language-aware prose detection heuristic (first-line pattern matching per file extension)
- AC-1.6: Tier 3/4 performs syntax validation using the configurable syntax checker map; files with unmapped extensions are accepted without syntax check
- AC-1.7: Tier 4 successfully reimplements branch changes onto canonical when conflict markers are too complex for Tier 3
- AC-1.8: Tier 3 uses Sonnet model; Tier 4 uses Opus model
- AC-1.9: Each tier's outcome (success/failure, tier used, file path) is recorded per-file in the SQLite events table
- AC-1.10: MergeReport type extended with per-file `resolved_tiers` map (filepath -> tier) indicating which tier resolved each file
- AC-1.11: All Claude SDK calls use non-interactive `query()` (no streaming, no prompts)
- AC-1.12: Files exceeding the size gate (default: 1000 lines) skip AI resolution and cascade to PR creation
- AC-1.13: AI resolution stops when per-session budget is exhausted (soft enforcement: current file completes, subsequent files escalate to PR)
- AC-1.14: Full test suite runs after each merge commit; test failure triggers recording of AI-resolved files to conflict patterns, `git reset --hard HEAD~1` to remove failed merge commit, and PR escalation
- AC-1.15: Fallback PR creation uses `git town propose` for git-town integration
- AC-1.16: Each conflicted file independently progresses through tiers; a single merge commit can contain files resolved by different tiers
- AC-1.17: If any file in a multi-file conflict reaches Fallback, the entire merge escalates to PR (no partial merge commits)
- AC-1.18: Merge commits preserve proper two-parent merge topology using `git merge --no-commit --no-ff`
- AC-1.19: Actual AI costs from Claude SDK response metadata are tracked and used for budget enforcement and reporting
- AC-1.20: Syntax checker map is configurable in `.foreman/config.json` with defaults for .ts and .js extensions
- AC-1.21: Prose detection uses language-aware first-line heuristic with built-in patterns for .ts/.js, .py, and .go; unmapped extensions use generic prose pattern rejection
- AC-1.22: Prose detection language patterns are extensible via `.foreman/config.json` under `mergeQueue.proseDetection`
- AC-1.23: All merge queue failure modes produce structured error codes (MQ-xxx) in error messages and log entries

#### FR-2: Auto-Commit State Files Before Merge (bd-uba.2)

**Description:** Before any merge attempt, detect and auto-commit uncommitted changes in known state file paths to prevent merge failures caused by dirty state.

**State File Paths:**
- `.seeds/**` -- Seed/task tracking data
- `.foreman/**` -- Foreman configuration and reports

**Behavior:**
1. Before `mergeWorktree()` is called, check for uncommitted changes in state file paths using `git status --porcelain -- .seeds/ .foreman/`
2. If changes exist, stage them with `git add .seeds/ .foreman/`
3. Commit with message: `chore: auto-commit state files before merge`
4. If no changes exist, skip (no empty commits)
5. Apply to both the target branch and the feature branch before merge

**Acceptance Criteria:**
- AC-2.1: Uncommitted `.seeds/` changes are auto-committed before merge attempt
- AC-2.2: Uncommitted `.foreman/` changes are auto-committed before merge attempt
- AC-2.3: No commit is created when state files have no changes
- AC-2.4: Auto-commit uses a descriptive commit message distinguishable from agent commits
- AC-2.5: State file auto-commit works on both target branch and feature branch

### 4.2 P2 -- Important

#### FR-3: Persistent Overlap-Aware Merge Queue (bd-uba.3)

**Description:** Replace inline merge iteration with a persistent SQLite-backed merge queue that survives process restarts and supports concurrent agent completion. Uses a hybrid enqueue strategy: agents auto-enqueue on completion (primary path) with `foreman merge` performing a reconciliation scan as a safety net. Queue processing uses overlap-aware ordering with graph-based conflict clustering to minimize merge conflicts.

**Schema:**

```sql
CREATE TABLE IF NOT EXISTS merge_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  branch_name TEXT NOT NULL,
  seed_id TEXT NOT NULL,
  run_id TEXT NOT NULL,
  agent_name TEXT,
  files_modified TEXT DEFAULT '[]',  -- JSON array of file paths
  enqueued_at TEXT NOT NULL,
  started_at TEXT,
  completed_at TEXT,
  status TEXT DEFAULT 'pending'
    CHECK (status IN ('pending', 'merging', 'merged', 'conflict', 'failed')),
  resolved_tier INTEGER,  -- highest tier used (1-4) or NULL if clean merge; per-file detail available in conflict_patterns table and in-memory MergeReport
  error TEXT,
  FOREIGN KEY (run_id) REFERENCES runs(id)
);

CREATE INDEX IF NOT EXISTS idx_merge_queue_status
  ON merge_queue (status, enqueued_at);
```

**Enqueue Strategy (Hybrid):**

| Path | Trigger | Description |
|------|---------|-------------|
| Primary (auto-enqueue) | Agent finalize phase | Agent worker calls `mergeQueue.enqueue()` immediately after successful finalization. This is the normal path and ensures the queue is always up-to-date. |
| Safety net (reconciliation) | `foreman merge` invocation | Before processing the queue, `foreman merge` scans for completed runs that are NOT in the queue (by cross-referencing `runs` table status=completed with `merge_queue` entries). Any missing entries are enqueued with a log message: "Reconciliation: enqueued {branch} (missed auto-enqueue)". |

**Operations:**

| Operation | Description |
|-----------|-------------|
| `enqueue(branch, seedId, runId, filesModified?)` | Add entry with status=pending, enqueued_at=now. Idempotent: skip if run_id already in queue. |
| `dequeue()` | Get oldest pending entry, atomically set status=merging |
| `peek()` | Get oldest pending entry without changing status |
| `list(statusFilter?)` | List all entries, optionally filtered by status |
| `updateStatus(id, status, resolvedTier?, error?)` | Update entry status and metadata |
| `remove(id)` | Delete entry from queue |
| `reconcile()` | Scan completed runs, validate branch existence, enqueue any not already in queue |

**Reconciliation Branch Validation:**
- During reconciliation, before enqueuing a completed run, verify the branch still exists in git (`git rev-parse --verify refs/heads/{branchName}`)
- If the branch no longer exists (e.g., manually deleted, already cleaned up), skip with log message: "Reconciliation: skipped {branch} (branch no longer exists)"
- This prevents stale entries from completed runs that predate the merge queue feature or whose branches were cleaned up externally

**Concurrency:**
- SQLite WAL mode (already configured in store.ts)
- 5-second busy timeout for concurrent access
- Dequeue uses atomic SQL claim (see Overlap-Aware Ordering for claim strategy)

**Overlap-Aware Ordering (Graph-Based Conflict Clustering):**

Instead of strict FIFO ordering, the merge queue uses graph-based conflict clustering to minimize merge conflicts:

1. **Build overlap graph:** Create a graph where each pending queue entry is a node. Add an edge between two nodes if their `files_modified` arrays share any file paths.
2. **Identify clusters:** Find connected components in the overlap graph. Each connected component is a "conflict cluster" -- entries within a cluster may conflict with each other; entries in different clusters are independent.
3. **Process clusters:**
   - Independent clusters (no file overlap between them) can be processed in parallel when `--parallel N` is used
   - Within each cluster, entries are processed in FIFO order (by `enqueued_at`) to maintain deterministic behavior
4. **Re-cluster after each merge:** After a merge completes and modifies files on the target branch, re-evaluate remaining entries for new potential overlaps (the merged files may now overlap with previously independent entries)

**Parallel Processing (`--parallel N`):**
- `foreman merge --parallel N` enables concurrent processing of up to N independent conflict clusters
- **AI resolution work** (Tier 3/4) runs in parallel across entries in different clusters -- each entry's conflict resolution can proceed independently
- **Git merge commits** are strictly sequential -- a mutex/lock ensures only one merge commit happens at a time on the target branch
- Within a cluster, entries are processed sequentially in FIFO order
- Default: `--parallel 1` (sequential processing, same as omitting the flag)
- Recommended max: `--parallel 4` (diminishing returns beyond this due to sequential commit bottleneck)
- **Budget tracking in parallel mode:** Optimistic (approximate). Each parallel worker tracks its own running cost independently against the shared session budget. The session total may slightly exceed the configured cap when multiple workers make concurrent AI calls. This trades precision for simplicity -- exact budget enforcement would require a shared lock on every AI call, adding latency and complexity disproportionate to the benefit.
- **Re-clustering cancellation:** When a merge commit triggers re-clustering (see Overlap-Aware Ordering), any in-progress AI resolution work in other workers whose cluster independence is invalidated by the new overlap is cancelled and re-queued. The new cluster ordering is respected. This ensures correctness: a worker must not commit a resolution that was computed under stale cluster assumptions.

**Integration Points:**
- Agent worker finalize phase calls `mergeQueue.enqueue()` after successful finalization (primary path)
- `foreman merge` runs `reconcile()` before processing queue (safety net)
- `foreman merge` processes queue entries via `dequeue()` loop
- `foreman merge --list` reads from queue instead of filtering completed runs
- Queue entries retain `files_modified` for conflict pattern analysis (FR-7)

**Acceptance Criteria:**
- AC-3.1: Merge queue persists across CLI invocations (process restart does not lose entries)
- AC-3.2: Concurrent agents can enqueue without conflicts (WAL mode + busy timeout)
- AC-3.3: Dequeue is atomic -- two concurrent `foreman merge` processes cannot claim the same entry
- AC-3.4: Queue entries record which resolution tier was used (`resolved_tier`)
- AC-3.5: `foreman merge --list` shows queue entries with status, branch, seed, and age
- AC-3.6: Migration adds merge_queue table without affecting existing store data
- AC-3.7: Agent finalize phase auto-enqueues completed branches (primary enqueue path)
- AC-3.8: `foreman merge` reconciliation scan detects and enqueues completed runs not in the queue, validating branch existence first
- AC-3.9: Enqueue is idempotent -- duplicate enqueue for same run_id is silently skipped
- AC-3.10: `foreman merge --parallel N` processes up to N independent conflict clusters concurrently with sequential git commits
- AC-3.11: Reconciliation skips completed runs whose branches no longer exist in git, with log message
- AC-3.12: Overlap-aware ordering groups entries by file overlap into conflict clusters
- AC-3.13: Independent clusters (no shared files) are processed in parallel when `--parallel N > 1`
- AC-3.14: Within a conflict cluster, entries are processed in FIFO order by enqueued_at
- AC-3.15: After each merge, remaining entries are re-evaluated for new overlaps with merged files
- AC-3.16: In parallel mode, per-session budget tracking is optimistic (approximate); each worker tracks independently and session total may slightly exceed the configured cap
- AC-3.17: When re-clustering after a merge commit invalidates the independence of a cluster with in-progress AI resolution, that work is cancelled and the entry is re-queued into the correct cluster

#### FR-4: Safe Branch Deletion (bd-uba.4)

**Description:** Replace unconditional `git branch -D` (force delete) with merge-status-aware deletion that prevents accidental loss of unmerged work.

**Current code (`git.ts:deleteBranch`):**
```typescript
await git(["branch", "-D", branchName], repoPath);
```

**New behavior:**
1. Check merge status: `git merge-base --is-ancestor {branchName} {targetBranch}`
2. If merged: use `git branch -d` (safe delete) -- succeeds because branch is merged
3. If not merged:
   - Without `--force`: log warning "Branch {branchName} has unmerged commits. Use --force to delete." and skip deletion
   - With `--force`: use `git branch -D` and log warning "Force-deleting unmerged branch {branchName}"
4. Handle "not found" errors gracefully (branch already deleted)

**API Change:**
```typescript
export async function deleteBranch(
  repoPath: string,
  branchName: string,
  options?: { force?: boolean; targetBranch?: string }
): Promise<{ deleted: boolean; wasFullyMerged: boolean }>;
```

**Acceptance Criteria:**
- AC-4.1: Merged branches are deleted with `git branch -d` (safe delete)
- AC-4.2: Unmerged branches are NOT deleted without explicit `--force`
- AC-4.3: Warning is logged when attempting to delete an unmerged branch without force
- AC-4.4: Force-deleted unmerged branches produce a warning log entry
- AC-4.5: Already-deleted branches (not found) are handled gracefully without error
- AC-4.6: Refinery and reset commands updated to use new safe deletion API

#### FR-5: Dedicated Worktree Management Commands (bd-uba.5)

**Description:** Add first-class CLI commands for inspecting and cleaning up git worktrees, removing the need to use `doctor --fix` or `reset` for worktree management.

**Commands:**

**`foreman worktree list [--json]`**
- Lists all `foreman/*` worktrees with:
  - Branch name
  - Worktree path
  - Associated agent/run status (from store)
  - Associated seed ID
  - Age (time since creation)
- `--json` flag outputs structured JSON for scripting/CI

**`foreman worktree clean [--completed|--all] [--force]`**
- `--completed` (default): Clean worktrees for completed/merged/failed agents only
- `--all`: Clean all foreman worktrees (including active ones)
- `--force`: Force-delete even if branch has unmerged commits (uses FR-4 safe deletion)
- Shows summary: "Cleaned N worktrees, freed M MB"
- Skips worktrees with active (running/pending) agents unless `--all`

**Implementation:**
- New file: `src/cli/commands/worktree.ts`
- Reuses `listWorktrees()` and `removeWorktree()` from `git.ts`
- Cross-references worktree branches with run status from store

**Acceptance Criteria:**
- AC-5.1: `foreman worktree list` shows all foreman/* worktrees with branch, path, agent status, and seed
- AC-5.2: `foreman worktree list --json` outputs valid JSON array
- AC-5.3: `foreman worktree clean` removes only completed/merged/failed worktrees by default
- AC-5.4: `foreman worktree clean --all` removes all foreman worktrees (with confirmation message)
- AC-5.5: `foreman worktree clean` respects safe branch deletion (FR-4)
- AC-5.6: Active agent worktrees are not cleaned unless `--all` is specified

### 4.3 P3 -- Nice to Have

#### FR-6: Seeds Preservation for Non-Merged Branches (bd-uba.6)

**Description:** When a branch is not merged (e.g., coordinator/lead branches, or branches abandoned after conflict), preserve any seed status changes from that branch back to the canonical branch.

**Mechanism:**
1. Use three-dot diff to extract seed changes: `git diff {targetBranch}...{branchName} -- .seeds/`
2. If diff is non-empty, write to temp patch file
3. Apply patch to target branch: `git apply --index {patchFile}`
4. Commit: `chore: preserve seed status from {branchName}`
5. Clean up temp patch file in `finally` block (always, even on error)

**Guard Rails:**
- Only preserve `.seeds/` changes, not `.foreman/` or code
- Skip if the branch has no seed-related changes
- If `git apply` fails (e.g., conflicting seed changes), log warning and skip (do not block branch cleanup)

**Acceptance Criteria:**
- AC-6.1: Seed status changes from non-merged branches are applied to the target branch
- AC-6.2: Only `.seeds/` directory changes are preserved (no code leakage)
- AC-6.3: Failed patch application logs a warning but does not block branch cleanup
- AC-6.4: Temp patch file is always cleaned up (finally block)

#### FR-7: Conflict Pattern Learning (bd-uba.7)

**Blocked by:** FR-1 (AI-Powered Conflict Resolution)

**Description:** Record outcomes of conflict resolution attempts and use historical data to skip resolution tiers that consistently fail for similar file patterns.

**Schema:**

```sql
CREATE TABLE IF NOT EXISTS conflict_patterns (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  file_path TEXT NOT NULL,
  file_extension TEXT NOT NULL,
  tier INTEGER NOT NULL,
  success INTEGER NOT NULL,  -- 0 or 1
  failure_reason TEXT,  -- 'validation', 'timeout', 'post_merge_test_failure', etc.
  merge_queue_id INTEGER,  -- links to merge_queue entry for cross-referencing
  seed_id TEXT,
  recorded_at TEXT NOT NULL,
  FOREIGN KEY (merge_queue_id) REFERENCES merge_queue(id)
);

CREATE INDEX IF NOT EXISTS idx_conflict_patterns_file
  ON conflict_patterns (file_extension, tier);

CREATE INDEX IF NOT EXISTS idx_conflict_patterns_merge
  ON conflict_patterns (merge_queue_id);
```

**Logic:**
- After each tier attempt (success or failure), record: file path, extension, tier, outcome, and failure reason
- On post-merge test failure, record ALL AI-resolved files from that merge with `success=0` and `failure_reason='post_merge_test_failure'`, enabling pattern learning to identify which file combinations lead to test failures
- Before attempting a tier, check history for overlapping files:
  - If tier has >= 2 failures AND 0 successes for files with the same extension: skip tier
  - If a file has been involved in post-merge test failures >= 2 times with AI resolution: prefer Fallback (PR) for that file
- When AI-resolve (Tier 3/4) is attempted, include past successful resolution examples as context
- Recording is fire-and-forget (errors logged but never block merge)

**Acceptance Criteria:**
- AC-7.1: Each conflict resolution attempt is recorded with file, tier, and outcome
- AC-7.2: Tiers with >= 2 failures and 0 successes for matching file extensions are skipped
- AC-7.3: Past successful resolutions are provided as context to AI-resolve tiers
- AC-7.4: Pattern recording never blocks or delays the merge process
- AC-7.5: Pattern data persists in SQLite alongside existing store
- AC-7.6: Post-merge test failures record all AI-resolved files with `failure_reason='post_merge_test_failure'`
- AC-7.7: Files with >= 2 post-merge test failure records prefer Fallback (PR) over AI resolution

#### FR-8: Merge Dry-Run Mode (bd-uba.8)

**Description:** Add `foreman merge --dry-run` to preview merge operations without executing them.

**Output:**
For each queued/completed branch, show:
- Branch name and seed ID
- Files changed (from `git diff --stat {targetBranch}...{branchName}`)
- Potential conflicts detected via `git merge-tree` (or temporary merge + abort)
- Estimated resolution tier based on conflict pattern history (if FR-7 available)

**Implementation:**
- Use `git merge-tree $(git merge-base {target} {branch}) {target} {branch}` for conflict detection without modifying working tree
- If `merge-tree` is not available (older git), fall back to: merge in detached HEAD, check for conflicts, abort
- Output formatted table or `--json` for scripting

**Acceptance Criteria:**
- AC-8.1: `foreman merge --dry-run` shows branch, files changed, and conflict status without modifying the working tree
- AC-8.2: Potential conflicts are accurately detected (matches what `git merge` would produce)
- AC-8.3: Dry-run works with `--seed <id>` to preview a single merge
- AC-8.4: No git state is modified during dry-run (working tree, index, HEAD unchanged)
- AC-8.5: When FR-7 (conflict pattern learning) data is available, dry-run shows estimated resolution tier per conflict based on historical pattern data
- AC-8.6: When FR-7 is not available (not yet implemented or no pattern data exists), dry-run gracefully degrades by omitting the estimated tier column (no errors, no empty/confusing output)

### 4.4 P4 -- Backlog

#### FR-9: Untracked File Conflict Prevention (bd-uba.9)

**Description:** Before merge, detect untracked files in the working tree that would conflict with files being merged in from the branch.

**Detection:**
1. Get list of files in branch but not in target: `git diff --name-only --diff-filter=A {targetBranch}...{branchName}`
2. Check if any of those files exist as untracked in the working tree
3. If overlap found:
   - Default: delete conflicting untracked files with warning logged
   - `--stash-untracked`: move to `.foreman/stashed/` for recovery
   - `--abort-on-untracked`: abort merge with clear error message listing conflicting files

**Acceptance Criteria:**
- AC-9.1: Untracked file conflicts are detected before merge attempt
- AC-9.2: Default behavior removes conflicting untracked files with warning
- AC-9.3: Stash option preserves untracked files in `.foreman/stashed/`
- AC-9.4: Abort option provides clear error listing all conflicting files

#### FR-10: Merge Queue Health Checks (bd-uba.10)

**Blocked by:** FR-3 (Persistent Merge Queue)

**Description:** Extend the existing `foreman doctor` command to detect and auto-fix merge queue issues.

**Checks:**
| Check | Condition | Auto-Fix |
|-------|-----------|----------|
| Stale pending | Entry pending/merging > 24h | Delete stale entry, reset run status |
| Duplicate branches | Same branch_name, multiple entries | Keep max(id), delete others |
| Orphaned entries | Queue entry references non-existent run | Delete orphaned entry |

**Acceptance Criteria:**
- AC-10.1: Doctor detects merge queue entries stuck in pending/merging for >24h
- AC-10.2: Doctor detects duplicate branch entries in the queue
- AC-10.3: `foreman doctor --fix` auto-resolves stale and duplicate entries
- AC-10.4: Health check results integrate into existing DoctorReport format

---

## 5. Non-Functional Requirements

### 5.1 Performance

| Requirement | Target | Rationale |
|-------------|--------|-----------|
| Merge queue enqueue latency | < 50ms | Must not slow down agent finalize phase |
| Merge queue dequeue (atomic) | < 100ms | Including SQLite transaction |
| Tier 1-2 resolution | < 5s per branch | Git operations only, no AI calls |
| Tier 3 AI resolution (Sonnet) | < 60s per file | Claude SDK query with timeout |
| Tier 4 reimagine (Opus) | < 120s per file | More complex Claude SDK query with higher-capability model |
| Dry-run preview | < 10s for 10 branches | No merge execution, just analysis |
| Post-merge test suite | Project-dependent | Runs after each merge commit; timeout inherited from project config |
| Syntax check per file | < 15s per file | Full validation (tsc --noEmit for full type checking, node --check); TypeScript type checking requires project context and may take 10-15s on larger codebases |

### 5.2 Reliability

- **Crash recovery:** Merge queue entries in `merging` status must be detectable and recoverable after process crash (doctor health check FR-10)
- **Atomic operations:** Dequeue must be atomic to prevent double-processing in concurrent scenarios
- **Idempotent migrations:** Schema changes must use `CREATE TABLE IF NOT EXISTS` and `ALTER TABLE ... ADD COLUMN` with error suppression (matching existing pattern in `store.ts`)
- **Test failure safety:** Post-merge test failures trigger `git reset --hard HEAD~1` (removing the failed merge commit) + PR escalation, never leaving the target branch in a broken state. Reset is used instead of revert to avoid the anti-merge pitfall; safe because the merge commit is local and unpushed.

### 5.3 Compatibility

- **TypeScript strict mode:** No `any` escape hatches, all new code must compile under `strict: true`
- **ESM only:** All imports use `.js` extensions
- **Non-interactive:** All git and shell commands must be non-interactive (no `-i` flags, no prompts)
- **Transition strategy:** New merge queue behavior is the default from day one. `foreman merge --legacy` provides an escape hatch to the old inline behavior. The `--legacy` flag produces a hard error after 50 successful merges through the new queue (tracked in SQLite), with message directing users to remove the flag. A deprecation warning is shown on every `--legacy` invocation before the threshold is reached. This is intentionally a hard stop -- CI scripts using `--legacy` will break, forcing migration to the new queue path.
- **SQLite compatibility:** Must work with existing better-sqlite3 setup, WAL mode, and migration pattern
- **git-town integration:** Merge queue internals use direct git commands for low-level operations (merge, rebase, conflict resolution). Branch creation/cleanup and the final "ship" step (PR creation fallback) use git-town commands (`git town propose`, `git town hack`, etc.) to maintain project conventions.

### 5.4 Observability

- All merge operations log events to the existing `events` table with structured details and error codes (MQ-xxx)
- Tier resolution outcomes recorded for metrics (which tier resolved, time taken, model used)
- `foreman merge --list` provides queue status overview
- `foreman merge --stats` provides cumulative AI cost tracking (daily/weekly/monthly/all-time) -- see Section 12
- Conflict pattern history queryable for debugging
- **Running success rate display:** After each `foreman merge` invocation, display a rolling success rate summary:
  ```
  AI resolution rate: 12/15 conflicts (80%) over last 30 days
  Tier breakdown: T2: 5, T3: 6, T4: 1 | Fallback to PR: 3
  Session cost: $0.47 / $5.00 budget (actual from SDK metadata)
  ```
- Success rate data sourced from the `conflict_patterns` table (FR-7) or the `merge_queue` table `resolved_tier` field
- All error/warning log messages include structured error codes (see Section 11) for grep-ability and CI parsing

---

## 6. Technical Design Notes

These are architectural guidance notes for the implementing team (tech-lead-orchestrator), not binding implementation decisions.

### 6.1 Suggested Module Structure

```
src/orchestrator/merge-queue.ts       -- MergeQueue class (SQLite queue + overlap-aware ordering + reconciliation)
src/orchestrator/conflict-resolver.ts -- Per-file 4-tier resolution logic + validation
src/orchestrator/conflict-cluster.ts  -- Graph-based overlap clustering algorithm
src/orchestrator/conflict-patterns.ts -- Pattern learning (FR-7) including test failure tracking
src/orchestrator/merge-validator.ts   -- Configurable syntax checker map + post-merge test orchestration
src/cli/commands/worktree.ts          -- Worktree CLI commands
```

### 6.2 Integration with Existing Code

- `Refinery.mergeCompleted()` should delegate to `MergeQueue.dequeue()` loop instead of iterating `getCompletedRuns()`
- `ConflictResolver` replaces the inline `autoResolveRebaseConflicts()` and `createPrForConflict()` logic
- `git.ts:deleteBranch()` signature changes are backward-compatible (options parameter is optional)
- New merge_queue and conflict_patterns tables added via the existing migration pattern in `store.ts`
- Agent worker finalize phase (`src/orchestrator/agent-worker.ts`) updated to call `mergeQueue.enqueue()` after successful completion
- `foreman merge` gains `--legacy`, `--parallel N`, `--dry-run`, `--list`, and `--stats` flags
- Fallback PR creation uses `git town propose` instead of direct `gh pr create`

### 6.3 Claude SDK Usage for Tier 3/4

- Use `query()` from `@anthropic-ai/claude-code` SDK (same as agent worker)
- **Tier 3 model:** `claude-sonnet-4-6` (balances quality and cost for straightforward conflict resolution)
- **Tier 4 model:** `claude-opus-4-6` (higher capability for complex reimagination tasks where Sonnet is insufficient)
- System prompt must instruct: "Output only the resolved file content. No explanations, no markdown fencing, no prose."
- Max tokens: 16K per file (sufficient for most source files)
- Timeout: 60s for Tier 3, 120s for Tier 4
- **File size gate:** Files exceeding 1000 lines (configurable) skip AI resolution entirely
- **Cost tracking:** Pre-call estimate (4 chars/token) for budget check; post-call update with actuals from Claude SDK response metadata (`input_tokens`, `output_tokens`). Soft budget enforcement: current file completes even if over budget, subsequent files skip AI.

### 6.4 Transition and Legacy Support

- The new merge queue path is the default behavior for `foreman merge`
- `foreman merge --legacy` activates the old inline merge path (current `Refinery.mergeCompleted()` behavior)
- A counter in SQLite tracks successful merges through the new queue:
  ```sql
  -- Tracked via: SELECT COUNT(*) FROM merge_queue WHERE status = 'merged'
  ```
- When the counter reaches 50, the `--legacy` flag is deprecated: using it produces an error directing users to remove the flag
- The old inline merge code path can be removed in a future cleanup epic after the 50-merge threshold is reached

### 6.5 Parallel Merge Architecture (Cluster-Based)

- `foreman merge --parallel N` processes up to N independent conflict clusters concurrently
- **Cluster computation:** Build an overlap graph from `files_modified`, find connected components. Each component is a cluster.
- Each cluster is assigned to a worker. Workers process entries within their cluster sequentially (FIFO).
- A shared mutex/semaphore gates the final git merge commit step -- only one worker can commit at a time
- After each sequential commit, the test suite runs; on failure the commit is reverted and PR is created
- **Re-clustering with cancellation:** After each merge commit, remaining entries are re-evaluated since newly merged files may create new overlaps between previously independent clusters. If re-clustering invalidates the independence of a cluster that has in-progress AI resolution work, that work is cancelled and the entry is re-queued into the correct cluster. This ensures correctness: no worker commits a resolution computed under stale cluster assumptions.
- Workers that complete resolution wait for the commit lock rather than blocking queue dequeue
- **Budget tracking:** Each parallel worker tracks AI costs independently against the shared session budget (optimistic/approximate). The session total may slightly exceed the configured cap when multiple workers make concurrent AI calls. Exact synchronization is not required.

---

## 7. Dependencies and Risks

### 7.1 Dependencies

| Dependency | Type | Impact |
|------------|------|--------|
| FR-7 blocked by FR-1 | Internal | Conflict patterns require resolution tiers to exist first |
| FR-10 blocked by FR-3 | Internal | Health checks require merge queue table to exist |
| Claude SDK (`@anthropic-ai/claude-code`) | External | Required for Tier 3 (Sonnet) and Tier 4 (Opus) AI resolution |
| better-sqlite3 | External | Already in use; merge queue extends existing store |
| git >= 2.38 | External | `git merge-tree` (3-way) required for dry-run mode |
| git-town | External | Required for branch lifecycle and PR creation fallback |

### 7.2 Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| AI resolution produces invalid code | Medium | High | Multi-layer validation: prose detection, per-file syntax check, conflict marker detection; full test suite after each merge commit with auto-revert on failure |
| AI resolution cost escalation | Low | Medium | Per-session budget cap (default $5); per-file size gate (default 1000 lines); Sonnet for Tier 3, Opus only for Tier 4; pattern learning skips failing tiers |
| Concurrent merge corruption | Low | High | SQLite WAL + atomic dequeue; sequential git commit with mutex; parallel only for AI resolution work |
| Migration breaks existing store | Low | High | Idempotent migrations matching existing pattern; no destructive changes to existing tables |
| git merge-tree unavailable | Low | Low | Fallback to temporary merge+abort for dry-run; version check on startup |
| Post-merge test failure blocks pipeline | Medium | Medium | `git reset --hard HEAD~1` + PR escalation ensures target branch stays clean; queue processing continues with next entry |
| Opus cost for Tier 4 higher than expected | Low | Medium | Per-session budget cap; file size gate prevents large-file Opus calls; pattern learning skips Tier 4 for consistently failing file types |
| Overlap clustering adds latency | Low | Low | Graph computation is O(N^2) on queue size which is typically small (<50 entries); re-clustering after each merge adds minimal overhead |
| Per-file cascade creates inconsistent merge state | Low | Medium | If any file reaches Fallback, entire merge aborts via `git merge --abort`; no partial merge commits are ever created |

### 7.3 Implementation Order

Recommended implementation sequence based on dependencies and value delivery:

1. **FR-2** (Auto-commit state files) -- Quick win, no schema changes, prevents immediate pain
2. **FR-4** (Safe branch deletion) -- Quick win, API change enables later features
3. **FR-3** (Persistent merge queue) -- Foundation for queue-based merge flow; includes hybrid enqueue, reconciliation with branch validation, overlap-aware clustering, `--legacy` flag, and `--parallel N`
4. **FR-1** (AI conflict resolution) -- Highest user value; includes per-file tier cascade, Sonnet/Opus tiering, configurable syntax checker map, post-merge tests with pattern learning, auto-revert, cost controls with actual tracking
5. **FR-5** (Worktree commands) -- Independent, can parallelize with FR-1
6. **FR-8** (Dry-run mode) -- Benefits from queue but not strictly dependent
7. **FR-6** (Seeds preservation) -- Independent, lower priority
8. **FR-7** (Conflict patterns) -- Requires FR-1 data; enables running success rate display
9. **FR-9** (Untracked file prevention) -- Edge case handling
10. **FR-10** (Queue health checks) -- Requires FR-3, polish item

---

## 8. Success Metrics

| Metric | Current | Target | Measurement |
|--------|---------|--------|-------------|
| Auto-resolved code conflicts | 0% | >= 80% | (conflicts resolved by Tier 2-4) / (total code conflicts), displayed as rolling 30-day rate in merge output |
| Merge failures from state files | Occasional | 0 | Count of merge failures with `.seeds/` or `.foreman/` in error |
| Merge state loss on restart | Always | Never | Queue entries persist in SQLite |
| Accidental branch deletion | Possible | 0 | Count of `branch -D` on unmerged branches without --force |
| Time to resolve merge (median) | 5-15 min (manual) | < 2 min (automated) | Time from merge start to completion |
| AI resolution cost per conflict | N/A | < $0.10 (Tier 3), < $1.00 (Tier 4) | Claude SDK token cost per file, tracked per session |
| Per-session cost | N/A | < $5.00 (default cap) | Total AI resolution cost per `foreman merge` invocation |
| Post-merge test pass rate | N/A | >= 95% | Percentage of AI-resolved merges that pass post-merge tests without revert |
| Legacy flag usage | N/A | 0 after 50 merges | Count of `--legacy` invocations; target: zero after stabilization threshold |

---

## 9. Resolved Questions

These questions were raised in PRD v1.0 and resolved through stakeholder interview on 2026-03-12.

### 9.1 Queue auto-enqueue

**Decision: Hybrid approach.**

The agent finalize phase auto-enqueues completed branches as the primary path. `foreman merge` performs a reconciliation scan before processing the queue as a safety net, detecting and enqueuing any completed runs that were missed (e.g., due to agent crash before enqueue call). This provides robustness without relying solely on either mechanism.

See FR-3 for detailed specification of both paths.

### 9.2 Tier 3/4 model selection

**Decision: Sonnet for Tier 3, Opus for Tier 4.**

Tier 3 (AI Resolve) uses `claude-sonnet-4-6` for straightforward conflict resolution where the conflict markers provide sufficient context. Tier 4 (Reimagine) escalates to `claude-opus-4-6` because reimplementation from canonical + branch versions is a substantially more complex task requiring deeper code understanding. Cost is managed through per-file size gates and per-session budget caps.

See FR-1 Cost Controls and Section 6.3 for implementation details.

### 9.3 Concurrent merge execution

**Decision: Hybrid -- parallel AI resolution with sequential git merge commits.**

`foreman merge --parallel N` enables concurrent processing where AI resolution work (Tier 3/4) runs in parallel across queue entries, but actual git merge commits are strictly sequential (protected by a mutex). This maximizes throughput for AI-heavy resolution while preventing git state corruption. Default is sequential (N=1).

See FR-3 Parallel Processing and Section 6.5 for architecture details.

### 9.4 git-town integration

**Decision: Direct git for merge internals, git-town for ship step and branch lifecycle.**

Merge queue internal operations (merge, rebase, conflict resolution, revert) use direct git commands because they require fine-grained control not exposed by git-town. The final "ship" step (PR creation on fallback) and branch creation/cleanup use git-town commands (`git town propose`, `git town hack`) to maintain project conventions.

See Section 5.3 Compatibility for integration specification.

### 9.5 Tier 2 resolution scope

**Decision: Per-file resolution with per-file safety check.**

Tier 2 uses a regular `git merge`, then selectively resolves individual conflicted files with `git checkout --theirs` only for files where the safety check passes. Files that fail the safety check cascade independently to Tier 3. This provides more granular control than the global `-X theirs` approach.

See FR-1 Tier 2 Per-File Safety Check for details.

### 9.6 Multi-file conflict tier cascade

**Decision: Per-file cascade.**

Each conflicted file independently progresses through the tier cascade. A single merge commit can contain files resolved by different tiers (e.g., file A by Tier 2, file B by Tier 3, file C by Tier 4). This maximizes the AI resolution rate by not wasting successful resolutions when one file fails a tier. If any file reaches Fallback, the entire merge escalates to PR.

See FR-1 Per-File Tier Progression for details.

### 9.7 Syntax validation for unmapped file types

**Decision: Configurable syntax checker map with accept-without-check for unmapped extensions.**

Users can define custom syntax checkers per file extension in `.foreman/config.json` under `mergeQueue.syntaxCheckers`. Default checkers are provided for `.ts` (`tsc --noEmit`) and `.js` (`node --check`). Files with extensions not in the map are accepted without syntax check (prose/marker detection still applies).

See Configuration Reference (Section 10) for the syntax checker map schema.

### 9.8 Post-merge test failure handling

**Decision: Remove failed merge commit and escalate to PR, with conflict pattern learning.**

On post-merge test failure, the merge commit is removed via `git reset --hard HEAD~1` (not `git revert`, which would create an anti-merge commit preventing future re-merge of the branch) and escalated to PR creation. All AI-resolved files from the failed merge are recorded in the `conflict_patterns` table with `failure_reason='post_merge_test_failure'`, enabling pattern learning to identify which file combinations lead to test failures over time.

See FR-1 Post-Merge Validation and FR-7 for details.

### 9.9 Reconciliation scan for pre-existing completed runs

**Decision: Enqueue all but validate branch existence first.**

During reconciliation, completed runs are only enqueued if their branch still exists in git. Branches that have been deleted (manually, already cleaned up, or predating the merge queue feature) are skipped with a log message.

See FR-3 Reconciliation Branch Validation for details.

### 9.10 Legacy flag post-threshold behavior

**Decision: Hard error after 50 successful merges.**

After 50 successful queue merges, `foreman merge --legacy` produces a hard error with a message directing users to remove the flag. This is intentionally a hard stop to force migration. CI scripts will break, but this is accepted as the cost of clean deprecation.

See Section 5.3 Compatibility for details.

### 9.11 Merge queue ordering strategy

**Decision: Overlap-aware ordering with graph-based conflict clustering.**

The merge queue uses graph-based conflict clustering instead of strict FIFO. Entries are grouped into clusters based on `files_modified` overlap. Independent clusters can be processed in parallel (when `--parallel N` is used). Within each cluster, entries are processed in FIFO order. After each merge, clusters are re-evaluated since newly merged files may create new overlaps.

See FR-3 Overlap-Aware Ordering for details.

### 9.12 Tier 4 merge commit topology

**Decision: Use `git merge --no-commit --no-ff` to preserve two-parent merge topology.**

The initial merge attempt uses `git merge --no-commit --no-ff` to keep the merge state open. Individual conflicted files are resolved through their respective tiers while the merge remains in progress. After all files are resolved, `git commit` creates the merge commit with proper two-parent topology. This preserves clean git history.

See FR-1 Merge Commit Strategy for details.

### 9.13 Cost estimation and budget enforcement

**Decision: Estimated + actuals with soft budget enforcement.**

Pre-call estimates (4 chars/token) are used for budget checks. Post-call, actual costs from Claude SDK response metadata update the session total. Budget enforcement is soft on the current file: if the estimate fits within remaining budget, the call proceeds; if actual cost pushes over budget, the current file's resolution is kept but subsequent files skip AI resolution.

See FR-1 Cost Controls for details.

### 9.14 Prose detection strategy

**Decision: Language-aware first-line heuristic.**

Replaced the hardcoded prose prefix list ("I ", "Here's", "Let me", etc.) with a language-aware heuristic that checks whether the first non-empty line of AI output matches a valid code pattern for the file's extension. Built-in patterns provided for .ts/.js, .py, and .go. Unmapped extensions fall back to generic prose prefix rejection. Patterns are configurable and extensible via `.foreman/config.json` under `mergeQueue.proseDetection`.

See FR-1 Tier 3 AI Resolve validation and Configuration Reference for details.

### 9.15 Post-merge test failure recovery mechanism

**Decision: `git reset --hard HEAD~1` instead of `git revert`.**

Using `git revert` to undo a failed merge commit creates an "anti-merge" in git history that prevents the branch from being re-merged later (git considers the changes already merged). Since the merge commit is local and unpushed, `git reset --hard HEAD~1` safely removes it without this pitfall, allowing the branch to be re-merged after fixes via the PR workflow.

See FR-1 Post-Merge Validation for details.

### 9.16 Error message format

**Decision: Structured error codes (MQ-xxx).**

All merge queue failure modes produce structured error codes (MQ-001 through MQ-020) in log messages, queue entry error fields, and CLI output. Error codes are categorized by type (budget, validation, AI, test, queue, branch, merge, pattern, legacy, state) and are designed for programmatic parsing in CI pipelines and documentation reference.

See Section 11 for the complete error code reference.

### 9.17 Cost tracking persistence

**Decision: Cumulative cost tracking with `foreman merge --stats`.**

AI resolution costs are tracked per-call in a `merge_costs` SQLite table with actual costs from Claude SDK response metadata. `foreman merge --stats` displays daily, weekly, monthly, and all-time cost summaries with breakdowns by tier and model. JSON output available for CI integration.

See Section 12 for schema and output format.

### 9.18 Parallel budget synchronization

**Decision: Optimistic (approximate) budget tracking.**

In parallel mode (`--parallel N`), each worker tracks its own running AI cost independently against the shared session budget. The session total may slightly exceed the configured cap when multiple workers make concurrent AI calls. This trades precision for simplicity -- exact budget enforcement would require a shared lock on every AI call, adding latency and complexity disproportionate to the benefit. The per-session budget cap remains a soft limit in all modes.

See FR-3 Parallel Processing and FR-1 Cost Controls for details.

### 9.19 Re-clustering vs in-progress AI resolution

**Decision: Cancel and re-queue.**

When a merge commit triggers re-clustering and invalidates the independence of a cluster that has in-progress AI resolution work, that work is cancelled and the entry is re-queued into the correct cluster. The new cluster ordering is respected. This ensures correctness over efficiency: a worker must not commit a resolution that was computed under stale cluster assumptions where file overlaps were not accounted for.

See FR-3 Parallel Processing and Section 6.5 for details.

### 9.20 Syntax check performance target

**Decision: Keep full `tsc --noEmit`, increase target to 15s.**

Full TypeScript type checking via `tsc --noEmit` is retained for thoroughness (catches type errors that `--isolatedModules` would miss). The per-file syntax check performance target is increased from 5s to 15s to accommodate the project-wide type checking that `tsc --noEmit` requires. For `.js` files, `node --check` remains fast (<1s).

See Section 5.1 Performance for the updated target.

### 9.21 Dry-run graceful degradation without FR-7

**Decision: Omit estimated tier column when pattern data unavailable.**

When FR-7 (conflict pattern learning) is not yet implemented or no pattern data exists, `foreman merge --dry-run` gracefully degrades by omitting the estimated resolution tier column entirely. No errors, no empty columns, no "N/A" placeholders -- the output simply shows the columns that have data available.

See FR-8 AC-8.5 and AC-8.6 for acceptance criteria.

---

## 10. Configuration Reference

All merge queue settings are configurable via `.foreman/config.json`. Below is the complete schema with defaults:

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
      ".ts": ["^import\\b", "^export\\b", "^const\\b", "^let\\b", "^var\\b", "^function\\b", "^class\\b", "^interface\\b", "^type\\b", "^enum\\b", "^//", "^/\\*", "^[\"']use", "^[{(]", "^\\w+\\s*[=:(]"],
      ".js": ["^import\\b", "^export\\b", "^const\\b", "^let\\b", "^var\\b", "^function\\b", "^class\\b", "^//", "^/\\*", "^[\"']use", "^[{(]", "^\\w+\\s*[=:(]"],
      ".py": ["^import\\b", "^from\\b", "^def\\b", "^class\\b", "^#", "^@", "^if\\b", "^try\\b", "^with\\b", "^[\"\\\"{3}]", "^['''{3}]", "^\\w+\\s*[=:(]"],
      ".go": ["^package\\b", "^import\\b", "^func\\b", "^type\\b", "^var\\b", "^const\\b", "^//", "^/\\*"]
    },
    "parallel": 1,
    "legacyThreshold": 50
  }
}
```

| Setting | Default | Description |
|---------|---------|-------------|
| `tier2SafetyCheck.maxDiscardedLines` | 20 | Max canonical lines Tier 2 can discard before failing |
| `tier2SafetyCheck.maxDiscardedPercent` | 30 | Max percentage of canonical file Tier 2 can discard before failing |
| `costControls.maxFileLines` | 1000 | Files exceeding this line count skip AI resolution (Tier 3/4) |
| `costControls.maxSessionBudgetUsd` | 5.00 | Max AI cost per `foreman merge` invocation (soft enforcement: current file completes, subsequent files skip AI) |
| `syntaxCheckers` | `{".ts": "tsc --noEmit", ".js": "node --check"}` | Map of file extensions to syntax validation commands. Files with unmapped extensions are accepted without syntax check. Users can add custom checkers (e.g., `".py": "python -m py_compile"`, `".go": "gofmt -e"`) |
| `proseDetection` | Built-in patterns for .ts/.js, .py, .go | Map of file extensions to arrays of regex patterns matching valid first-line code patterns. If the first non-empty line of AI output does not match any pattern for the file's extension, the output is rejected as prose. Unmapped extensions use a generic prose prefix rejection list. Users can add custom patterns for additional languages. |
| `parallel` | 1 | Default parallelism for `foreman merge` (overridden by `--parallel N` flag) |
| `legacyThreshold` | 50 | Number of successful queue merges before `--legacy` flag produces a hard error |

---

## 11. Error Code Reference

All merge queue failure modes produce structured error codes for consistent logging, CI integration, and documentation reference. Error codes appear in log messages, queue entry `error` fields, and CLI output.

| Code | Category | Description |
|------|----------|-------------|
| `MQ-001` | Budget | Per-session AI budget exhausted; remaining conflicts escalated to PR |
| `MQ-002` | Validation | Syntax validation failed for AI-resolved file |
| `MQ-003` | Validation | Prose detected in AI output (language-aware heuristic rejection) |
| `MQ-004` | Validation | Conflict markers remain in AI output |
| `MQ-005` | Validation | Markdown fencing detected in AI output |
| `MQ-006` | AI | Claude SDK call failed (timeout, API error, or model error) |
| `MQ-007` | Test | Post-merge test failure; merge commit removed, PR created |
| `MQ-008` | Queue | Stale queue entry detected (pending/merging > 24h) |
| `MQ-009` | Queue | Duplicate branch entry in merge queue |
| `MQ-010` | Queue | Orphaned queue entry (references non-existent run) |
| `MQ-011` | Branch | Branch no longer exists during reconciliation scan |
| `MQ-012` | Branch | Unmerged branch deletion attempted without --force |
| `MQ-013` | Merge | File exceeds size gate; skipped AI resolution |
| `MQ-014` | Merge | Untracked file conflict detected |
| `MQ-015` | Pattern | Tier skipped due to pattern learning (>= 2 failures, 0 successes) |
| `MQ-016` | Pattern | File skipped AI resolution due to repeated post-merge test failures |
| `MQ-017` | Legacy | --legacy flag used after stabilization threshold reached |
| `MQ-018` | Merge | All tiers exhausted for file; entire merge escalated to PR |
| `MQ-019` | Seeds | Seed preservation patch failed to apply |
| `MQ-020` | State | Auto-commit of state files failed |

Error codes are structured as `MQ-{NNN}` where the numeric range indicates the category:
- 001-006: Budget, validation, and AI errors
- 007: Test failure (post-merge)
- 008-010: Queue health errors (stale, duplicate, orphaned)
- 011-014: Branch and merge errors
- 015-020: Pattern learning, legacy, seeds, and state errors

---

## 12. Cumulative Cost Tracking

### 12.1 Cost Tracking Schema

AI resolution costs are tracked per-session and cumulatively in SQLite:

```sql
CREATE TABLE IF NOT EXISTS merge_costs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,       -- unique ID per `foreman merge` invocation
  merge_queue_id INTEGER,         -- links to merge_queue entry
  file_path TEXT NOT NULL,
  tier INTEGER NOT NULL,          -- 3 or 4 (only AI tiers incur cost)
  model TEXT NOT NULL,            -- 'claude-sonnet-4-6' or 'claude-opus-4-6'
  input_tokens INTEGER NOT NULL,
  output_tokens INTEGER NOT NULL,
  estimated_cost_usd REAL NOT NULL,  -- pre-call estimate
  actual_cost_usd REAL NOT NULL,     -- post-call actual from SDK metadata
  recorded_at TEXT NOT NULL,
  FOREIGN KEY (merge_queue_id) REFERENCES merge_queue(id)
);

CREATE INDEX IF NOT EXISTS idx_merge_costs_session
  ON merge_costs (session_id);

CREATE INDEX IF NOT EXISTS idx_merge_costs_date
  ON merge_costs (recorded_at);
```

### 12.2 `foreman merge --stats`

Display cumulative AI resolution cost statistics:

```
$ foreman merge --stats

AI Resolution Cost Summary
--------------------------
Today:       $0.82 (3 sessions, 8 files)
This week:   $4.17 (12 sessions, 31 files)
This month:  $18.43 (47 sessions, 124 files)
All time:    $42.91 (112 sessions, 298 files)

Avg cost per file:  $0.14
Avg cost per session: $0.38

By tier:
  Tier 3 (Sonnet): $12.18 (267 files, avg $0.05/file)
  Tier 4 (Opus):   $30.73 (31 files, avg $0.99/file)

By model:
  claude-sonnet-4-6:  $12.18
  claude-opus-4-6:       $30.73
```

- Time periods: today, this week (Mon-Sun), this month (calendar), all time
- Breakdowns by tier and model
- `--stats --json` outputs structured JSON for CI/scripting integration

**Acceptance Criteria:**
- AC-COST.1: Every AI resolution call (Tier 3/4) records actual cost to `merge_costs` table
- AC-COST.2: `foreman merge --stats` displays daily, weekly, monthly, and all-time cost summaries
- AC-COST.3: Cost breakdown by tier and model is available in stats output
- AC-COST.4: `foreman merge --stats --json` outputs valid JSON for programmatic consumption
- AC-COST.5: Cost tracking is fire-and-forget (recording errors logged but never block merge)

---

## 13. Version History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-03-12 | Product Management | Initial PRD draft with 10 functional requirements, 4 open questions |
| 2.0 | 2026-03-12 | Product Management | Refined PRD based on stakeholder interview. Key changes: (1) Resolved all 4 open questions -- hybrid auto-enqueue with reconciliation, Sonnet/Opus model tiering, parallel AI with sequential commits, direct git + git-town hybrid. (2) Added per-file syntax validation and full test suite per merge commit. (3) Added auto-revert + PR escalation on post-merge test failure. (4) Updated Tier 2 safety check to hybrid threshold (lines OR percentage, configurable). (5) Added cost controls: per-session budget cap ($5 default) and per-file size gate (1000 lines default). (6) Changed transition strategy: new behavior default from day one with --legacy escape hatch, removed after 50 successful queue merges. (7) Added running success rate display in merge output. (8) Added parallel merge architecture (--parallel N flag). (9) Added Configuration Reference section (Section 10). (10) Updated acceptance criteria throughout to reflect new requirements. |
| 3.0 | 2026-03-12 | Product Management | Second refinement pass with 10 additional stakeholder decisions. Key changes: (1) Tier 2 changed from global `git merge -X theirs` to per-file `git checkout --theirs` with per-file safety check -- files failing safety check cascade independently to Tier 3. (2) Per-file tier cascade -- each conflicted file independently progresses through tiers; a single merge commit can contain files resolved by different tiers. (3) Configurable syntax checker map in `.foreman/config.json` with defaults for .ts/.js and accept-without-check for unmapped extensions. (4) Post-merge test failure records all AI-resolved files to conflict_patterns with failure_reason for pattern learning. (5) Reconciliation scan validates branch existence before enqueuing -- skips deleted branches with log message. (6) Confirmed hard error for --legacy after 50 merges (no grace period). (7) Overlap-aware queue ordering with graph-based conflict clustering -- independent clusters processed in parallel, FIFO within clusters, re-clustering after each merge. (8) Tier 4 uses `git merge --no-commit --no-ff` to preserve two-parent merge topology. (9) Cost tracking uses estimated + actuals from Claude SDK response metadata with soft budget enforcement (current file completes, subsequent files skip AI). (10) Added conflict-cluster.ts to suggested module structure. (11) Extended conflict_patterns schema with failure_reason and merge_queue_id columns. (12) Added 9 new resolved questions (9.5-9.13). (13) Updated 5 new acceptance criteria for FR-1 (AC-1.16 through AC-1.20) and 5 for FR-3 (AC-3.11 through AC-3.15) and 2 for FR-7 (AC-7.6, AC-7.7). |
| 4.0 | 2026-03-12 | Product Management | Third refinement pass (polish). 6 stakeholder decisions. Key changes: (1) Replaced hardcoded prose detection prefix list with language-aware first-line heuristic -- built-in patterns for .ts/.js, .py, .go with generic fallback for unmapped extensions; patterns configurable via `mergeQueue.proseDetection` in config. (2) Clarified `resolved_tier` schema column stores max tier used (single integer); per-file detail available in MergeReport and conflict_patterns table. (3) Changed post-merge test failure recovery from `git revert --no-edit HEAD` to `git reset --hard HEAD~1` to avoid anti-merge pitfall where revert prevents future re-merge of the branch. (4) Added structured error code system (MQ-001 through MQ-020) covering all failure modes -- budget, validation, AI, test, queue, branch, merge, pattern, legacy, and state errors; referenceable in docs and usable for programmatic CI handling (Section 11). (5) Added cumulative AI cost tracking with `merge_costs` SQLite table and `foreman merge --stats` command showing daily/weekly/monthly/all-time cost summaries with tier and model breakdowns (Section 12). (6) Confirmed `tsc --noEmit` for full TypeScript type checking (thoroughness over speed). Added 3 new FR-1 acceptance criteria (AC-1.21 through AC-1.23) and 5 cost tracking acceptance criteria (AC-COST.1 through AC-COST.5). |
| 5.0 | 2026-03-12 | Product Management | Final quality pass. 4 stakeholder decisions focused on cross-feature edge cases and internal consistency. Key changes: (1) Parallel budget tracking is optimistic/approximate -- each worker tracks independently, session total may slightly exceed cap; simplicity over precision (resolved question 9.18). (2) Syntax check performance target increased from 5s to 15s per file to accommodate full `tsc --noEmit` project-wide type checking (resolved question 9.20). (3) Re-clustering after merge commit cancels in-progress AI resolution work in invalidated clusters and re-queues entries; correctness over efficiency (resolved question 9.19). (4) Added two acceptance criteria to FR-8 (Dry-Run): AC-8.5 for showing estimated resolution tiers when FR-7 data exists, AC-8.6 for graceful degradation when FR-7 is unavailable (resolved question 9.21). (5) Fixed error code range descriptions in Section 11 which had overlapping ranges (007-009 was listed in two categories). (6) Added 2 new FR-3 acceptance criteria (AC-3.16 for parallel budget, AC-3.17 for re-clustering cancellation). (7) Updated Section 6.5 parallel architecture with re-clustering cancellation semantics and budget tracking approach. (8) Added 4 new resolved questions (9.18-9.21). |
