import type Database from "better-sqlite3";
import { orderByCluster } from "./conflict-cluster.js";
import { detectDefaultBranch } from "../lib/git.js";
import { GitBackend } from "../lib/vcs/git-backend.js";

// ── Types ──────────────────────────────────────────────────────────────

export type MergeQueueStatus = "pending" | "merging" | "merged" | "conflict" | "failed";

export interface MergeQueueEntry {
  id: number;
  branch_name: string;
  seed_id: string;
  run_id: string;
  agent_name: string | null;
  files_modified: string[];
  enqueued_at: string;
  started_at: string | null;
  completed_at: string | null;
  status: MergeQueueStatus;
  resolved_tier: number | null;
  error: string | null;
  retry_count: number;
  last_attempted_at: string | null;
}

/** Raw row shape from SQLite (files_modified is a JSON string). */
interface MergeQueueRow {
  id: number;
  branch_name: string;
  seed_id: string;
  run_id: string;
  agent_name: string | null;
  files_modified: string;
  enqueued_at: string;
  started_at: string | null;
  completed_at: string | null;
  status: MergeQueueStatus;
  resolved_tier: number | null;
  error: string | null;
  retry_count: number;
  last_attempted_at: string | null;
}

interface EnqueueInput {
  branchName: string;
  seedId: string;
  runId: string;
  agentName?: string;
  filesModified?: string[];
}

export interface MissingFromQueueEntry {
  run_id: string;
  seed_id: string;
}

export interface ReconcileResult {
  enqueued: number;
  skipped: number;
  invalidBranch: number;
  failedToEnqueue: Array<{ run_id: string; seed_id: string; reason: string }>;
}

/** Signature for an injected execFile-style async function. */
export type ExecFileAsyncFn = (
  cmd: string,
  args: string[],
  options?: { cwd?: string }
) => Promise<{ stdout: string; stderr: string }>;

// ── Retry Policy ───────────────────────────────────────────────────────

export const RETRY_CONFIG = {
  maxRetries: 3,
  initialDelayMs: 60_000,       // 1 minute
  maxDelayMs: 3_600_000,        // 1 hour
  backoffMultiplier: 2,
};

// ── Helpers ────────────────────────────────────────────────────────────

function rowToEntry(row: MergeQueueRow): MergeQueueEntry {
  return {
    ...row,
    files_modified: JSON.parse(row.files_modified) as string[],
    retry_count: row.retry_count ?? 0,
    last_attempted_at: row.last_attempted_at ?? null,
  };
}

// ── MergeQueue ─────────────────────────────────────────────────────────

export class MergeQueue {
  private db: Database.Database;

  constructor(db: Database.Database) {
    this.db = db;
  }

  /**
   * Add a branch to the merge queue.
   * Idempotent: if the same branch_name+run_id already exists, return the existing entry.
   */
  enqueue(input: EnqueueInput): MergeQueueEntry {
    const { branchName, seedId, runId, agentName, filesModified } = input;

    // Check for existing entry (idempotency)
    const existing = this.db
      .prepare("SELECT * FROM merge_queue WHERE branch_name = ? AND run_id = ?")
      .get(branchName, runId) as MergeQueueRow | undefined;

    if (existing) {
      return rowToEntry(existing);
    }

    const now = new Date().toISOString();
    const filesJson = JSON.stringify(filesModified ?? []);

    const row = this.db
      .prepare(
        `INSERT INTO merge_queue (branch_name, seed_id, run_id, agent_name, files_modified, enqueued_at, status)
         VALUES (?, ?, ?, ?, ?, ?, 'pending')
         RETURNING *`
      )
      .get(branchName, seedId, runId, agentName ?? null, filesJson, now) as MergeQueueRow;

    return rowToEntry(row);
  }

  /**
   * Atomically claim the next pending entry.
   * Sets status to 'merging' and started_at to now.
   * Returns null if no pending entries exist.
   */
  dequeue(): MergeQueueEntry | null {
    const now = new Date().toISOString();
    const row = this.db
      .prepare(
        `UPDATE merge_queue
         SET status = 'merging', started_at = ?
         WHERE id = (
           SELECT id FROM merge_queue
           WHERE status = 'pending'
           ORDER BY enqueued_at ASC
           LIMIT 1
         )
         RETURNING *`
      )
      .get(now) as MergeQueueRow | undefined;

    return row ? rowToEntry(row) : null;
  }

  /**
   * Peek at the next pending entry without claiming it.
   */
  peek(): MergeQueueEntry | null {
    const row = this.db
      .prepare(
        "SELECT * FROM merge_queue WHERE status = 'pending' ORDER BY enqueued_at ASC LIMIT 1"
      )
      .get() as MergeQueueRow | undefined;

    return row ? rowToEntry(row) : null;
  }

  /**
   * List entries, optionally filtered by status.
   */
  list(status?: MergeQueueStatus): MergeQueueEntry[] {
    let rows: MergeQueueRow[];
    if (status) {
      rows = this.db
        .prepare("SELECT * FROM merge_queue WHERE status = ? ORDER BY enqueued_at ASC")
        .all(status) as MergeQueueRow[];
    } else {
      rows = this.db
        .prepare("SELECT * FROM merge_queue ORDER BY enqueued_at ASC")
        .all() as MergeQueueRow[];
    }
    return rows.map(rowToEntry);
  }

  /**
   * Update the status (and optional extra fields) of an entry.
   */
  updateStatus(
    id: number,
    status: MergeQueueStatus,
    extra?: { resolvedTier?: number; error?: string; completedAt?: string; lastAttemptedAt?: string; retryCount?: number }
  ): void {
    const fields = ["status = ?"];
    const params: unknown[] = [status];

    if (extra?.resolvedTier !== undefined) {
      fields.push("resolved_tier = ?");
      params.push(extra.resolvedTier);
    }
    if (extra?.error !== undefined) {
      fields.push("error = ?");
      params.push(extra.error);
    }
    if (extra?.completedAt !== undefined) {
      fields.push("completed_at = ?");
      params.push(extra.completedAt);
    }
    if (extra?.lastAttemptedAt !== undefined) {
      fields.push("last_attempted_at = ?");
      params.push(extra.lastAttemptedAt);
    }
    if (extra?.retryCount !== undefined) {
      fields.push("retry_count = ?");
      params.push(extra.retryCount);
    }

    params.push(id);
    this.db
      .prepare(`UPDATE merge_queue SET ${fields.join(", ")} WHERE id = ?`)
      .run(...params);
  }

  /**
   * Reset a failed/conflict entry for a given seed back to 'pending' so it
   * can be retried. Used by `foreman merge --seed <id>` to allow re-processing
   * entries that previously ended in a terminal failure state.
   *
   * Returns true if an entry was reset, false if no retryable entry was found.
   */
  resetForRetry(seedId: string): boolean {
    const now = new Date().toISOString();
    const result = this.db
      .prepare(
        `UPDATE merge_queue
         SET status = 'pending', error = NULL, started_at = NULL, last_attempted_at = ?
         WHERE seed_id = ? AND status IN ('failed', 'conflict', 'merging')
         RETURNING id`
      )
      .get(now, seedId);
    return result != null;
  }

  /**
   * Calculate the delay (in ms) before the next retry attempt using exponential backoff.
   */
  private retryDelayMs(retryCount: number): number {
    const delay = RETRY_CONFIG.initialDelayMs * Math.pow(RETRY_CONFIG.backoffMultiplier, retryCount);
    return Math.min(delay, RETRY_CONFIG.maxDelayMs);
  }

  /**
   * Determine whether an entry is eligible for automatic retry.
   * Returns true if retry_count < maxRetries AND enough time has passed since last attempt.
   */
  shouldRetry(entry: MergeQueueEntry): boolean {
    if (entry.retry_count >= RETRY_CONFIG.maxRetries) return false;
    if (!entry.last_attempted_at) return true;
    const elapsed = Date.now() - new Date(entry.last_attempted_at).getTime();
    return elapsed >= this.retryDelayMs(entry.retry_count);
  }

  /**
   * Return all conflict/failed entries that are eligible for automatic retry.
   */
  getRetryableEntries(): MergeQueueEntry[] {
    const rows = this.db
      .prepare("SELECT * FROM merge_queue WHERE status IN ('conflict', 'failed') ORDER BY enqueued_at ASC")
      .all() as MergeQueueRow[];
    return rows.map(rowToEntry).filter((e) => this.shouldRetry(e));
  }

  /**
   * Re-enqueue a failed/conflict entry by resetting it to pending.
   * Increments retry_count and records last_attempted_at.
   * Returns true if successful, false if entry not found or max retries exceeded.
   */
  reEnqueue(id: number): boolean {
    const now = new Date().toISOString();
    const result = this.db
      .prepare(
        `UPDATE merge_queue
         SET status = 'pending', error = NULL, started_at = NULL,
             retry_count = retry_count + 1, last_attempted_at = ?
         WHERE id = ? AND status IN ('conflict', 'failed') AND retry_count < ${RETRY_CONFIG.maxRetries}
         RETURNING id`
      )
      .get(now, id);
    return result != null;
  }

  /**
   * Delete an entry from the queue.
   */
  remove(id: number): void {
    this.db.prepare("DELETE FROM merge_queue WHERE id = ?").run(id);
  }

  /**
   * Return all pending entries ordered by conflict cluster.
   * Entries within the same cluster (sharing modified files) are grouped consecutively.
   * Within each cluster, FIFO order (by enqueued_at) is maintained.
   */
  getOrderedPending(): MergeQueueEntry[] {
    const pending = this.list("pending");
    return orderByCluster(pending);
  }

  /**
   * Atomically claim the next pending entry using cluster-aware ordering.
   * Entries that share modified files with each other are processed consecutively
   * to reduce merge conflict likelihood.
   * Returns null if no pending entries exist.
   */
  dequeueOrdered(): MergeQueueEntry | null {
    const ordered = this.getOrderedPending();
    if (ordered.length === 0) return null;

    const target = ordered[0];
    const now = new Date().toISOString();

    const row = this.db
      .prepare(
        `UPDATE merge_queue
         SET status = 'merging', started_at = ?
         WHERE id = ? AND status = 'pending'
         RETURNING *`
      )
      .get(now, target.id) as MergeQueueRow | undefined;

    return row ? rowToEntry(row) : null;
  }

  /**
   * Return completed runs that are NOT present in the merge queue.
   * Used to detect runs that completed but were never enqueued (e.g. due to
   * missing branches, reconciliation failures, or system crashes).
   */
  missingFromQueue(): MissingFromQueueEntry[] {
    return this.db
      .prepare(
        `SELECT r.id AS run_id, r.seed_id
         FROM runs r
         WHERE r.status = 'completed'
         AND r.id NOT IN (SELECT run_id FROM merge_queue)
         ORDER BY r.created_at ASC`
      )
      .all() as MissingFromQueueEntry[];
  }

  /**
   * Reconcile completed runs with the merge queue.
   * For each completed run not already queued, validate its branch exists
   * and enqueue it with the list of modified files.
   */
  async reconcile(
    db: Database.Database,
    repoPath: string,
    backend?: GitBackend
  ): Promise<ReconcileResult> {
    const git = backend ?? new GitBackend(repoPath);
    // Get all completed runs
    const completedRuns = db
      .prepare("SELECT * FROM runs WHERE status = 'completed' ORDER BY created_at ASC")
      .all() as Array<{ id: string; seed_id: string }>;

    // Get all run_ids AND seed_ids already in merge_queue.
    // Dedup by seed_id so that sentinel-created duplicate completed runs for
    // the same seed don't each create a separate queue entry.
    const mqRows = db
      .prepare("SELECT run_id, seed_id FROM merge_queue")
      .all() as Array<{ run_id: string; seed_id: string }>;
    const existingRunIds = new Set(mqRows.map((r) => r.run_id));
    const existingSeedIds = new Set(mqRows.map((r) => r.seed_id));

    const defaultBranch = await detectDefaultBranch(repoPath);

    let enqueued = 0;
    let skipped = 0;
    let invalidBranch = 0;
    const failedToEnqueue: Array<{ run_id: string; seed_id: string; reason: string }> = [];

    for (const run of completedRuns) {
      // Skip if this exact run is already queued
      if (existingRunIds.has(run.id)) {
        skipped++;
        continue;
      }
      // Skip if any run for this seed is already queued (dedup sentinel retries)
      if (existingSeedIds.has(run.seed_id)) {
        skipped++;
        continue;
      }

      const branchName = `foreman/${run.seed_id}`;

      // Validate branch exists via VcsBackend
      const exists = await git.branchExists(repoPath, branchName);
      if (!exists) {
        invalidBranch++;
        failedToEnqueue.push({
          run_id: run.id,
          seed_id: run.seed_id,
          reason: `branch '${branchName}' not found`,
        });
        continue;
      }

      // Get modified files via VcsBackend
      const filesModified = await git.getChangedFiles(repoPath, defaultBranch, branchName);

      this.enqueue({
        branchName,
        seedId: run.seed_id,
        runId: run.id,
        filesModified,
      });
      // Track newly enqueued seed so further duplicates in this batch are skipped
      existingSeedIds.add(run.seed_id);
      enqueued++;
    }

    // Secondary pass: recover runs that pushed a branch but crashed before the
    // run status was updated to "completed". We check for a remote-tracking ref
    // (refs/remotes/origin/foreman/<seedId>) which only exists after a successful
    // git push. This is defense-in-depth on top of the primary fix that marks runs
    // as "completed" before calling finalize().
    const interruptedRuns = db
      .prepare(
        "SELECT * FROM runs WHERE status IN ('pending', 'running') ORDER BY created_at ASC"
      )
      .all() as Array<{ id: string; seed_id: string; created_at: string | null }>;

    // Deduplicate by seed_id: only process the oldest run per seed. A seed maps
    // 1-to-1 with a branch name (foreman/<seedId>), so if multiple runs exist for
    // the same seed (e.g. a crashed old run and a newly-dispatched replacement),
    // we must not falsely mark the newer run "completed" just because the old
    // remote-tracking ref is still present. Taking the oldest (created_at ASC)
    // ensures we recover the run that actually pushed the branch.
    const seenSeedIds = new Set<string>();

    for (const run of interruptedRuns) {
      if (existingRunIds.has(run.id)) {
        // Already in merge queue — skip (enqueue is idempotent, but avoid double-counting)
        continue;
      }

      // Only recover one run per seed to avoid marking a newer in-progress run
      // as "completed" when the old remote ref is still present.
      if (seenSeedIds.has(run.seed_id)) {
        continue;
      }
      seenSeedIds.add(run.seed_id);

      const branchName = `foreman/${run.seed_id}`;

      // Check if the remote branch exists (indicates push succeeded before crash)
      const remoteExists = await git.branchExistsOnRemote(repoPath, branchName);
      if (!remoteExists) {
        // No remote branch — run is genuinely in-progress or never pushed
        continue;
      }

      // Guard against stale remote tracking refs after `foreman reset`:
      // `foreman reset` deletes the local branch but the remote tracking ref
      // (refs/remotes/origin/foreman/<seedId>) may persist until a `git fetch
      // --prune` is run. If the remote branch's latest commit predates this
      // run's creation time, the ref is left over from a previous (reset) run —
      // not from this one. Enqueuing it would cause an immediate merge-failed
      // with reason "no-commits" because the newly-dispatched branch is empty.
      //
      // If we cannot determine the commit timestamp, we skip conservatively to
      // avoid false-positive recovery (the reconcile() primary pass handles the
      // normal completion path).
      if (run.created_at) {
        const runCreatedMs = new Date(run.created_at).getTime();
        const commitTs = await git.getRefCommitTimestamp(repoPath, `refs/remotes/origin/${branchName}`);
        if (commitTs === null) {
          // Cannot determine commit timestamp — skip to avoid false recovery.
          // The reconcile() primary pass handles completed runs normally.
          continue;
        }
        const commitMs = commitTs * 1000;
        if (commitMs < runCreatedMs) {
          // Remote branch was pushed before this run was created — stale ref
          // from a previous run (e.g. after foreman reset --seed <id>).
          // Skip to prevent the refinery from attempting a merge with no commits.
          continue;
        }
      }

      // Remote branch exists and its commit is at-or-after this run's creation —
      // this run pushed its branch but crashed before updating its status.
      // Recover it now.
      const recoveredAt = new Date().toISOString();
      db.prepare("UPDATE runs SET status = 'completed', completed_at = ? WHERE id = ?").run(
        recoveredAt,
        run.id
      );

      // Get modified files via VcsBackend
      const recoveredFiles = await git.getChangedFiles(repoPath, defaultBranch, branchName);

      this.enqueue({
        branchName,
        seedId: run.seed_id,
        runId: run.id,
        filesModified: recoveredFiles,
      });
      enqueued++;
    }

    return { enqueued, skipped, invalidBranch, failedToEnqueue };
  }
}
