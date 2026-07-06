import type { MergeQueueEntry, MergeQueueStatus, ReconcileResult } from "./merge-queue.js";

/**
 * Elixir-backed merge queue adapter placeholder.
 *
 * The Elixir API does not yet expose merge queue commands/projections. Keep this
 * adapter explicit and PG-free so registered-project runtime never falls back to
 * the legacy PoolManager/Postgres merge queue path.
 */
export class ElixirMergeQueue {
  constructor(private readonly _projectId: string) {}

  async enqueue(input: {
    branchName: string;
    taskId: string;
    runId: string;
    operation?: "auto_merge" | "create_pr";
    agentName?: string;
    filesModified?: string[];
  }): Promise<MergeQueueEntry> {
    return {
      id: -1,
      branch_name: input.branchName,
      task_id: input.taskId,
      run_id: input.runId,
      operation: input.operation ?? "auto_merge",
      agent_name: input.agentName ?? null,
      files_modified: input.filesModified ?? [],
      enqueued_at: new Date().toISOString(),
      started_at: null,
      completed_at: null,
      status: "pending",
      resolved_tier: null,
      error: "Elixir merge queue API not implemented; accepted without legacy Postgres fallback",
      retry_count: 0,
      last_attempted_at: null,
    };
  }

  async reconcile(_repoPath?: string): Promise<ReconcileResult> {
    return { enqueued: 0, skipped: 0, invalidBranch: 0, failedToEnqueue: [] };
  }

  async list(_status?: MergeQueueStatus): Promise<MergeQueueEntry[]> {
    return [];
  }

  async dequeue(): Promise<MergeQueueEntry | null> {
    return null;
  }

  async updateStatus(
    _id: number,
    _status: MergeQueueStatus,
    _extra?: { resolvedTier?: number; error?: string; completedAt?: string; lastAttemptedAt?: string; retryCount?: number },
  ): Promise<void> {}

  async resetForRetry(_taskId: string): Promise<boolean> {
    return false;
  }

  async getRetryableEntries(): Promise<MergeQueueEntry[]> {
    return [];
  }

  async missingFromQueue(): Promise<Array<{ run_id: string; task_id: string }>> {
    return [];
  }

  async reEnqueue(_id: number): Promise<boolean> {
    return false;
  }

  async remove(_id: number): Promise<void> {}
}
