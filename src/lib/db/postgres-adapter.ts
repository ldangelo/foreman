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
   * @throws Error("not implemented")
   */
  async createProject(metadata: ProjectMetadata): Promise<ProjectRow> {
    throw new Error("not implemented");
  }

  /**
   * List all projects, optionally filtered by status.
   * @throws Error("not implemented")
   */
  async listProjects(filters?: {
    status?: "active" | "paused" | "archived";
    search?: string;
  }): Promise<ProjectRow[]> {
    throw new Error("not implemented");
  }

  /**
   * Get a single project by ID.
   * @throws Error("not implemented")
   */
  async getProject(projectId: string): Promise<ProjectRow | null> {
    throw new Error("not implemented");
  }

  /**
   * Update project fields.
   * @throws Error("not implemented")
   */
  async updateProject(
    projectId: string,
    updates: Partial<Pick<ProjectRow, "name" | "path" | "status" | "github_url" | "default_branch">>
  ): Promise<void> {
    throw new Error("not implemented");
  }

  /**
   * Remove (archive) a project.
   * @throws Error("not implemented")
   */
  async removeProject(
    projectId: string,
    options?: { force?: boolean }
  ): Promise<void> {
    throw new Error("not implemented");
  }

  /**
   * Sync a project (git fetch + update last_sync timestamp).
   * @throws Error("not implemented")
   */
  async syncProject(projectId: string): Promise<void> {
    throw new Error("not implemented");
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
