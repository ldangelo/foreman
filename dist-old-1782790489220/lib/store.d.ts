import type { NativeTaskStatus } from "../orchestrator/types.js";
type LocalStoreRunResult = {
    changes: number;
    lastInsertRowid?: number | bigint;
};
type LocalStoreStatement = {
    run: (...args: unknown[]) => LocalStoreRunResult;
    get: (...args: unknown[]) => any;
    all: (...args: unknown[]) => any[];
};
type LocalStoreDatabase = {
    prepare: (...args: unknown[]) => LocalStoreStatement;
    exec: (...args: unknown[]) => void;
    pragma: (...args: unknown[]) => unknown;
    transaction: (fn: (...args: unknown[]) => unknown) => (...args: unknown[]) => unknown;
    close: () => void;
};
export interface Project {
    id: string;
    name: string;
    path: string;
    status: "active" | "paused" | "archived";
    created_at: string;
    updated_at: string;
}
export interface Run {
    id: string;
    project_id: string;
    seed_id: string;
    agent_type: string;
    session_key: string | null;
    worktree_path: string | null;
    status: "pending" | "running" | "completed" | "failed" | "stuck" | "cooldown" | "merged" | "conflict" | "test-failed" | "pr-created" | "reset";
    started_at: string | null;
    completed_at: string | null;
    created_at: string;
    progress: string | null;
    /** @deprecated tmux removed; column kept for DB backward compat */
    tmux_session?: string | null;
    /** Branch that this seed's worktree was branched from (null = default branch). Used for branch stacking. */
    base_branch?: string | null;
    /** Per-run merge strategy: 'auto' (refinery), 'pr' (gh pr create), or 'none' (skip). */
    merge_strategy?: "auto" | "pr" | "none" | null;
    /**
     * HEAD SHA at the time this run's PR was created.
     * Used for PR identity (AC-1): PR reuse requires matching head SHA.
     * Captured at finalize start in pipeline-executor.
     */
    commit_sha?: string | null;
    /**
     * Canonical PR URL for this run (null = no PR yet).
     * Set by Refinery.ensurePullRequestForRun() after PR creation.
     */
    pr_url?: string | null;
    /**
     * GitHub PR state: 'none' | 'draft' | 'open' | 'merged' | 'closed'.
     * Used for task list PR state surfacing (AC-4).
     */
    pr_state?: "none" | "draft" | "open" | "merged" | "closed" | null;
    /**
     * Branch HEAD SHA when the PR was last updated.
     * Used to detect head mismatch (AC-2): PR must be recreated when SHA changes.
     */
    pr_head_sha?: string | null;
    /**
     * ISO timestamp when the task's cooldown period ends.
     * Set when a phase fails with a retryable error and retryAfterCooldown is enabled.
     * The dispatcher skips this task until the cooldown period expires.
     */
    cooldown_until?: string | null;
}
export interface Cost {
    id: string;
    run_id: string;
    tokens_in: number;
    tokens_out: number;
    cache_read: number;
    estimated_cost: number;
    recorded_at: string;
}
export type EventType = "dispatch" | "claim" | "complete" | "fail" | "merge" | "stuck" | "restart" | "recover" | "conflict" | "test-fail" | "pr-created" | "pr-stale" | "merge-queue-enqueue" | "merge-queue-dequeue" | "merge-queue-resolve" | "merge-queue-fallback" | "merge-cleanup-fallback" | "sentinel-start" | "sentinel-pass" | "sentinel-fail" | "heartbeat" | "guardrail-veto" | "guardrail-corrected" | "worktree-rebased" | "worktree-rebase-failed" | "phase-start" | "phase-complete" | "cooldown";
export interface Event {
    id: string;
    project_id: string;
    run_id: string | null;
    event_type: EventType;
    details: string | null;
    created_at: string;
}
export interface RunProgress {
    toolCalls: number;
    toolBreakdown: Record<string, number>;
    filesChanged: string[];
    turns: number;
    costUsd: number;
    tokensIn: number;
    tokensOut: number;
    lastToolCall: string | null;
    lastActivity: string;
    currentPhase?: string;
    costByPhase?: Record<string, number>;
    agentByPhase?: Record<string, string>;
    /** Target branch name QA validated against. */
    qaValidatedTargetBranch?: string;
    /** Target branch revision/hash resolved when QA passed. */
    qaValidatedTargetRef?: string;
    /** Workspace HEAD revision/hash resolved when QA passed. */
    qaValidatedHeadRef?: string;
    /** Current target branch revision/hash resolved during finalize preparation. */
    currentTargetRef?: string;
    /** Epic mode: total number of child tasks. */
    epicTaskCount?: number;
    /** Epic mode: number of tasks completed so far. */
    epicTasksCompleted?: number;
    /** Epic mode: seed ID of the currently executing task. */
    epicCurrentTaskId?: string;
    /** Epic mode: per-task cost breakdown. */
    epicCostByTask?: Record<string, number>;
}
export interface Metrics {
    totalCost: number;
    totalTokens: number;
    tasksByStatus: Record<string, number>;
    costByRuntime: Array<{
        run_id: string;
        cost: number;
        duration_seconds: number | null;
    }>;
    costByPhase?: Record<string, number>;
    agentCostBreakdown?: Record<string, number>;
}
export interface Message {
    id: string;
    run_id: string;
    sender_agent_type: string;
    recipient_agent_type: string;
    subject: string;
    body: string;
    read: number;
    created_at: string;
    deleted_at: string | null;
}
/**
 * A task row from the native Postgres `tasks` table (PRD-2026-006 REQ-003).
 * Matches the TASKS_SCHEMA column definitions.
 */
export interface NativeTask {
    id: string;
    title: string;
    description: string | null;
    type: string;
    priority: number;
    status: NativeTaskStatus;
    run_id: string | null;
    branch: string | null;
    external_id: string | null;
    labels?: string[] | null;
    parent?: string | null;
    parentId?: string | null;
    created_at: string;
    updated_at: string;
    approved_at: string | null;
    closed_at: string | null;
}
export interface MergeAgentConfigRow {
    id: string;
    enabled: number;
    poll_interval_ms: number;
    created_at: string;
    updated_at: string;
}
export interface SentinelConfigRow {
    id: number;
    project_id: string;
    branch: string;
    test_command: string;
    interval_minutes: number;
    failure_threshold: number;
    enabled: number;
    pid: number | null;
    created_at: string;
    updated_at: string;
}
export interface SentinelRunRow {
    id: string;
    project_id: string;
    branch: string;
    commit_hash: string | null;
    status: "running" | "passed" | "failed" | "error";
    test_command: string;
    output: string | null;
    failure_count: number;
    started_at: string;
    completed_at: string | null;
}
/**
 * A task row from the native `tasks` table (PRD-2026-006 REQ-003).
 * Used by the dashboard "Needs Human" panel and phase-visibility views.
 */
export interface NativeTask {
    id: string;
    title: string;
    description: string | null;
    type: string;
    priority: number;
    status: NativeTaskStatus;
    run_id: string | null;
    branch: string | null;
    external_id: string | null;
    labels?: string[] | null;
    parent?: string | null;
    parentId?: string | null;
    created_at: string;
    updated_at: string;
    approved_at: string | null;
    closed_at: string | null;
    /** Attached project name/id for cross-project aggregation (not a DB column). */
    projectName?: string;
    projectId?: string;
    projectPath?: string;
}
/**
 * Thrown when a task status value is not in the set of valid statuses defined
 * by the tasks table CHECK constraint.
 *
 * Valid statuses mirror the CHECK constraint in TASKS_SCHEMA below.
 * Update both if new statuses are added (ref: PRD-2026-006 REQ-003).
 */
export declare class InvalidTaskStatusError extends Error {
    readonly attemptedStatus: string;
    readonly validStatuses: string[];
    constructor(attemptedStatus: string, validStatuses: string[]);
}
/**
 * Narrow interface for run-related store operations.
 * Covers create, read, update, and query operations for pipeline runs.
 */
export type RunStore = Pick<ForemanStore, "createRun" | "updateRun" | "getRun" | "getActiveRuns" | "getRunsByStatus" | "getRunsByStatuses" | "getRunsByStatusSince" | "getRunsByStatusesSince" | "purgeOldRuns" | "deleteRun" | "getRunsForSeed" | "hasActiveOrPendingRun" | "getRunsByBaseBranch" | "getRunEvents">;
/**
 * Narrow interface for project-related store operations.
 * Covers project registration, lookup, and updates.
 */
export type ProjectStore = Pick<ForemanStore, "registerProject" | "getProject" | "getProjectByPath" | "listProjects" | "updateProject">;
/**
 * Narrow interface for progress and event logging.
 * Covers run progress tracking and event emission.
 */
export type ProgressEventStore = Pick<ForemanStore, "updateRunProgress" | "getRunProgress" | "logEvent" | "getEvents">;
/**
 * Narrow interface for inter-agent messaging.
 * Covers message sending, retrieval, and management.
 */
export type MailStore = Pick<ForemanStore, "sendMessage" | "getMessages" | "getAllMessages" | "getAllMessagesGlobal" | "markMessageRead" | "markAllMessagesRead" | "deleteMessage" | "getMessage">;
/**
 * Narrow interface for native task management.
 * Covers task CRUD operations and claiming.
 */
export type TaskStore = Pick<ForemanStore, "listTasksByStatus" | "updateTaskStatus" | "hasNativeTasks" | "getTaskById" | "getTaskByExternalId" | "getReadyTasks" | "claimTask">;
/**
 * Narrow interface for sentinel configuration and runs.
 * Covers CI/sentinel integration for branch monitoring.
 */
export type SentinelStore = Pick<ForemanStore, "upsertSentinelConfig" | "getSentinelConfig" | "recordSentinelRun" | "updateSentinelRun" | "getSentinelRuns">;
/**
 * Narrow interface for cost tracking and metrics.
 * Covers cost recording, aggregation, and success rate calculations.
 */
export type CostMetricsStore = Pick<ForemanStore, "recordCost" | "getCosts" | "getCostBreakdown" | "getPhaseMetrics" | "getRecentOutcomeCounts" | "getSuccessRate" | "getMetrics" | "logRateLimitEvent" | "getRateLimitCountsByModel" | "getRecentRateLimitEvents">;
/**
 * Narrow interface for dashboard read operations.
 * Covers all read-only methods needed by pollDashboard() and readProjectRegistry().
 * The CLI uses this interface so pure read functions don't need the full store type.
 */
export type DashboardReadStore = Pick<ForemanStore, "listProjects" | "getProject" | "getActiveRuns" | "getRunsByStatus" | "getRunProgress" | "getMetrics" | "getEvents" | "getSuccessRate" | "listTasksByStatus" | "close">;
/**
 * Narrow read-only interface for the status command.
 * Covers project lookup, active runs, progress, metrics, success rate, and recent outcomes.
 */
export type StatusReadStore = Pick<ForemanStore, "getProjectByPath" | "getActiveRuns" | "getRunProgress" | "getRunsForSeed" | "getRecentOutcomeCounts" | "getSuccessRate" | "getMetrics">;
export declare class ForemanStore {
    private db;
    /**
     * Create a disabled ForemanStore compatibility object for a project.
     *
     * Current state access should go through the Postgres-backed daemon APIs.
     *
     * @param projectPath - Absolute path to the project root directory.
     */
    static forProject(projectPath: string): ForemanStore;
    /**
     * Create a DashboardReadStore for a project.
     *
     * Returns a disabled local-store compatibility handle typed as DashboardReadStore.
     * Use this factory when you only need read-only dashboard operations
     * (pollDashboard, readProjectRegistry) and don't need write access.
     *
     * @param projectPath - Absolute path to the project root directory.
     * @returns A DashboardReadStore instance for the project.
     */
    static forDashboard(projectPath: string): DashboardReadStore;
    /**
     * Open the project database in READONLY mode for safe concurrent dashboard reads.
     *
     * Returns a disabled local-store compatibility handle.
     * Postgres-backed dashboard reads should use the daemon APIs.
     *
     * This is intentionally a static factory that bypasses the normal ForemanStore
     * constructor (which runs migrations and writes to the DB) — the dashboard reads
     * should never write to a project's database.
     *
     * @param projectPath - Absolute path to the project root directory.
     * @returns A disabled local-store compatibility handle.
     */
    static openReadonly(_projectPath: string): LocalStoreDatabase;
    constructor(dbPath?: string);
    /** Expose the underlying database for modules that need direct access (e.g. MergeQueue). */
    getDb(): LocalStoreDatabase;
    isOpen(): boolean;
    close(): void;
    /**
     * List tasks from the native `tasks` table filtered by one or more statuses.
     * Returns an empty array if the `tasks` table does not exist (older DBs).
     *
     * @param statuses - Array of status strings to filter by (e.g. ['conflict', 'failed', 'stuck', 'backlog'])
     * @param limit    - Maximum number of rows to return (default: 200)
     */
    listTasksByStatus(statuses: string[], limit?: number): NativeTask[];
    /**
     * Update a task status via a short-lived write.  Used by dashboard
     * interactive actions (approve / retry).
     *
     * @param taskId    - Task UUID to update.
     * @param newStatus - Target status (must be in TASKS_SCHEMA CHECK constraint).
     */
    updateTaskStatus(taskId: string, newStatus: string): void;
    /**
     * Update task labels via a short-lived write.
     * Used by dispatcher for branch label auto-labeling.
     *
     * @param taskId - Task UUID to update.
     * @param labels - New labels array.
     */
    updateTaskLabels(taskId: string, labels: string[]): void;
    registerProject(name: string, path: string): Project;
    getProject(id: string): Project | null;
    getProjectByPath(path: string): Project | null;
    listProjects(status?: string): Project[];
    updateProject(id: string, updates: Partial<Pick<Project, "name" | "path" | "status">>): void;
    createRun(projectId: string, seedId: string, agentType: Run["agent_type"], worktreePath?: string, opts?: {
        baseBranch?: string | null;
        mergeStrategy?: Run["merge_strategy"];
    }): Run;
    updateRun(id: string, updates: Partial<Pick<Run, "status" | "session_key" | "worktree_path" | "started_at" | "completed_at" | "base_branch" | "merge_strategy" | "commit_sha" | "pr_url" | "pr_state" | "pr_head_sha" | "cooldown_until">>): void;
    getRun(id: string): Run | null;
    getActiveRuns(projectId?: string): Run[];
    getRunsByStatus(status: Run["status"], projectId?: string): Run[];
    /**
     * Fetch runs whose status is any of the given values.
     * Used by Refinery.getCompletedRuns() to find retry-eligible runs when a seedId
     * filter is active (e.g. after a test-failed or conflict).
     */
    getRunsByStatuses(statuses: Run["status"][], projectId?: string): Run[];
    getRunsByStatusSince(status: Run["status"], since: string, projectId?: string): Run[];
    /**
     * Fetch runs matching any of the given statuses created on or after `since`.
     * Used by the dispatcher's onError=stop guard to check for recent failures.
     */
    getRunsByStatusesSince(statuses: Run["status"][], since: string, projectId?: string): Run[];
    /**
     * Purge old runs in terminal states (failed, merged, test-failed, conflict)
     * that are older than the given cutoff date. Returns number of rows deleted.
     */
    purgeOldRuns(olderThan: string, projectId?: string): number;
    /**
     * Delete a single run record by ID.
     * Returns true if a row was deleted, false if no such run existed.
     */
    deleteRun(runId: string): boolean;
    getRunsForSeed(seedId: string, projectId?: string): Run[];
    /**
     * Check whether a seed already has a non-terminal run in the database.
     *
     * "Non-terminal" means the run is still active or has produced a result that
     * should block a new dispatch (pending, running, completed, stuck, pr-created).
     * Terminal/retryable states (failed, merged, conflict, test-failed, reset) are
     * excluded so that genuinely failed seeds can be retried.
     *
     * Used by the dispatcher as a just-in-time guard immediately before calling
     * createRun(), preventing duplicate dispatches when two dispatch cycles race
     * and both observe an empty activeRuns snapshot.
     *
     * @returns true if the seed should be skipped (a non-terminal run exists),
     *          false if it is safe to dispatch.
     */
    hasActiveOrPendingRun(seedId: string, projectId?: string): boolean;
    /**
     * Find all runs that were branched from the given base branch (i.e. stacked on it).
     * Used by rebaseStackedBranches() to find dependent seeds after a merge.
     */
    getRunsByBaseBranch(baseBranch: string, projectId?: string): Run[];
    getRunEvents(runId: string, eventType?: EventType): Event[];
    updateRunProgress(runId: string, progress: RunProgress): void;
    getRunProgress(runId: string): RunProgress | null;
    recordCost(runId: string, tokensIn: number, tokensOut: number, cacheRead: number, estimatedCost: number): void;
    getCosts(projectId?: string, since?: string): Cost[];
    /**
     * Get per-phase and per-agent cost breakdown for a single run.
     * Returns empty records if the run has no phase cost data (backwards compatible).
     */
    getCostBreakdown(runId: string): {
        byPhase: Record<string, number>;
        byAgent: Record<string, number>;
    };
    /**
     * Aggregate phase costs across all runs in a project.
     * Reads per-phase cost data stored in progress JSON.
     */
    getPhaseMetrics(projectId?: string, since?: string): {
        totalByPhase: Record<string, number>;
        totalByAgent: Record<string, number>;
        runsByPhase: Record<string, number>;
    };
    getRecentOutcomeCounts(projectId?: string, since?: string): {
        merged: number;
        failed: number;
        stuck: number;
    };
    /**
     * Compute the 24-hour pipeline success rate for a project.
     *
     * Success rate = merged / (merged + failed), where:
     * - "merged" includes both `merged` and `pr-created` statuses
     * - "failed" includes `failed`, `test-failed`, and `reset`
     * - only the latest authoritative run per seed is counted
     * - `completed` (pending merge), `running`, `pending`, and `stuck` are excluded
     *
     * Returns `{ rate: null, merged: 0, failed: 0 }` when fewer than 3 terminal
     * runs have completed in the last 24 hours (not enough data to be meaningful).
     *
     * @param projectId - Scope to a specific project; omit for global.
     */
    getSuccessRate(projectId?: string): {
        rate: number | null;
        merged: number;
        failed: number;
    };
    logEvent(projectId: string, eventType: EventType, details?: Record<string, unknown> | string, runId?: string): void;
    getEvents(projectId?: string, limit?: number, eventType?: string): Event[];
    /**
     * Log a rate limit event when a 429 is detected.
     * This enables per-model rate limit tracking and alerting.
     */
    logRateLimitEvent(projectId: string, model: string, phase: string | undefined, error: string, retryAfterSeconds?: number, runId?: string): void;
    /**
     * Get rate limit event counts grouped by model for the last N hours.
     * Used for visualization and alerting (P2, P3 recommendations).
     */
    getRateLimitCountsByModel(projectId: string, hoursBack?: number): Record<string, number>;
    /**
     * Get recent rate limit events for alerting purposes.
     */
    getRecentRateLimitEvents(projectId: string, limit?: number): Array<{
        id: string;
        model: string;
        phase: string | null;
        error: string;
        retry_after_seconds: number | null;
        recorded_at: string;
    }>;
    /**
     * Send a message from one agent to another within a run.
     * Messages are scoped by run_id so agents in different runs cannot cross-communicate.
     */
    sendMessage(runId: string, senderAgentType: string, recipientAgentType: string, subject: string, body: string): Message;
    /**
     * Get messages for an agent in a run.
     * @param runId - The run to scope messages to
     * @param agentType - The recipient agent type
     * @param unreadOnly - If true, only return unread messages (default: false)
     */
    getMessages(runId: string, agentType: string, unreadOnly?: boolean): Message[];
    /**
     * Get all messages in a run (for lead/coordinator visibility).
     */
    getAllMessages(runId: string): Message[];
    /**
     * Get all messages across all runs (for global watch mode).
     */
    getAllMessagesGlobal(limit?: number): Message[];
    /**
     * Mark a message as read.
     * @returns true if the message was found and updated, false if no such message exists.
     */
    markMessageRead(messageId: string): boolean;
    /**
     * Mark all messages for an agent in a run as read.
     *
     * The `deleted_at IS NULL` guard is intentional: soft-deleted messages are
     * excluded from all normal queries and should not be resurrected by a bulk
     * read — they remain "deleted" and do not count as unread.
     */
    markAllMessagesRead(runId: string, agentType: string): void;
    /**
     * Soft-delete a message (sets deleted_at timestamp).
     * @returns true if the message was found and soft-deleted, false if no such message exists.
     */
    deleteMessage(messageId: string): boolean;
    /**
     * Get a single message by ID.
     */
    getMessage(messageId: string): Message | null;
    upsertSentinelConfig(projectId: string, config: Partial<Omit<SentinelConfigRow, "id" | "project_id" | "created_at" | "updated_at">>): SentinelConfigRow;
    getSentinelConfig(projectId: string): SentinelConfigRow | null;
    recordSentinelRun(run: Omit<SentinelRunRow, "failure_count"> & {
        failure_count?: number;
    }): void;
    updateSentinelRun(id: string, updates: Partial<Pick<SentinelRunRow, "status" | "output" | "completed_at" | "failure_count">>): void;
    getSentinelRuns(projectId?: string, limit?: number): SentinelRunRow[];
    /**
     * Get the merge agent configuration row (singleton with id='default').
     * Returns null if not yet initialized (before `foreman init`).
     */
    getMergeAgentConfig(): MergeAgentConfigRow | null;
    /**
     * Create or update the merge agent configuration.
     * Upserts the singleton 'default' row.
     */
    setMergeAgentConfig(config: Partial<Omit<MergeAgentConfigRow, "id" | "created_at" | "updated_at">>): MergeAgentConfigRow;
    getMetrics(projectId?: string, since?: string): Metrics;
    /**
     * Check whether the native `tasks` table exists and contains at least one row.
     *
     * Used by the dispatcher to decide whether to query the native store or fall
     * back to the BeadsRustClient (br) CLI.  Returns false if the table is missing
     * (schema not yet applied) or empty.
     */
    hasNativeTasks(): boolean;
    /**
     * Look up a native task by its `id` column.
     *
     * Falls back when getTaskByExternalId misses because the task has no external_id set.
     */
    getTaskById(id: string): NativeTask | null;
    /**
     * Look up a native task by external_id.
     *
     * Used when an explicit bead ID may correspond to a native task row in auto mode.
     * Returns null when the tasks table is missing or no row matches.
     */
    getTaskByExternalId(externalId: string): NativeTask | null;
    /**
     * Return all tasks with status = 'ready', ordered by priority ASC then created_at ASC.
     *
     * Implements REQ-017 AC-017.1: "SELECT * FROM tasks WHERE status = 'ready'
     * ORDER BY priority ASC, created_at ASC".
     */
    getReadyTasks(): NativeTask[];
    /**
     * Atomically claim a task by transitioning its status from 'ready' to 'in-progress'
     * and recording the associated run_id in a single Postgres transaction.
     *
     * Implements REQ-017 AC-017.2: the UPDATE is atomic — if two concurrent dispatcher
     * instances attempt to claim the same task, exactly one succeeds (the WHERE clause
     * only matches rows still in status='ready').
     *
     * @param taskId - The task ID to claim.
     * @param runId  - The run ID to associate with the claimed task.
     * @returns true if the task was claimed (row affected), false if it was already
     *          claimed by another process (0 rows affected).
     */
    claimTask(taskId: string, runId: string): boolean;
}
export {};
//# sourceMappingURL=store.d.ts.map