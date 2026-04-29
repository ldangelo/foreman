/**
 * Postgres-backed ForemanStore implementation.
 * Replaces SQLite-based storage with Postgres for multi-project support.
 */

import { PostgresAdapter } from "./db/postgres-adapter.js";
import type { IStore } from "./store-interface.js";
import type {
  Project,
  Run,
  Cost,
  RunProgress,
  Message,
  NativeTask,
  BeadWriteEntry,
  MergeAgentConfigRow,
  SentinelConfigRow,
  SentinelRunRow,
} from "./store.js";

// Re-export types from store.ts
export type {
  Project,
  Run,
  Cost,
  RunProgress,
  Message,
  NativeTask,
  BeadWriteEntry,
  MergeAgentConfigRow,
  SentinelConfigRow,
  SentinelRunRow,
} from "./store.js";

// EventType enum
export type EventType =
  | "dispatch"
  | "claim"
  | "complete"
  | "fail"
  | "merge"
  | "stuck"
  | "restart"
  | "recover"
  | "conflict"
  | "test-fail"
  | "pr-created"
  | "sentinel-start"
  | "sentinel-pass"
  | "sentinel-fail"
  | "phase-start"
  | "heartbeat";

/**
 * Factory to get or create the shared PostgresAdapter instance.
 */
let _adapter: PostgresAdapter | null = null;

function getAdapter(): PostgresAdapter {
  if (!_adapter) {
    _adapter = new PostgresAdapter();
  }
  return _adapter;
}

/**
 * Postgres-backed ForemanStore.
 * All operations are scoped to a single project via projectId.
 */
export class PostgresStore implements IStore {
  private adapter: PostgresAdapter;
  readonly projectId: string;

  constructor(projectId: string, adapter?: PostgresAdapter) {
    this.projectId = projectId;
    this.adapter = adapter ?? getAdapter();
  }

  /**
   * Create a PostgresStore for a project by its ID.
   */
  static forProject(projectId: string): PostgresStore {
    return new PostgresStore(projectId);
  }

  close(): void {
    // Postgres connections are pooled; no per-project close needed
  }

  isOpen(): boolean {
    return true;
  }

  // ── Native Tasks ─────────────────────────────────────────────────────

  async listTasksByStatus(statuses: string[], limit = 200): Promise<NativeTask[]> {
    if (statuses.length === 0) return [];
    const rows = await this.adapter.listTasks(this.projectId, {
      status: statuses as Array<"backlog" | "ready" | "in_progress" | "blocked" | "conflict" | "failed" | "stuck" | "closed">,
      limit,
    });
    return rows as unknown as NativeTask[];
  }

  async updateTaskStatus(taskId: string, newStatus: string): Promise<void> {
    await this.adapter.updateTask(this.projectId, taskId, { status: newStatus });
  }

  async updateTaskStatusForRun(runId: string, newStatus: string): Promise<void> {
    await this.adapter.updateTaskStatusForRun(this.projectId, runId, newStatus);
  }

  async getTaskById(id: string): Promise<NativeTask | null> {
    const task = await this.adapter.getTask(this.projectId, id);
    return (task as unknown as NativeTask) ?? null;
  }

  async getTaskByExternalId(externalId: string): Promise<NativeTask | null> {
    const task = await this.adapter.getTaskByExternalId(this.projectId, externalId);
    return (task as unknown as NativeTask) ?? null;
  }

  async hasNativeTasks(): Promise<boolean> {
    return this.adapter.hasNativeTasks(this.projectId);
  }

  async claimTaskAsync(taskId: string, runId: string): Promise<boolean> {
    return this.adapter.claimTask(this.projectId, taskId, runId);
  }

  // ── Projects ─────────────────────────────────────────────────────────

  async getProject(id: string): Promise<Project | null> {
    const row = await this.adapter.getProject(id);
    if (!row) return null;
    return {
      id: row.id,
      name: row.name,
      path: row.path,
      status: row.status as Project["status"],
      created_at: row.created_at,
      updated_at: row.updated_at,
    };
  }

  async getProjectByPath(_path: string): Promise<Project | null> {
    return this.getProject(this.projectId);
  }

  async listProjects(_status?: string): Promise<Project[]> {
    const project = await this.getProject(this.projectId);
    return project ? [project] : [];
  }

  async updateProject(id: string, updates: Partial<Pick<Project, "name" | "path" | "status">>): Promise<void> {
    await this.adapter.updateProject(id, updates);
  }

  // ── Runs ─────────────────────────────────────────────────────────────

  async createRun(
    projectId: string,
    seedId: string,
    agentType: string,
    worktreePath: string | null,
    opts?: {
      baseBranch?: string | null;
      mergeStrategy?: string | null;
      sessionKey?: string | null;
    },
  ): Promise<Run> {
    const run = await this.adapter.createRun(projectId, seedId, agentType, {
      sessionKey: opts?.sessionKey ?? undefined,
      worktreePath: worktreePath ?? undefined,
      baseBranch: opts?.baseBranch ?? undefined,
      mergeStrategy: (opts?.mergeStrategy as "auto" | "pr" | "none") ?? undefined,
    });
    return this.rowToRun(run);
  }

  async updateRun(
    runId: string,
    updates: Partial<Pick<Run, "status" | "worktree_path" | "session_key" | "started_at" | "completed_at">>,
  ): Promise<void> {
    const updateData: Record<string, string | null> = {};
    if (updates.status) updateData.status = updates.status;
    if (updates.worktree_path !== undefined) updateData.worktree_path = updates.worktree_path;
    if (updates.session_key !== undefined) updateData.session_key = updates.session_key;
    if (updates.started_at !== undefined) updateData.started_at = updates.started_at;
    if (updates.completed_at !== undefined) updateData.completed_at = updates.completed_at;
    await this.adapter.updateRun(this.projectId, runId, updateData);
  }

  async getRun(id: string): Promise<Run | null> {
    const row = await this.adapter.getRun(this.projectId, id);
    return row ? this.rowToRun(row) : null;
  }

  async getActiveRuns(_projectId?: string): Promise<Run[]> {
    const rows = await this.adapter.listActiveRuns(_projectId ?? this.projectId);
    return rows.map((r) => this.rowToRun(r));
  }

  async getRunsByStatus(status: Run["status"], projectId?: string): Promise<Run[]> {
    const rows = await this.adapter.listRuns(projectId ?? this.projectId, { status: [status] });
    return rows.map((r) => this.rowToRun(r));
  }

  async getRunsByStatuses(statuses: Run["status"][], projectId?: string): Promise<Run[]> {
    const rows = await this.adapter.listRuns(projectId ?? this.projectId, { status: statuses });
    return rows.map((r) => this.rowToRun(r));
  }

  async getRunsByStatusesSince(statuses: Run["status"][], since: string, projectId?: string): Promise<Run[]> {
    const rows = await this.adapter.getRunsByStatusesSince(projectId ?? this.projectId, statuses, since);
    return rows.map((r) => this.rowToRun(r));
  }

  async getRunsByStatusSince(status: Run["status"], since: string, projectId?: string): Promise<Run[]> {
    return this.getRunsByStatusesSince([status], since, projectId);
  }

  async purgeOldRuns(olderThan: string, projectId?: string): Promise<number> {
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

  async deleteRun(runId: string): Promise<boolean> {
    return this.adapter.deleteRun(this.projectId, runId);
  }

  async getRunsForSeed(seedId: string, projectId?: string): Promise<Run[]> {
    const rows = await this.adapter.listRuns(projectId ?? this.projectId, {});
    return rows.filter((r) => r.seed_id === seedId).map((r) => this.rowToRun(r));
  }

  async hasActiveOrPendingRun(seedId: string, projectId?: string): Promise<boolean> {
    return this.adapter.hasActiveOrPendingRun(projectId ?? this.projectId, seedId);
  }

  async getRunsByBaseBranch(baseBranch: string, projectId?: string): Promise<Run[]> {
    const rows = await this.adapter.listRuns(projectId ?? this.projectId, {});
    return rows.filter((r) => (r as unknown as Record<string, unknown>).base_branch === baseBranch).map((r) => this.rowToRun(r));
  }

  // ── Events ──────────────────────────────────────────────────────────

  async logEvent(
    projectId: string,
    eventType: EventType,
    data: Record<string, unknown>,
    runId?: string,
  ): Promise<void> {
    if (!runId) return;
    await this.adapter.recordPipelineEvent({
      projectId,
      runId,
      taskId: (data.seedId as string | undefined) ?? undefined,
      eventType,
      payload: data,
    });
  }

  async getRunEvents(runId: string, eventType?: EventType): Promise<Array<{ id: string; event_type: string; data: string; created_at: string }>> {
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

  async getEvents(
    projectId?: string,
    limit = 200,
    eventType?: string,
  ): Promise<Array<{ id: string; project_id: string; run_id: string | null; event_type: string; data: string; created_at: string }>> {
    const runs = await this.adapter.listPipelineRuns(projectId ?? this.projectId, { limit: 500 });
    const all = (
      await Promise.all(runs.map((run) => this.adapter.listPipelineEvents(run.id)))
    )
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

  async recordCost(runId: string, tokensIn: number, tokensOut: number, cacheRead: number, estimatedCost: number): Promise<void> {
    await this.adapter.recordCost(this.projectId, runId, { tokensIn, tokensOut, cacheRead, estimatedCost });
  }

  async getCosts(_projectId?: string, _since?: string): Promise<Cost[]> {
    return [];
  }

  async getCostBreakdown(_runId: string): Promise<{ byPhase: Record<string, number>; byAgent: Record<string, number> }> {
    return { byPhase: {}, byAgent: {} };
  }

  async getPhaseMetrics(_projectId?: string, _since?: string): Promise<{
    totalCost: number;
    totalTokens: number;
    tasksByStatus: Record<string, number>;
  }> {
    return { totalCost: 0, totalTokens: 0, tasksByStatus: {} };
  }

  async getSuccessRate(_projectId?: string): Promise<{ rate: number | null; merged: number; failed: number }> {
    return { rate: null, merged: 0, failed: 0 };
  }

  async updateRunProgress(runId: string, progress: RunProgress): Promise<void> {
    await this.adapter.updateRunProgress(this.projectId, runId, {
      ...progress,
      phase: progress.currentPhase,
    });
  }

  async getRunProgress(runId: string): Promise<RunProgress | null> {
    const run = await this.getRun(runId);
    if (!run?.progress) return null;
    try {
      const raw = JSON.parse(run.progress) as Record<string, unknown>;
      return {
        toolCalls: typeof raw.toolCalls === "number" ? raw.toolCalls : 0,
        toolBreakdown: typeof raw.toolBreakdown === "object" && raw.toolBreakdown ? raw.toolBreakdown as Record<string, number> : {},
        filesChanged: Array.isArray(raw.filesChanged) ? raw.filesChanged as string[] : [],
        turns: typeof raw.turns === "number" ? raw.turns : 0,
        costUsd: typeof raw.costUsd === "number" ? raw.costUsd : 0,
        tokensIn: typeof raw.tokensIn === "number" ? raw.tokensIn : 0,
        tokensOut: typeof raw.tokensOut === "number" ? raw.tokensOut : 0,
        lastToolCall: typeof raw.lastToolCall === "string" ? raw.lastToolCall : null,
        lastActivity: typeof raw.lastActivity === "string" ? raw.lastActivity : new Date().toISOString(),
        currentPhase: (typeof raw.currentPhase === "string" ? raw.currentPhase : typeof raw.phase === "string" ? raw.phase : undefined),
        costByPhase: typeof raw.costByPhase === "object" && raw.costByPhase ? raw.costByPhase as Record<string, number> : undefined,
        agentByPhase: typeof raw.agentByPhase === "object" && raw.agentByPhase ? raw.agentByPhase as Record<string, string> : undefined,
        qaValidatedTargetBranch: typeof raw.qaValidatedTargetBranch === "string" ? raw.qaValidatedTargetBranch : undefined,
        qaValidatedTargetRef: typeof raw.qaValidatedTargetRef === "string" ? raw.qaValidatedTargetRef : undefined,
        qaValidatedHeadRef: typeof raw.qaValidatedHeadRef === "string" ? raw.qaValidatedHeadRef : undefined,
        currentTargetRef: typeof raw.currentTargetRef === "string" ? raw.currentTargetRef : undefined,
        epicTaskCount: typeof raw.epicTaskCount === "number" ? raw.epicTaskCount : undefined,
        epicTasksCompleted: typeof raw.epicTasksCompleted === "number" ? raw.epicTasksCompleted : undefined,
        epicCurrentTaskId: typeof raw.epicCurrentTaskId === "string" ? raw.epicCurrentTaskId : undefined,
        epicCostByTask: typeof raw.epicCostByTask === "object" && raw.epicCostByTask ? raw.epicCostByTask as Record<string, number> : undefined,
      };
    } catch {
      return null;
    }
  }

  // ── Rate Limiting ───────────────────────────────────────────────────

  async logRateLimitEvent(
    projectId: string,
    model: string,
    phase: string,
    error: string,
    retryAfterSeconds?: number,
    runId?: string,
  ): Promise<void> {
    await this.adapter.logRateLimitEvent(
      projectId,
      runId ?? null,
      model,
      phase,
      error,
      retryAfterSeconds ?? null,
    );
  }

  async getRateLimitCountsByModel(projectId: string, hoursBack = 24): Promise<Record<string, number>> {
    // Not implemented in PostgresAdapter yet
    return {};
  }

  async getRecentRateLimitEvents(
    projectId: string,
    _limit = 10,
  ): Promise<Array<{ model: string; tokens_used: number; window_start: string; created_at: string }>> {
    // Not implemented in PostgresAdapter yet
    return [];
  }

  // ── Messaging ───────────────────────────────────────────────────────

  async sendMessage(
    runId: string,
    senderAgentType: string,
    recipientAgentType: string,
    subject: string,
    body: string,
  ): Promise<void> {
    await this.adapter.sendMessage(this.projectId, runId, senderAgentType, recipientAgentType, subject, body);
  }

  async getMessages(runId: string, agentType: string, unreadOnly = false): Promise<Message[]> {
    return await this.adapter.getMessages(this.projectId, runId, agentType, unreadOnly) as unknown as Message[];
  }

  async markMessageRead(messageId: string): Promise<void> {
    await this.adapter.markMessageRead(this.projectId, messageId);
  }

  async markAllMessagesRead(runId: string, agentType: string): Promise<void> {
    await this.adapter.markAllMessagesRead(this.projectId, runId, agentType);
  }

  async deleteMessage(messageId: string): Promise<void> {
    await this.adapter.deleteMessage(this.projectId, messageId);
  }

  async getAllMessages(runId: string): Promise<Message[]> {
    return await this.adapter.getAllMessages(runId) as unknown as Message[];
  }

  async getAllMessagesGlobal(limit = 200): Promise<Message[]> {
    return await this.adapter.getAllMessagesGlobal(this.projectId, limit) as unknown as Message[];
  }

  // ── Bead Write Queue ────────────────────────────────────────────────

  async getPendingBeadWrites(): Promise<BeadWriteEntry[]> {
    // Not implemented in Postgres yet
    return [];
  }

  async markBeadWriteProcessed(_id: string): Promise<boolean> {
    // Not implemented in Postgres yet
    return false;
  }

  // ── Merge Queue ─────────────────────────────────────────────────────

  async enqueueMerge(_runId: string, _mergeData: Record<string, unknown>): Promise<void> {
    // Not implemented
  }

  async getMergeQueue(): Promise<BeadWriteEntry[]> {
    return [];
  }

  async getMergeQueueStats(): Promise<{ pending: number; running: number }> {
    return { pending: 0, running: 0 };
  }

  async updateMergeQueueEntry(_runId: string, _updates: Record<string, unknown>): Promise<void> {
    // Not implemented
  }

  async removeMergeQueueEntry(_runId: string): Promise<void> {
    // Not implemented
  }

  // ── Merge Costs ─────────────────────────────────────────────────────

  async recordMergeCost(_runId: string, _phase: string, _tokensIn: number, _tokensOut: number, _estimatedCost: number): Promise<void> {
    // Not implemented
  }

  async getMergeCosts(_runId?: string): Promise<Cost[]> {
    return [];
  }

  // ── Conflict Patterns ────────────────────────────────────────────────

  async getConflictPatterns(_projectId: string): Promise<Array<{ id: string; pattern: string; resolution: string }>> {
    return [];
  }

  async upsertConflictPattern(_projectId: string, _pattern: string, _resolution: string): Promise<void> {
    // Not implemented
  }

  async deleteConflictPattern(_id: string): Promise<void> {
    // Not implemented
  }

  // ── Sentinel ─────────────────────────────────────────────────────────

  async getSentinelConfig(projectId: string): Promise<SentinelConfigRow | null> {
    return this.adapter.getSentinelConfig(projectId);
  }

  async upsertSentinelConfig(projectId: string, config: Partial<Omit<SentinelConfigRow, "id" | "project_id" | "created_at" | "updated_at">>): Promise<void> {
    await this.adapter.upsertSentinelConfig(projectId, config);
  }

  async getSentinelRuns(projectId: string, limit?: number): Promise<SentinelRunRow[]> {
    return this.adapter.getSentinelRuns(projectId, limit);
  }

  async recordSentinelRun(projectId: string, run: Omit<SentinelRunRow, "failure_count"> & { failure_count?: number }): Promise<void> {
    await this.adapter.recordSentinelRun(projectId, run);
  }

  async updateSentinelRun(id: string, updates: Partial<SentinelRunRow>): Promise<void> {
    await this.adapter.updateSentinelRun(this.projectId, id, updates);
  }

  // ── Merge Agent Config ──────────────────────────────────────────────

  async getMergeAgentConfig(_projectId: string): Promise<MergeAgentConfigRow | null> {
    return null;
  }

  async upsertMergeAgentConfig(_projectId: string, _config: MergeAgentConfigRow): Promise<void> {
    // Not implemented
  }

  // ── Merge Strategy ─────────────────────────────────────────────────

  async getMergeStrategyConfig(_projectId: string): Promise<{ id: string; project_id: string; strategy: string; created_at: string; updated_at: string } | null> {
    return null;
  }

  async upsertMergeStrategyConfig(_projectId: string, _config: { strategy: string }): Promise<void> {
    // Not implemented
  }

  // ── Sync wrappers for backward compatibility ─────────────────────────

  listTasksByStatusSync(statuses: string[], limit = 200): NativeTask[] {
    // Sync version not supported for Postgres
    throw new Error("Sync operations not supported in PostgresStore");
  }

  getProjectByPathSync(_path: string): Project | null {
    throw new Error("Sync operations not supported in PostgresStore");
  }

  listProjectsSync(_status?: string): Project[] {
    throw new Error("Sync operations not supported in PostgresStore");
  }

  getActiveRunsSync(_projectId?: string): Run[] {
    throw new Error("Sync operations not supported in PostgresStore");
  }

  // ── Helper ──────────────────────────────────────────────────────────

  private rowToRun(row: {
    id: string;
    project_id: string;
    seed_id: string;
    agent_type: string;
    session_key: string | null;
    worktree_path: string | null;
    status: string;
    started_at: string | null;
    completed_at: string | null;
    created_at: string;
    progress: string | null;
  }): Run {
    return {
      id: row.id,
      project_id: row.project_id,
      seed_id: row.seed_id,
      agent_type: row.agent_type,
      session_key: row.session_key,
      worktree_path: row.worktree_path,
      status: row.status as Run["status"],
      started_at: row.started_at,
      completed_at: row.completed_at,
      created_at: row.created_at,
      progress: row.progress,
    };
  }
}
