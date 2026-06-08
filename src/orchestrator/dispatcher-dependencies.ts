/**
 * Dispatcher dependency facade.
 *
 * Encapsulates all dependencies that the Dispatcher needs to function.
 * This file defines the minimal interface surface that dispatcher.ts
 * depends on, reducing coupling from35+ direct imports to a stable set
 * of interface-only dependencies.
 */

import type { ITaskClient, Issue } from "../lib/task-client.js";
import type { ForemanStore } from "../lib/store.js";
import type { BvClient } from "../lib/bv.js";
import type { VcsBackend } from "../lib/vcs/index.js";
import type { NativeTask } from "../lib/store.js";
import type { RunStoreReadModel } from "./read-models.js";
import type { RunCommands, RunFactory } from "./write-models.js";
import type { ModelSelection, RuntimeSelection } from "./types.js";
import type { RuntimeMode } from "../cli/commands/run.js";

// ── Task store interface ───────────────────────────────────────────────────

/**
 * Interface for task store operations used by the dispatcher.
 * Abstracts over native Postgres tasks and Beads.
 */
export interface TaskStoreOps {
  /** Check whether the store has any tasks. */
  hasNativeTasks(): Promise<boolean>;
  /** Get all tasks in a ready state. */
  getReadyTasks(): Promise<NativeTask[]>;
  /** Get a task by its external ID. */
  getTaskByExternalId(externalId: string): Promise<NativeTask | null>;
  /** Get a task by its ID. */
  getTaskById(id: string): Promise<NativeTask | null>;
  /** Claim a task for a run. */
  claimTask(taskId: string, runId: string): Promise<boolean>;
  /** Update a task's status. */
  updateTaskStatus?(taskId: string, status: string): Promise<void>;
}

// ── Run operations interface ───────────────────────────────────────────────

/**
 * Interface for run write operations.
 * Used when the dispatcher operates in external project mode.
 */
export interface RunOps {
  createRun(args: {
    runId: string;
    projectId: string;
    seedId: string;
    agentType: string;
    branchName: string;
    worktreePath: string | null;
    baseBranch?: string | null;
    mergeStrategy?: string | null;
  }): Promise<{ id: string } | void>;
  updateRun(
    runId: string,
    updates: {
      status?: string;
      sessionKey?: string | null;
      worktreePath?: string | null;
      startedAt?: string | null;
      completedAt?: string | null;
    },
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

// ── Dispatcher overrides ───────────────────────────────────────────────────

/**
 * Optional overrides for dispatcher behavior.
 * Allows tests and external callers to inject mock implementations.
 */
export interface DispatcherOverrides {
  /** Custom implementation for counting recent failures. */
  getRecentFailureCount?: (projectId: string, since: string) => Promise<number>;
  /** Custom task store operations. */
  nativeTaskOps?: TaskStoreOps;
  /** Get active seed IDs. */
  getActiveSeedIds?: () => Promise<string[]>;
  /** Check if a seed has an active or pending run. */
  hasActiveOrPendingRun?: (seedId: string) => Promise<boolean>;
  /** Get count of active agents. */
  getActiveAgentCount?: () => Promise<number>;
  /** External project ID when operating in external mode. */
  externalProjectId?: string;
  /** Custom run queries. */
  getRunsByStatus?: (status: string, projectId: string) => Promise<{ status: string }[]>;
  getRunsForSeed?: (seedId: string, projectId: string) => Promise<{ id: string }[]>;
  getRun?: (runId: string) => Promise<{ id: string; status: string } | null>;
  getActiveRuns?: (projectId: string) => Promise<{ id: string }[]>;
  /** Custom run write operations (required when externalProjectId is set). */
  runOps?: RunOps;
}

// ── Dispatcher dependencies ────────────────────────────────────────────────

/**
 * Complete dependency interface for the Dispatcher.
 * All concrete dependencies are injected through this interface.
 */
export interface DispatcherDeps {
  /** Task client for querying seeds/tasks. */
  taskClient: ITaskClient;
  /** Read model for accessing run data. */
  storeReadModel: RunStoreReadModel;
  /** Commands for mutating run records. */
  runCommands: RunCommands;
  /** Factory for creating new runs. */
  runFactory: RunFactory;
  /** VCS backend for version control operations. */
  vcsBackend: VcsBackend;
  /** Project path for workspace operations. */
  projectPath: string;
  /** Optional BV client for beads operations. */
  bvClient?: BvClient | null;
  /** Optional overrides for testing/external use. */
  overrides?: DispatcherOverrides;
}

// ── Convenience types for common patterns ────────────────────────────────

/** Dispatch options mirroring the Dispatcher.dispatch() API. */
export interface DispatchOptions {
  maxAgents?: number;
  runtime?: RuntimeSelection;
  runtimeMode?: RuntimeMode;
  model?: ModelSelection;
  dryRun?: boolean;
  telemetry?: boolean;
  projectId?: string;
  pipeline?: boolean;
  skipExplore?: boolean;
  skipReview?: boolean;
  seedId?: string;
  notifyUrl?: string;
  targetBranch?: string;
  staggerMs?: number;
}

/** Result of a dispatch operation. */
export interface DispatchResult {
  dispatched: Array<{
    seedId: string;
    title: string;
    runtime: RuntimeSelection;
    model: ModelSelection;
    worktreePath: string;
    runId: string;
    branchName: string;
  }>;
  skipped: Array<{
    seedId: string;
    title: string;
    reason: string;
  }>;
  resumed: Array<{
    seedId: string;
    title: string;
    model: ModelSelection;
    runId: string;
    sessionId: string;
    previousStatus: string;
  }>;
  activeAgents: number;
}
