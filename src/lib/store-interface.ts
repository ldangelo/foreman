/**
 * Common interface for task stores.
 * Both ForemanStore (SQLite) and PostgresStore implement this interface.
 */

import type {
  Project,
  Run,
  NativeTask,
  EventType,
  RunProgress,
} from "./store.js";

export interface IStore {
  readonly projectId: string;

  // Lifecycle
  close(): void;

  // Tasks
  listTasksByStatus(statuses: string[], limit?: number): Promise<NativeTask[]>;
  updateTaskStatus(taskId: string, newStatus: string): Promise<void>;
  getTaskById(id: string): Promise<NativeTask | null>;
  getTaskByExternalId(externalId: string): Promise<NativeTask | null>;
  hasNativeTasks(): Promise<boolean>;
  claimTaskAsync(taskId: string, runId: string): Promise<boolean>;

  // Projects
  getProject(id: string): Promise<Project | null>;
  getProjectByPath(path: string): Promise<Project | null>;
  listProjects(status?: string): Promise<Project[]>;
  updateProject(id: string, updates: Partial<Pick<Project, "name" | "path" | "status">>): Promise<void>;

  // Runs
  createRun(
    projectId: string,
    seedId: string,
    agentType: string,
    worktreePath: string | null,
    opts?: {
      baseBranch?: string | null;
      mergeStrategy?: string | null;
      sessionKey?: string | null;
    },
  ): Promise<Run>;
  updateRun(
    runId: string,
    updates: Partial<Pick<Run, "status" | "worktree_path" | "session_key" | "started_at" | "completed_at">>,
  ): Promise<void>;
  getRun(id: string): Promise<Run | null>;
  getActiveRuns(projectId?: string): Promise<Run[]>;
  getRunsByStatus(status: Run["status"], projectId?: string): Promise<Run[]>;
  getRunsByStatuses(statuses: Run["status"][], projectId?: string): Promise<Run[]>;
  getRunsByStatusesSince(statuses: Run["status"][], since: string, projectId?: string): Promise<Run[]>;
  getRunsByStatusSince(status: Run["status"], since: string, projectId?: string): Promise<Run[]>;
  purgeOldRuns(olderThan: string, projectId?: string): Promise<number>;
  deleteRun(runId: string): Promise<boolean>;
  getRunsForSeed(seedId: string, projectId?: string): Promise<Run[]>;
  hasActiveOrPendingRun(seedId: string, projectId?: string): Promise<boolean>;
  getRunsByBaseBranch(baseBranch: string, projectId?: string): Promise<Run[]>;

  // Events
  logEvent(projectId: string, eventType: EventType, data: Record<string, unknown>, runId?: string): Promise<void>;

  // Costs
  recordCost(runId: string, tokensIn: number, tokensOut: number, cacheRead: number, estimatedCost: number): Promise<void>;

  // Progress
  updateRunProgress(runId: string, progress: RunProgress): Promise<void>;
  getRunProgress(runId: string): Promise<RunProgress | null>;

  // Messaging
  sendMessage(
    runId: string,
    senderAgentType: string,
    recipientAgentType: string,
    subject: string,
    body: string,
  ): Promise<void>;
}
