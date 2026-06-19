import { orderByCluster } from "./conflict-cluster.js";
import { VcsBackendFactory } from "../lib/vcs/index.js";
import type { VcsBackend } from "../lib/vcs/interface.js";
import type { MergeQueueEntry, MissingFromQueueEntry, ReconcileResult } from "./merge-queue.js";
import type { MergeQueueOperation, MergeQueueStatus } from "../lib/db/postgres-adapter.js";
import { PostgresAdapter } from "../lib/db/postgres-adapter.js";

interface EnqueueInput {
  branchName: string;
  seedId: string;
  runId: string;
  operation?: MergeQueueOperation;
  agentName?: string;
  filesModified?: string[];
}

export class PostgresMergeQueue {
  constructor(
    private readonly projectId: string,
    private readonly adapter: PostgresAdapter = new PostgresAdapter(),
  ) {}

  async enqueue(input: EnqueueInput): Promise<MergeQueueEntry> {
    return this.adapter.enqueueMergeQueueEntry({
      projectId: this.projectId,
      branchName: input.branchName,
      seedId: input.seedId,
      runId: input.runId,
      operation: input.operation,
      agentName: input.agentName ?? null,
      filesModified: input.filesModified,
    }) as unknown as MergeQueueEntry;
  }

  async list(status?: MergeQueueStatus): Promise<MergeQueueEntry[]> {
    return await this.adapter.listMergeQueue(this.projectId, status) as unknown as MergeQueueEntry[];
  }

  async dequeue(): Promise<MergeQueueEntry | null> {
    const entries = await this.list("pending");
    const entry = entries[0];
    if (!entry) return null;
    await this.updateStatus(entry.id, "merging", { lastAttemptedAt: new Date().toISOString() });
    const refreshed = (await this.list()).find((row) => row.id === entry.id);
    return refreshed ?? null;
  }

  async getOrderedPending(): Promise<MergeQueueEntry[]> {
    return orderByCluster(await this.list("pending"));
  }

  async updateStatus(
    id: number,
    status: MergeQueueStatus,
    extra?: { resolvedTier?: number; error?: string; completedAt?: string; lastAttemptedAt?: string; retryCount?: number },
  ): Promise<void> {
    await this.adapter.updateMergeQueueStatus(this.projectId, id, status, extra);
  }

  async remove(id: number): Promise<void> {
    await this.adapter.removeMergeQueueEntry(this.projectId, id);
  }

  async resetForRetry(seedId: string): Promise<boolean> {
    return await this.adapter.resetMergeQueueForRetry(this.projectId, seedId);
  }

  async getRetryableEntries(): Promise<MergeQueueEntry[]> {
    return await this.adapter.listRetryableMergeQueue(this.projectId) as unknown as MergeQueueEntry[];
  }

  async reEnqueue(id: number): Promise<boolean> {
    return await this.adapter.reEnqueueMergeQueue(this.projectId, id);
  }

  async missingFromQueue(): Promise<MissingFromQueueEntry[]> {
    return await this.adapter.listMissingFromMergeQueue(this.projectId);
  }

  async reconcile(repoPath: string, backend?: VcsBackend): Promise<ReconcileResult> {
    const vcs = backend ?? await VcsBackendFactory.create({ backend: "auto" }, repoPath);
    const completedRuns = await this.adapter.listPipelineRuns(this.projectId, { status: "success", limit: 1000 });
    const mqRows = await this.list();
    const existingRunIds = new Set(mqRows.map((r) => r.run_id));
    const existingSeedIds = new Set(mqRows.map((r) => r.seed_id));
    const defaultBranch = await vcs.detectDefaultBranch(repoPath);

    let enqueued = 0;
    let skipped = 0;
    let invalidBranch = 0;
    const failedToEnqueue: Array<{ run_id: string; seed_id: string; reason: string }> = [];

    for (const run of completedRuns) {
      if (existingRunIds.has(run.id) || existingSeedIds.has(run.bead_id)) {
        skipped++;
        continue;
      }
      const branchName = `foreman/${run.bead_id}`;
      const exists = await vcs.branchExists(repoPath, branchName);
      if (!exists) {
        invalidBranch++;
        failedToEnqueue.push({ run_id: run.id, seed_id: run.bead_id, reason: `branch '${branchName}' not found` });
        continue;
      }
      const filesModified = await vcs.getChangedFiles(repoPath, defaultBranch, branchName);
      await this.enqueue({
        branchName,
        seedId: run.bead_id,
        runId: run.id,
        operation: run.merge_strategy === "pr" ? "create_pr" : "auto_merge",
        filesModified,
      });
      existingSeedIds.add(run.bead_id);
      enqueued++;
    }

    return { enqueued, skipped, invalidBranch, failedToEnqueue };
  }
}
