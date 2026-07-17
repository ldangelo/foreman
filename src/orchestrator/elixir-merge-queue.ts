import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { MergeQueueEntry, MergeQueueStatus, ReconcileResult } from "./merge-queue.js";
import { PIPELINE_BUFFERS } from "../lib/config.js";

const execFileAsync = promisify(execFile);

// Standard timeout for gh CLI operations (30 seconds)
const GH_TIMEOUT_MS = 30_000;

// Label prefix for foreman queue metadata
const FOREMAN_LABEL_PREFIX = "foreman/";
const STATUS_LABEL_PREFIX = `${FOREMAN_LABEL_PREFIX}status:`;
const OPERATION_LABEL_PREFIX = `${FOREMAN_LABEL_PREFIX}operation:`;

/**
 * GitHub-backed merge queue for registered projects.
 *
 * Uses `gh pr merge` directly as the authoritative merge mechanism, following the
 * coding guideline that "domain events [must] be the source of truth and
 * operational trigger; projections are read model only and must not be polled
 * as the primary signal."
 *
 * Queue entries are synthesized from gh state. Status and operation are tracked
 * via gh labels on the PRs:
 *   - foreman/status:<status> — tracks queue lifecycle state
 *   - foreman/operation:<operation> — preserves enqueue intent (auto_merge or create_pr)
 *
 * This ensures terminal entries (merged, conflict, failed) are not recreated
 * as pending and that create_pr entries retain their operation for downstream handling.
 */
export class ElixirMergeQueue {
  // Track enqueued taskIds to distinguish newly discovered entries from total open PRs
  private readonly _enqueuedTaskIds = new Set<string>();
  // Track operation per taskId for entries enqueued before PR is created
  private readonly _taskOperations = new Map<string, "auto_merge" | "create_pr">();

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
    const operation = input.operation ?? "auto_merge";
    // Track this taskId and its operation for later retrieval when the PR is discovered
    this._enqueuedTaskIds.add(input.taskId);
    this._taskOperations.set(input.taskId, operation);
    // Return a pending entry. The caller (refinery) will query gh to get the actual PR number.
    // Using id: 0 signals that the real id will come from gh; this avoids the disjoint id space
    // problem where synthetic IDs couldn't be used with remove()/updateStatus().
    return {
      id: 0, // Placeholder; refinery queries gh to get real PR number
      branch_name: input.branchName,
      task_id: input.taskId,
      run_id: input.runId,
      operation,
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
        { cwd, maxBuffer: PIPELINE_BUFFERS.maxBufferBytes, timeout: GH_TIMEOUT_MS },
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
      // Copy operation from stored map if available, otherwise default to auto_merge
      if (!this._taskOperations.has(taskId)) {
        this._taskOperations.set(taskId, "auto_merge");
      }
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
        ["pr", "list", "--state", "open", "--json", "number,title,headRefName,body,createdAt,updatedAt,labels", "--limit", "100"],
        { cwd: this._projectPath, maxBuffer: PIPELINE_BUFFERS.maxBufferBytes, timeout: GH_TIMEOUT_MS },
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
      labels: Array<{ name: string }>;
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
   * Persists the authoritative lifecycle transition so list() can consume it.
   */
  async updateStatus(
    id: number,
    status: MergeQueueStatus,
    extra?: {
      resolvedTier?: number;
      error?: string;
      completedAt?: string;
      lastAttemptedAt?: string;
      retryCount?: number;
    },
  ): Promise<void> {
    // Get current labels. Compute stale foreman/status:* labels to remove
    // (so prToEntry reads exactly one current lifecycle status), while
    // preserving foreman/operation:*.
    const labels = await this._getPrLabels(id);
    const operationLabel = labels.find((l) => l.startsWith(OPERATION_LABEL_PREFIX));
    const currentOperation = operationLabel?.replace(OPERATION_LABEL_PREFIX, "") as "auto_merge" | "create_pr" | undefined;
    const staleStatusLabels = labels.filter((l) => l.startsWith(STATUS_LABEL_PREFIX) && l !== `${STATUS_LABEL_PREFIX}${status}`);

    // Build the labels to add: new status + preserved operation.
    const addLabels: string[] = [`${STATUS_LABEL_PREFIX}${status}`];
    if (currentOperation) {
      addLabels.push(`${OPERATION_LABEL_PREFIX}${currentOperation}`);
    }

    try {
      // Remove stale status labels first. `gh pr edit --remove-label` exits
      // non-zero if a label is absent, so per-label errors are swallowed.
      for (const stale of staleStatusLabels) {
        try {
          await execFileAsync(
            "gh",
            ["pr", "edit", String(id), "--remove-label", stale],
            { cwd: this._projectPath, maxBuffer: PIPELINE_BUFFERS.maxBufferBytes, timeout: GH_TIMEOUT_MS },
          );
        } catch {
          // Label may not be present; that's fine.
        }
      }
      await execFileAsync(
        "gh",
        ["pr", "edit", String(id), "--add-label", addLabels.join(",")],
        { cwd: this._projectPath, maxBuffer: PIPELINE_BUFFERS.maxBufferBytes, timeout: GH_TIMEOUT_MS },
      );
    } catch (err) {
      // Surface gh failures so callers know status update failed
      const message = err instanceof Error ? err.message : String(err);
      throw new Error(`Failed to update status for PR #${id}: ${message}`);
    }

    void extra; // Extra info is handled by refinery in the run store
  }

  /**
   * Get current labels on a PR.
   */
  private async _getPrLabels(prNumber: number): Promise<string[]> {
    try {
      const result = await execFileAsync(
        "gh",
        ["pr", "view", String(prNumber), "--json", "labels", "--jq", ".labels[].name"],
        { cwd: this._projectPath, maxBuffer: PIPELINE_BUFFERS.maxBufferBytes, timeout: GH_TIMEOUT_MS },
      );
      return result.stdout
        .split("\n")
        .map((l) => l.trim())
        .filter((l) => l.length > 0);
    } catch {
      return [];
    }
  }

  /**
   * Reset a failed or conflict entry for retry. Returns false when the entry
   * is missing or not in a retryable state. On success, persists the
   * status transition to "pending" so dequeue() picks it up again.
   */
  async resetForRetry(taskId: string): Promise<boolean> {
    const entry = await this._findEntry({ taskId });
    if (!entry || (entry.status !== "failed" && entry.status !== "conflict")) {
      return false;
    }
    await this.updateStatus(entry.id, "pending");
    return true;
  }

  /**
   * Get entries eligible for retry. Returns entries currently labeled
   * "failed" or "conflict" so refinery can re-enqueue them.
   */
  async getRetryableEntries(): Promise<MergeQueueEntry[]> {
    const entries = await this.list();
    return entries.filter((e) => e.status === "failed" || e.status === "conflict");
  }

  /**
   * Find entries missing from the queue (tracked in gh but not in refinery state).
   * For gh-backed queue, all foreman/* PRs are automatically in the queue.
   */
  async missingFromQueue(): Promise<Array<{ run_id: string; task_id: string }>> {
    return [];
  }

  /**
   * Re-enqueue a previously dequeued entry. Only succeeds for failed or
   * conflict entries; persists the status transition to "pending".
   */
  async reEnqueue(id: number): Promise<boolean> {
    const entry = await this._findEntry({ id });
    if (!entry || (entry.status !== "failed" && entry.status !== "conflict")) {
      return false;
    }
    await this.updateStatus(entry.id, "pending");
    return true;
  }

  /**
   * Find a single entry by taskId or id. Returns null if not found.
   */
  private async _findEntry(filter: { taskId?: string; id?: number }): Promise<MergeQueueEntry | null> {
    const entries = await this.list();
    return entries.find((e) => {
      if (filter.taskId !== undefined && e.task_id !== filter.taskId) return false;
      if (filter.id !== undefined && e.id !== filter.id) return false;
      return true;
    }) ?? null;
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
          { cwd: this._projectPath, maxBuffer: PIPELINE_BUFFERS.maxBufferBytes, timeout: GH_TIMEOUT_MS },
        );
      } catch (err) {
        // Propagate failures so callers know the removal failed
        const message = err instanceof Error ? err.message : String(err);
        throw new Error(`Failed to close merge-queue PR #${entry.id}: ${message}`);
      }
    }
  }

  // ── Private helpers ─────────────────────────────────────────────────────

  /**
   * Convert a gh PR to a MergeQueueEntry.
   * Uses the real PR number as id, ensuring consistency with gh state.
   * Reads status and operation from gh labels to preserve authoritative state.
   */
  private prToEntry(pr: {
    number: number;
    headRefName: string;
    title: string;
    body: string;
    createdAt: string;
    updatedAt: string;
    labels: Array<{ name: string }>;
  }): MergeQueueEntry {
    // Extract task_id and run_id from PR body and title independently.
    // A nonempty body must not suppress title-only metadata.
    const TASK_ID_RE = /(?:task[_-]?id[:\s]*)([a-z]+-[a-z0-9]+)/i;
    const RUN_ID_RE = /(?:run[_-]?id[:\s]*)([a-f0-9-]+)/i;
    const taskIdMatch = TASK_ID_RE.exec(pr.body) ?? TASK_ID_RE.exec(pr.title);
    const runIdMatch = RUN_ID_RE.exec(pr.body) ?? RUN_ID_RE.exec(pr.title);
    const taskId = taskIdMatch?.[1] ?? pr.headRefName;

    // Parse status from labels (foreman/status:<status>)
    const statusLabel = pr.labels?.find((l) => l.name.startsWith(STATUS_LABEL_PREFIX));
    const labelStatus = statusLabel?.name.replace(STATUS_LABEL_PREFIX, "") as MergeQueueStatus | undefined;

    // Parse operation from labels (foreman/operation:<operation>)
    const operationLabel = pr.labels?.find((l) => l.name.startsWith(OPERATION_LABEL_PREFIX));
    const labelOperation = operationLabel?.name.replace(OPERATION_LABEL_PREFIX, "") as "auto_merge" | "create_pr" | undefined;

    // Priority: labels > stored map > default
    const operation = labelOperation ?? this._taskOperations.get(taskId) ?? "auto_merge";

    // Derive status: if label indicates terminal state, use it; otherwise default to pending
    // Terminal states (merged, conflict, failed) won't appear in open PRs but we track them
    // in labels for entries that were processed and still visible
    let status: MergeQueueStatus = "pending";
    if (labelStatus === "merging") {
      status = "merging";
    } else if (labelStatus === "merged" || labelStatus === "conflict" || labelStatus === "failed") {
      // Terminal states — these entries should be excluded from dequeue but included in list()
      // so callers can see the outcome
      status = labelStatus;
    }

    return {
      id: pr.number, // Real GitHub PR number
      branch_name: pr.headRefName,
      task_id: taskId,
      run_id: runIdMatch?.[1] ?? "",
      operation,
      agent_name: null,
      files_modified: [],
      enqueued_at: pr.createdAt,
      started_at: null,
      completed_at: null,
      status,
      resolved_tier: null,
      error: null,
      retry_count: 0,
      last_attempted_at: null,
    };
  }
}
