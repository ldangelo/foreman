/**
 * Postgres-backed ForemanStore implementation.
 * Replaces Postgres-based storage with Postgres for multi-project support.
 */
import { PostgresAdapter } from "./db/postgres-adapter.js";
import { query } from "./db/pool-manager.js";
/**
 * Factory to get or create the shared PostgresAdapter instance.
 */
let _adapter = null;
function getAdapter() {
    if (!_adapter) {
        _adapter = new PostgresAdapter();
    }
    return _adapter;
}
/**
 * Postgres-backed ForemanStore.
 * All operations are scoped to a single project via projectId.
 */
export class PostgresStore {
    adapter;
    projectId;
    constructor(projectId, adapter) {
        this.projectId = projectId;
        this.adapter = adapter ?? getAdapter();
    }
    /**
     * Create a PostgresStore for a project by its ID.
     */
    static forProject(projectId) {
        return new PostgresStore(projectId);
    }
    close() {
        // Postgres connections are pooled; no per-project close needed
    }
    isOpen() {
        return true;
    }
    // ── Native Tasks ─────────────────────────────────────────────────────
    async listTasksByStatus(statuses, limit = 200) {
        if (statuses.length === 0)
            return [];
        const rows = await this.adapter.listTasks(this.projectId, {
            status: statuses,
            limit,
        });
        return rows;
    }
    async updateTaskStatus(taskId, newStatus) {
        // Normalize legacy 'in_progress' (underscore) to native 'in-progress' (hyphen)
        // before writing to the database CHECK constraint.
        const normalizedStatus = newStatus === "in_progress" ? "in-progress" : newStatus;
        await this.adapter.updateTask(this.projectId, taskId, { status: normalizedStatus });
    }
    async updateTaskStatusForRun(runId, newStatus) {
        // Normalize legacy 'in_progress' (underscore) to native 'in-progress' (hyphen)
        // before writing to the database CHECK constraint.
        const normalizedStatus = newStatus === "in_progress" ? "in-progress" : newStatus;
        await this.adapter.updateTaskStatusForRun(this.projectId, runId, normalizedStatus);
    }
    async getTaskById(id) {
        const task = await this.adapter.getTask(this.projectId, id);
        return task ?? null;
    }
    async getTaskByExternalId(externalId) {
        const task = await this.adapter.getTaskByExternalId(this.projectId, externalId);
        return task ?? null;
    }
    async hasNativeTasks() {
        return this.adapter.hasNativeTasks(this.projectId);
    }
    async claimTaskAsync(taskId, runId) {
        return this.adapter.claimTask(this.projectId, taskId, runId);
    }
    // ── Projects ─────────────────────────────────────────────────────────
    async getProject(id) {
        const row = await this.adapter.getProject(id);
        if (!row)
            return null;
        return {
            id: row.id,
            name: row.name,
            path: row.path,
            status: row.status,
            created_at: row.created_at,
            updated_at: row.updated_at,
        };
    }
    async getProjectByPath(_path) {
        return this.getProject(this.projectId);
    }
    async listProjects(_status) {
        const project = await this.getProject(this.projectId);
        return project ? [project] : [];
    }
    async updateProject(id, updates) {
        await this.adapter.updateProject(id, updates);
    }
    // ── Runs ─────────────────────────────────────────────────────────────
    async createRun(projectId, seedId, agentType, worktreePath, opts) {
        const run = await this.adapter.createRun(projectId, seedId, agentType, {
            sessionKey: opts?.sessionKey ?? undefined,
            worktreePath: worktreePath ?? undefined,
            baseBranch: opts?.baseBranch ?? undefined,
            mergeStrategy: opts?.mergeStrategy ?? undefined,
        });
        return this.rowToRun(run);
    }
    async updateRun(runId, updates) {
        const updateData = {};
        if (updates.status)
            updateData.status = updates.status;
        if (updates.worktree_path !== undefined)
            updateData.worktree_path = updates.worktree_path;
        if (updates.session_key !== undefined)
            updateData.session_key = updates.session_key;
        if (updates.started_at !== undefined)
            updateData.started_at = updates.started_at;
        if (updates.completed_at !== undefined)
            updateData.completed_at = updates.completed_at;
        if (updates.merge_strategy !== undefined)
            updateData.merge_strategy = updates.merge_strategy;
        await this.adapter.updateRun(this.projectId, runId, updateData);
    }
    async getRun(id) {
        const row = await this.adapter.getRun(this.projectId, id);
        return row ? this.rowToRun(row) : null;
    }
    async getActiveRuns(_projectId) {
        const rows = await this.adapter.listActiveRuns(_projectId ?? this.projectId);
        return rows.map((r) => this.rowToRun(r));
    }
    async getRunsByStatus(status, projectId) {
        const rows = await this.adapter.listRuns(projectId ?? this.projectId, { status: [status] });
        return rows.map((r) => this.rowToRun(r));
    }
    async getRunsByStatuses(statuses, projectId) {
        const rows = await this.adapter.listRuns(projectId ?? this.projectId, { status: statuses });
        return rows.map((r) => this.rowToRun(r));
    }
    async getRunsByStatusesSince(statuses, since, projectId) {
        const rows = await this.adapter.getRunsByStatusesSince(projectId ?? this.projectId, statuses, since);
        return rows.map((r) => this.rowToRun(r));
    }
    async getRunsByStatusSince(status, since, projectId) {
        return this.getRunsByStatusesSince([status], since, projectId);
    }
    async purgeOldRuns(olderThan, projectId) {
        const pid = projectId ?? this.projectId;
        const runs = await this.adapter.listRuns(pid, {});
        let count = 0;
        for (const run of runs) {
            if (run.created_at < olderThan && (run.status === "completed" || run.status === "failed")) {
                await this.adapter.deleteRun(pid, run.id);
                count++;
            }
        }
        return count;
    }
    async deleteRun(runId) {
        return this.adapter.deleteRun(this.projectId, runId);
    }
    async getRunsForSeed(seedId, projectId) {
        const rows = await this.adapter.listRuns(projectId ?? this.projectId, {});
        return rows.filter((r) => r.seed_id === seedId).map((r) => this.rowToRun(r));
    }
    async hasActiveOrPendingRun(seedId, projectId) {
        return this.adapter.hasActiveOrPendingRun(projectId ?? this.projectId, seedId);
    }
    async getRunsByBaseBranch(baseBranch, projectId) {
        const rows = await this.adapter.listRuns(projectId ?? this.projectId, {});
        return rows.filter((r) => r.base_branch === baseBranch).map((r) => this.rowToRun(r));
    }
    // ── Events ──────────────────────────────────────────────────────────
    async logEvent(projectId, eventType, data, runId) {
        if (!runId)
            return;
        await this.adapter.recordPipelineEvent({
            projectId,
            runId,
            taskId: data.seedId ?? undefined,
            eventType,
            payload: data,
        });
    }
    async recordSentinelEvent(projectId, sentinelRunId, eventType, data) {
        await this.adapter.recordSentinelEvent({
            projectId,
            sentinelRunId,
            eventType,
            payload: data,
        });
    }
    async getRunEvents(runId, eventType) {
        const rows = await this.adapter.listPipelineEvents(runId);
        return rows
            .filter((row) => (eventType ? row.event_type === eventType : true))
            .map((row) => ({
            id: row.id,
            event_type: row.event_type,
            data: JSON.stringify(row.payload ?? {}),
            created_at: row.created_at,
        }));
    }
    async getEvents(projectId, limit = 200, eventType) {
        const runs = await this.adapter.listPipelineRuns(projectId ?? this.projectId, { limit: 500 });
        const all = (await Promise.all(runs.map((run) => this.adapter.listPipelineEvents(run.id))))
            .flat()
            .filter((row) => (eventType ? row.event_type === eventType : true))
            .sort((a, b) => b.created_at.localeCompare(a.created_at))
            .slice(0, limit)
            .map((row) => ({
            id: row.id,
            project_id: row.project_id,
            run_id: row.run_id,
            event_type: row.event_type,
            data: JSON.stringify(row.payload ?? {}),
            created_at: row.created_at,
        }));
        return all;
    }
    // ── Costs ───────────────────────────────────────────────────────────
    async recordCost(runId, tokensIn, tokensOut, cacheRead, estimatedCost) {
        await this.adapter.recordCost(this.projectId, runId, { tokensIn, tokensOut, cacheRead, estimatedCost });
    }
    async getCosts(_projectId, since) {
        const params = [this.projectId];
        const conditions = ["r.project_id = $1"];
        if (since) {
            params.push(since);
            conditions.push(`c.recorded_at >= $${params.length}`);
        }
        return query(`SELECT c.id, c.run_id, c.tokens_in, c.tokens_out, c.cache_read,
              c.estimated_cost::float AS estimated_cost,
              c.recorded_at::text AS recorded_at
         FROM costs c
         JOIN runs r ON r.id = c.run_id
        WHERE ${conditions.join(" AND ")}
        ORDER BY c.recorded_at DESC`, params);
    }
    async getCostBreakdown(runId) {
        const rows = await query(`SELECT r.agent_type, c.estimated_cost::float AS estimated_cost
         FROM costs c
         JOIN runs r ON r.id = c.run_id
        WHERE r.project_id = $1 AND r.id = $2`, [this.projectId, runId]);
        const total = rows.reduce((sum, row) => sum + Number(row.estimated_cost), 0);
        const agent = rows[0]?.agent_type ?? "unknown";
        return { byPhase: { total }, byAgent: { [agent]: total } };
    }
    async getPhaseMetrics(_projectId, since) {
        const costs = await this.getCosts(this.projectId, since);
        const statuses = await query(`SELECT status, count(*)::int AS count FROM runs WHERE project_id = $1 GROUP BY status`, [this.projectId]);
        const mapStatus = (status) => {
            if (status === "success")
                return "completed";
            if (status === "failure")
                return "failed";
            if (status === "cancelled" || status === "skipped")
                return "reset";
            return status;
        };
        return {
            totalCost: costs.reduce((sum, cost) => sum + Number(cost.estimated_cost), 0),
            totalTokens: costs.reduce((sum, cost) => sum + cost.tokens_in + cost.tokens_out + cost.cache_read, 0),
            tasksByStatus: Object.fromEntries(statuses.map((row) => [mapStatus(row.status), row.count])),
        };
    }
    async getSuccessRate(_projectId) {
        const rows = await query(`SELECT status, count(*)::int AS count
         FROM runs
        WHERE project_id = $1 AND status IN ('success', 'failure')
        GROUP BY status`, [this.projectId]);
        const counts = Object.fromEntries(rows.map((row) => [row.status, row.count]));
        const merged = counts.success ?? 0;
        const failed = counts.failure ?? 0;
        const total = merged + failed;
        return { rate: total === 0 ? null : merged / total, merged, failed };
    }
    async updateRunProgress(runId, progress) {
        await this.adapter.updateRunProgress(this.projectId, runId, {
            ...progress,
            phase: progress.currentPhase,
        });
    }
    async getRunProgress(runId) {
        const run = await this.getRun(runId);
        if (!run?.progress)
            return null;
        try {
            const raw = JSON.parse(run.progress);
            return {
                toolCalls: typeof raw.toolCalls === "number" ? raw.toolCalls : 0,
                toolBreakdown: typeof raw.toolBreakdown === "object" && raw.toolBreakdown ? raw.toolBreakdown : {},
                filesChanged: Array.isArray(raw.filesChanged) ? raw.filesChanged : [],
                turns: typeof raw.turns === "number" ? raw.turns : 0,
                costUsd: typeof raw.costUsd === "number" ? raw.costUsd : 0,
                tokensIn: typeof raw.tokensIn === "number" ? raw.tokensIn : 0,
                tokensOut: typeof raw.tokensOut === "number" ? raw.tokensOut : 0,
                lastToolCall: typeof raw.lastToolCall === "string" ? raw.lastToolCall : null,
                lastActivity: typeof raw.lastActivity === "string" ? raw.lastActivity : new Date().toISOString(),
                currentPhase: (typeof raw.currentPhase === "string" ? raw.currentPhase : typeof raw.phase === "string" ? raw.phase : undefined),
                costByPhase: typeof raw.costByPhase === "object" && raw.costByPhase ? raw.costByPhase : undefined,
                agentByPhase: typeof raw.agentByPhase === "object" && raw.agentByPhase ? raw.agentByPhase : undefined,
                qaValidatedTargetBranch: typeof raw.qaValidatedTargetBranch === "string" ? raw.qaValidatedTargetBranch : undefined,
                qaValidatedTargetRef: typeof raw.qaValidatedTargetRef === "string" ? raw.qaValidatedTargetRef : undefined,
                qaValidatedHeadRef: typeof raw.qaValidatedHeadRef === "string" ? raw.qaValidatedHeadRef : undefined,
                currentTargetRef: typeof raw.currentTargetRef === "string" ? raw.currentTargetRef : undefined,
                epicTaskCount: typeof raw.epicTaskCount === "number" ? raw.epicTaskCount : undefined,
                epicTasksCompleted: typeof raw.epicTasksCompleted === "number" ? raw.epicTasksCompleted : undefined,
                epicCurrentTaskId: typeof raw.epicCurrentTaskId === "string" ? raw.epicCurrentTaskId : undefined,
                epicCostByTask: typeof raw.epicCostByTask === "object" && raw.epicCostByTask ? raw.epicCostByTask : undefined,
            };
        }
        catch {
            return null;
        }
    }
    // ── Rate Limiting ───────────────────────────────────────────────────
    async logRateLimitEvent(projectId, model, phase, error, retryAfterSeconds, runId) {
        await this.adapter.logRateLimitEvent(projectId, runId ?? null, model, phase, error, retryAfterSeconds ?? null);
    }
    async getRateLimitCountsByModel(projectId, hoursBack = 24) {
        // Not implemented in PostgresAdapter yet
        return {};
    }
    async getRecentRateLimitEvents(projectId, _limit = 10) {
        // Not implemented in PostgresAdapter yet
        return [];
    }
    // ── Messaging ───────────────────────────────────────────────────────
    async sendMessage(runId, senderAgentType, recipientAgentType, subject, body) {
        await this.adapter.sendMessage(this.projectId, runId, senderAgentType, recipientAgentType, subject, body);
    }
    async getMessages(runId, agentType, unreadOnly = false) {
        return await this.adapter.getMessages(this.projectId, runId, agentType, unreadOnly);
    }
    async markMessageRead(messageId) {
        await this.adapter.markMessageRead(this.projectId, messageId);
    }
    async markAllMessagesRead(runId, agentType) {
        await this.adapter.markAllMessagesRead(this.projectId, runId, agentType);
    }
    async deleteMessage(messageId) {
        await this.adapter.deleteMessage(this.projectId, messageId);
    }
    async getAllMessages(runId) {
        return await this.adapter.getAllMessages(runId);
    }
    async getAllMessagesGlobal(limit = 200) {
        return await this.adapter.getAllMessagesGlobal(this.projectId, limit);
    }
    // ── Merge Queue ─────────────────────────────────────────────────────
    async enqueueMerge(_runId, _mergeData) {
        // Not implemented
    }
    async getMergeQueue() {
        return [];
    }
    async getMergeQueueStats() {
        return { pending: 0, running: 0 };
    }
    async updateMergeQueueEntry(_runId, _updates) {
        // Not implemented
    }
    async removeMergeQueueEntry(_runId) {
        // Not implemented
    }
    // ── Merge Costs ─────────────────────────────────────────────────────
    async recordMergeCost(_runId, _phase, _tokensIn, _tokensOut, _estimatedCost) {
        // Not implemented
    }
    async getMergeCosts(_runId) {
        return [];
    }
    // ── Conflict Patterns ────────────────────────────────────────────────
    async getConflictPatterns(_projectId) {
        return [];
    }
    async upsertConflictPattern(_projectId, _pattern, _resolution) {
        // Not implemented
    }
    async deleteConflictPattern(_id) {
        // Not implemented
    }
    // ── Sentinel ─────────────────────────────────────────────────────────
    async getSentinelConfig(projectId) {
        return this.adapter.getSentinelConfig(projectId);
    }
    async upsertSentinelConfig(projectId, config) {
        await this.adapter.upsertSentinelConfig(projectId, config);
    }
    async getSentinelRuns(projectId, limit) {
        return this.adapter.getSentinelRuns(projectId, limit);
    }
    async recordSentinelRun(projectId, run) {
        await this.adapter.recordSentinelRun(projectId, run);
    }
    async updateSentinelRun(id, updates) {
        await this.adapter.updateSentinelRun(this.projectId, id, updates);
    }
    // ── Merge Agent Config ──────────────────────────────────────────────
    async getMergeAgentConfig(_projectId) {
        return null;
    }
    async upsertMergeAgentConfig(_projectId, _config) {
        // Not implemented
    }
    // ── Merge Strategy ─────────────────────────────────────────────────
    async getMergeStrategyConfig(_projectId) {
        return null;
    }
    async upsertMergeStrategyConfig(_projectId, _config) {
        // Not implemented
    }
    // ── Sync wrappers for backward compatibility ─────────────────────────
    listTasksByStatusSync(statuses, limit = 200) {
        // Sync version not supported for Postgres
        throw new Error("Sync operations not supported in PostgresStore");
    }
    getProjectByPathSync(_path) {
        throw new Error("Sync operations not supported in PostgresStore");
    }
    listProjectsSync(_status) {
        throw new Error("Sync operations not supported in PostgresStore");
    }
    getActiveRunsSync(_projectId) {
        throw new Error("Sync operations not supported in PostgresStore");
    }
    // ── Helper ──────────────────────────────────────────────────────────
    rowToRun(row) {
        return {
            id: row.id,
            project_id: row.project_id,
            seed_id: row.seed_id,
            agent_type: row.agent_type,
            session_key: row.session_key,
            worktree_path: row.worktree_path,
            status: row.status,
            started_at: row.started_at,
            completed_at: row.completed_at,
            created_at: row.created_at,
            progress: row.progress,
            base_branch: row.base_branch,
            merge_strategy: row.merge_strategy,
            commit_sha: row.commit_sha,
            pr_url: row.pr_url,
            pr_state: row.pr_state,
            pr_head_sha: row.pr_head_sha,
        };
    }
}
//# sourceMappingURL=postgres-store.js.map