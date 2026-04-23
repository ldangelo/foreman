/**
 * PostgresAdapter — database operations via PoolManager.
 *
 * All methods throw Error("not implemented") in this skeleton phase (TRD-003).
 * Full implementations follow in TRD-011, TRD-026, TRD-027, etc.
 *
 * Design decisions:
 * - All methods accept `projectId: string` as the first argument for data isolation.
 * - All methods delegate to PoolManager.query() / PoolManager.execute().
 * - Transactions use PoolManager.acquireClient() / PoolManager.releaseClient().
 * - No string interpolation of user input into SQL — parameterized queries only.
 *
 * @module postgres-adapter
 */

import {
  PoolManager,
  query,
  execute,
  acquireClient,
  releaseClient,
} from "./pool-manager.js";

// ---------------------------------------------------------------------------
// Type definitions
// ---------------------------------------------------------------------------

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
  status: string;
  started_at: string | null;
  completed_at: string | null;
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

// TRD-032: Pipeline run / event / message tables

export interface PipelineRunRow {
  id: string;
  project_id: string;
  bead_id: string;
  run_number: number;
  status: string;
  branch: string;
  commit_sha: string | null;
  trigger: string;
  queued_at: string;
  started_at: string | null;
  finished_at: string | null;
  created_at: string;
  updated_at: string;
}

export interface PipelineEventRow {
  id: string;
  project_id: string;
  run_id: string;
  task_id: string | null;
  event_type: string;
  payload: Record<string, unknown> | null;
  created_at: string;
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

// ---------------------------------------------------------------------------
// PostgresAdapter
// ---------------------------------------------------------------------------

export class PostgresAdapter {
  // -------------------------------------------------------------------------
  // Project operations
  // -------------------------------------------------------------------------

  /**
   * Create a new project.
   *
   * @param metadata.projectId - Optional. If not provided, the database generates a UUID.
   * @returns The inserted project row.
   * @throws DatabaseError on constraint violation (e.g. duplicate path).
   */
  async createProject(metadata: ProjectMetadata): Promise<ProjectRow> {
    const rows = await query<ProjectRow>(
      `INSERT INTO projects (name, path, github_url, repo_key, default_branch, status)
       VALUES ($1, $2, $3, $4, $5, $6)
       RETURNING *`,
      [
        metadata.name,
        metadata.path,
        metadata.githubUrl ?? null,
        metadata.repoKey ?? null,
        metadata.defaultBranch ?? null,
        metadata.status ?? "active",
      ],
    );
    return rows[0];
  }

  /**
   * List all projects, optionally filtered by status.
   *
   * @param filters.status - Filter by project status.
   * @param filters.search - ILIKE pattern match on project name.
   * @returns Matching project rows, ordered by created_at DESC.
   */
  async listProjects(filters?: {
    status?: "active" | "paused" | "archived";
    search?: string;
  }): Promise<ProjectRow[]> {
    const conditions: string[] = [];
    const params: unknown[] = [];
    let paramIndex = 1;

    if (filters?.status) {
      conditions.push(`status = $${paramIndex++}`);
      params.push(filters.status);
    }

    if (filters?.search) {
      conditions.push(`name ILIKE $${paramIndex++}`);
      params.push(`%${filters.search}%`);
    }

    const where =
      conditions.length > 0 ? `WHERE ${conditions.join(" AND ")}` : "";

    return query<ProjectRow>(
      `SELECT * FROM projects ${where} ORDER BY created_at DESC`,
      params,
    );
  }

  /**
   * Get a single project by ID.
   *
   * @param projectId - The project UUID.
   * @returns The project row, or null if not found.
   */
  async getProject(projectId: string): Promise<ProjectRow | null> {
    const rows = await query<ProjectRow>(
      `SELECT * FROM projects WHERE id = $1`,
      [projectId],
    );
    return rows[0] ?? null;
  }

  /**
   * Update project fields.
   *
   * @param projectId - The project UUID.
   * @param updates - Fields to update. All fields are optional.
   * @throws DatabaseError if the project does not exist.
   */
  async updateProject(
    projectId: string,
    updates: Partial<Pick<ProjectRow, "name" | "path" | "status" | "github_url" | "repo_key" | "default_branch" | "last_sync_at">>,
  ): Promise<void> {
    const setClauses: string[] = ["updated_at = now()"];
    const params: unknown[] = [];
    let i = 1;

    if (updates.name !== undefined) {
      setClauses.push(`name = $${i++}`);
      params.push(updates.name);
    }
    if (updates.path !== undefined) {
      setClauses.push(`path = $${i++}`);
      params.push(updates.path);
    }
    if (updates.status !== undefined) {
      setClauses.push(`status = $${i++}`);
      params.push(updates.status);
    }
    if (updates.last_sync_at !== undefined) {
      setClauses.push(`last_sync_at = $${i++}`);
      params.push(updates.last_sync_at);
    }
    if (updates.github_url !== undefined) {
      setClauses.push(`github_url = $${i++}`);
      params.push(updates.github_url);
    }
    if (updates.repo_key !== undefined) {
      setClauses.push(`repo_key = $${i++}`);
      params.push(updates.repo_key);
    }
    if (updates.default_branch !== undefined) {
      setClauses.push(`default_branch = $${i++}`);
      params.push(updates.default_branch);
    }

    if (setClauses.length === 1) return; // only updated_at, nothing to do

    params.push(projectId);
    await execute(
      `UPDATE projects SET ${setClauses.join(", ")} WHERE id = $${i}`,
      params,
    );
  }

  /**
   * Remove (archive) a project.
   *
   * Default behaviour: soft-delete by setting status = 'archived'.
   * With force=true: hard-delete the row.
   *
   * @param projectId - The project UUID.
   * @param options.force - If true, DELETE the row. If false (default), archive it.
   */
  async removeProject(
    projectId: string,
    options?: { force?: boolean },
  ): Promise<void> {
    if (options?.force) {
      await execute(`DELETE FROM projects WHERE id = $1`, [projectId]);
    } else {
      await execute(
        `UPDATE projects SET status = 'archived', updated_at = now() WHERE id = $1`,
        [projectId],
      );
    }
  }

  /**
   * Sync a project (git fetch + update last_sync timestamp).
   *
   * Updates last_sync_at to the current time. Actual git fetch is handled
   * by the caller's process.
   *
   * @param projectId - The project UUID.
   */
  async syncProject(projectId: string): Promise<void> {
    await execute(
      `UPDATE projects SET last_sync_at = now(), updated_at = now() WHERE id = $1`,
      [projectId],
    );
  }

  // -------------------------------------------------------------------------
  // Task operations
  // -------------------------------------------------------------------------

  /**
   * Create a new task in backlog status.
   *
   * @param projectId - The owner project UUID.
   * @param taskData - Task fields. Required: id. Optional: title, description, type, priority.
   * @throws DatabaseError on constraint violation.
   */
  async createTask(projectId: string, taskData: Record<string, unknown>): Promise<TaskRow> {
    const id = taskData.id as string;
    const title = (taskData.title as string) ?? id;
    const description = taskData.description as string | null ?? null;
    const type = (taskData.type as string) ?? "task";
    const priority = (taskData.priority as number) ?? 2;
    const externalId = taskData.external_id as string | null ?? null;
    const branch = taskData.branch as string | null ?? null;

    const rows = await query<TaskRow>(
      `INSERT INTO tasks (id, project_id, title, description, type, priority, external_id, branch)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
       RETURNING *`,
      [id, projectId, title, description, type, priority, externalId, branch],
    );
    return rows[0];
  }

  /**
   * List tasks for a project with optional filters.
   *
   * @param projectId - The owner project UUID.
   * @param filters.status - Include only these statuses.
   * @param filters.runId - Include only tasks for this run.
   * @param filters.limit - Max rows to return (default: 100).
   */
  async listTasks(
    projectId: string,
    filters?: {
      status?: string[];
      runId?: string;
      limit?: number;
    }
  ): Promise<TaskRow[]> {
    const conditions = ["project_id = $1"];
    const params: unknown[] = [projectId];
    let i = 2;

    if (filters?.status && filters.status.length > 0) {
      conditions.push(`status IN (${filters.status.map((_, idx) => `$${i + idx}`).join(",")})`);
      params.push(...filters.status);
      i += filters.status.length;
    }

    if (filters?.runId !== undefined) {
      conditions.push(`run_id = $${i++}`);
      params.push(filters.runId);
    }

    const limit = filters?.limit ?? 100;
    params.push(limit);

    return query<TaskRow>(
      `SELECT * FROM tasks WHERE ${conditions.join(" AND ")}
       ORDER BY priority ASC, created_at ASC
       LIMIT $${i}`,
      params,
    );
  }

  /**
   * Get a single task by ID.
   *
   * @param projectId - The owner project UUID.
   * @param taskId - The task UUID.
   * @returns The task row, or null if not found or belongs to a different project.
   */
  async getTask(projectId: string, taskId: string): Promise<TaskRow | null> {
    const rows = await query<TaskRow>(
      `SELECT * FROM tasks WHERE id = $1 AND project_id = $2`,
      [taskId, projectId],
    );
    return rows[0] ?? null;
  }

  /**
   * Update a task's fields.
   *
   * @param projectId - The owner project UUID.
   * @param taskId - The task UUID.
   * @param updates - Fields to update. Supported: title, description, type, priority, status, branch, external_id.
   */
  async updateTask(
    projectId: string,
    taskId: string,
    updates: Record<string, unknown>
  ): Promise<void> {
    const setClauses: string[] = ["updated_at = now()"];
    const params: unknown[] = [];
    let i = 1;

    if (updates.title !== undefined) {
      setClauses.push(`title = $${i++}`);
      params.push(updates.title as string);
    }
    if (updates.description !== undefined) {
      setClauses.push(`description = $${i++}`);
      params.push(updates.description as string | null);
    }
    if (updates.type !== undefined) {
      setClauses.push(`type = $${i++}`);
      params.push(updates.type as string);
    }
    if (updates.priority !== undefined) {
      setClauses.push(`priority = $${i++}`);
      params.push(updates.priority as number);
    }
    if (updates.status !== undefined) {
      setClauses.push(`status = $${i++}`);
      params.push(updates.status as string);
    }
    if (updates.branch !== undefined) {
      setClauses.push(`branch = $${i++}`);
      params.push(updates.branch as string | null);
    }
    if (updates.external_id !== undefined) {
      setClauses.push(`external_id = $${i++}`);
      params.push(updates.external_id as string | null);
    }

    if (setClauses.length === 1) return; // only updated_at

    params.push(taskId, projectId);
    await execute(
      `UPDATE tasks SET ${setClauses.join(", ")} WHERE id = $${i++} AND project_id = $${i}`,
      params,
    );
  }

  /**
   * Delete a task and its dependencies.
   *
   * @param projectId - The owner project UUID.
   * @param taskId - The task UUID.
   */
  async deleteTask(projectId: string, taskId: string): Promise<void> {
    // ON DELETE CASCADE handles task_dependencies automatically
    await execute(
      `DELETE FROM tasks WHERE id = $1 AND project_id = $2`,
      [taskId, projectId],
    );
  }

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
  async claimTask(
    projectId: string,
    taskId: string,
    runId: string
  ): Promise<boolean> {
    const client = await acquireClient();
    try {
      await client.query("BEGIN");

      // SELECT ... FOR UPDATE acquires a row-level lock on the task
      const result = await client.query<{ id: string }>(
        `SELECT id FROM tasks
         WHERE id = $1 AND project_id = $2 AND status = 'ready'
         FOR UPDATE`,
        [taskId, projectId],
      );

      if (result.rows.length === 0) {
        // Task not found, not in 'ready' status, or belongs to another project
        await client.query("ROLLBACK");
        return false;
      }

      await client.query(
        `UPDATE tasks SET run_id = $1, status = 'in-progress', updated_at = now()
         WHERE id = $2 AND project_id = $3`,
        [runId, taskId, projectId],
      );

      await client.query("COMMIT");
      return true;
    } catch (err) {
      await client.query("ROLLBACK");
      throw err;
    } finally {
      releaseClient(client);
    }
  }

  /**
   * Approve a task: transition from 'backlog' to 'ready'.
   *
   * Only tasks in 'backlog' status can be approved. Sets approved_at timestamp.
   *
   * @param projectId - The owner project UUID.
   * @param taskId - The task UUID.
   * @throws Error if the task is not in 'backlog' status.
   */
  async approveTask(projectId: string, taskId: string): Promise<void> {
    const rows = await query<TaskRow>(
      `UPDATE tasks
       SET status = 'ready', approved_at = now(), updated_at = now()
       WHERE id = $1 AND project_id = $2 AND status = 'backlog'
       RETURNING id`,
      [taskId, projectId],
    );
    if (rows.length === 0) {
      throw new Error(
        `Cannot approve task '${taskId}': task not found or not in backlog status`,
      );
    }
  }

  /**
   * Reset a task back to 'ready' state.
   *
   * Clears run_id and transitions to 'ready'. Use after a run fails or is cancelled
   * to make the task available for re-dispatch.
   *
   * @param projectId - The owner project UUID.
   * @param taskId - The task UUID.
   */
  async resetTask(projectId: string, taskId: string): Promise<void> {
    await execute(
      `UPDATE tasks
       SET status = 'ready', run_id = NULL, updated_at = now()
       WHERE id = $1 AND project_id = $2`,
      [taskId, projectId],
    );
  }

  /**
   * Retry a failed or stuck task.
   *
   * Resets status to 'ready' for tasks in 'failed' or 'stuck' status,
   * allowing them to be re-dispatched.
   *
   * @param projectId - The owner project UUID.
   * @param taskId - The task UUID.
   */
  async retryTask(projectId: string, taskId: string): Promise<void> {
    const rows = await query<TaskRow>(
      `UPDATE tasks
       SET status = 'ready', run_id = NULL, updated_at = now()
       WHERE id = $1 AND project_id = $2 AND status IN ('failed', 'stuck')
       RETURNING id`,
      [taskId, projectId],
    );
    if (rows.length === 0) {
      throw new Error(
        `Cannot retry task '${taskId}': task not found or not in failed/stuck status`,
      );
    }
  }

  /**
   * List tasks in 'ready' status for a project (dispatchable tasks).
   *
   * @param projectId - The owner project UUID.
   * @returns Tasks with status = 'ready', ordered by priority ASC, created_at ASC.
   */
  async listReadyTasks(projectId: string): Promise<TaskRow[]> {
    return query<TaskRow>(
      `SELECT * FROM tasks
       WHERE project_id = $1 AND status = 'ready'
       ORDER BY priority ASC, created_at ASC`,
      [projectId],
    );
  }

  /**
   * List tasks that need human attention.
   *
   * Includes: backlog (not approved), conflict, failed, stuck, blocked.
   *
   * @param projectId - The owner project UUID.
   */
  async listNeedsHumanTasks(projectId: string): Promise<TaskRow[]> {
    return query<TaskRow>(
      `SELECT * FROM tasks
       WHERE project_id = $1 AND status IN ('backlog', 'conflict', 'failed', 'stuck', 'blocked')
       ORDER BY priority ASC, created_at ASC`,
      [projectId],
    );
  }

  // -------------------------------------------------------------------------
  // Run operations
  // -------------------------------------------------------------------------

  /**
   * Create a new run.
   * @throws Error("not implemented")
   */
  async createRun(
    projectId: string,
    seedId: string,
    agentType: string,
    options?: {
      sessionKey?: string;
      worktreePath?: string;
      baseBranch?: string;
      mergeStrategy?: "auto" | "pr" | "none";
    }
  ): Promise<RunRow> {
    throw new Error("not implemented");
  }

  /**
   * List runs for a project.
   * @throws Error("not implemented")
   */
  async listRuns(
    projectId: string,
    filters?: { status?: string[]; limit?: number }
  ): Promise<RunRow[]> {
    throw new Error("not implemented");
  }

  /**
   * Get a single run by ID.
   * @throws Error("not implemented")
   */
  async getRun(projectId: string, runId: string): Promise<RunRow | null> {
    throw new Error("not implemented");
  }

  /**
   * Update a run's fields.
   * @throws Error("not implemented")
   */
  async updateRun(
    projectId: string,
    runId: string,
    updates: Partial<Pick<RunRow, "status" | "session_key" | "worktree_path" | "progress" | "started_at" | "completed_at">>
  ): Promise<void> {
    throw new Error("not implemented");
  }

  /**
   * List active (pending/running) runs for a project.
   * @throws Error("not implemented")
   */
  async listActiveRuns(projectId: string): Promise<RunRow[]> {
    throw new Error("not implemented");
  }

  /**
   * Check if a seed has an active or pending run.
   * @throws Error("not implemented")
   */
  async hasActiveOrPendingRun(
    projectId: string,
    seedId: string
  ): Promise<boolean> {
    throw new Error("not implemented");
  }

  /**
   * Update run progress (phase, cost, tokens, etc.).
   * @throws Error("not implemented")
   */
  async updateRunProgress(
    projectId: string,
    runId: string,
    progress: {
      phase?: string;
      currentTargetRef?: string;
      lastToolCall?: string;
      lastActivity?: string;
      tokensIn?: number;
      tokensOut?: number;
      costByPhase?: Record<string, number>;
      agentByPhase?: Record<string, string>;
    }
  ): Promise<void> {
    throw new Error("not implemented");
  }

  /**
   * Purge runs older than a given timestamp.
   * @throws Error("not implemented")
   */
  async purgeOldRuns(
    projectId: string,
    olderThan: string
  ): Promise<number> {
    throw new Error("not implemented");
  }

  /**
   * Delete a run.
   * @throws Error("not implemented")
   */
  async deleteRun(projectId: string, runId: string): Promise<boolean> {
    throw new Error("not implemented");
  }

  // -------------------------------------------------------------------------
  // Cost recording
  // -------------------------------------------------------------------------

  /**
   * Record cost data for a run.
   * @throws Error("not implemented")
   */
  async recordCost(
    projectId: string,
    runId: string,
    cost: {
      tokensIn: number;
      tokensOut: number;
      cacheRead: number;
      estimatedCost: number;
    }
  ): Promise<void> {
    throw new Error("not implemented");
  }

  // -------------------------------------------------------------------------
  // Event logging
  // -------------------------------------------------------------------------

  /**
   * Log a project event.
   * @throws Error("not implemented")
   */
  async logEvent(
    projectId: string,
    runId: string | null,
    eventType: string,
    details?: string
  ): Promise<void> {
    throw new Error("not implemented");
  }

  /**
   * Log a rate limit event.
   * @throws Error("not implemented")
   */
  async logRateLimitEvent(
    projectId: string,
    runId: string | null,
    agentType: string,
    details: string
  ): Promise<void> {
    throw new Error("not implemented");
  }

  // -------------------------------------------------------------------------
  // Message operations
  // -------------------------------------------------------------------------

  /**
   * Send a message to an agent.
   * @throws Error("not implemented")
   */
  async sendMessage(
    projectId: string,
    runId: string,
    toAgent: string,
    body: string
  ): Promise<void> {
    throw new Error("not implemented");
  }

  /**
   * Mark a message as read.
   * @throws Error("not implemented")
   */
  async markMessageRead(
    projectId: string,
    messageId: string
  ): Promise<boolean> {
    throw new Error("not implemented");
  }

  /**
   * Mark all messages for a run/agent as read.
   * @throws Error("not implemented")
   */
  async markAllMessagesRead(
    projectId: string,
    runId: string,
    agentType: string
  ): Promise<void> {
    throw new Error("not implemented");
  }

  /**
   * Delete a message.
   * @throws Error("not implemented")
   */
  async deleteMessage(
    projectId: string,
    messageId: string
  ): Promise<boolean> {
    throw new Error("not implemented");
  }

  // -------------------------------------------------------------------------
  // Bead write queue
  // -------------------------------------------------------------------------

  /**
   * Enqueue a bead write operation.
   * @throws Error("not implemented")
   */
  async enqueueBeadWrite(
    projectId: string,
    sender: string,
    operation: string,
    payload: unknown
  ): Promise<void> {
    throw new Error("not implemented");
  }

  /**
   * Mark a bead write as processed.
   * @throws Error("not implemented")
   */
  async markBeadWriteProcessed(
    projectId: string,
    id: string
  ): Promise<boolean> {
    throw new Error("not implemented");
  }

  // -------------------------------------------------------------------------
  // Sentinel operations
  // -------------------------------------------------------------------------

  /**
   * Upsert sentinel configuration.
   * @throws Error("not implemented")
   */
  async upsertSentinelConfig(
    projectId: string,
    config: Record<string, unknown>
  ): Promise<void> {
    throw new Error("not implemented");
  }

  /**
   * Record a sentinel run.
   * @throws Error("not implemented")
   */
  async recordSentinelRun(
    projectId: string,
    run: Record<string, unknown>
  ): Promise<void> {
    throw new Error("not implemented");
  }

  /**
   * Update a sentinel run.
   * @throws Error("not implemented")
   */
  async updateSentinelRun(
    projectId: string,
    runId: string,
    updates: Record<string, unknown>
  ): Promise<void> {
    throw new Error("not implemented");
  }

  // -------------------------------------------------------------------------
  // Pipeline run / event / message operations (TRD-032)
  // -------------------------------------------------------------------------

  async createPipelineRun(data: {
    projectId: string;
    beadId: string;
    runNumber: number;
    branch: string;
    commitSha?: string;
    trigger?: string;
  }): Promise<PipelineRunRow> {
    const rows = await query<PipelineRunRow>(
      `INSERT INTO runs (project_id, bead_id, run_number, branch, commit_sha, trigger)
       VALUES ($1, $2, $3, $4, $5, $6)
       RETURNING *`,
      [
        data.projectId,
        data.beadId,
        data.runNumber,
        data.branch,
        data.commitSha ?? null,
        data.trigger ?? "manual",
      ]
    );
    return rows[0];
  }

  async listPipelineRuns(
    projectId: string,
    filters?: {
      beadId?: string;
      status?: string;
      limit?: number;
    }
  ): Promise<PipelineRunRow[]> {
    let sql = `SELECT * FROM runs WHERE project_id = $1`;
    const params: unknown[] = [projectId];
    let p = 2;
    if (filters?.beadId) {
      sql += ` AND bead_id = $${p++}`;
      params.push(filters.beadId);
    }
    if (filters?.status) {
      sql += ` AND status = $${p++}`;
      params.push(filters.status);
    }
    sql += ` ORDER BY created_at DESC`;
    if (filters?.limit) {
      sql += ` LIMIT $${p}`;
      params.push(filters.limit);
    }
    return query<PipelineRunRow>(sql, params);
  }

  async getPipelineRun(runId: string): Promise<PipelineRunRow | null> {
    const rows = await query<PipelineRunRow>(
      `SELECT * FROM runs WHERE id = $1`,
      [runId]
    );
    return rows[0] ?? null;
  }

  async updatePipelineRun(
    runId: string,
    updates: {
      status?: string;
      startedAt?: string;
      finishedAt?: string;
    }
  ): Promise<PipelineRunRow | null> {
    const setParts: string[] = [];
    const params: unknown[] = [];
    let p = 1;
    if (updates.status !== undefined) {
      setParts.push(`status = $${p++}`);
      params.push(updates.status);
    }
    if (updates.startedAt !== undefined) {
      setParts.push(`started_at = $${p++}`);
      params.push(updates.startedAt);
    }
    if (updates.finishedAt !== undefined) {
      setParts.push(`finished_at = $${p++}`);
      params.push(updates.finishedAt);
    }
    if (setParts.length === 0) return this.getPipelineRun(runId);
    setParts.push(`updated_at = now()`);
    params.push(runId);
    const rows = await query<PipelineRunRow>(
      `UPDATE runs SET ${setParts.join(", ")} WHERE id = $${p} RETURNING *`,
      params
    );
    return rows[0] ?? null;
  }

  async recordPipelineEvent(data: {
    projectId: string;
    runId: string;
    taskId?: string;
    eventType: string;
    payload?: Record<string, unknown>;
  }): Promise<PipelineEventRow> {
    const rows = await query<PipelineEventRow>(
      `INSERT INTO events (project_id, run_id, task_id, event_type, payload)
       VALUES ($1, $2, $3, $4, $5)
       RETURNING *`,
      [
        data.projectId,
        data.runId,
        data.taskId ?? null,
        data.eventType,
        data.payload ? JSON.stringify(data.payload) : null,
      ]
    );
    return rows[0];
  }

  async listPipelineEvents(runId: string): Promise<PipelineEventRow[]> {
    return query<PipelineEventRow>(
      `SELECT * FROM events WHERE run_id = $1 ORDER BY created_at ASC`,
      [runId]
    );
  }

  async appendMessage(data: {
    runId: string;
    stepKey?: string;
    stream: "stdout" | "stderr" | "system";
    chunk: string;
    lineNumber: number;
  }): Promise<MessageRow> {
    const rows = await query<MessageRow>(
      `INSERT INTO messages (run_id, step_key, stream, chunk, line_number)
       VALUES ($1, $2, $3, $4, $5)
       RETURNING *`,
      [data.runId, data.stepKey ?? null, data.stream, data.chunk, data.lineNumber]
    );
    return rows[0];
  }

  async listMessages(runId: string, stepKey?: string): Promise<MessageRow[]> {
    let sql = `SELECT * FROM messages WHERE run_id = $1`;
    const params: unknown[] = [runId];
    if (stepKey) {
      sql += ` AND step_key = $2`;
      params.push(stepKey);
    }
    sql += ` ORDER BY line_number ASC`;
    return query<MessageRow>(sql, params);
  }
}

// ---------------------------------------------------------------------------
// Named export
// ---------------------------------------------------------------------------

export const Database = { Adapter: PostgresAdapter };
