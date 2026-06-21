/**
 * Store read model adapter.
 *
 * Wraps ForemanStore and exposes the RunStoreReadModel interface,
 * enabling orchestrator modules to depend on the interface rather
 * than the concrete store implementation.
 */

import type { ForemanStore, RunProgress, Run } from "../lib/store.js";
import type {
  RunSummary,
  RunProgressSummary,
  RunStoreReadModel,
  RunStatus,
} from "./read-models.js";

// ── Mapping helpers ─────────────────────────────────────────────────────────

/** Map a concrete Run to a RunSummary read model. */
function mapRunToSummary(run: Run): RunSummary {
  return {
    id: run.id,
    taskId: run.seed_id,  // Database column is seed_id, maps to taskId in read model
    agentType: run.agent_type,
    status: run.status as RunStatus,
    worktreePath: run.worktree_path,
    baseBranch: run.base_branch ?? null,
    mergeStrategy: run.merge_strategy ?? null,
    commitSha: run.commit_sha ?? null,
    prUrl: run.pr_url ?? null,
    prState: (run.pr_state ?? "none") as RunSummary["prState"],
    prHeadSha: run.pr_head_sha ?? null,
    startedAt: run.started_at,
    completedAt: run.completed_at,
    createdAt: run.created_at,
    progress: run.progress,
    // Legacy store doesn't have archived column; default to false for backward compat
    archived: (run as Run & { archived?: boolean }).archived ?? false,
  };
}

/** Map a serialized RunProgress JSON to RunProgressSummary. */
function mapProgressToSummary(progress: RunProgress): RunProgressSummary {
  return {
    toolCalls: progress.toolCalls,
    toolBreakdown: progress.toolBreakdown,
    filesChanged: progress.filesChanged,
    turns: progress.turns,
    costUsd: progress.costUsd,
    tokensIn: progress.tokensIn,
    tokensOut: progress.tokensOut,
    lastToolCall: progress.lastToolCall,
    lastActivity: progress.lastActivity,
    currentPhase: progress.currentPhase,
    costByPhase: progress.costByPhase,
    agentByPhase: progress.agentByPhase,
    qaValidatedTargetBranch: progress.qaValidatedTargetBranch,
    qaValidatedTargetRef: progress.qaValidatedTargetRef,
    qaValidatedHeadRef: progress.qaValidatedHeadRef,
    currentTargetRef: progress.currentTargetRef,
    epicTaskCount: progress.epicTaskCount,
    epicTasksCompleted: progress.epicTasksCompleted,
    epicCurrentTaskId: progress.epicCurrentTaskId,
    epicCostByTask: progress.epicCostByTask,
  };
}

// ── Adapter implementation ─────────────────────────────────────────────────

/**
 * Adapter that wraps ForemanStore and exposes RunStoreReadModel.
 *
 * This allows orchestrator modules to depend on the read model interface
 * while the concrete store implementation remains unchanged.
 */
export class ForemanStoreReadModelAdapter implements RunStoreReadModel {
  constructor(private store: ForemanStore) {}

  async getRun(runId: string): Promise<RunSummary | null> {
    const run = this.store.getRun(runId);
    return run ? mapRunToSummary(run) : null;
  }

  async getRunsForSeed(taskId: string, projectId?: string): Promise<RunSummary[]> {
    const runs = this.store.getRunsForSeed(taskId, projectId);
    return runs.map(mapRunToSummary);
  }

  async getActiveRuns(projectId?: string): Promise<RunSummary[]> {
    const runs = this.store.getActiveRuns(projectId);
    return runs.map(mapRunToSummary);
  }

  async getRunsByStatus(status: RunStatus, projectId?: string): Promise<RunSummary[]> {
    const runs = this.store.getRunsByStatus(status as Run["status"], projectId);
    return runs.map(mapRunToSummary);
  }

  async getRunsByStatuses(statuses: RunStatus[], projectId?: string): Promise<RunSummary[]> {
    const runs = this.store.getRunsByStatuses(statuses as Run["status"][], projectId);
    return runs.map(mapRunToSummary);
  }

  async getRunsByStatusesSince(
    statuses: RunStatus[],
    since: string,
    projectId?: string,
  ): Promise<RunSummary[]> {
    const runs = this.store.getRunsByStatusesSince(
      statuses as Run["status"][],
      since,
      projectId,
    );
    return runs.map(mapRunToSummary);
  }

  async hasActiveOrPendingRun(taskId: string, projectId?: string): Promise<boolean> {
    return this.store.hasActiveOrPendingRun(taskId, projectId);
  }

  async getRunProgress(runId: string): Promise<RunProgressSummary | null> {
    const progress = this.store.getRunProgress(runId);
    return progress ? mapProgressToSummary(progress) : null;
  }

  /**
   * Fetch recent active runs: pending/running or failed within the last 30 days.
   * Excludes archived runs by default.
   *
   * @param projectId - Optional project filter
   */
  async getRecentActiveRuns(projectId?: string): Promise<RunSummary[]> {
    // Get active runs (pending/running)
    const activeRuns = await this.getActiveRuns(projectId);

    // Get failed runs from the last 30 days
    const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();
    const failedRuns = await this.getRunsByStatusesSince(
      ["failed", "test-failed", "stuck", "conflict"] as RunStatus[],
      thirtyDaysAgo,
      projectId,
    );

    // Combine and deduplicate by run ID
    const runMap = new Map<string, RunSummary>();
    for (const run of activeRuns) {
      runMap.set(run.id, run);
    }
    for (const run of failedRuns) {
      if (run.createdAt < thirtyDaysAgo) continue;
      if (!runMap.has(run.id)) {
        runMap.set(run.id, run);
      }
    }

    // Filter out archived runs
    const results = Array.from(runMap.values()).filter((run) => !run.archived);

    // Sort by created_at DESC
    results.sort((a, b) => b.createdAt.localeCompare(a.createdAt));

    return results;
  }

  /**
   * Archive a set of runs by their IDs.
   *
   * Note: The legacy ForemanStore does not support archiving. This method
   * is a no-op for backward compatibility. Use the PostgresAdapter directly
   * for archival operations in production.
   *
   * @param runIds - Array of run IDs to archive
   * @param _projectId - Ignored for legacy store
   * @returns 0 (archiving not supported in legacy store)
   */
  async archiveRuns(runIds: string[], _projectId?: string): Promise<number> {
    // Legacy store does not support archiving; this is a no-op
    // Production should use PostgresAdapter.archiveRuns() instead
    return 0;
  }
}
