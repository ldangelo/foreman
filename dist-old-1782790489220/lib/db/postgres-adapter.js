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
import { query, execute, acquireClient, releaseClient, } from "./pool-manager.js";
import { randomBytes } from "node:crypto";
import { normalizeTaskIdPrefix } from "../task-store.js";
function mapLegacyRunStatusToPipeline(status) {
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
function mapPipelineRunStatusToLegacy(status) {
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
function runRowSelectSql() {
    return `
    SELECT
      id,
      project_id,
      bead_id AS seed_id,
      COALESCE(agent_type, 'claude-code') AS agent_type,
      session_key,
      worktree_path,
      branch,
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
// ---------------------------------------------------------------------------
// PostgresAdapter
// ---------------------------------------------------------------------------
export class PostgresAdapter {
    async allocateTaskId(projectId) {
        const rows = await query(`SELECT name FROM projects WHERE id = $1 LIMIT 1`, [projectId]);
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
    async createProject(metadata) {
        const rows = await query(`INSERT INTO projects (name, path, github_url, repo_key, default_branch, status)
       VALUES ($1, $2, $3, $4, $5, $6)
       RETURNING *`, [
            metadata.name,
            metadata.path,
            metadata.githubUrl ?? null,
            metadata.repoKey ?? null,
            metadata.defaultBranch ?? null,
            metadata.status ?? "active",
        ]);
        return rows[0];
    }
    /**
     * List all projects, optionally filtered by status.
     *
     * @param filters.status - Filter by project status.
     * @param filters.search - ILIKE pattern match on project name.
     * @returns Matching project rows, ordered by created_at DESC.
     */
    async listProjects(filters) {
        const conditions = [];
        const params = [];
        let paramIndex = 1;
        if (filters?.status) {
            conditions.push(`status = $${paramIndex++}`);
            params.push(filters.status);
        }
        if (filters?.search) {
            conditions.push(`name ILIKE $${paramIndex++}`);
            params.push(`%${filters.search}%`);
        }
        const where = conditions.length > 0 ? `WHERE ${conditions.join(" AND ")}` : "";
        return query(`SELECT * FROM projects ${where} ORDER BY created_at DESC`, params);
    }
    /**
     * Get a single project by ID.
     *
     * @param projectId - The project UUID.
     * @returns The project row, or null if not found.
     */
    async getProject(projectId) {
        const rows = await query(`SELECT * FROM projects WHERE id = $1`, [projectId]);
        return rows[0] ?? null;
    }
    /**
     * Update project fields.
     *
     * @param projectId - The project UUID.
     * @param updates - Fields to update. All fields are optional.
     * @throws DatabaseError if the project does not exist.
     */
    async updateProject(projectId, updates) {
        const setClauses = ["updated_at = now()"];
        const params = [];
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
        if (setClauses.length === 1)
            return; // only updated_at, nothing to do
        params.push(projectId);
        await execute(`UPDATE projects SET ${setClauses.join(", ")} WHERE id = $${i}`, params);
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
    async removeProject(projectId, options) {
        if (options?.force) {
            await execute(`DELETE FROM projects WHERE id = $1`, [projectId]);
        }
        else {
            await execute(`UPDATE projects SET status = 'archived', updated_at = now() WHERE id = $1`, [projectId]);
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
    async syncProject(projectId) {
        await execute(`UPDATE projects SET last_sync_at = now(), updated_at = now() WHERE id = $1`, [projectId]);
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
    async createTask(projectId, taskData) {
        const id = taskData.id ?? await this.allocateTaskId(projectId);
        const title = taskData.title ?? id;
        const description = taskData.description ?? null;
        const type = taskData.type ?? "task";
        const priority = taskData.priority ?? 2;
        const externalId = taskData.external_id ??
            taskData.externalId ??
            null;
        const branch = taskData.branch ?? null;
        const status = taskData.status ?? "backlog";
        const createdAt = taskData.created_at ?? new Date().toISOString();
        const updatedAt = taskData.updated_at ?? createdAt;
        const approvedAt = taskData.approved_at ?? null;
        const closedAt = taskData.closed_at ?? null;
        const rows = await query(`INSERT INTO tasks (
         id, project_id, title, description, type, priority, status,
         external_id, branch, created_at, updated_at, approved_at, closed_at,
         external_repo, github_issue_number, github_milestone, sync_enabled, labels
       )
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18)
       RETURNING *`, [
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
            taskData.external_repo ??
                taskData.externalRepo ??
                null,
            taskData.github_issue_number ??
                taskData.githubIssueNumber ??
                null,
            taskData.github_milestone ??
                taskData.githubMilestone ??
                null,
            taskData.sync_enabled ??
                taskData.syncEnabled ??
                false,
            taskData.labels ?? null,
        ]);
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
    async listTasks(projectId, filters) {
        const conditions = ["t.project_id = $1"];
        const params = [projectId];
        let i = 2;
        if (filters?.status && filters.status.length > 0) {
            conditions.push(`t.status IN (${filters.status.map((_, idx) => `$${i + idx}`).join(",")})`);
            params.push(...filters.status);
            i += filters.status.length;
        }
        if (filters?.runId !== undefined) {
            conditions.push(`t.run_id = $${i++}`);
            params.push(filters.runId);
        }
        if (filters?.externalId !== undefined) {
            conditions.push(`t.external_id = $${i++}`);
            params.push(filters.externalId);
        }
        if (filters?.labels && filters.labels.length > 0) {
            conditions.push(`t.labels @> $${i++}::text[]`);
            params.push(filters.labels);
        }
        const limit = filters?.limit ?? 100;
        params.push(limit);
        // LEFT JOIN runs to get PR state (AC-4: task list surfaces PR state)
        return query(`SELECT t.*, r.pr_state, r.pr_url, r.pr_head_sha
       FROM tasks t
       LEFT JOIN runs r ON t.run_id = r.id
       WHERE ${conditions.join(" AND ")}
       ORDER BY t.priority ASC, t.created_at ASC
       LIMIT $${i}`, params);
    }
    /**
     * Get a single task by ID.
     *
     * @param projectId - The owner project UUID.
     * @param taskId - The task UUID.
     * @returns The task row, or null if not found or belongs to a different project.
     */
    async getTask(projectId, taskId) {
        const rows = await query(`SELECT * FROM tasks WHERE id = $1 AND project_id = $2`, [taskId, projectId]);
        return rows[0] ?? null;
    }
    /**
     * Update a task's fields.
     *
     * @param projectId - The owner project UUID.
     * @param taskId - The task UUID.
     * @param updates - Fields to update. Supported: title, description, type, priority, status, branch, external_id.
     */
    async addTaskNote(projectId, taskId, input) {
        const rows = await query(`INSERT INTO task_notes (
         id, project_id, task_id, run_id, phase, author, kind, body, metadata, created_at
       )
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, now())
       RETURNING *`, [
            `note-${randomBytes(8).toString("hex")}`,
            projectId,
            taskId,
            input.runId ?? null,
            input.phase ?? null,
            input.author,
            input.kind ?? "progress",
            input.body,
            input.metadata ?? null,
        ]);
        return rows[0];
    }
    async listTaskNotes(projectId, taskId, opts) {
        const limit = opts?.limit ?? 50;
        const direction = opts?.newestFirst === false ? "ASC" : "DESC";
        const notes = await query(`SELECT *
       FROM task_notes
       WHERE project_id = $1 AND task_id = $2
       ORDER BY created_at ${direction}
       LIMIT $3`, [projectId, taskId, limit]);
        if (notes.length > 0)
            return notes;
        const events = await query(`SELECT *
       FROM events
       WHERE project_id = $1
         AND (
           task_id = $2
           OR run_id IN (SELECT id FROM runs WHERE project_id = $1 AND bead_id = $2)
         )
         AND event_type IN ('phase-start', 'complete', 'fail', 'stuck', 'conflict')
       ORDER BY created_at ${direction}
       LIMIT $3`, [projectId, taskId, limit]);
        return events.map((event) => {
            const payload = event.payload ?? {};
            const phase = typeof payload.phase === "string" ? payload.phase : null;
            const reason = typeof payload.reason === "string" ? payload.reason : null;
            const title = typeof payload.title === "string" ? payload.title : null;
            const body = (() => {
                if (event.event_type === "phase-start")
                    return `${phase ?? "Phase"} started.`;
                if (event.event_type === "complete")
                    return `${phase ?? "Task"} completed.`;
                if (event.event_type === "fail")
                    return reason ? `${phase ?? "Task"} failed: ${reason}` : `${title ?? "Task"} failed.`;
                if (event.event_type === "stuck")
                    return reason ? `${phase ?? "Task"} stuck: ${reason}` : `${phase ?? "Task"} stuck.`;
                if (event.event_type === "conflict")
                    return reason ? `${phase ?? "Task"} conflict: ${reason}` : `${phase ?? "Task"} conflict.`;
                return event.event_type;
            })();
            return {
                id: `event-${event.id}`,
                project_id: event.project_id,
                task_id: event.task_id ?? taskId,
                run_id: event.run_id,
                phase,
                author: "pipeline",
                kind: event.event_type === "fail" || event.event_type === "stuck" || event.event_type === "conflict" ? "failure" : "progress",
                body,
                metadata: { source: "events", eventType: event.event_type, payload },
                created_at: event.created_at,
            };
        });
    }
    async updateTask(projectId, taskId, updates) {
        const setClauses = ["updated_at = now()"];
        const params = [];
        let i = 1;
        if (updates.title !== undefined) {
            setClauses.push(`title = $${i++}`);
            params.push(updates.title);
        }
        if (updates.description !== undefined) {
            setClauses.push(`description = $${i++}`);
            params.push(updates.description);
        }
        if (updates.type !== undefined) {
            setClauses.push(`type = $${i++}`);
            params.push(updates.type);
        }
        if (updates.priority !== undefined) {
            setClauses.push(`priority = $${i++}`);
            params.push(updates.priority);
        }
        if (updates.status !== undefined) {
            setClauses.push(`status = $${i++}`);
            params.push(updates.status);
        }
        if (updates.branch !== undefined) {
            setClauses.push(`branch = $${i++}`);
            params.push(updates.branch);
        }
        if (updates.external_id !== undefined) {
            setClauses.push(`external_id = $${i++}`);
            params.push(updates.external_id);
        }
        if (setClauses.length === 1)
            return; // only updated_at
        params.push(taskId, projectId);
        await execute(`UPDATE tasks SET ${setClauses.join(", ")} WHERE id = $${i++} AND project_id = $${i}`, params);
    }
    /**
     * Sync the claimed task linked to a run into a terminal status.
     *
     * No-op when no task is currently linked to the run.
     */
    async updateTaskStatusForRun(projectId, runId, status) {
        await execute(`UPDATE tasks
       SET status = $1, updated_at = now()
       WHERE project_id = $2 AND run_id = $3`, [status, projectId, runId]);
    }
    /**
     * Delete a task and its dependencies.
     *
     * @param projectId - The owner project UUID.
     * @param taskId - The task UUID.
     */
    async deleteTask(projectId, taskId) {
        // ON DELETE CASCADE handles task_dependencies automatically
        await execute(`DELETE FROM tasks WHERE id = $1 AND project_id = $2`, [taskId, projectId]);
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
    async claimTask(projectId, taskId, runId) {
        const client = await acquireClient();
        try {
            await client.query("BEGIN");
            // SELECT ... FOR UPDATE acquires a row-level lock on the task
            const result = await client.query(`SELECT id FROM tasks
         WHERE id = $1 AND project_id = $2 AND status = 'ready'
         FOR UPDATE`, [taskId, projectId]);
            if (result.rows.length === 0) {
                // Task not found, not in 'ready' status, or belongs to another project
                await client.query("ROLLBACK");
                return false;
            }
            await client.query(`UPDATE tasks SET run_id = $1, status = 'in-progress', updated_at = now()
          WHERE id = $2 AND project_id = $3`, [runId, taskId, projectId]);
            await client.query("COMMIT");
            return true;
        }
        catch (err) {
            await client.query("ROLLBACK");
            throw err;
        }
        finally {
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
    async approveTask(projectId, taskId) {
        const rows = await query(`UPDATE tasks
       SET status = 'ready', approved_at = now(), updated_at = now()
       WHERE id = $1 AND project_id = $2 AND status = 'backlog'
       RETURNING id`, [taskId, projectId]);
        if (rows.length === 0) {
            throw new Error(`Cannot approve task '${taskId}': task not found or not in backlog status`);
        }
    }
    async closeTask(projectId, taskId) {
        const rows = await query(`UPDATE tasks
       SET status = 'closed', closed_at = now(), updated_at = now()
       WHERE id = $1 AND project_id = $2
       RETURNING id`, [taskId, projectId]);
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
    async resetTask(projectId, taskId) {
        await execute(`UPDATE tasks
       SET status = 'ready', run_id = NULL, updated_at = now()
       WHERE id = $1 AND project_id = $2`, [taskId, projectId]);
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
    async retryTask(projectId, taskId) {
        const rows = await query(`UPDATE tasks
       SET status = 'ready', run_id = NULL, updated_at = now()
       WHERE id = $1 AND project_id = $2 AND status IN ('failed', 'stuck')
       RETURNING id`, [taskId, projectId]);
        if (rows.length === 0) {
            throw new Error(`Cannot retry task '${taskId}': task not found or not in failed/stuck status`);
        }
    }
    /**
     * List tasks in 'ready' status for a project (dispatchable tasks).
     *
     * @param projectId - The owner project UUID.
     * @returns Tasks with status = 'ready', ordered by priority ASC, created_at ASC.
     */
    async listReadyTasks(projectId) {
        return query(`SELECT * FROM tasks
       WHERE project_id = $1 AND status = 'ready'
       ORDER BY priority ASC, created_at ASC`, [projectId]);
    }
    /**
     * List ready tasks whose blockers are all closed.
     *
     * A task can remain in the native `ready` state while dependency links express
     * that another task must close first. Dispatchers must use this query rather
     * than raw status filtering so dependency-blocked ready tasks are not claimed.
     */
    async listDispatchableReadyTasks(projectId, limit = 1000) {
        return query(`SELECT t.*
       FROM tasks t
       WHERE t.project_id = $1
         AND t.status = 'ready'
         AND NOT EXISTS (
           SELECT 1
           FROM task_dependencies td
           JOIN tasks blocker ON blocker.id = td.from_task_id
           WHERE td.to_task_id = t.id
             AND blocker.project_id = $1
             AND blocker.status <> 'closed'
         )
       ORDER BY t.priority ASC, t.created_at ASC
       LIMIT $2`, [projectId, limit]);
    }
    /**
     * List tasks that need human attention.
     *
     * Includes: backlog (not approved), conflict, failed, stuck, blocked.
     *
     * @param projectId - The owner project UUID.
     */
    async listNeedsHumanTasks(projectId) {
        return query(`SELECT * FROM tasks
       WHERE project_id = $1 AND status IN ('backlog', 'conflict', 'failed', 'stuck', 'blocked')
       ORDER BY priority ASC, created_at ASC`, [projectId]);
    }
    /**
     * Get a task by its external ID (e.g., bead ID).
     */
    async getTaskByExternalId(projectId, externalId) {
        const rows = await query(`SELECT * FROM tasks WHERE project_id = $1 AND external_id = $2 LIMIT 1`, [projectId, externalId]);
        return rows[0] ?? null;
    }
    /**
     * Check if any tasks exist for a project (native tasks).
     */
    async hasNativeTasks(projectId) {
        const result = await query(`SELECT COUNT(*) as cnt FROM tasks WHERE project_id = $1`, [projectId]);
        return parseInt(result[0]?.cnt ?? "0", 10) > 0;
    }
    async addTaskDependency(projectId, fromTaskId, toTaskId, type = "blocks") {
        if (fromTaskId === toTaskId) {
            throw new Error("Adding this dependency would create a circular dependency.");
        }
        const client = await acquireClient();
        try {
            await client.query("BEGIN");
            const rows = await client.query(`SELECT id FROM tasks
         WHERE project_id = $1 AND id IN ($2, $3)`, [projectId, fromTaskId, toTaskId]);
            if (rows.rows.length !== 2) {
                throw new Error("One or both task IDs were not found in this project.");
            }
            const cycle = await client.query(`WITH RECURSIVE reach(id) AS (
           SELECT $1::text
           UNION
           SELECT td.to_task_id
           FROM task_dependencies td
           JOIN reach r ON td.from_task_id = r.id
         )
         SELECT 1 AS found
         FROM reach
         WHERE id = $2
         LIMIT 1`, [toTaskId, fromTaskId]);
            if (cycle.rows.length > 0) {
                throw new Error("Adding this dependency would create a circular dependency.");
            }
            await client.query(`INSERT INTO task_dependencies (from_task_id, to_task_id, type)
         VALUES ($1, $2, $3)
         ON CONFLICT DO NOTHING`, [fromTaskId, toTaskId, type]);
            await client.query("COMMIT");
        }
        catch (err) {
            await client.query("ROLLBACK");
            throw err;
        }
        finally {
            releaseClient(client);
        }
    }
    async listTaskDependencies(projectId, taskId, direction = "outgoing") {
        if (direction === "outgoing") {
            return query(`SELECT td.*
         FROM task_dependencies td
         JOIN tasks t ON t.id = td.from_task_id
         WHERE t.project_id = $1 AND td.from_task_id = $2
         ORDER BY td.to_task_id ASC`, [projectId, taskId]);
        }
        return query(`SELECT td.*
       FROM task_dependencies td
       JOIN tasks t ON t.id = td.to_task_id
       WHERE t.project_id = $1 AND td.to_task_id = $2
       ORDER BY td.from_task_id ASC`, [projectId, taskId]);
    }
    async removeTaskDependency(projectId, fromTaskId, toTaskId, type = "blocks") {
        await execute(`DELETE FROM task_dependencies td
       USING tasks tf, tasks tt
       WHERE td.from_task_id = $1
         AND td.to_task_id = $2
         AND td.type = $3
         AND tf.id = td.from_task_id
         AND tf.project_id = $4
         AND tt.id = td.to_task_id
         AND tt.project_id = $4`, [fromTaskId, toTaskId, type, projectId]);
    }
    /**
     * Get runs by multiple statuses since a given time.
     */
    async getRunsByStatusesSince(projectId, statuses, since) {
        if (statuses.length === 0)
            return [];
        const placeholders = statuses.map((_, i) => `$${i + 2}`).join(", ");
        return query(`SELECT * FROM runs
       WHERE project_id = $1 AND status IN (${placeholders}) AND created_at >= $${statuses.length + 2}
       ORDER BY created_at DESC`, [projectId, ...statuses, since]);
    }
    // ---------------------------------------------------------------------------
    // Run operations
    // ---------------------------------------------------------------------------
    /**
     * Create a new run.
       */
    async createRun(projectId, seedId, agentType, options) {
        const rows = await query(`INSERT INTO runs (
         project_id, bead_id, run_number, status, branch, trigger,
         agent_type, session_key, worktree_path, base_branch, merge_strategy, progress
       )
       VALUES (
         $1::uuid,
         $2::varchar(255),
         COALESCE((SELECT MAX(run_number) + 1 FROM runs WHERE bead_id = $3::varchar(255)), 1),
         'pending',
         $4::varchar(255),
         'manual',
         $5::varchar(64),
         $6::text,
         $7::text,
         $8::varchar(255),
         $9::varchar(16),
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
         CASE WHEN progress IS NULL THEN NULL ELSE progress::text END AS progress,
         base_branch,
         merge_strategy`, [
            projectId,
            seedId,
            seedId,
            options?.worktreePath ?? `foreman/${seedId}`,
            agentType,
            options?.sessionKey ?? null,
            options?.worktreePath ?? null,
            options?.baseBranch ?? null,
            options?.mergeStrategy ?? "auto",
        ]);
        return rows[0];
    }
    /**
     * List runs for a project.
       */
    async listRuns(projectId, filters) {
        const conditions = [`project_id = $1`];
        const params = [projectId];
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
        const rows = await query(sql, params);
        return rows.map((row) => ({ ...row, status: mapPipelineRunStatusToLegacy(row.status) }));
    }
    /**
     * Get a single run by ID.
       */
    async getRun(projectId, runId) {
        const rows = await query(`${runRowSelectSql()} WHERE project_id = $1 AND id = $2 LIMIT 1`, [projectId, runId]);
        const row = rows[0];
        return row ? { ...row, status: mapPipelineRunStatusToLegacy(row.status) } : null;
    }
    /**
     * Update a run's fields.
       */
    async updateRun(projectId, runId, updates) {
        const setClauses = ["updated_at = now()"];
        const params = [];
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
        if (updates.merge_strategy !== undefined) {
            setClauses.push(`merge_strategy = $${i++}`);
            params.push(updates.merge_strategy);
        }
        params.push(runId, projectId);
        await execute(`UPDATE runs SET ${setClauses.join(", ")} WHERE id = $${i++} AND project_id = $${i}`, params);
    }
    /**
     * List active (pending/running) runs for a project.
       */
    async listActiveRuns(projectId) {
        const rows = await query(`${runRowSelectSql()} r
       WHERE r.project_id = $1
         AND r.status IN ('pending','running')
         AND NOT EXISTS (
           SELECT 1
           FROM tasks t
           WHERE t.project_id = r.project_id
             AND t.id = r.bead_id
             AND t.status IN ('closed','merged')
         )
       ORDER BY r.created_at DESC`, [projectId]);
        return rows.map((row) => ({ ...row, status: mapPipelineRunStatusToLegacy(row.status) }));
    }
    /**
     * Check if a seed has an active or pending run.
       */
    async hasActiveOrPendingRun(projectId, seedId) {
        const rows = await query(`SELECT 1 as found FROM runs WHERE project_id = $1 AND bead_id = $2 AND status IN ('pending','running','success') LIMIT 1`, [projectId, seedId]);
        return rows.length > 0;
    }
    /**
     * Update run progress (phase, cost, tokens, etc.).
       */
    async updateRunProgress(projectId, runId, progress) {
        const run = await this.getRun(projectId, runId);
        let existing = {};
        if (run?.progress) {
            try {
                existing = JSON.parse(run.progress);
            }
            catch {
                existing = {};
            }
        }
        const merged = { ...existing, ...progress };
        await this.updateRun(projectId, runId, { progress: JSON.stringify(merged) });
    }
    /**
     * Purge runs older than a given timestamp.
       */
    async purgeOldRuns(projectId, olderThan) {
        return execute(`DELETE FROM runs
       WHERE project_id = $1
         AND status IN ('failure', 'success')
         AND created_at < $2`, [projectId, olderThan]);
    }
    /**
     * Delete a run.
       */
    async deleteRun(projectId, runId) {
        const changed = await execute(`DELETE FROM runs WHERE project_id = $1 AND id = $2`, [projectId, runId]);
        return changed > 0;
    }
    // -------------------------------------------------------------------------
    // Cost recording
    // -------------------------------------------------------------------------
    /**
     * Record cost data for a run.
       */
    async recordCost(projectId, runId, cost) {
        await execute(`INSERT INTO costs (run_id, tokens_in, tokens_out, cache_read, estimated_cost, recorded_at)
       VALUES ($1, $2, $3, $4, $5, clock_timestamp())`, [runId, cost.tokensIn, cost.tokensOut, cost.cacheRead, cost.estimatedCost]);
    }
    // -------------------------------------------------------------------------
    // Event logging
    // -------------------------------------------------------------------------
    /**
     * Log a project event.
       */
    async logEvent(projectId, runId, eventType, details) {
        let payload;
        if (details !== undefined) {
            try {
                const parsed = JSON.parse(details);
                if (parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)) {
                    payload = parsed;
                }
                else {
                    payload = { details: parsed };
                }
            }
            catch {
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
       */
    async logRateLimitEvent(projectId, runId, model, phase, error, retryAfterSeconds) {
        await execute(`INSERT INTO rate_limit_events (
         project_id, run_id, model, phase, error, retry_after_seconds
       ) VALUES ($1, $2, $3, $4, $5, $6)`, [projectId, runId, model, phase, error, retryAfterSeconds]);
    }
    // -------------------------------------------------------------------------
    // Message operations
    // -------------------------------------------------------------------------
    /**
     * Send a message to an agent.
       */
    async sendMessage(projectId, runId, senderAgentType, toAgent, subject, body) {
        const rows = await query(`INSERT INTO agent_messages (
         project_id, run_id, sender_agent_type, recipient_agent_type, subject, body, read, created_at
        )
        VALUES ($1, $2, $3, $4, $5, $6, 0, clock_timestamp())
        RETURNING *`, [projectId, runId, senderAgentType, toAgent, subject, body]);
        return rows[0];
    }
    /**
     * Mark a message as read.
       */
    async markMessageRead(projectId, messageId) {
        const result = await execute(`UPDATE agent_messages
       SET read = 1
       WHERE id = $1 AND project_id = $2 AND deleted_at IS NULL`, [messageId, projectId]);
        return result > 0;
    }
    /**
     * Mark all messages for a run/agent as read.
       */
    async markAllMessagesRead(projectId, runId, agentType) {
        await execute(`UPDATE agent_messages
       SET read = 1
       WHERE project_id = $1 AND run_id = $2 AND recipient_agent_type = $3 AND deleted_at IS NULL`, [projectId, runId, agentType]);
    }
    /**
     * Delete a message.
       */
    async deleteMessage(projectId, messageId) {
        const result = await execute(`UPDATE agent_messages
       SET deleted_at = now()
       WHERE id = $1 AND project_id = $2 AND deleted_at IS NULL`, [messageId, projectId]);
        return result > 0;
    }
    async getMessages(projectId, runId, agentType, unreadOnly = false) {
        let sql = `SELECT * FROM agent_messages
               WHERE project_id = $1 AND run_id = $2 AND recipient_agent_type = $3 AND deleted_at IS NULL`;
        const params = [projectId, runId, agentType];
        if (unreadOnly) {
            sql += ` AND read = 0`;
        }
        sql += ` ORDER BY created_at ASC`;
        return query(sql, params);
    }
    async getAllMessages(runId) {
        return query(`SELECT * FROM agent_messages
       WHERE run_id = $1 AND deleted_at IS NULL
       ORDER BY created_at ASC`, [runId]);
    }
    async getAllMessagesGlobal(projectId, limit = 200) {
        const rows = await query(`SELECT * FROM agent_messages
       WHERE project_id = $1 AND deleted_at IS NULL
       ORDER BY created_at DESC
       LIMIT $2`, [projectId, limit]);
        return rows.reverse();
    }
    async enqueueMergeQueueEntry(data) {
        const rows = await query(`INSERT INTO merge_queue (
         project_id, branch_name, seed_id, run_id, operation, agent_name, files_modified
       )
       VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb)
       ON CONFLICT (project_id, branch_name, run_id) DO UPDATE
       SET branch_name = EXCLUDED.branch_name
       RETURNING *`, [
            data.projectId,
            data.branchName,
            data.seedId,
            data.runId,
            data.operation ?? "auto_merge",
            data.agentName ?? null,
            JSON.stringify(data.filesModified ?? []),
        ]);
        return rows[0];
    }
    async listMergeQueue(projectId, status) {
        const params = [projectId];
        let sql = `SELECT * FROM merge_queue WHERE project_id = $1`;
        if (status) {
            sql += ` AND status = $2`;
            params.push(status);
        }
        sql += ` ORDER BY enqueued_at ASC`;
        return query(sql, params);
    }
    async updateMergeQueueStatus(projectId, id, status, extra) {
        const fields = ["status = $1"];
        const params = [status];
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
    async removeMergeQueueEntry(projectId, id) {
        await execute(`DELETE FROM merge_queue WHERE project_id = $1 AND id = $2`, [projectId, id]);
    }
    async resetMergeQueueForRetry(projectId, seedId) {
        const rows = await query(`UPDATE merge_queue
       SET status = 'pending', error = NULL, started_at = NULL, last_attempted_at = now()
       WHERE project_id = $1 AND seed_id = $2 AND status IN ('failed','conflict','merging')
       RETURNING id`, [projectId, seedId]);
        return rows.length > 0;
    }
    async listRetryableMergeQueue(projectId) {
        return query(`SELECT * FROM merge_queue
       WHERE project_id = $1 AND status IN ('conflict','failed')
       ORDER BY enqueued_at ASC`, [projectId]);
    }
    async reEnqueueMergeQueue(projectId, id) {
        const rows = await query(`UPDATE merge_queue
       SET status = 'pending', error = NULL, started_at = NULL,
           retry_count = retry_count + 1, last_attempted_at = now()
       WHERE project_id = $1 AND id = $2 AND status IN ('conflict','failed')
       RETURNING id`, [projectId, id]);
        return rows.length > 0;
    }
    async listMissingFromMergeQueue(projectId) {
        return query(`SELECT r.id AS run_id, r.bead_id AS seed_id
       FROM runs r
       WHERE r.project_id = $1 AND r.status = 'success'
         AND r.id NOT IN (SELECT run_id FROM merge_queue WHERE project_id = $1)
       ORDER BY r.created_at ASC`, [projectId]);
    }
    // -------------------------------------------------------------------------
    // Sentinel operations
    // -------------------------------------------------------------------------
    /**
     * Upsert sentinel configuration.
       */
    async upsertSentinelConfig(projectId, config) {
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
        await execute(`INSERT INTO sentinel_configs (${fields.join(",")})
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
       ON CONFLICT (project_id) DO UPDATE SET
         branch = EXCLUDED.branch,
         test_command = EXCLUDED.test_command,
         interval_minutes = EXCLUDED.interval_minutes,
         failure_threshold = EXCLUDED.failure_threshold,
         enabled = EXCLUDED.enabled,
         pid = EXCLUDED.pid,
         updated_at = EXCLUDED.updated_at`, [
            projectId,
            config.branch ?? "main",
            config.test_command ?? "npm test",
            config.interval_minutes ?? 30,
            config.failure_threshold ?? 2,
            config.enabled ?? 1,
            config.pid ?? null,
            now,
            now,
        ]);
    }
    /**
     * Record a sentinel run.
       */
    async recordSentinelRun(projectId, run) {
        await execute(`INSERT INTO sentinel_runs (
         id, project_id, branch, commit_hash, status, test_command, output, failure_count, started_at, completed_at
       ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`, [
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
        ]);
    }
    /**
     * Update a sentinel run.
       */
    async updateSentinelRun(projectId, runId, updates) {
        const fields = [];
        const params = [];
        let i = 1;
        for (const key of ["status", "output", "completed_at", "failure_count"]) {
            if (updates[key] !== undefined) {
                fields.push(`${key} = $${i++}`);
                params.push(updates[key]);
            }
        }
        if (fields.length === 0)
            return;
        params.push(projectId, runId);
        await execute(`UPDATE sentinel_runs SET ${fields.join(", ")} WHERE project_id = $${i++} AND id = $${i}`, params);
    }
    async getSentinelConfig(projectId) {
        const rows = await query(`SELECT * FROM sentinel_configs WHERE project_id = $1 LIMIT 1`, [projectId]);
        return rows[0] ?? null;
    }
    async getSentinelRuns(projectId, limit = 10) {
        return query(`SELECT * FROM sentinel_runs WHERE project_id = $1 ORDER BY started_at DESC LIMIT $2`, [projectId, limit]);
    }
    // -------------------------------------------------------------------------
    // Pipeline run / event / message operations (TRD-032)
    // -------------------------------------------------------------------------
    async createPipelineRun(data) {
        const rows = await query(`INSERT INTO runs (
         id, project_id, bead_id, run_number, status, branch, commit_sha, trigger,
         agent_type, session_key, worktree_path, progress, base_branch, merge_strategy,
         queued_at, created_at, updated_at
        )
        VALUES (COALESCE($1, gen_random_uuid()), $2, $3, $4, 'pending', $5, $6, $7, $8, $9, $10, $11::jsonb, $12, $13, clock_timestamp(), clock_timestamp(), clock_timestamp())
        RETURNING *`, [
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
        ]);
        return rows[0];
    }
    async listPipelineRuns(projectId, filters) {
        let sql = `SELECT * FROM runs WHERE project_id = $1`;
        const params = [projectId];
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
        return query(sql, params);
    }
    async getPipelineRun(runId) {
        const rows = await query(`SELECT * FROM runs WHERE id = $1`, [runId]);
        return rows[0] ?? null;
    }
    async updatePipelineRun(runId, updates) {
        const setParts = [];
        const params = [];
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
        if (setParts.length === 0)
            return this.getPipelineRun(runId);
        setParts.push(`updated_at = now()`);
        params.push(runId);
        const rows = await query(`UPDATE runs SET ${setParts.join(", ")} WHERE id = $${p} RETURNING *`, params);
        return rows[0] ?? null;
    }
    async recordPipelineEvent(data) {
        const rows = await query(`INSERT INTO events (project_id, run_id, task_id, event_type, payload, created_at)
       VALUES ($1, $2, $3, $4, $5, clock_timestamp())
       RETURNING *`, [
            data.projectId,
            data.runId,
            data.taskId ?? null,
            data.eventType,
            data.payload ? JSON.stringify(data.payload) : null,
        ]);
        return rows[0];
    }
    async recordSentinelEvent(data) {
        const rows = await query(`INSERT INTO events (project_id, run_id, sentinel_run_id, task_id, event_type, payload, created_at)
       VALUES ($1, NULL, $2, NULL, $3, $4, clock_timestamp())
       RETURNING *`, [
            data.projectId,
            data.sentinelRunId,
            data.eventType,
            data.payload ? JSON.stringify(data.payload) : null,
        ]);
        return rows[0];
    }
    async listPipelineEvents(runId) {
        return query(`SELECT * FROM events WHERE run_id = $1 ORDER BY created_at ASC`, [runId]);
    }
    async listProjectPipelineEvents(projectId, limit = 100) {
        return query(`SELECT * FROM events WHERE project_id = $1 ORDER BY created_at DESC LIMIT $2`, [projectId, limit]);
    }
    async listPipelineEventsForRun(runId, limit = 100) {
        return query(`SELECT * FROM events WHERE run_id = $1 ORDER BY created_at DESC LIMIT $2`, [runId, limit]);
    }
    async listSentinelEvents(sentinelRunId) {
        return query(`SELECT * FROM events WHERE sentinel_run_id = $1 ORDER BY created_at ASC`, [sentinelRunId]);
    }
    async appendMessage(data) {
        const rows = await query(`INSERT INTO messages (run_id, step_key, stream, chunk, line_number, created_at)
       VALUES ($1, $2, $3, $4, $5, clock_timestamp())
       RETURNING *`, [data.runId, data.stepKey ?? null, data.stream, data.chunk, data.lineNumber]);
        return rows[0];
    }
    async listMessages(runId, stepKey) {
        let sql = `SELECT * FROM messages WHERE run_id = $1`;
        const params = [runId];
        if (stepKey) {
            sql += ` AND step_key = $2`;
            params.push(stepKey);
        }
        sql += ` ORDER BY line_number ASC`;
        return query(sql, params);
    }
    // GitHub repository operations (TRD-008)
    async upsertGithubRepo(input) {
        const rows = await query(`INSERT INTO github_repos (
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
       RETURNING *`, [
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
        ]);
        return rows[0];
    }
    async getGithubRepo(projectId, owner, repo) {
        const rows = await query(`SELECT * FROM github_repos
       WHERE project_id = $1 AND owner = $2 AND repo = $3`, [projectId, owner, repo]);
        return rows[0] ?? null;
    }
    async listGithubRepos(projectId) {
        return query(`SELECT * FROM github_repos
       WHERE project_id = $1
       ORDER BY created_at DESC`, [projectId]);
    }
    async deleteGithubRepo(id) {
        const result = await execute(`DELETE FROM github_repos WHERE id = $1`, [id]);
        return result.rowCount > 0;
    }
    async recordGithubSyncEvent(input) {
        const rows = await query(`INSERT INTO github_sync_events (
         project_id, external_id, event_type, direction,
         github_payload, foreman_changes,
         conflict_detected, resolved_with, processed_at
       )
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now())
       RETURNING *`, [
            input.projectId,
            input.externalId,
            input.eventType,
            input.direction,
            input.githubPayload ? JSON.stringify(input.githubPayload) : null,
            input.foremanChanges ? JSON.stringify(input.foremanChanges) : null,
            input.conflictDetected ?? false,
            input.resolvedWith ?? null,
        ]);
        return rows[0];
    }
    async listGithubSyncEvents(projectId, externalId, limit = 100) {
        if (externalId) {
            return query(`SELECT * FROM github_sync_events
         WHERE project_id = $1 AND external_id = $2
         ORDER BY processed_at DESC
         LIMIT $3`, [projectId, externalId, limit]);
        }
        return query(`SELECT * FROM github_sync_events
       WHERE project_id = $1
       ORDER BY processed_at DESC
       LIMIT $2`, [projectId, limit]);
    }
    async updateGithubRepoLastSync(id) {
        await execute("UPDATE github_repos SET last_sync_at = now(), updated_at = now() WHERE id = $1", [id]);
    }
    async listTasksWithExternalId(projectId) {
        return query("SELECT * FROM tasks WHERE project_id = $1 AND external_repo IS NOT NULL AND github_issue_number IS NOT NULL ORDER BY updated_at DESC", [projectId]);
    }
    async updateTaskGitHubFields(projectId, taskId, updates) {
        const setParts = [];
        const params = [];
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
        if (updates.type !== undefined) {
            setParts.push("type = $" + i++);
            params.push(updates.type);
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
        params.push(taskId, projectId);
        const sql = "UPDATE tasks SET " + setParts.join(", ") + " WHERE id = $" + i + " AND project_id = $" + (i + 1) + " RETURNING *";
        const rows = await query(sql, params);
        return rows[0] ?? null;
    }
    // -------------------------------------------------------------------------
    // Jira issue state operations (TRD-013: polling infrastructure)
    // -------------------------------------------------------------------------
    /**
     * Fetch all Jira issue states from the database.
     */
    async getJiraIssueStates() {
        return query(`SELECT
        jmp.jira_project_key AS project_key,
        jis.issue_key,
        jis.last_known_status,
        jis.last_updated_at
       FROM jira_issue_states jis
       JOIN jira_monitored_projects jmp ON jis.jira_monitored_project_id = jmp.id
       JOIN jira_projects jp ON jmp.jira_project_id = jp.id
       ORDER BY jis.last_updated_at DESC`);
    }
    /**
     * Upsert a Jira issue state record.
     * Creates the record if it doesn't exist, updates if it does.
     */
    async upsertJiraIssueState(input) {
        // Look up the monitored project ID from the project key
        const monitoredRows = await query(`SELECT jmp.id
       FROM jira_monitored_projects jmp
       JOIN jira_projects jp ON jmp.jira_project_id = jp.id
       WHERE jmp.jira_project_key = $1
       LIMIT 1`, [input.jiraProjectKey]);
        const monitoredId = monitoredRows[0]?.id;
        if (!monitoredId) {
            console.warn(`[PostgresAdapter] No monitored project found for key: ${input.jiraProjectKey}`);
        }
    }
    // -------------------------------------------------------------------------
    // Jira project operations (TRD-013)
    // -------------------------------------------------------------------------
    /**
     * List Jira project configurations for a Foreman project.
     */
    async listJiraProjects(projectId) {
        return query(`SELECT id, project_id, api_url, email, poll_interval_seconds, webhook_enabled, last_poll_at, webhook_secret_encrypted
       FROM jira_projects
       WHERE project_id = $1`, [projectId]);
    }
    /**
     * Get observability metrics for Jira monitoring (TRD-028).
     */
    async getJiraMetrics(projectId, jiraProjectKey) {
        const countResult = await query(`SELECT COUNT(*)::text AS count
       FROM jira_issue_states
       WHERE jira_project_key = $1 AND project_id = $2`, [jiraProjectKey, projectId]);
        const monitoredIssues = parseInt(countResult[0]?.count ?? "0", 10);
        const todayResult = await query(`SELECT COUNT(*)::text AS count
       FROM jira_issue_states
       WHERE jira_project_key = $1
         AND project_id = $2
         AND last_triggered_at IS NOT NULL
         AND last_triggered_at > NOW() - INTERVAL '24 hours'`, [jiraProjectKey, projectId]);
        const triggeredToday = parseInt(todayResult[0]?.count ?? "0", 10);
        const errorResult = await query(`SELECT last_error FROM jira_monitored_projects
       WHERE jira_project_key = $1 AND project_id = $2`, [jiraProjectKey, projectId]);
        return {
            monitoredIssues,
            triggeredToday,
            lastError: errorResult[0]?.last_error ?? undefined,
        };
    }
}
// ---------------------------------------------------------------------------
// Named export
// ---------------------------------------------------------------------------
export const Database = { Adapter: PostgresAdapter };
//# sourceMappingURL=postgres-adapter.js.map