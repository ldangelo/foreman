import Database from "better-sqlite3";
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
    status: "pending" | "running" | "completed" | "failed" | "stuck" | "merged" | "conflict" | "test-failed" | "pr-created" | "reset";
    started_at: string | null;
    completed_at: string | null;
    created_at: string;
    progress: string | null;
    /** @deprecated tmux removed; column kept for DB backward compat */
    tmux_session?: string | null;
    /** Branch that this seed's worktree was branched from (null = default branch). Used for branch stacking. */
    base_branch?: string | null;
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
export type EventType = "dispatch" | "claim" | "complete" | "fail" | "merge" | "stuck" | "restart" | "recover" | "conflict" | "test-fail" | "pr-created" | "merge-queue-enqueue" | "merge-queue-dequeue" | "merge-queue-resolve" | "merge-queue-fallback" | "sentinel-start" | "sentinel-pass" | "sentinel-fail";
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
 * Represents a pending bead write operation in the serialized write queue.
 *
 * Operations are inserted by agent-workers, refinery, pipeline-executor, and
 * auto-merge, then drained and executed sequentially by the dispatcher.
 * This eliminates concurrent br CLI invocations that cause SQLite contention.
 */
export interface BeadWriteEntry {
    /** Unique entry ID (UUID). */
    id: string;
    /** Source of the write (e.g. "agent-worker", "refinery", "pipeline-executor"). */
    sender: string;
    /** Operation type: "close-seed" | "reset-seed" | "mark-failed" | "add-notes" | "add-labels". */
    operation: string;
    /** JSON-encoded payload specific to the operation. */
    payload: string;
    /** ISO timestamp when the entry was inserted. */
    created_at: string;
    /** ISO timestamp when the entry was processed (null = pending). */
    processed_at: string | null;
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
export declare class ForemanStore {
    private db;
    /**
     * Create a ForemanStore backed by a project-local SQLite database.
     *
     * The database is stored at `<projectPath>/.foreman/foreman.db`, keeping
     * all state scoped to the project rather than the user's home directory.
     *
     * @param projectPath - Absolute path to the project root directory.
     */
    static forProject(projectPath: string): ForemanStore;
    constructor(dbPath?: string);
    /** Expose the underlying database for modules that need direct access (e.g. MergeQueue). */
    getDb(): Database.Database;
    close(): void;
    registerProject(name: string, path: string): Project;
    getProject(id: string): Project | null;
    getProjectByPath(path: string): Project | null;
    listProjects(status?: string): Project[];
    updateProject(id: string, updates: Partial<Pick<Project, "name" | "path" | "status">>): void;
    createRun(projectId: string, seedId: string, agentType: Run["agent_type"], worktreePath?: string, opts?: {
        baseBranch?: string | null;
    }): Run;
    updateRun(id: string, updates: Partial<Pick<Run, "status" | "session_key" | "worktree_path" | "started_at" | "completed_at" | "base_branch">>): void;
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
    logEvent(projectId: string, eventType: EventType, details?: Record<string, unknown> | string, runId?: string): void;
    getEvents(projectId?: string, limit?: number, eventType?: string): Event[];
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
    /**
     * Enqueue a bead write operation for sequential processing by the dispatcher.
     *
     * Called by agent-workers, refinery, pipeline-executor, and auto-merge
     * instead of invoking the br CLI directly. The dispatcher drains this queue
     * and executes br commands one at a time, eliminating SQLite lock contention.
     *
     * @param sender - Human-readable source identifier (e.g. "agent-worker", "refinery")
     * @param operation - Operation type: "close-seed" | "reset-seed" | "mark-failed" | "add-notes" | "add-labels"
     * @param payload - Operation-specific data (will be JSON-stringified)
     */
    enqueueBeadWrite(sender: string, operation: string, payload: unknown): void;
    /**
     * Retrieve all pending (unprocessed) bead write entries in insertion order.
     * Returns entries where processed_at IS NULL, ordered by created_at ASC.
     */
    getPendingBeadWrites(): BeadWriteEntry[];
    /**
     * Mark a bead write entry as processed by setting its processed_at timestamp.
     * @returns true if the entry was found and updated, false otherwise.
     */
    markBeadWriteProcessed(id: string): boolean;
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
}
//# sourceMappingURL=store.d.ts.map