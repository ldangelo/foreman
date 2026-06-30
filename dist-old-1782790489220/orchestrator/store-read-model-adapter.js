/**
 * Store read model adapter.
 *
 * Wraps ForemanStore and exposes the RunStoreReadModel interface,
 * enabling orchestrator modules to depend on the interface rather
 * than the concrete store implementation.
 */
// ── Mapping helpers ─────────────────────────────────────────────────────────
/** Map a concrete Run to a RunSummary read model. */
function mapRunToSummary(run) {
    return {
        id: run.id,
        taskId: run.seed_id, // Database column is seed_id, maps to taskId in read model
        agentType: run.agent_type,
        status: run.status,
        worktreePath: run.worktree_path,
        baseBranch: run.base_branch ?? null,
        mergeStrategy: run.merge_strategy ?? null,
        commitSha: run.commit_sha ?? null,
        prUrl: run.pr_url ?? null,
        prState: (run.pr_state ?? "none"),
        prHeadSha: run.pr_head_sha ?? null,
        startedAt: run.started_at,
        completedAt: run.completed_at,
        createdAt: run.created_at,
        progress: run.progress,
    };
}
/** Map a serialized RunProgress JSON to RunProgressSummary. */
function mapProgressToSummary(progress) {
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
export class ForemanStoreReadModelAdapter {
    store;
    constructor(store) {
        this.store = store;
    }
    async getRun(runId) {
        const run = this.store.getRun(runId);
        return run ? mapRunToSummary(run) : null;
    }
    async getRunsForSeed(taskId, projectId) {
        const runs = this.store.getRunsForSeed(taskId, projectId);
        return runs.map(mapRunToSummary);
    }
    async getActiveRuns(projectId) {
        const runs = this.store.getActiveRuns(projectId);
        return runs.map(mapRunToSummary);
    }
    async getRunsByStatus(status, projectId) {
        const runs = this.store.getRunsByStatus(status, projectId);
        return runs.map(mapRunToSummary);
    }
    async getRunsByStatuses(statuses, projectId) {
        const runs = this.store.getRunsByStatuses(statuses, projectId);
        return runs.map(mapRunToSummary);
    }
    async getRunsByStatusesSince(statuses, since, projectId) {
        const runs = this.store.getRunsByStatusesSince(statuses, since, projectId);
        return runs.map(mapRunToSummary);
    }
    async hasActiveOrPendingRun(taskId, projectId) {
        return this.store.hasActiveOrPendingRun(taskId, projectId);
    }
    async getRunProgress(runId) {
        const progress = this.store.getRunProgress(runId);
        return progress ? mapProgressToSummary(progress) : null;
    }
}
//# sourceMappingURL=store-read-model-adapter.js.map