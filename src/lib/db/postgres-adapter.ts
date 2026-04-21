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
  defaultBranch?: string;
  status?: "active" | "paused" | "archived";
}

export interface ProjectRow {
  id: string;
  name: string;
  path: string;
  github_url: string | null;
  default_branch: string | null;
  status: "active" | "paused" | "archived";
  created_at: string;
  updated_at: string;
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
  run_id: string | null;
  status: string;
  created_at: string;
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
      `INSERT INTO projects (name, path, github_url, default_branch, status)
       VALUES ($1, $2, $3, $4, $5)
       RETURNING *`,
      [
        metadata.name,
        metadata.path,
        metadata.githubUrl ?? null,
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
    updates: Partial<Pick<ProjectRow, "name" | "path" | "status" | "github_url" | "default_branch">>,
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
    if (updates.github_url !== undefined) {
      setClauses.push(`github_url = $${i++}`);
      params.push(updates.github_url);
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
   * Create a new task.
   * @throws Error("not implemented")
   */
  async createTask(projectId: string, taskData: Record<string, unknown>): Promise<TaskRow> {
    throw new Error("not implemented");
  }

  /**
   * List tasks with optional filters.
   * @throws Error("not implemented")
   */
  async listTasks(
    projectId: string,
    filters?: {
      status?: string[];
      runId?: string;
      limit?: number;
    }
  ): Promise<TaskRow[]> {
    throw new Error("not implemented");
  }

  /**
   * Get a single task by ID.
   * @throws Error("not implemented")
   */
  async getTask(projectId: string, taskId: string): Promise<TaskRow | null> {
    throw new Error("not implemented");
  }

  /**
   * Update a task's fields.
   * @throws Error("not implemented")
   */
  async updateTask(
    projectId: string,
    taskId: string,
    updates: Record<string, unknown>
  ): Promise<void> {
    throw new Error("not implemented");
  }

  /**
   * Delete a task.
   * @throws Error("not implemented")
   */
  async deleteTask(projectId: string, taskId: string): Promise<void> {
    throw new Error("not implemented");
  }

  /**
   * Claim a task for a run (uses SELECT ... FOR UPDATE).
   * @throws Error("not implemented")
   */
  async claimTask(
    projectId: string,
    taskId: string,
    runId: string
  ): Promise<boolean> {
    throw new Error("not implemented");
  }

  /**
   * Approve a task (human approval gate).
   * @throws Error("not implemented")
   */
  async approveTask(projectId: string, taskId: string): Promise<void> {
    throw new Error("not implemented");
  }

  /**
   * Reset a task back to ready state.
   * @throws Error("not implemented")
   */
  async resetTask(projectId: string, taskId: string): Promise<void> {
    throw new Error("not implemented");
  }

  /**
   * Retry a failed/stuck task.
   * @throws Error("not implemented")
   */
  async retryTask(projectId: string, taskId: string): Promise<void> {
    throw new Error("not implemented");
  }

  /**
   * List tasks in 'ready' status for a project.
   * @throws Error("not implemented")
   */
  async listReadyTasks(projectId: string): Promise<TaskRow[]> {
    throw new Error("not implemented");
  }

  /**
   * List tasks that need human attention (conflict, failed, stuck, backlog).
   * @throws Error("not implemented")
   */
  async listNeedsHumanTasks(projectId: string): Promise<TaskRow[]> {
    throw new Error("not implemented");
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
}

// ---------------------------------------------------------------------------
// Named export
// ---------------------------------------------------------------------------

export const Database = { Adapter: PostgresAdapter };
