/**
 * PostgresAdapter — database operations via PoolManager.
 *
 * This adapter implements project/task operations, legacy Foreman compatibility
 * operations, and pipeline/GitHub support on Postgres.
 *
 * Design decisions:
 * - All methods accept `projectId: string` as the first argument for data isolation.
 * - All methods delegate to PoolManager.query() / PoolManager.execute().
 * - Transactions use PoolManager.acquireClient() / PoolManager.releaseClient().
 * - No string interpolation of user input into SQL — parameterized queries only.
 *
 * @module postgres-adapter
 */
import type { RunProgress, SentinelConfigRow, SentinelRunRow } from "../store.js";
export interface ProjectMetadata {
    id?: string;
    name: string;
    path: string;
    githubUrl?: string;
    repoKey?: string | null;
    defaultBranch?: string;
    status?: "active" | "paused" | "archived";
}
export interface ProjectRow {
    id: string;
    name: string;
    path: string;
    github_url: string | null;
    repo_key: string | null;
    default_branch: string | null;
    status: "active" | "paused" | "archived";
    created_at: string;
    updated_at: string;
    last_sync_at: string | null;
}
export interface RunRow {
    id: string;
    project_id: string;
    seed_id: string;
    agent_type: string;
    session_key: string | null;
    worktree_path: string | null;
    branch: string | null;
    status: string;
    started_at: string | null;
    completed_at: string | null;
    base_branch: string | null;
    merge_strategy: "auto" | "pr" | "none" | null;
    created_at: string;
    progress: string | null;
}
export interface TaskRow {
    id: string;
    project_id: string;
    title: string;
    description: string | null;
    type: string;
    priority: number;
    status: string;
    run_id: string | null;
    branch: string | null;
    external_id: string | null;
    created_at: string;
    updated_at: string;
    approved_at: string | null;
    closed_at: string | null;
    external_repo?: string | null;
    github_issue_number?: number | null;
    github_milestone?: string | null;
    sync_enabled?: boolean;
    last_sync_at?: string | null;
    labels?: string[] | null;
    pr_state?: "none" | "draft" | "open" | "merged" | "closed" | null;
    pr_url?: string | null;
    /** HEAD SHA of the branch when the PR was last updated. Null if no PR exists. */
    pr_head_sha?: string | null;
}
export interface TaskDependencyRow {
    from_task_id: string;
    to_task_id: string;
    type: "blocks" | "parent-child";
}
export interface TaskNoteRow {
    id: string;
    project_id: string;
    task_id: string;
    run_id: string | null;
    phase: string | null;
    author: string;
    kind: string;
    body: string;
    metadata: Record<string, unknown> | null;
    created_at: string;
}
export interface AddTaskNoteInput {
    runId?: string | null;
    phase?: string | null;
    author: string;
    kind?: string;
    body: string;
    metadata?: Record<string, unknown> | null;
}
export interface EventRow {
    id: string;
    project_id: string;
    run_id: string | null;
    event_type: string;
    details: string | null;
    created_at: string;
}
export interface CostRow {
    id: string;
    run_id: string;
    tokens_in: number;
    tokens_out: number;
    cache_read: number;
    estimated_cost: number;
    recorded_at: string;
}
export interface PipelineRunRow {
    id: string;
    project_id: string;
    bead_id: string;
    run_number: number;
    status: string;
    branch: string;
    commit_sha: string | null;
    trigger: string;
    agent_type: string | null;
    session_key: string | null;
    worktree_path: string | null;
    progress: string | null;
    base_branch: string | null;
    merge_strategy: string | null;
    queued_at: string;
    started_at: string | null;
    finished_at: string | null;
    created_at: string;
    updated_at: string;
}
export interface PipelineEventRow {
    id: string;
    project_id: string;
    run_id: string | null;
    sentinel_run_id: string | null;
    task_id: string | null;
    event_type: string;
    payload: Record<string, unknown> | null;
    created_at: string;
}
export interface RateLimitEventRow {
    id: string;
    project_id: string;
    run_id: string | null;
    model: string;
    phase: string | null;
    error: string;
    retry_after_seconds: number | null;
    recorded_at: string;
}
export interface MessageRow {
    id: string;
    run_id: string;
    step_key: string | null;
    stream: string;
    chunk: string;
    line_number: number;
    created_at: string;
}
export interface AgentMessageRow {
    id: string;
    project_id: string;
    run_id: string;
    sender_agent_type: string;
    recipient_agent_type: string;
    subject: string;
    body: string;
    read: number;
    created_at: string;
    deleted_at: string | null;
}
export type MergeQueueStatus = "pending" | "merging" | "merged" | "conflict" | "failed";
export type MergeQueueOperation = "auto_merge" | "create_pr";
export interface MergeQueueEntryRow {
    id: number;
    project_id: string;
    branch_name: string;
    seed_id: string;
    run_id: string;
    operation: MergeQueueOperation;
    agent_name: string | null;
    files_modified: string[];
    enqueued_at: string;
    started_at: string | null;
    completed_at: string | null;
    status: MergeQueueStatus;
    resolved_tier: number | null;
    error: string | null;
    retry_count: number;
    last_attempted_at: string | null;
}
export interface GithubRepoRow {
    id: string;
    project_id: string;
    owner: string;
    repo: string;
    auth_type: "pat" | "app";
    auth_config: Record<string, unknown>;
    default_labels: string[];
    auto_import: boolean;
    webhook_secret: string | null;
    webhook_enabled: boolean;
    sync_strategy: "foreman-wins" | "github-wins" | "manual" | "last-write-wins";
    last_sync_at: string | null;
    created_at: string;
    updated_at: string;
}
export interface GithubSyncEventRow {
    id: string;
    project_id: string;
    external_id: string;
    event_type: string;
    direction: "to_github" | "from_github";
    github_payload: Record<string, unknown> | null;
    foreman_changes: Record<string, unknown> | null;
    conflict_detected: boolean;
    resolved_with: string | null;
    processed_at: string;
}
export interface UpsertGithubRepoInput {
    id?: string;
    projectId: string;
    owner: string;
    repo: string;
    authType?: "pat" | "app";
    authConfig?: Record<string, unknown>;
    defaultLabels?: string[];
    autoImport?: boolean;
    webhookSecret?: string | null;
    webhookEnabled?: boolean;
    syncStrategy?: "foreman-wins" | "github-wins" | "manual" | "last-write-wins";
    lastSyncAt?: string | null;
}
export interface RecordGithubSyncEventInput {
    projectId: string;
    externalId: string;
    eventType: string;
    direction: "to_github" | "from_github";
    githubPayload?: Record<string, unknown> | null;
    foremanChanges?: Record<string, unknown> | null;
    conflictDetected?: boolean;
    resolvedWith?: string | null;
}
export interface JiraIssueStateRow {
    project_key: string;
    issue_key: string;
    last_known_status: string;
    last_updated_at: string;
}
export interface JiraIssueStateInput {
    jiraProjectKey: string;
    issueKey: string;
    lastKnownStatus: string;
    lastUpdatedAt: string;
}
export interface JiraProjectRow {
    id: string;
    project_id: string;
    api_url: string;
    email: string;
    poll_interval_seconds: number | null;
    webhook_enabled: boolean;
    last_poll_at: string | null;
    webhook_secret_encrypted: string | null;
}
export declare class PostgresAdapter {
    private allocateTaskId;
    /**
     * Create a new project.
     *
     * @param metadata.projectId - Optional. If not provided, the database generates a UUID.
     * @returns The inserted project row.
     * @throws DatabaseError on constraint violation (e.g. duplicate path).
     */
    createProject(metadata: ProjectMetadata): Promise<ProjectRow>;
    /**
     * List all projects, optionally filtered by status.
     *
     * @param filters.status - Filter by project status.
     * @param filters.search - ILIKE pattern match on project name.
     * @returns Matching project rows, ordered by created_at DESC.
     */
    listProjects(filters?: {
        status?: "active" | "paused" | "archived";
        search?: string;
    }): Promise<ProjectRow[]>;
    /**
     * Get a single project by ID.
     *
     * @param projectId - The project UUID.
     * @returns The project row, or null if not found.
     */
    getProject(projectId: string): Promise<ProjectRow | null>;
    /**
     * Update project fields.
     *
     * @param projectId - The project UUID.
     * @param updates - Fields to update. All fields are optional.
     * @throws DatabaseError if the project does not exist.
     */
    updateProject(projectId: string, updates: Partial<Pick<ProjectRow, "name" | "path" | "status" | "github_url" | "repo_key" | "default_branch" | "last_sync_at">>): Promise<void>;
    /**
     * Remove (archive) a project.
     *
     * Default behaviour: soft-delete by setting status = 'archived'.
     * With force=true: hard-delete the row.
     *
     * @param projectId - The project UUID.
     * @param options.force - If true, DELETE the row. If false (default), archive it.
     */
    removeProject(projectId: string, options?: {
        force?: boolean;
    }): Promise<void>;
    /**
     * Sync a project (git fetch + update last_sync timestamp).
     *
     * Updates last_sync_at to the current time. Actual git fetch is handled
     * by the caller's process.
     *
     * @param projectId - The project UUID.
     */
    syncProject(projectId: string): Promise<void>;
    /**
     * Create a new task in backlog status.
     *
     * @param projectId - The owner project UUID.
     * @param taskData - Task fields. Required: id. Optional: title, description, type, priority.
     * @throws DatabaseError on constraint violation.
     */
    createTask(projectId: string, taskData: Record<string, unknown>): Promise<TaskRow>;
    /**
     * List tasks for a project with optional filters.
     *
     * @param projectId - The owner project UUID.
     * @param filters.status - Include only these statuses.
     * @param filters.runId - Include only tasks for this run.
     * @param filters.limit - Max rows to return (default: 100).
     */
    listTasks(projectId: string, filters?: {
        status?: string[];
        runId?: string;
        limit?: number;
        externalId?: string;
        labels?: string[];
    }): Promise<TaskRow[]>;
    /**
     * Get a single task by ID.
     *
     * @param projectId - The owner project UUID.
     * @param taskId - The task UUID.
     * @returns The task row, or null if not found or belongs to a different project.
     */
    getTask(projectId: string, taskId: string): Promise<TaskRow | null>;
    /**
     * Update a task's fields.
     *
     * @param projectId - The owner project UUID.
     * @param taskId - The task UUID.
     * @param updates - Fields to update. Supported: title, description, type, priority, status, branch, external_id.
     */
    addTaskNote(projectId: string, taskId: string, input: AddTaskNoteInput): Promise<TaskNoteRow>;
    listTaskNotes(projectId: string, taskId: string, opts?: {
        limit?: number;
        newestFirst?: boolean;
    }): Promise<TaskNoteRow[]>;
    updateTask(projectId: string, taskId: string, updates: Record<string, unknown>): Promise<void>;
    /**
     * Sync the claimed task linked to a run into a terminal status.
     *
     * No-op when no task is currently linked to the run.
     */
    updateTaskStatusForRun(projectId: string, runId: string, status: string): Promise<void>;
    /**
     * Delete a task and its dependencies.
     *
     * @param projectId - The owner project UUID.
     * @param taskId - The task UUID.
     */
    deleteTask(projectId: string, taskId: string): Promise<void>;
    /**
     * Claim a task for a run using SELECT ... FOR UPDATE.
     *
     * Uses row-level locking to prevent concurrent claims on the same task.
     * Only tasks in 'ready' status can be claimed.
     *
     * @param projectId - The owner project UUID.
     * @param taskId - The task UUID.
     * @param runId - The run UUID claiming this task.
     * @returns true if the claim succeeded (task was 'ready' and is now claimed),
     *          false if the task was already claimed by another run.
     */
    claimTask(projectId: string, taskId: string, runId: string | null): Promise<boolean>;
    /**
     * Approve a task: transition from 'backlog' to 'ready'.
     *
     * Only tasks in 'backlog' status can be approved. Sets approved_at timestamp.
     *
     * @param projectId - The owner project UUID.
     * @param taskId - The task UUID.
     * @throws Error if the task is not in 'backlog' status.
     */
    approveTask(projectId: string, taskId: string): Promise<void>;
    closeTask(projectId: string, taskId: string): Promise<void>;
    /**
     * Reset a task back to 'ready' state.
     *
     * Clears run_id and transitions to 'ready'. Use after a run fails or is cancelled
     * to make the task available for re-dispatch.
     *
     * @param projectId - The owner project UUID.
     * @param taskId - The task UUID.
     */
    resetTask(projectId: string, taskId: string): Promise<void>;
    /**
     * Retry a failed or stuck task.
     *
     * Resets status to 'ready' for tasks in 'failed' or 'stuck' status,
     * allowing them to be re-dispatched.
     *
     * @param projectId - The owner project UUID.
     * @param taskId - The task UUID.
     */
    retryTask(projectId: string, taskId: string): Promise<void>;
    /**
     * List tasks in 'ready' status for a project (dispatchable tasks).
     *
     * @param projectId - The owner project UUID.
     * @returns Tasks with status = 'ready', ordered by priority ASC, created_at ASC.
     */
    listReadyTasks(projectId: string): Promise<TaskRow[]>;
    /**
     * List ready tasks whose blockers are all closed.
     *
     * A task can remain in the native `ready` state while dependency links express
     * that another task must close first. Dispatchers must use this query rather
     * than raw status filtering so dependency-blocked ready tasks are not claimed.
     */
    listDispatchableReadyTasks(projectId: string, limit?: number): Promise<TaskRow[]>;
    /**
     * List tasks that need human attention.
     *
     * Includes: backlog (not approved), conflict, failed, stuck, blocked.
     *
     * @param projectId - The owner project UUID.
     */
    listNeedsHumanTasks(projectId: string): Promise<TaskRow[]>;
    /**
     * Get a task by its external ID (e.g., bead ID).
     */
    getTaskByExternalId(projectId: string, externalId: string): Promise<TaskRow | null>;
    /**
     * Check if any tasks exist for a project (native tasks).
     */
    hasNativeTasks(projectId: string): Promise<boolean>;
    addTaskDependency(projectId: string, fromTaskId: string, toTaskId: string, type?: "blocks" | "parent-child"): Promise<void>;
    listTaskDependencies(projectId: string, taskId: string, direction?: "outgoing" | "incoming"): Promise<TaskDependencyRow[]>;
    removeTaskDependency(projectId: string, fromTaskId: string, toTaskId: string, type?: "blocks" | "parent-child"): Promise<void>;
    /**
     * Get runs by multiple statuses since a given time.
     */
    getRunsByStatusesSince(projectId: string, statuses: string[], since: string): Promise<RunRow[]>;
    /**
     * Create a new run.
       */
    createRun(projectId: string, seedId: string, agentType: string, options?: {
        sessionKey?: string;
        worktreePath?: string;
        baseBranch?: string;
        mergeStrategy?: "auto" | "pr" | "none";
    }): Promise<RunRow>;
    /**
     * List runs for a project.
       */
    listRuns(projectId: string, filters?: {
        status?: string[];
        limit?: number;
    }): Promise<RunRow[]>;
    /**
     * Get a single run by ID.
       */
    getRun(projectId: string, runId: string): Promise<RunRow | null>;
    /**
     * Update a run's fields.
       */
    updateRun(projectId: string, runId: string, updates: Partial<Pick<RunRow, "status" | "session_key" | "worktree_path" | "progress" | "started_at" | "completed_at" | "base_branch" | "merge_strategy">>): Promise<void>;
    /**
     * List active (pending/running) runs for a project.
       */
    listActiveRuns(projectId: string): Promise<RunRow[]>;
    /**
     * Check if a seed has an active or pending run.
       */
    hasActiveOrPendingRun(projectId: string, seedId: string): Promise<boolean>;
    /**
     * Update run progress (phase, cost, tokens, etc.).
       */
    updateRunProgress(projectId: string, runId: string, progress: Partial<RunProgress> & {
        phase?: string;
    }): Promise<void>;
    /**
     * Purge runs older than a given timestamp.
       */
    purgeOldRuns(projectId: string, olderThan: string): Promise<number>;
    /**
     * Delete a run.
       */
    deleteRun(projectId: string, runId: string): Promise<boolean>;
    /**
     * Record cost data for a run.
       */
    recordCost(projectId: string, runId: string, cost: {
        tokensIn: number;
        tokensOut: number;
        cacheRead: number;
        estimatedCost: number;
    }): Promise<void>;
    /**
     * Log a project event.
       */
    logEvent(projectId: string, runId: string | null, eventType: string, details?: string): Promise<void>;
    /**
     * Log a rate limit event.
       */
    logRateLimitEvent(projectId: string, runId: string | null, model: string, phase: string | null, error: string, retryAfterSeconds: number | null): Promise<void>;
    /**
     * Send a message to an agent.
       */
    sendMessage(projectId: string, runId: string, senderAgentType: string, toAgent: string, subject: string, body: string): Promise<AgentMessageRow>;
    /**
     * Mark a message as read.
       */
    markMessageRead(projectId: string, messageId: string): Promise<boolean>;
    /**
     * Mark all messages for a run/agent as read.
       */
    markAllMessagesRead(projectId: string, runId: string, agentType: string): Promise<void>;
    /**
     * Delete a message.
       */
    deleteMessage(projectId: string, messageId: string): Promise<boolean>;
    getMessages(projectId: string, runId: string, agentType: string, unreadOnly?: boolean): Promise<AgentMessageRow[]>;
    getAllMessages(runId: string): Promise<AgentMessageRow[]>;
    getAllMessagesGlobal(projectId: string, limit?: number): Promise<AgentMessageRow[]>;
    enqueueMergeQueueEntry(data: {
        projectId: string;
        branchName: string;
        seedId: string;
        runId: string;
        operation?: MergeQueueOperation;
        agentName?: string | null;
        filesModified?: string[];
    }): Promise<MergeQueueEntryRow>;
    listMergeQueue(projectId: string, status?: MergeQueueStatus): Promise<MergeQueueEntryRow[]>;
    updateMergeQueueStatus(projectId: string, id: number, status: MergeQueueStatus, extra?: {
        resolvedTier?: number;
        error?: string;
        completedAt?: string;
        lastAttemptedAt?: string;
        retryCount?: number;
    }): Promise<void>;
    removeMergeQueueEntry(projectId: string, id: number): Promise<void>;
    resetMergeQueueForRetry(projectId: string, seedId: string): Promise<boolean>;
    listRetryableMergeQueue(projectId: string): Promise<MergeQueueEntryRow[]>;
    reEnqueueMergeQueue(projectId: string, id: number): Promise<boolean>;
    listMissingFromMergeQueue(projectId: string): Promise<Array<{
        run_id: string;
        seed_id: string;
    }>>;
    /**
     * Upsert sentinel configuration.
       */
    upsertSentinelConfig(projectId: string, config: Record<string, unknown>): Promise<void>;
    /**
     * Record a sentinel run.
       */
    recordSentinelRun(projectId: string, run: Record<string, unknown>): Promise<void>;
    /**
     * Update a sentinel run.
       */
    updateSentinelRun(projectId: string, runId: string, updates: Record<string, unknown>): Promise<void>;
    getSentinelConfig(projectId: string): Promise<SentinelConfigRow | null>;
    getSentinelRuns(projectId: string, limit?: number): Promise<SentinelRunRow[]>;
    createPipelineRun(data: {
        id?: string;
        projectId: string;
        beadId: string;
        runNumber: number;
        branch: string;
        commitSha?: string;
        trigger?: string;
        agentType?: string;
        sessionKey?: string;
        worktreePath?: string;
        progress?: string;
        baseBranch?: string;
        mergeStrategy?: string;
    }): Promise<PipelineRunRow>;
    listPipelineRuns(projectId: string, filters?: {
        beadId?: string;
        status?: string;
        limit?: number;
    }): Promise<PipelineRunRow[]>;
    getPipelineRun(runId: string): Promise<PipelineRunRow | null>;
    updatePipelineRun(runId: string, updates: {
        status?: string;
        sessionKey?: string;
        worktreePath?: string;
        progress?: string;
        baseBranch?: string;
        mergeStrategy?: string;
        startedAt?: string;
        finishedAt?: string;
    }): Promise<PipelineRunRow | null>;
    recordPipelineEvent(data: {
        projectId: string;
        runId: string | null;
        taskId?: string;
        eventType: string;
        payload?: Record<string, unknown>;
    }): Promise<PipelineEventRow>;
    recordSentinelEvent(data: {
        projectId: string;
        sentinelRunId: string;
        eventType: "sentinel-start" | "sentinel-pass" | "sentinel-fail";
        payload?: Record<string, unknown>;
    }): Promise<PipelineEventRow>;
    listPipelineEvents(runId: string): Promise<PipelineEventRow[]>;
    listProjectPipelineEvents(projectId: string, limit?: number): Promise<PipelineEventRow[]>;
    listPipelineEventsForRun(runId: string, limit?: number): Promise<PipelineEventRow[]>;
    listSentinelEvents(sentinelRunId: string): Promise<PipelineEventRow[]>;
    appendMessage(data: {
        runId: string;
        stepKey?: string;
        stream: "stdout" | "stderr" | "system";
        chunk: string;
        lineNumber: number;
    }): Promise<MessageRow>;
    listMessages(runId: string, stepKey?: string): Promise<MessageRow[]>;
    upsertGithubRepo(input: UpsertGithubRepoInput): Promise<GithubRepoRow>;
    getGithubRepo(projectId: string, owner: string, repo: string): Promise<GithubRepoRow | null>;
    listGithubRepos(projectId: string): Promise<GithubRepoRow[]>;
    deleteGithubRepo(id: string): Promise<boolean>;
    recordGithubSyncEvent(input: RecordGithubSyncEventInput): Promise<GithubSyncEventRow>;
    listGithubSyncEvents(projectId: string, externalId?: string, limit?: number): Promise<GithubSyncEventRow[]>;
    updateGithubRepoLastSync(id: string): Promise<void>;
    listTasksWithExternalId(projectId: string): Promise<TaskRow[]>;
    updateTaskGitHubFields(projectId: string, taskId: string, updates: {
        title?: string;
        description?: string | null;
        state?: "open" | "closed";
        labels?: string[];
        type?: string;
        milestone?: string | null;
        syncEnabled?: boolean;
        lastSyncAt?: string;
    }): Promise<TaskRow | null>;
    /**
     * Fetch all Jira issue states from the database.
     */
    getJiraIssueStates(): Promise<JiraIssueStateRow[]>;
    /**
     * Upsert a Jira issue state record.
     * Creates the record if it doesn't exist, updates if it does.
     */
    upsertJiraIssueState(input: JiraIssueStateInput): Promise<void>;
    /**
     * List Jira project configurations for a Foreman project.
     */
    listJiraProjects(projectId: string): Promise<JiraProjectRow[]>;
    /**
     * Get observability metrics for Jira monitoring (TRD-028).
     */
    getJiraMetrics(projectId: string, jiraProjectKey: string): Promise<{
        monitoredIssues: number;
        triggeredToday: number;
        lastError?: string;
    }>;
}
export declare const Database: {
    Adapter: typeof PostgresAdapter;
};
//# sourceMappingURL=postgres-adapter.d.ts.map