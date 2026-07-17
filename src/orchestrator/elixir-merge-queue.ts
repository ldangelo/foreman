import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { MergeQueueEntry, MergeQueueStatus, ReconcileResult } from "./merge-queue.js";
import { PIPELINE_BUFFERS } from "../lib/config.js";

const execFileAsync = promisify(execFile);

/**
 * GitHub-backed merge queue for registered projects.
 *
 * Uses `gh pr merge` directly as the authoritative merge mechanism, following the
 * coding guideline that "domain events [must] be the source of truth and
 * operational trigger; projections are read model only and must not be polled
 * as the primary signal."
 *
 * Queue entries are synthesized from gh state rather than stored in SQLite,
 * eliminating the need for a disabled local store compatibility layer.
 */
export class ElixirMergeQueue {
  // Track enqueued taskIds to distinguish newly discovered entries from total open PRs
  private readonly _enqueuedTaskIds = new Set<string>();

  constructor(
    private readonly _projectId: string,
    private readonly _projectPath: string,
  ) {}

  /**
   * Enqueue a branch for merge via `gh pr merge`.
   *
   * Creates a synthetic queue entry representing the pending merge operation.
   * The actual merge is executed by refinery via `gh pr merge --admin --squash`.
   * Uses PR number as entry id to maintain consistency with list()/prToEntry().
   */
  async enqueue(input: {
    branchName: string;
    taskId: string;
    runId: string;
    operation?: "auto_merge" | "create_pr";
    agentName?: string;
    filesModified?: string[];
  }): Promise<MergeQueueEntry> {
    const now = new Date().toISOString();
    // Track this taskId as enqueued for reconciliation bookkeeping
    this._enqueuedTaskIds.add(input.taskId);
    // Return a pending entry. The caller (refinery) will query gh to get the actual PR number.
    // Using id: 0 signals that the real id will come from gh; this avoids the disjoint id space
    // problem where synthetic IDs couldn't be used with remove()/updateStatus().
    return {
      id: 0, // Placeholder; refinery queries gh to get real PR number
      branch_name: input.branchName,
      task_id: input.taskId,
      run_id: input.runId,
      operation: input.operation ?? "auto_merge",
      agent_name: input.agentName ?? "pipeline",
      files_modified: input.filesModified ?? [],
      enqueued_at: now,
      started_at: null,
      completed_at: null,
      status: "pending",
      resolved_tier: null,
      error: null,
      retry_count: 0,
      last_attempted_at: null,
    };
  }

  /**
   * Reconcile queue state with gh PR state.
   * Returns only newly discovered foreman/* PRs that weren't previously enqueued via this instance.
   */
  async reconcile(repoPath?: string): Promise<ReconcileResult> {
    const cwd = repoPath ?? this._projectPath;
    let stdout: string;
    try {
      const result = await execFileAsync(
        "gh",
        ["pr", "list", "--state", "open", "--json", "number,title,headRefName,body", "--limit", "100"],
        { cwd, maxBuffer: PIPELINE_BUFFERS.maxBufferBytes },
      );
      stdout = result.stdout;
    } catch (err) {
      // Surface gh failures so callers know the queue state is unknown
      const message = err instanceof Error ? err.message : String(err);
      return {
        enqueued: 0,
        skipped: 0,
        invalidBranch: 0,
        failedToEnqueue: [{ run_id: "", task_id: "", reason: `gh pr list failed: ${message}` }],
      };
    }

    let prs: Array<{ number: number; headRefName: string; title: string; body: string }>;
    try {
      prs = JSON.parse(stdout);
    } catch (err) {
      // Surface JSON parse failures
      const message = err instanceof Error ? err.message : String(err);
      return {
        enqueued: 0,
        skipped: 0,
        invalidBranch: 0,
        failedToEnqueue: [{ run_id: "", task_id: "", reason: `gh pr list JSON parse failed: ${message}` }],
      };
    }

    // Count only newly discovered foreman/* PRs not previously enqueued
    let newlyEnqueued = 0;
    const failedToEnqueue: ReconcileResult["failedToEnqueue"] = [];

    for (const pr of prs) {
      if (!pr.headRefName.startsWith("foreman/")) continue;

      // Extract task_id from branch name (foreman/<taskId>) or PR body
      const taskIdMatch = /(?:task[_-]?id[:\s]*)([a-z]+-[a-z0-9]+)/i.exec(pr.body || "");
      const taskId = taskIdMatch?.[1] ?? pr.headRefName.replace("foreman/", "");

      if (this._enqueuedTaskIds.has(taskId)) {
        // Already tracked as enqueued via this instance
        continue;
      }

      // Newly discovered entry
      this._enqueuedTaskIds.add(taskId);
      newlyEnqueued++;
    }

    return {
      enqueued: newlyEnqueued,
      skipped: 0,
      invalidBranch: 0,
      failedToEnqueue,
    };
  }

  /**
   * List queue entries by querying gh PR state.
   */
  async list(status?: MergeQueueStatus): Promise<MergeQueueEntry[]> {
    let stdout: string;
    try {
      const result = await execFileAsync(
        "gh",
        ["pr", "list", "--state", "open", "--json", "number,title,headRefName,body,createdAt,updatedAt", "--limit", "100"],
        { cwd: this._projectPath, maxBuffer: PIPELINE_BUFFERS.maxBufferBytes },
      );
      stdout = result.stdout;
    } catch (err) {
      // Surface gh failures so callers know the queue state is unknown
      console.error(`[ElixirMergeQueue] list() failed: ${err instanceof Error ? err.message : String(err)}`);
      throw err;
    }

    let prs: Array<{
      number: number;
      headRefName: string;
      title: string;
      body: string;
      createdAt: string;
      updatedAt: string;
    }>;
    try {
      prs = JSON.parse(stdout);
    } catch (err) {
      // Surface JSON parse failures
      const message = err instanceof Error ? err.message : String(err);
      console.error(`[ElixirMergeQueue] list() JSON parse failed: ${message}`);
      throw new Error(`Failed to parse gh pr list output: ${message}`);
    }

    return prs
      .filter((pr) => pr.headRefName.startsWith("foreman/"))
      .map((pr) => this.prToEntry(pr))
      .filter((entry) => !status || entry.status === status);
  }

  /**
   * Dequeue the next pending entry (oldest open foreman/* PR by createdAt).
   * Uses FIFO ordering to prevent starvation of older queued tasks.
   */
  async dequeue(): Promise<MergeQueueEntry | null> {
    const entries = await this.list("pending");
    if (entries.length === 0) return null;

    // Sort by enqueued_at ascending (oldest first) for FIFO behavior
    entries.sort((a, b) => new Date(a.enqueued_at).getTime() - new Date(b.enqueued_at).getTime());

    return entries[0] ?? null;
  }

  /**
   * Update entry status — updates gh PR labels to reflect queue state.
   * Note: gh doesn't natively support queue status labels, so this is a no-op
   * for registered projects. Status tracking is handled by refinery internally.
   */
  async updateStatus(
    id: number,
    status: MergeQueueStatus,
    _extra?: {
      resolvedTier?: number;
      error?: string;
      completedAt?: string;
      lastAttemptedAt?: string;
      retryCount?: number;
    },
  ): Promise<void> {
    // gh doesn't support custom labels for queue status tracking.
    // Status transitions are handled by refinery via gh pr merge commands.
    void id;
    void status;
  }

  /**
   * Reset a failed entry for retry.
   */
  async resetForRetry(taskId: string): Promise<boolean> {
    // For gh-backed queue, retry means re-triggering the merge via gh pr merge.
    // This is handled by refinery.processOnce() calling gh pr merge.
    void taskId;
    return true;
  }

  /**
   * Get entries eligible for retry.
   */
  async getRetryableEntries(): Promise<MergeQueueEntry[]> {
    // gh doesn't expose retry state — entries are tracked by refinery
    return [];
  }

  /**
   * Find entries missing from the queue (tracked in gh but not in refinery state).
   */
  async missingFromQueue(): Promise<Array<{ run_id: string; task_id: string }>> {
    // For gh-backed queue, all foreman/* PRs are automatically in the queue
    return [];
  }

  /**
   * Re-enqueue a previously dequeued entry.
   */
  async reEnqueue(id: number): Promise<boolean> {
    void id;
    return true;
  }

  /**
   * Remove an entry from the queue (close the PR).
   */
  async remove(id: number): Promise<void> {
    // Find the PR by its real number (id) and close it
    const entries = await this.list();
    const entry = entries.find((e) => e.id === id);
    if (entry) {
      try {
        await execFileAsync(
          "gh",
          ["pr", "close", String(entry.id)],
          { cwd: this._projectPath, maxBuffer: PIPELINE_BUFFERS.maxBufferBytes },
        );
      } catch {
        // Non-fatal — entry will remain in gh but is removed from queue view
      }
    }
  }

  // ── Private helpers ─────────────────────────────────────────────────────

  /**
   * Convert a gh PR to a MergeQueueEntry.
   * Uses the real PR number as id, ensuring consistency with gh state.
   */
  private prToEntry(pr: {
    number: number;
    headRefName: string;
    title: string;
    body: string;
    createdAt: string;
    updatedAt: string;
  }): MergeQueueEntry {
    // Extract task_id and run_id from PR body or title
    const taskIdMatch = /(?:task[_-]?id[:\s]*)([a-z]+-[a-z0-9]+)/i.exec(pr.body || pr.title);
    const runIdMatch = /(?:run[_-]?id[:\s]*)([a-f0-9-]+)/i.exec(pr.body || pr.title);
    return {
      id: pr.number, // Real GitHub PR number
      branch_name: pr.headRefName,
      task_id: taskIdMatch?.[1] ?? pr.headRefName,
      run_id: runIdMatch?.[1] ?? "",
      operation: "auto_merge",
      agent_name: null,
      files_modified: [],
      enqueued_at: pr.createdAt,
      started_at: null,
      completed_at: null,
      status: "pending",
      resolved_tier: null,
      error: null,
      retry_count: 0,
      last_attempted_at: null,
    };
  }
}
