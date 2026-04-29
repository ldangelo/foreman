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
import type { RunProgress, SentinelConfigRow, SentinelRunRow } from "../store.js";
import { randomBytes } from "node:crypto";
import { normalizeTaskIdPrefix } from "../task-store.js";

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
  base_branch: string | null;
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
  // GitHub integration fields (TRD-007)
  external_repo?: string | null;
  github_issue_number?: number | null;
  github_milestone?: string | null;
  sync_enabled?: boolean;
  last_sync_at?: string | null;
  // Labels array (may not exist in all projects)
  labels?: string[] | null;
}

export interface TaskDependencyRow {
  from_task_id: string;
  to_task_id: string;
  type: "blocks" | "parent-child";
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
  run_id: string;
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

function mapLegacyRunStatusToPipeline(status: string): PipelineRunRow["status"] {
  switch (status) {
    case "pending":
      return "pending";
    case "running":
      return "running";
    case "completed":
    case "merged":
    case "pr-created":
      return "success";
    case "failed":
    case "test-failed":
    case "stuck":
    case "conflict":
      return "failure";
    case "reset":
      return "cancelled";
    default:
      return "skipped";
  }
}

function mapPipelineRunStatusToLegacy(status: string): RunRow["status"] {
  switch (status) {
    case "pending":
      return "pending";
    case "running":
      return "running";
    case "success":
      return "completed";
    case "failure":
      return "failed";
    case "cancelled":
    case "skipped":
      return "reset";
    default:
      return "failed";
  }
}

function runRowSelectSql(): string {
  return `
    SELECT
      id,
      project_id,
      bead_id AS seed_id,
      COALESCE(agent_type, 'claude-code') AS agent_type,
      session_key,
      worktree_path,
      status,
      started_at,
      finished_at AS completed_at,
      created_at,
      CASE WHEN progress IS NULL THEN NULL ELSE progress::text END AS progress,
      base_branch,
      merge_strategy
    FROM runs
  `;
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

// ---------------------------------------------------------------------------
// GitHub integration types (TRD-007, TRD-008)
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// PostgresAdapter
// ---------------------------------------------------------------------------

export class PostgresAdapter {
  private async allocateTaskId(projectId: string): Promise<string> {
    const rows = await query<{ name: string | null }>(
      `SELECT name FROM projects WHERE id = $1 LIMIT 1`,
      [projectId],
    );
    const prefix = normalizeTaskIdPrefix(rows[0]?.name);
    return `${prefix}-${randomBytes(3).toString("hex").slice(0, 5)}`;
  }

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
    const id = (taskData.id as string | undefined) ?? await this.allocateTaskId(projectId);
    const title = (taskData.title as string) ?? id;
    const description = taskData.description as string | null ?? null;
    const type = (taskData.type as string) ?? "task";
    const priority = (taskData.priority as number) ?? 2;
    const externalId =
      (taskData.external_id as string | null | undefined) ??
      (taskData.externalId as string | null | undefined) ??
      null;
    const branch = taskData.branch as string | null ?? null;
    const status = (taskData.status as string) ?? "backlog";
    const createdAt = (taskData.created_at as string) ?? new Date().toISOString();
    const updatedAt = (taskData.updated_at as string) ?? createdAt;
    const approvedAt = taskData.approved_at as string | null ?? null;
    const closedAt = taskData.closed_at as string | null ?? null;

    const rows = await query<TaskRow>(
      `INSERT INTO tasks (
         id, project_id, title, description, type, priority, status,
         external_id, branch, created_at, updated_at, approved_at, closed_at,
         external_repo, github_issue_number, github_milestone, sync_enabled
       )
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17)
       RETURNING *`,
      [
        id,
        projectId,
        title,
        description,
        type,
        priority,
        status,
        externalId,
        branch,
        createdAt,
        updatedAt,
        approvedAt,
        closedAt,
        (taskData.external_repo as string | null | undefined) ??
          (taskData.externalRepo as string | null | undefined) ??
          null,
        (taskData.github_issue_number as number | null | undefined) ??
          (taskData.githubIssueNumber as number | null | undefined) ??
          null,
        (taskData.github_milestone as string | null | undefined) ??
          (taskData.githubMilestone as string | null | undefined) ??
          null,
        (taskData.sync_enabled as boolean | undefined) ??
          (taskData.syncEnabled as boolean | undefined) ??
          false,
      ],
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
      externalId?: string;
      labels?: string[];
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

    if (filters?.externalId !== undefined) {
      conditions.push(`external_id = $${i++}`);
      params.push(filters.externalId);
    }

    if (filters?.labels && filters.labels.length > 0) {
      conditions.push(`labels @> $${i++}::text[]`);
      params.push(filters.labels);
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
   * Sync the claimed task linked to a run into a terminal status.
   *
   * No-op when no task is currently linked to the run.
   */
  async updateTaskStatusForRun(projectId: string, runId: string, status: string): Promise<void> {
    await execute(
      `UPDATE tasks
       SET status = $1, updated_at = now()
       WHERE project_id = $2 AND run_id = $3`,
      [status, projectId, runId],
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
    runId: string | null
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

  async closeTask(projectId: string, taskId: string): Promise<void> {
    const rows = await query<TaskRow>(
      `UPDATE tasks
       SET status = 'closed', closed_at = now(), updated_at = now()
       WHERE id = $1 AND project_id = $2
       RETURNING id`,
      [taskId, projectId],
    );
    if (rows.length === 0) {
      throw new Error(`Cannot close task '${taskId}': task not found`);
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

  /**
   * Get a task by its external ID (e.g., bead ID).
   */
  async getTaskByExternalId(projectId: string, externalId: string): Promise<TaskRow | null> {
    const rows = await query<TaskRow>(
      `SELECT * FROM tasks WHERE project_id = $1 AND external_id = $2 LIMIT 1`,
      [projectId, externalId],
    );
    return rows[0] ?? null;
  }

  /**
   * Check if any tasks exist for a project (native tasks).
   */
  async hasNativeTasks(projectId: string): Promise<boolean> {
    const result = await query<{ cnt: string }>(
      `SELECT COUNT(*) as cnt FROM tasks WHERE project_id = $1`,
      [projectId],
    );
    return parseInt(result[0]?.cnt ?? "0", 10) > 0;
  }

  async addTaskDependency(
    projectId: string,
    fromTaskId: string,
    toTaskId: string,
    type: "blocks" | "parent-child" = "blocks",
  ): Promise<void> {
    if (fromTaskId === toTaskId) {
      throw new Error("Adding this dependency would create a circular dependency.");
    }

    const client = await acquireClient();
    try {
      await client.query("BEGIN");

      const rows = await client.query<{ id: string }>(
        `SELECT id FROM tasks
         WHERE project_id = $1 AND id IN ($2, $3)`,
        [projectId, fromTaskId, toTaskId],
      );
      if (rows.rows.length !== 2) {
        throw new Error("One or both task IDs were not found in this project.");
      }

      const cycle = await client.query<{ found: number }>(
        `WITH RECURSIVE reach(id) AS (
           SELECT $1::text
           UNION
           SELECT td.to_task_id
           FROM task_dependencies td
           JOIN reach r ON td.from_task_id = r.id
         )
         SELECT 1 AS found
         FROM reach
         WHERE id = $2
         LIMIT 1`,
        [toTaskId, fromTaskId],
      );
      if (cycle.rows.length > 0) {
        throw new Error("Adding this dependency would create a circular dependency.");
      }

      await client.query(
        `INSERT INTO task_dependencies (from_task_id, to_task_id, type)
         VALUES ($1, $2, $3)
         ON CONFLICT DO NOTHING`,
        [fromTaskId, toTaskId, type],
      );

      await client.query("COMMIT");
    } catch (err) {
      await client.query("ROLLBACK");
      throw err;
    } finally {
      releaseClient(client);
    }
  }

  async listTaskDependencies(
    projectId: string,
    taskId: string,
    direction: "outgoing" | "incoming" = "outgoing",
  ): Promise<TaskDependencyRow[]> {
    if (direction === "outgoing") {
      return query<TaskDependencyRow>(
        `SELECT td.*
         FROM task_dependencies td
         JOIN tasks t ON t.id = td.from_task_id
         WHERE t.project_id = $1 AND td.from_task_id = $2
         ORDER BY td.to_task_id ASC`,
        [projectId, taskId],
      );
    }

    return query<TaskDependencyRow>(
      `SELECT td.*
       FROM task_dependencies td
       JOIN tasks t ON t.id = td.to_task_id
       WHERE t.project_id = $1 AND td.to_task_id = $2
       ORDER BY td.from_task_id ASC`,
      [projectId, taskId],
    );
  }

  async removeTaskDependency(
    projectId: string,
    fromTaskId: string,
    toTaskId: string,
    type: "blocks" | "parent-child" = "blocks",
  ): Promise<void> {
    await execute(
      `DELETE FROM task_dependencies td
       USING tasks tf, tasks tt
       WHERE td.from_task_id = $1
         AND td.to_task_id = $2
         AND td.type = $3
         AND tf.id = td.from_task_id
         AND tf.project_id = $4
         AND tt.id = td.to_task_id
         AND tt.project_id = $4`,
      [fromTaskId, toTaskId, type, projectId],
    );
  }

  /**
   * Get runs by multiple statuses since a given time.
   */
  async getRunsByStatusesSince(
    projectId: string,
    statuses: string[],
    since: string,
  ): Promise<RunRow[]> {
    if (statuses.length === 0) return [];
    const placeholders = statuses.map((_, i) => `$${i + 2}`).join(", ");
    return query<RunRow>(
      `SELECT * FROM runs
       WHERE project_id = $1 AND status IN (${placeholders}) AND created_at >= $${statuses.length + 2}
       ORDER BY created_at DESC`,
      [projectId, ...statuses, since],
    );
  }

  // ---------------------------------------------------------------------------
  // Run operations
  // ---------------------------------------------------------------------------

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
    const rows = await query<RunRow>(
      `INSERT INTO runs (
         project_id, bead_id, run_number, status, branch, trigger,
         agent_type, session_key, worktree_path, base_branch, merge_strategy, progress
       )
       VALUES (
         $1,
         $2,
         COALESCE((SELECT MAX(run_number) + 1 FROM runs WHERE project_id = $1 AND bead_id = $2), 1),
         'pending',
         $3,
         'manual',
         $4,
         $5,
         $6,
         $7,
         $8,
         NULL
       )
       RETURNING
         id,
         project_id,
         bead_id AS seed_id,
         agent_type,
         session_key,
         worktree_path,
         status,
         started_at,
         finished_at AS completed_at,
         created_at,
         CASE WHEN progress IS NULL THEN NULL ELSE progress::text END AS progress`,
      [
        projectId,
        seedId,
        options?.worktreePath ?? `foreman/${seedId}`,
        agentType,
        options?.sessionKey ?? null,
        options?.worktreePath ?? null,
        options?.baseBranch ?? null,
        options?.mergeStrategy ?? null,
      ],
    );
    return rows[0];
  }

  /**
   * List runs for a project.
   * @throws Error("not implemented")
   */
  async listRuns(
    projectId: string,
    filters?: { status?: string[]; limit?: number }
  ): Promise<RunRow[]> {
    const conditions = [`project_id = $1`];
    const params: unknown[] = [projectId];
    let i = 2;
    if (filters?.status && filters.status.length > 0) {
      const mapped = filters.status.map(mapLegacyRunStatusToPipeline);
      conditions.push(`status IN (${mapped.map((_, idx) => `$${i + idx}`).join(",")})`);
      params.push(...mapped);
      i += mapped.length;
    }
    let sql = `${runRowSelectSql()} WHERE ${conditions.join(" AND ")} ORDER BY created_at DESC`;
    if (filters?.limit) {
      sql += ` LIMIT $${i}`;
      params.push(filters.limit);
    }
    const rows = await query<RunRow>(sql, params);
    return rows.map((row) => ({ ...row, status: mapPipelineRunStatusToLegacy(row.status) }));
  }

  /**
   * Get a single run by ID.
   * @throws Error("not implemented")
   */
  async getRun(projectId: string, runId: string): Promise<RunRow | null> {
    const rows = await query<RunRow>(
      `${runRowSelectSql()} WHERE project_id = $1 AND id = $2 LIMIT 1`,
      [projectId, runId],
    );
    const row = rows[0];
    return row ? { ...row, status: mapPipelineRunStatusToLegacy(row.status) } : null;
  }

  /**
   * Update a run's fields.
   * @throws Error("not implemented")
   */
  async updateRun(
    projectId: string,
    runId: string,
    updates: Partial<Pick<RunRow, "status" | "session_key" | "worktree_path" | "progress" | "started_at" | "completed_at" | "base_branch">>
  ): Promise<void> {
    const setClauses: string[] = ["updated_at = now()"];
    const params: unknown[] = [];
    let i = 1;
    if (updates.status !== undefined) {
      setClauses.push(`status = $${i++}`);
      params.push(mapLegacyRunStatusToPipeline(updates.status));
    }
    if (updates.session_key !== undefined) {
      setClauses.push(`session_key = $${i++}`);
      params.push(updates.session_key);
    }
    if (updates.worktree_path !== undefined) {
      setClauses.push(`worktree_path = $${i++}`);
      params.push(updates.worktree_path);
    }
    if (updates.progress !== undefined) {
      setClauses.push(`progress = $${i++}::jsonb`);
      params.push(updates.progress);
    }
    if (updates.started_at !== undefined) {
      setClauses.push(`started_at = $${i++}`);
      params.push(updates.started_at);
    }
    if (updates.completed_at !== undefined) {
      setClauses.push(`finished_at = $${i++}`);
      params.push(updates.completed_at);
    }
    if (updates.base_branch !== undefined) {
      setClauses.push(`base_branch = $${i++}`);
      params.push(updates.base_branch);
    }
    params.push(runId, projectId);
    await execute(
      `UPDATE runs SET ${setClauses.join(", ")} WHERE id = $${i++} AND project_id = $${i}`,
      params,
    );
  }

  /**
   * List active (pending/running) runs for a project.
   * @throws Error("not implemented")
   */
  async listActiveRuns(projectId: string): Promise<RunRow[]> {
    const rows = await query<RunRow>(
      `${runRowSelectSql()} r
       WHERE r.project_id = $1
         AND r.status IN ('pending','running')
         AND NOT EXISTS (
           SELECT 1
           FROM tasks t
           WHERE t.project_id = r.project_id
             AND t.id = r.bead_id
             AND t.status IN ('closed','merged')
         )
       ORDER BY r.created_at DESC`,
       [projectId],
     );
    return rows.map((row) => ({ ...row, status: mapPipelineRunStatusToLegacy(row.status) }));
  }

  /**
   * Check if a seed has an active or pending run.
   * @throws Error("not implemented")
   */
  async hasActiveOrPendingRun(
    projectId: string,
    seedId: string
  ): Promise<boolean> {
    const rows = await query<{ found: number }>(
      `SELECT 1 as found FROM runs WHERE project_id = $1 AND bead_id = $2 AND status IN ('pending','running','success') LIMIT 1`,
      [projectId, seedId],
    );
    return rows.length > 0;
  }

  /**
   * Update run progress (phase, cost, tokens, etc.).
   * @throws Error("not implemented")
   */
  async updateRunProgress(
    projectId: string,
    runId: string,
    progress: Partial<RunProgress> & { phase?: string }
  ): Promise<void> {
    const run = await this.getRun(projectId, runId);
    let existing: Record<string, unknown> = {};
    if (run?.progress) {
      try {
        existing = JSON.parse(run.progress) as Record<string, unknown>;
      } catch {
        existing = {};
      }
    }
    const merged = { ...existing, ...progress };
    await this.updateRun(projectId, runId, { progress: JSON.stringify(merged) });
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
    let payload: Record<string, unknown> | undefined;
    if (details !== undefined) {
      try {
        const parsed = JSON.parse(details) as unknown;
        if (parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)) {
          payload = parsed as Record<string, unknown>;
        } else {
          payload = { details: parsed };
        }
      } catch {
        payload = { details };
      }
    }

    await this.recordPipelineEvent({
      projectId,
      runId,
      eventType,
      payload,
    });
  }

  /**
   * Log a rate limit event.
   * @throws Error("not implemented")
   */
  async logRateLimitEvent(
    projectId: string,
    runId: string | null,
    model: string,
    phase: string | null,
    error: string,
    retryAfterSeconds: number | null
  ): Promise<void> {
    await execute(
      `INSERT INTO rate_limit_events (
         project_id, run_id, model, phase, error, retry_after_seconds
       ) VALUES ($1, $2, $3, $4, $5, $6)`,
      [projectId, runId, model, phase, error, retryAfterSeconds],
    );
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
    senderAgentType: string,
    toAgent: string,
    subject: string,
    body: string
  ): Promise<AgentMessageRow> {
    const rows = await query<AgentMessageRow>(
      `INSERT INTO agent_messages (
         project_id, run_id, sender_agent_type, recipient_agent_type, subject, body, read, created_at
        )
        VALUES ($1, $2, $3, $4, $5, $6, 0, clock_timestamp())
        RETURNING *`,
      [projectId, runId, senderAgentType, toAgent, subject, body],
    );
    return rows[0];
  }

  /**
   * Mark a message as read.
   * @throws Error("not implemented")
   */
  async markMessageRead(
    projectId: string,
    messageId: string
  ): Promise<boolean> {
    const result = await execute(
      `UPDATE agent_messages
       SET read = 1
       WHERE id = $1 AND project_id = $2 AND deleted_at IS NULL`,
      [messageId, projectId],
    );
    return result > 0;
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
    await execute(
      `UPDATE agent_messages
       SET read = 1
       WHERE project_id = $1 AND run_id = $2 AND recipient_agent_type = $3 AND deleted_at IS NULL`,
      [projectId, runId, agentType],
    );
  }

  /**
   * Delete a message.
   * @throws Error("not implemented")
   */
  async deleteMessage(
    projectId: string,
    messageId: string
  ): Promise<boolean> {
    const result = await execute(
      `UPDATE agent_messages
       SET deleted_at = now()
       WHERE id = $1 AND project_id = $2 AND deleted_at IS NULL`,
      [messageId, projectId],
    );
    return result > 0;
  }

  async getMessages(
    projectId: string,
    runId: string,
    agentType: string,
    unreadOnly = false,
  ): Promise<AgentMessageRow[]> {
    let sql = `SELECT * FROM agent_messages
               WHERE project_id = $1 AND run_id = $2 AND recipient_agent_type = $3 AND deleted_at IS NULL`;
    const params: unknown[] = [projectId, runId, agentType];
    if (unreadOnly) {
      sql += ` AND read = 0`;
    }
    sql += ` ORDER BY created_at ASC`;
    return query<AgentMessageRow>(sql, params);
  }

  async getAllMessages(runId: string): Promise<AgentMessageRow[]> {
    return query<AgentMessageRow>(
      `SELECT * FROM agent_messages
       WHERE run_id = $1 AND deleted_at IS NULL
       ORDER BY created_at ASC`,
      [runId],
    );
  }

  async getAllMessagesGlobal(projectId: string, limit = 200): Promise<AgentMessageRow[]> {
    const rows = await query<AgentMessageRow>(
      `SELECT * FROM agent_messages
       WHERE project_id = $1 AND deleted_at IS NULL
       ORDER BY created_at DESC
       LIMIT $2`,
      [projectId, limit],
    );
    return rows.reverse();
  }

  async enqueueMergeQueueEntry(data: {
    projectId: string;
    branchName: string;
    seedId: string;
    runId: string;
    operation?: MergeQueueOperation;
    agentName?: string | null;
    filesModified?: string[];
  }): Promise<MergeQueueEntryRow> {
    const rows = await query<MergeQueueEntryRow>(
      `INSERT INTO merge_queue (
         project_id, branch_name, seed_id, run_id, operation, agent_name, files_modified
       )
       VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb)
       ON CONFLICT (project_id, branch_name, run_id) DO UPDATE
       SET branch_name = EXCLUDED.branch_name
       RETURNING *`,
      [
        data.projectId,
        data.branchName,
        data.seedId,
        data.runId,
        data.operation ?? "auto_merge",
        data.agentName ?? null,
        JSON.stringify(data.filesModified ?? []),
      ],
    );
    return rows[0];
  }

  async listMergeQueue(projectId: string, status?: MergeQueueStatus): Promise<MergeQueueEntryRow[]> {
    const params: unknown[] = [projectId];
    let sql = `SELECT * FROM merge_queue WHERE project_id = $1`;
    if (status) {
      sql += ` AND status = $2`;
      params.push(status);
    }
    sql += ` ORDER BY enqueued_at ASC`;
    return query<MergeQueueEntryRow>(sql, params);
  }

  async updateMergeQueueStatus(
    projectId: string,
    id: number,
    status: MergeQueueStatus,
    extra?: { resolvedTier?: number; error?: string; completedAt?: string; lastAttemptedAt?: string; retryCount?: number },
  ): Promise<void> {
    const fields = ["status = $1"];
    const params: unknown[] = [status];
    let i = 2;
    if (extra?.resolvedTier !== undefined) {
      fields.push(`resolved_tier = $${i++}`);
      params.push(extra.resolvedTier);
    }
    if (extra?.error !== undefined) {
      fields.push(`error = $${i++}`);
      params.push(extra.error);
    }
    if (extra?.completedAt !== undefined) {
      fields.push(`completed_at = $${i++}`);
      params.push(extra.completedAt);
    }
    if (extra?.lastAttemptedAt !== undefined) {
      fields.push(`last_attempted_at = $${i++}`);
      params.push(extra.lastAttemptedAt);
    }
    if (extra?.retryCount !== undefined) {
      fields.push(`retry_count = $${i++}`);
      params.push(extra.retryCount);
    }
    params.push(projectId, id);
    await execute(`UPDATE merge_queue SET ${fields.join(", ")} WHERE project_id = $${i++} AND id = $${i}`, params);
  }

  async removeMergeQueueEntry(projectId: string, id: number): Promise<void> {
    await execute(`DELETE FROM merge_queue WHERE project_id = $1 AND id = $2`, [projectId, id]);
  }

  async resetMergeQueueForRetry(projectId: string, seedId: string): Promise<boolean> {
    const rows = await query<{ id: number }>(
      `UPDATE merge_queue
       SET status = 'pending', error = NULL, started_at = NULL, last_attempted_at = now()
       WHERE project_id = $1 AND seed_id = $2 AND status IN ('failed','conflict','merging')
       RETURNING id`,
      [projectId, seedId],
    );
    return rows.length > 0;
  }

  async listRetryableMergeQueue(projectId: string): Promise<MergeQueueEntryRow[]> {
    return query<MergeQueueEntryRow>(
      `SELECT * FROM merge_queue
       WHERE project_id = $1 AND status IN ('conflict','failed')
       ORDER BY enqueued_at ASC`,
      [projectId],
    );
  }

  async reEnqueueMergeQueue(projectId: string, id: number): Promise<boolean> {
    const rows = await query<{ id: number }>(
      `UPDATE merge_queue
       SET status = 'pending', error = NULL, started_at = NULL,
           retry_count = retry_count + 1, last_attempted_at = now()
       WHERE project_id = $1 AND id = $2 AND status IN ('conflict','failed')
       RETURNING id`,
      [projectId, id],
    );
    return rows.length > 0;
  }

  async listMissingFromMergeQueue(projectId: string): Promise<Array<{ run_id: string; seed_id: string }>> {
    return query<{ run_id: string; seed_id: string }>(
      `SELECT r.id AS run_id, r.bead_id AS seed_id
       FROM runs r
       WHERE r.project_id = $1 AND r.status = 'success'
         AND r.id NOT IN (SELECT run_id FROM merge_queue WHERE project_id = $1)
       ORDER BY r.created_at ASC`,
      [projectId],
    );
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
    const fields = [
      "project_id",
      "branch",
      "test_command",
      "interval_minutes",
      "failure_threshold",
      "enabled",
      "pid",
      "created_at",
      "updated_at",
    ];
    const now = new Date().toISOString();
    await execute(
      `INSERT INTO sentinel_configs (${fields.join(",")})
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
       ON CONFLICT (project_id) DO UPDATE SET
         branch = EXCLUDED.branch,
         test_command = EXCLUDED.test_command,
         interval_minutes = EXCLUDED.interval_minutes,
         failure_threshold = EXCLUDED.failure_threshold,
         enabled = EXCLUDED.enabled,
         pid = EXCLUDED.pid,
         updated_at = EXCLUDED.updated_at`,
      [
        projectId,
        config.branch ?? "main",
        config.test_command ?? "npm test",
        config.interval_minutes ?? 30,
        config.failure_threshold ?? 2,
        config.enabled ?? 1,
        config.pid ?? null,
        now,
        now,
      ],
    );
  }

  /**
   * Record a sentinel run.
   * @throws Error("not implemented")
   */
  async recordSentinelRun(
    projectId: string,
    run: Record<string, unknown>
  ): Promise<void> {
    await execute(
      `INSERT INTO sentinel_runs (
         id, project_id, branch, commit_hash, status, test_command, output, failure_count, started_at, completed_at
       ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
      [
        run.id,
        projectId,
        run.branch,
        run.commit_hash ?? null,
        run.status,
        run.test_command,
        run.output ?? null,
        run.failure_count ?? 0,
        run.started_at,
        run.completed_at ?? null,
      ],
    );
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
    const fields: string[] = [];
    const params: unknown[] = [];
    let i = 1;
    for (const key of ["status", "output", "completed_at", "failure_count"] as const) {
      if (updates[key] !== undefined) {
        fields.push(`${key} = $${i++}`);
        params.push(updates[key]);
      }
    }
    if (fields.length === 0) return;
    params.push(projectId, runId);
    await execute(`UPDATE sentinel_runs SET ${fields.join(", ")} WHERE project_id = $${i++} AND id = $${i}`, params);
  }

  async getSentinelConfig(projectId: string): Promise<SentinelConfigRow | null> {
    const rows = await query<SentinelConfigRow>(
      `SELECT * FROM sentinel_configs WHERE project_id = $1 LIMIT 1`,
      [projectId],
    );
    return rows[0] ?? null;
  }

  async getSentinelRuns(projectId: string, limit = 10): Promise<SentinelRunRow[]> {
    return query<SentinelRunRow>(
      `SELECT * FROM sentinel_runs WHERE project_id = $1 ORDER BY started_at DESC LIMIT $2`,
      [projectId, limit],
    );
  }

  // -------------------------------------------------------------------------
  // Pipeline run / event / message operations (TRD-032)
  // -------------------------------------------------------------------------

  async createPipelineRun(data: {
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
  }): Promise<PipelineRunRow> {
    const rows = await query<PipelineRunRow>(
      `INSERT INTO runs (
         id, project_id, bead_id, run_number, status, branch, commit_sha, trigger,
         agent_type, session_key, worktree_path, progress, base_branch, merge_strategy,
         queued_at, created_at, updated_at
        )
        VALUES (COALESCE($1, gen_random_uuid()), $2, $3, $4, 'pending', $5, $6, $7, $8, $9, $10, $11::jsonb, $12, $13, clock_timestamp(), clock_timestamp(), clock_timestamp())
        RETURNING *`,
      [
        data.id ?? null,
        data.projectId,
        data.beadId,
        data.runNumber,
        data.branch,
        data.commitSha ?? null,
        data.trigger ?? "manual",
        data.agentType ?? null,
        data.sessionKey ?? null,
        data.worktreePath ?? null,
        data.progress ?? null,
        data.baseBranch ?? null,
        data.mergeStrategy ?? null,
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
      sessionKey?: string;
      worktreePath?: string;
      progress?: string;
      baseBranch?: string;
      mergeStrategy?: string;
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
    if (updates.sessionKey !== undefined) {
      setParts.push(`session_key = $${p++}`);
      params.push(updates.sessionKey);
    }
    if (updates.worktreePath !== undefined) {
      setParts.push(`worktree_path = $${p++}`);
      params.push(updates.worktreePath);
    }
    if (updates.progress !== undefined) {
      setParts.push(`progress = $${p++}::jsonb`);
      params.push(updates.progress);
    }
    if (updates.baseBranch !== undefined) {
      setParts.push(`base_branch = $${p++}`);
      params.push(updates.baseBranch);
    }
    if (updates.mergeStrategy !== undefined) {
      setParts.push(`merge_strategy = $${p++}`);
      params.push(updates.mergeStrategy);
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
    runId: string | null;
    taskId?: string;
    eventType: string;
    payload?: Record<string, unknown>;
  }): Promise<PipelineEventRow> {
    const rows = await query<PipelineEventRow>(
      `INSERT INTO events (project_id, run_id, task_id, event_type, payload, created_at)
       VALUES ($1, $2, $3, $4, $5, clock_timestamp())
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
      `INSERT INTO messages (run_id, step_key, stream, chunk, line_number, created_at)
       VALUES ($1, $2, $3, $4, $5, clock_timestamp())
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

  // GitHub repository operations (TRD-008)
  async upsertGithubRepo(input: UpsertGithubRepoInput): Promise<GithubRepoRow> {
    const rows = await query<GithubRepoRow>(
      `INSERT INTO github_repos (
         id, project_id, owner, repo, auth_type, auth_config,
         default_labels, auto_import, webhook_secret, webhook_enabled,
         sync_strategy, last_sync_at, created_at, updated_at
       )
       VALUES (
         COALESCE($1, gen_random_uuid()),
         $2, $3, $4, $5, $6,
         COALESCE($7::text[], '{}'::text[]), COALESCE($8, false), $9, COALESCE($10, false),
         COALESCE($11, 'github-wins'), $12,
         now(), now()
       )
       ON CONFLICT (project_id, owner, repo)
       DO UPDATE SET
         auth_type     = EXCLUDED.auth_type,
         auth_config   = EXCLUDED.auth_config,
         default_labels     = EXCLUDED.default_labels,
         auto_import        = EXCLUDED.auto_import,
         webhook_secret     = EXCLUDED.webhook_secret,
         webhook_enabled    = EXCLUDED.webhook_enabled,
         sync_strategy      = EXCLUDED.sync_strategy,
         last_sync_at       = EXCLUDED.last_sync_at,
         updated_at         = now()
       RETURNING *`,
      [
        input.id ?? null,
        input.projectId,
        input.owner,
        input.repo,
        input.authType ?? "pat",
        JSON.stringify(input.authConfig ?? {}),
        input.defaultLabels ?? null,
        input.autoImport ?? false,
        input.webhookSecret ?? null,
        input.webhookEnabled ?? false,
        input.syncStrategy ?? "github-wins",
        input.lastSyncAt ?? null,
      ],
    );
    return rows[0];
  }

  async getGithubRepo(
    projectId: string,
    owner: string,
    repo: string,
  ): Promise<GithubRepoRow | null> {
    const rows = await query<GithubRepoRow>(
      `SELECT * FROM github_repos
       WHERE project_id = $1 AND owner = $2 AND repo = $3`,
      [projectId, owner, repo],
    );
    return rows[0] ?? null;
  }

  async listGithubRepos(projectId: string): Promise<GithubRepoRow[]> {
    return query<GithubRepoRow>(
      `SELECT * FROM github_repos
       WHERE project_id = $1
       ORDER BY created_at DESC`,
      [projectId],
    );
  }

  async deleteGithubRepo(id: string): Promise<boolean> {
    const result = await execute(
      `DELETE FROM github_repos WHERE id = $1`,
      [id],
    );
    return (result as unknown as { rowCount: number }).rowCount > 0;
  }

  async recordGithubSyncEvent(
    input: RecordGithubSyncEventInput,
  ): Promise<GithubSyncEventRow> {
    const rows = await query<GithubSyncEventRow>(
      `INSERT INTO github_sync_events (
         project_id, external_id, event_type, direction,
         github_payload, foreman_changes,
         conflict_detected, resolved_with, processed_at
       )
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now())
       RETURNING *`,
      [
        input.projectId,
        input.externalId,
        input.eventType,
        input.direction,
        input.githubPayload ? JSON.stringify(input.githubPayload) : null,
        input.foremanChanges ? JSON.stringify(input.foremanChanges) : null,
        input.conflictDetected ?? false,
        input.resolvedWith ?? null,
      ],
    );
    return rows[0];
  }

  async listGithubSyncEvents(
    projectId: string,
    externalId?: string,
    limit = 100,
  ): Promise<GithubSyncEventRow[]> {
    if (externalId) {
      return query<GithubSyncEventRow>(
        `SELECT * FROM github_sync_events
         WHERE project_id = $1 AND external_id = $2
         ORDER BY processed_at DESC
         LIMIT $3`,
        [projectId, externalId, limit],
      );
    }
    return query<GithubSyncEventRow>(
      `SELECT * FROM github_sync_events
       WHERE project_id = $1
       ORDER BY processed_at DESC
       LIMIT $2`,
      [projectId, limit],
    );
  }

  async updateGithubRepoLastSync(id: string): Promise<void> {
    await execute(
      "UPDATE github_repos SET last_sync_at = now(), updated_at = now() WHERE id = $1",
      [id],
    );
  }

  async listTasksWithExternalId(projectId: string): Promise<TaskRow[]> {
    return query<TaskRow>(
      "SELECT * FROM tasks WHERE project_id = $1 AND external_repo IS NOT NULL AND github_issue_number IS NOT NULL ORDER BY updated_at DESC",
      [projectId],
    );
  }

  async updateTaskGitHubFields(
    projectId: string,
    taskId: string,
    updates: {
      title?: string;
      description?: string | null;
      state?: "open" | "closed";
      labels?: string[];
      milestone?: string | null;
      syncEnabled?: boolean;
      lastSyncAt?: string;
    },
  ): Promise<TaskRow | null> {
    const setParts: string[] = [];
    const params: unknown[] = [];
    let i = 1;
    if (updates.title !== undefined) {
      setParts.push("title = $" + i++);
      params.push(updates.title);
    }
    if (updates.description !== undefined) {
      setParts.push("description = $" + i++);
      params.push(updates.description);
    }
    if (updates.state !== undefined) {
      setParts.push("status = $" + i++);
      params.push(updates.state === "closed" ? "merged" : "backlog");
    }
    if (updates.labels !== undefined) {
      setParts.push("labels = $" + i++ + "::text[]");
      params.push(updates.labels);
    }
    if (updates.milestone !== undefined) {
      setParts.push("github_milestone = $" + i++);
      params.push(updates.milestone);
    }
    if (updates.syncEnabled !== undefined) {
      setParts.push("sync_enabled = $" + i++);
      params.push(updates.syncEnabled);
    }
    if (updates.lastSyncAt !== undefined) {
      setParts.push("last_sync_at = $" + i++);
      params.push(updates.lastSyncAt);
    }
    if (setParts.length === 0) {
      return null;
    }
    setParts.push("updated_at = now()");
    params.push(projectId, taskId);
    const sql = "UPDATE tasks SET " + setParts.join(", ") + " WHERE id = $" + i + " AND project_id = $" + (i + 1) + " RETURNING *";
    const rows = await query<TaskRow>(sql, params);
    return rows[0] ?? null;
  }
}


// ---------------------------------------------------------------------------
// Named export
// ---------------------------------------------------------------------------

export const Database = { Adapter: PostgresAdapter };
