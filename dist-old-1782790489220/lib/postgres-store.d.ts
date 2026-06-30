/**
 * Postgres-backed ForemanStore implementation.
 * Replaces Postgres-based storage with Postgres for multi-project support.
 */
import { PostgresAdapter } from "./db/postgres-adapter.js";
import type { IStore } from "./store-interface.js";
import type { Project, Run, Cost, RunProgress, Message, NativeTask, MergeAgentConfigRow, SentinelConfigRow, SentinelRunRow } from "./store.js";
export type { Project, Run, Cost, RunProgress, Message, NativeTask, MergeAgentConfigRow, SentinelConfigRow, SentinelRunRow, } from "./store.js";
export type EventType = "dispatch" | "claim" | "complete" | "fail" | "merge" | "stuck" | "restart" | "recover" | "conflict" | "test-fail" | "pr-created" | "sentinel-start" | "sentinel-pass" | "sentinel-fail" | "phase-start" | "heartbeat";
/**
 * Postgres-backed ForemanStore.
 * All operations are scoped to a single project via projectId.
 */
export declare class PostgresStore implements IStore {
    private adapter;
    readonly projectId: string;
    constructor(projectId: string, adapter?: PostgresAdapter);
    /**
     * Create a PostgresStore for a project by its ID.
     */
    static forProject(projectId: string): PostgresStore;
    close(): void;
    isOpen(): boolean;
    listTasksByStatus(statuses: string[], limit?: number): Promise<NativeTask[]>;
    updateTaskStatus(taskId: string, newStatus: string): Promise<void>;
    updateTaskStatusForRun(runId: string, newStatus: string): Promise<void>;
    getTaskById(id: string): Promise<NativeTask | null>;
    getTaskByExternalId(externalId: string): Promise<NativeTask | null>;
    hasNativeTasks(): Promise<boolean>;
    claimTaskAsync(taskId: string, runId: string): Promise<boolean>;
    getProject(id: string): Promise<Project | null>;
    getProjectByPath(_path: string): Promise<Project | null>;
    listProjects(_status?: string): Promise<Project[]>;
    updateProject(id: string, updates: Partial<Pick<Project, "name" | "path" | "status">>): Promise<void>;
    createRun(projectId: string, seedId: string, agentType: string, worktreePath: string | null, opts?: {
        baseBranch?: string | null;
        mergeStrategy?: string | null;
        sessionKey?: string | null;
    }): Promise<Run>;
    updateRun(runId: string, updates: Partial<Pick<Run, "status" | "worktree_path" | "session_key" | "started_at" | "completed_at" | "merge_strategy">>): Promise<void>;
    getRun(id: string): Promise<Run | null>;
    getActiveRuns(_projectId?: string): Promise<Run[]>;
    getRunsByStatus(status: Run["status"], projectId?: string): Promise<Run[]>;
    getRunsByStatuses(statuses: Run["status"][], projectId?: string): Promise<Run[]>;
    getRunsByStatusesSince(statuses: Run["status"][], since: string, projectId?: string): Promise<Run[]>;
    getRunsByStatusSince(status: Run["status"], since: string, projectId?: string): Promise<Run[]>;
    purgeOldRuns(olderThan: string, projectId?: string): Promise<number>;
    deleteRun(runId: string): Promise<boolean>;
    getRunsForSeed(seedId: string, projectId?: string): Promise<Run[]>;
    hasActiveOrPendingRun(seedId: string, projectId?: string): Promise<boolean>;
    getRunsByBaseBranch(baseBranch: string, projectId?: string): Promise<Run[]>;
    logEvent(projectId: string, eventType: EventType, data: Record<string, unknown>, runId?: string): Promise<void>;
    recordSentinelEvent(projectId: string, sentinelRunId: string, eventType: "sentinel-start" | "sentinel-pass" | "sentinel-fail", data: Record<string, unknown>): Promise<void>;
    getRunEvents(runId: string, eventType?: EventType): Promise<Array<{
        id: string;
        event_type: string;
        data: string;
        created_at: string;
    }>>;
    getEvents(projectId?: string, limit?: number, eventType?: string): Promise<Array<{
        id: string;
        project_id: string;
        run_id: string | null;
        event_type: string;
        data: string;
        created_at: string;
    }>>;
    recordCost(runId: string, tokensIn: number, tokensOut: number, cacheRead: number, estimatedCost: number): Promise<void>;
    getCosts(_projectId?: string, since?: string): Promise<Cost[]>;
    getCostBreakdown(runId: string): Promise<{
        byPhase: Record<string, number>;
        byAgent: Record<string, number>;
    }>;
    getPhaseMetrics(_projectId?: string, since?: string): Promise<{
        totalCost: number;
        totalTokens: number;
        tasksByStatus: Record<string, number>;
    }>;
    getSuccessRate(_projectId?: string): Promise<{
        rate: number | null;
        merged: number;
        failed: number;
    }>;
    updateRunProgress(runId: string, progress: RunProgress): Promise<void>;
    getRunProgress(runId: string): Promise<RunProgress | null>;
    logRateLimitEvent(projectId: string, model: string, phase: string, error: string, retryAfterSeconds?: number, runId?: string): Promise<void>;
    getRateLimitCountsByModel(projectId: string, hoursBack?: number): Promise<Record<string, number>>;
    getRecentRateLimitEvents(projectId: string, _limit?: number): Promise<Array<{
        model: string;
        tokens_used: number;
        window_start: string;
        created_at: string;
    }>>;
    sendMessage(runId: string, senderAgentType: string, recipientAgentType: string, subject: string, body: string): Promise<void>;
    getMessages(runId: string, agentType: string, unreadOnly?: boolean): Promise<Message[]>;
    markMessageRead(messageId: string): Promise<void>;
    markAllMessagesRead(runId: string, agentType: string): Promise<void>;
    deleteMessage(messageId: string): Promise<void>;
    getAllMessages(runId: string): Promise<Message[]>;
    getAllMessagesGlobal(limit?: number): Promise<Message[]>;
    enqueueMerge(_runId: string, _mergeData: Record<string, unknown>): Promise<void>;
    getMergeQueue(): Promise<unknown[]>;
    getMergeQueueStats(): Promise<{
        pending: number;
        running: number;
    }>;
    updateMergeQueueEntry(_runId: string, _updates: Record<string, unknown>): Promise<void>;
    removeMergeQueueEntry(_runId: string): Promise<void>;
    recordMergeCost(_runId: string, _phase: string, _tokensIn: number, _tokensOut: number, _estimatedCost: number): Promise<void>;
    getMergeCosts(_runId?: string): Promise<Cost[]>;
    getConflictPatterns(_projectId: string): Promise<Array<{
        id: string;
        pattern: string;
        resolution: string;
    }>>;
    upsertConflictPattern(_projectId: string, _pattern: string, _resolution: string): Promise<void>;
    deleteConflictPattern(_id: string): Promise<void>;
    getSentinelConfig(projectId: string): Promise<SentinelConfigRow | null>;
    upsertSentinelConfig(projectId: string, config: Partial<Omit<SentinelConfigRow, "id" | "project_id" | "created_at" | "updated_at">>): Promise<void>;
    getSentinelRuns(projectId: string, limit?: number): Promise<SentinelRunRow[]>;
    recordSentinelRun(projectId: string, run: Omit<SentinelRunRow, "failure_count"> & {
        failure_count?: number;
    }): Promise<void>;
    updateSentinelRun(id: string, updates: Partial<SentinelRunRow>): Promise<void>;
    getMergeAgentConfig(_projectId: string): Promise<MergeAgentConfigRow | null>;
    upsertMergeAgentConfig(_projectId: string, _config: MergeAgentConfigRow): Promise<void>;
    getMergeStrategyConfig(_projectId: string): Promise<{
        id: string;
        project_id: string;
        strategy: string;
        created_at: string;
        updated_at: string;
    } | null>;
    upsertMergeStrategyConfig(_projectId: string, _config: {
        strategy: string;
    }): Promise<void>;
    listTasksByStatusSync(statuses: string[], limit?: number): NativeTask[];
    getProjectByPathSync(_path: string): Project | null;
    listProjectsSync(_status?: string): Project[];
    getActiveRunsSync(_projectId?: string): Run[];
    private rowToRun;
}
//# sourceMappingURL=postgres-store.d.ts.map