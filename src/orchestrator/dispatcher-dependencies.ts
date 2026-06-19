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
import type { BeadWriteEntry, NativeTask, Run, EventType } from "../lib/store.js";
import type { RunStoreReadModel } from "./read-models.js";
import type { RunCommands, RunFactory } from "./write-models.js";
import type { ModelSelection, RuntimeSelection, NativeTaskStatus } from "./types.js";
import type { RuntimeMode } from "../cli/commands/run.js";
import type { Project } from "../lib/store.js";

// ── Awaitable helper ──────────────────────────────────────────────────────

/** Type that can be sync or async. */
export type Awaitable<T> = T | Promise<T>;

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
  updateTaskStatus?(taskId: string, status: NativeTaskStatus): Promise<void>;
}

// ── Dispatcher store deps (narrow interface) ──────────────────────────────

/**
 * Narrow interface capturing only the store methods the Dispatcher uses.
 * Replaces the full ForemanStore dependency to reduce coupling.
 *
 * Task operations (native-only path):
 * - getReadyTasks, getTaskByExternalId, getTaskById, claimTask, updateTaskLabels
 *
 * Run operations:
 * - createRun, getRun, updateRun, getActiveRuns, getRunsByStatus,
 *   getRunsForSeed, getRunsByStatusesSince
 *
 * Event/mail operations:
 * - logEvent, sendMessage
 *
 * Project operations:
 * - getProjectByPath
 *
 * Query operations:
 * - hasActiveOrPendingRun
 */
export interface DispatcherStoreDeps {
  // Task operations (native-only path)
  /** Get all tasks in a ready state. */
  getReadyTasks(): Awaitable<NativeTask[]>;
  /** Get a task by its external ID. */
  getTaskByExternalId(externalId: string): Awaitable<NativeTask | null>;
  /** Get a task by its ID. */
  getTaskById(id: string): Awaitable<NativeTask | null>;
  /** Claim a task for a run (returns true if claimed successfully). */
  claimTask(taskId: string, runId: string): Awaitable<boolean>;
  /** Update task labels. */
  updateTaskLabels?(taskId: string, labels: string[]): Awaitable<void>;
  /** Update task status. */
  updateTaskStatus?(taskId: string, status: string): Awaitable<void>;

  // Run operations
  /** Create a new run record. */
  createRun(
    projectId: string,
    seedId: string,
    agentType: string,
    worktreePath?: string | null | undefined,
    opts?: {
      baseBranch?: string | null;
      mergeStrategy?: string | null;
      sessionKey?: string | null;
    },
  ): Awaitable<Run>;
  /** Get a run by ID. */
  getRun(runId: string): Awaitable<Run | null>;
  /** Update a run record. */
  updateRun(
    runId: string,
    updates: Partial<Pick<Run, "status" | "session_key" | "worktree_path" | "started_at" | "completed_at">>,
  ): Awaitable<void>;
  /** Get all active runs (pending or running). */
  getActiveRuns(projectId?: string): Awaitable<Run[]>;
  /** Get runs by status. */
  getRunsByStatus(status: Run["status"], projectId?: string): Awaitable<Run[]>;
  /** Get runs for a seed. */
  getRunsForSeed(seedId: string, projectId?: string): Awaitable<Run[]>;
  /** Get runs matching any of the given statuses created on or after `since`. */
  getRunsByStatusesSince(
    statuses: Run["status"][],
    since: string,
    projectId?: string,
  ): Awaitable<Run[]>;

  // Event/mail operations
  /** Log an event. */
  logEvent(
    projectId: string,
    eventType: EventType,
    details: Record<string, unknown> | string,
    runId?: string
  ): Awaitable<void>;
  /** Send a message. */
  sendMessage(
    runId: string,
    senderAgentType: string,
    recipientAgentType: string,
    subject: string,
    body: string,
  ): Awaitable<unknown>;
  /** Update run progress. */
  updateRunProgress(runId: string, progress: unknown): Awaitable<void>;
  /** Get run progress. */
  getRunProgress(runId: string): Awaitable<unknown>;
  /** Get events for a run. */
  getEvents(runId: string): Awaitable<unknown[]>;

  // Project operations
  /** Get project by path. */
  getProjectByPath(path: string): Awaitable<Project | null>;

  // Query operations
  /** Check if a seed has an active or pending run. */
  hasActiveOrPendingRun(seedId: string, projectId?: string): Awaitable<boolean>;
  /** Pending serialized bead write operations. */
  getPendingBeadWrites?(): Awaitable<BeadWriteEntry[]>;
  /** Mark a serialized bead write operation processed. */
  markBeadWriteProcessed?(id: string): Awaitable<boolean>;
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
  /** Explicit workflow name override (from `foreman run --workflow <name>`). */
  workflow?: string;
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
