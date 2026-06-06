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
    seedId: run.seed_id,
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

  async getRunsForSeed(seedId: string, projectId?: string): Promise<RunSummary[]> {
    const runs = this.store.getRunsForSeed(seedId, projectId);
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

  async hasActiveOrPendingRun(seedId: string, projectId?: string): Promise<boolean> {
    return this.store.hasActiveOrPendingRun(seedId, projectId);
  }

  async getRunProgress(runId: string): Promise<RunProgressSummary | null> {
    const progress = this.store.getRunProgress(runId);
    return progress ? mapProgressToSummary(progress) : null;
  }
}
