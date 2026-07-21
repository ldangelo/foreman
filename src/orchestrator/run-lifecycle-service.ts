/**
 * Run lifecycle service.
 *
 * Encapsulates run create/update/log/mail operations for the dispatcher.
 * Uses narrow interfaces to reduce coupling to the full store.
 */

import { randomUUID } from "node:crypto";
import type { Run, EventType } from "../lib/store.js";
import type { RunStore, ProgressEventStore } from "../lib/store.js";

// ── Narrow interfaces ─────────────────────────────────────────────────────

/**
 * Narrow interface for mail sending (only method used by lifecycle service).
 */
export interface MailSendStore {
  sendMessage(
    runId: string,
    senderAgentType: string,
    recipientAgentType: string,
    subject: string,
    body: string,
  ): Promise<void>;
}

/**
 * Override-backed run operations for external project mode.
 */
export interface RunOpsOverrides {
  createRun(args: {
    runId: string;
    projectId: string;
    taskId: string;
    agentType: string;
    branchName: string;
    worktreePath: string | null;
    baseBranch?: string | null;
    mergeStrategy?: string | null;
  }): Promise<Run | void>;
  updateRun(
    runId: string,
    updates: Partial<Pick<Run, "status" | "session_key" | "worktree_path" | "started_at" | "completed_at">>,
  ): Promise<void>;
  sendMessage(
    runId: string,
    senderAgentType: string,
    recipientAgentType: string,
    subject: string,
    body: string,
  ): Promise<void>;
  logEvent(
    runId: string,
    projectId: string,
    eventType: string,
    payload: Record<string, unknown>,
  ): Promise<void>;
}

/**
 * Configuration for run lifecycle service.
 */
export interface RunLifecycleConfig {
  /** External project ID when operating in external mode. */
  externalProjectId?: string;
  /** Override run operations for external project mode. */
  runOps?: RunOpsOverrides;
  /** Override for fetching a run by ID (used in external mode to check terminal success). */
  getRun?: (runId: string) => Promise<Run | null>;
}

// ── Run lifecycle service ─────────────────────────────────────────────────

/**
 * Service encapsulating run lifecycle operations.
 * Handles run create/update/log/mail with support for both local store
 * and external project overrides.
 *
 * Note: Read operations (getActiveRuns, getRunsByStatus, etc.) are delegated
 * directly to the store. The dispatcher is responsible for checking override
 * hooks (DispatcherOverrides) before calling read methods.
 */
export class RunLifecycleService {
  constructor(
    private runStore: RunStore,
    private progressEventStore: ProgressEventStore,
    private mailStore: MailSendStore,
    private config?: RunLifecycleConfig,
  ) {}

  /**
   * Require a registered run op, throwing if not present in external mode.
   */
  private requireRegisteredRunOp<K extends keyof RunOpsOverrides>(
    method: K,
  ): NonNullable<RunOpsOverrides[K]> {
    const op = this.config?.runOps?.[method];
    if (op) {
      return op as NonNullable<RunOpsOverrides[K]>;
    }

    const projectId = this.config?.externalProjectId;
    throw new Error(
      `Registered dispatcher write override missing runOps.${String(method)} for project ${projectId ?? "unknown"}`,
    );
  }

  /**
   * Validate that required run ops are registered in external mode.
   */
  validateRegisteredRunOps(requiredMethods: Array<keyof RunOpsOverrides>): void {
    if (!this.config?.externalProjectId) return;

    for (const method of requiredMethods) {
      this.requireRegisteredRunOp(method);
    }
  }

  /**
   * Map internal run status to external project status.
   */
  private mapRunStatusForExternal(status: Run["status"]): "pending" | "running" | "success" | "failure" | "cancelled" | "skipped" | null {
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
        return null;
    }
  }

  /**
   * Check whether to preserve terminal success status.
   * Terminal success (merged, pr-created) should not be downgraded to failed/stuck.
   */
  private shouldPreserveTerminalSuccess(
    currentStatus: Run["status"] | undefined,
    nextStatus: Run["status"] | undefined,
  ): boolean {
    return (
      currentStatus !== undefined &&
      nextStatus !== undefined &&
      (currentStatus === "merged" || currentStatus === "pr-created") &&
      (nextStatus === "failed" || nextStatus === "stuck")
    );
  }

  // ── Run lifecycle operations ───────────────────────────────────────────

  /**
   * Create a new run record.
   */
  async createRunRecord(
    projectId: string,
    taskId: string,
    agentType: string,
    worktreePath: string | null,
    branchName: string,
    opts?: {
      baseBranch?: string | null;
      mergeStrategy?: Run["merge_strategy"];
      sessionKey?: string | null;
    },
  ): Promise<Run> {
    if (this.config?.externalProjectId) {
      const createRun = this.requireRegisteredRunOp("createRun");
      const runId = randomUUID();
      const createdAt = new Date().toISOString();
      const run = await createRun({
        runId,
        projectId,
        taskId,
        agentType,
        branchName,
        worktreePath,
        baseBranch: opts?.baseBranch ?? null,
        mergeStrategy: opts?.mergeStrategy ?? null,
      });
      if (run) {
        return run;
      }
      return {
        id: runId,
        project_id: projectId,
        task_id: taskId,
        agent_type: agentType,
        session_key: null,
        worktree_path: worktreePath,
        status: "pending",
        started_at: null,
        completed_at: null,
        created_at: createdAt,
        progress: null,
        tmux_session: null,
        base_branch: opts?.baseBranch ?? null,
        merge_strategy: opts?.mergeStrategy ?? "auto",
      };
    }

    const run = this.runStore.createRun(projectId, taskId, agentType, worktreePath ?? undefined, opts ? {
      ...opts,
      mergeStrategy: opts.mergeStrategy ?? undefined,
    } : undefined);
    return run;
  }

  /**
   * Update a run record.
   */
  async updateRunRecord(
    runId: string,
    updates: Partial<Pick<Run, "status" | "session_key" | "worktree_path" | "started_at" | "completed_at" | "route_to">>,
  ): Promise<void> {
    if (this.config?.externalProjectId) {
      const currentRun = this.config.getRun
        ? await this.config.getRun(runId)
        : null;
      if (this.shouldPreserveTerminalSuccess(currentRun?.status, updates.status)) {
        return;
      }

      const updateRun = this.requireRegisteredRunOp("updateRun");
      const normalized = { ...updates };
      if (updates.status) {
        const mapped = this.mapRunStatusForExternal(updates.status);
        if (!mapped) return;
        normalized.status = mapped as Run["status"];
      }
      await updateRun(runId, normalized);
      return;
    }

    // Check if getRun is available (some store implementations may not have it)
    const currentRun = "getRun" in this.runStore
      ? await this.runStore.getRun(runId)
      : null;
    if (this.shouldPreserveTerminalSuccess(currentRun?.status, updates.status)) {
      return;
    }

    await this.runStore.updateRun(runId, updates);
  }

  /**
   * Send a mail message.
   */
  async sendMailRecord(
    runId: string,
    senderAgentType: string,
    recipientAgentType: string,
    subject: string,
    body: string,
  ): Promise<void> {
    if (this.config?.externalProjectId) {
      const sendMessage = this.requireRegisteredRunOp("sendMessage");
      await sendMessage(runId, senderAgentType, recipientAgentType, subject, body);
      return;
    }

    await this.mailStore.sendMessage(runId, senderAgentType, recipientAgentType, subject, body);
  }

  /**
   * Log an event.
   */
  async logEventRecord(
    projectId: string,
    eventType: EventType,
    payload: Record<string, unknown>,
    runId: string,
  ): Promise<void> {
    if (this.config?.externalProjectId) {
      const logEvent = this.requireRegisteredRunOp("logEvent");
      await logEvent(runId, projectId, eventType, payload);
      return;
    }

    await this.progressEventStore.logEvent(projectId, eventType, payload, runId);
  }

  // ── Run query operations ───────────────────────────────────────────────

  /**
   * Get active runs for a project.
   */
  async getActiveRunsRecord(projectId: string): Promise<Run[]> {
    return this.runStore.getActiveRuns(projectId);
  }

  /**
   * Get runs by status for a project.
   */
  async getRunsByStatusRecord(
    status: Run["status"],
    projectId: string,
  ): Promise<Run[]> {
    return this.runStore.getRunsByStatus(status, projectId);
  }

  /**
   * Get runs for a task.
   */
  async getRunsForTaskRecord(
    taskId: string,
    projectId: string,
  ): Promise<Run[]> {
    return this.runStore.getRunsForTask(taskId, projectId);
  }

  /**
   * Get a run by ID.
   */
  async getRunRecord(runId: string): Promise<Run | null> {
    return this.runStore.getRun(runId);
  }
}
