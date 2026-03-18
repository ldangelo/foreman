import type Database from "better-sqlite3";
import { orderByCluster } from "./conflict-cluster.js";

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
}

interface EnqueueInput {
  branchName: string;
  seedId: string;
  runId: string;
  agentName?: string;
  filesModified?: string[];
}

interface ReconcileResult {
  enqueued: number;
  skipped: number;
  invalidBranch: number;
}

/** Signature for an injected execFile-style async function. */
export type ExecFileAsyncFn = (
  cmd: string,
  args: string[],
  options?: { cwd?: string }
) => Promise<{ stdout: string; stderr: string }>;

// ── Helpers ────────────────────────────────────────────────────────────

function rowToEntry(row: MergeQueueRow): MergeQueueEntry {
  return {
    ...row,
    files_modified: JSON.parse(row.files_modified) as string[],
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
    extra?: { resolvedTier?: number; error?: string; completedAt?: string }
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
    const result = this.db
      .prepare(
        `UPDATE merge_queue
         SET status = 'pending', error = NULL, started_at = NULL
         WHERE seed_id = ? AND status IN ('failed', 'conflict', 'merging')
         RETURNING id`
      )
      .get(seedId);
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
   * Reconcile completed runs with the merge queue.
   * For each completed run not already queued, validate its branch exists
   * and enqueue it with the list of modified files.
   */
  async reconcile(
    db: Database.Database,
    repoPath: string,
    execFileAsync: ExecFileAsyncFn
  ): Promise<ReconcileResult> {
    // Get all completed runs
    const completedRuns = db
      .prepare("SELECT * FROM runs WHERE status = 'completed' ORDER BY created_at ASC")
      .all() as Array<{ id: string; seed_id: string }>;

    // Get all run_ids already in merge_queue
    const existingRunIds = new Set(
      (
        db
          .prepare("SELECT run_id FROM merge_queue")
          .all() as Array<{ run_id: string }>
      ).map((r) => r.run_id)
    );

    let enqueued = 0;
    let skipped = 0;
    let invalidBranch = 0;

    for (const run of completedRuns) {
      if (existingRunIds.has(run.id)) {
        skipped++;
        continue;
      }

      const branchName = `foreman/${run.seed_id}`;

      // Validate branch exists
      try {
        await execFileAsync("git", ["rev-parse", "--verify", `refs/heads/${branchName}`], {
          cwd: repoPath,
        });
      } catch {
        invalidBranch++;
        continue;
      }

      // Get modified files
      let filesModified: string[] = [];
      try {
        const { stdout } = await execFileAsync(
          "git",
          ["diff", "--name-only", `main...${branchName}`],
          { cwd: repoPath }
        );
        filesModified = stdout.trim().split("\n").filter(Boolean);
      } catch {
        // If diff fails, proceed with empty files list
      }

      this.enqueue({
        branchName,
        seedId: run.seed_id,
        runId: run.id,
        filesModified,
      });
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
      .all() as Array<{ id: string; seed_id: string }>;

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
      try {
        await execFileAsync(
          "git",
          ["rev-parse", "--verify", `refs/remotes/origin/${branchName}`],
          { cwd: repoPath }
        );
      } catch {
        // No remote branch — run is genuinely in-progress or never pushed
        continue;
      }

      // Remote branch exists but run status was never updated — recover it
      const recoveredAt = new Date().toISOString();
      db.prepare("UPDATE runs SET status = 'completed', completed_at = ? WHERE id = ?").run(
        recoveredAt,
        run.id
      );

      // Get modified files
      let recoveredFiles: string[] = [];
      try {
        const { stdout } = await execFileAsync(
          "git",
          ["diff", "--name-only", `main...${branchName}`],
          { cwd: repoPath }
        );
        recoveredFiles = stdout.trim().split("\n").filter(Boolean);
      } catch {
        // If diff fails, proceed with empty files list
      }

      this.enqueue({
        branchName,
        seedId: run.seed_id,
        runId: run.id,
        filesModified: recoveredFiles,
      });
      enqueued++;
    }

    return { enqueued, skipped, invalidBranch };
  }
}
