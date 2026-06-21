/**
 * Read model interfaces for the orchestrator.
 *
 * These interfaces define the read-only contracts that orchestrator modules
 * use to access store data. Internal type changes in the store implementation
 * should not leak across these boundaries.
 *
 * Key principle: orchestrator modules never construct Run/RunProgress objects,
 * they only read through these interfaces.
 */

// ── Core types ─────────────────────────────────────────────────────────────

/** Valid run statuses across the system. */
export type RunStatus =
  | "pending"
  | "running"
  | "completed"
  | "failed"
  | "stuck"
  | "cooldown"
  | "merged"
  | "conflict"
  | "test-failed"
  | "pr-created"
  | "reset";

/** Per-run merge strategy selection. */
export type MergeStrategy = "auto" | "pr" | "none";

/** GitHub PR state for a run's PR. */
export type PrState = "none" | "draft" | "open" | "merged" | "closed";

// ── Run read model ─────────────────────────────────────────────────────────

/**
 * Read-only summary of a run record.
 * Used by orchestrator modules that only need to read run data.
 */
export interface RunSummary {
  id: string;
  taskId: string;
  agentType: string;
  status: RunStatus;
  worktreePath: string | null;
  baseBranch: string | null;
  mergeStrategy: MergeStrategy | null;
  commitSha: string | null;
  prUrl: string | null;
  prState: PrState | null;
  prHeadSha: string | null;
  startedAt: string | null;
  completedAt: string | null;
  /** ISO timestamp when the run was created. */
  createdAt: string;
  /** Serialized progress JSON string, or null if not set. */
  progress: string | null;
  /** Whether this run has been archived (hidden from default views). */
  archived: boolean;
}

// ── RunProgress read model ─────────────────────────────────────────────────

/**
 * Read-only summary of run progress.
 * Derived from the serialized progress JSON stored in runs.progress.
 */
export interface RunProgressSummary {
  toolCalls: number;
  toolBreakdown: Record<string, number>;
  filesChanged: string[];
  turns: number;
  costUsd: number;
  tokensIn: number;
  tokensOut: number;
  lastToolCall: string | null;
  lastActivity: string;
  currentPhase?: string;
  costByPhase?: Record<string, number>;
  agentByPhase?: Record<string, string>;
  qaValidatedTargetBranch?: string;
  qaValidatedTargetRef?: string;
  qaValidatedHeadRef?: string;
  currentTargetRef?: string;
  epicTaskCount?: number;
  epicTasksCompleted?: number;
  epicCurrentTaskId?: string;
  epicCostByTask?: Record<string, number>;
}

// ── Read model interface ───────────────────────────────────────────────────

/**
 * Options for filtering runs in read operations.
 */
export interface RunFilterOptions {
  /** Include archived runs in results. Default: false (excludes archived). */
  includeArchived?: boolean;
}

/**
 * Read-only interface for accessing run data.
 * Store implementations (ForemanStore, PostgresStore, etc.) must satisfy this.
 */
export interface RunStoreReadModel {
  /** Fetch a single run by ID. Returns null if not found. */
  getRun(runId: string): Promise<RunSummary | null>;

  /** Fetch all runs for a given task. */
  getRunsForSeed(taskId: string, projectId?: string, opts?: RunFilterOptions): Promise<RunSummary[]>;

  /** Fetch all active runs (pending or running). */
  getActiveRuns(projectId?: string, opts?: RunFilterOptions): Promise<RunSummary[]>;

  /** Fetch runs by status. */
  getRunsByStatus(status: RunStatus, projectId?: string, opts?: RunFilterOptions): Promise<RunSummary[]>;

  /** Fetch runs matching any of the given statuses. */
  getRunsByStatuses(statuses: RunStatus[], projectId?: string, opts?: RunFilterOptions): Promise<RunSummary[]>;

  /** Fetch runs matching any of the given statuses created on or after `since`. */
  getRunsByStatusesSince(statuses: RunStatus[], since: string, projectId?: string, opts?: RunFilterOptions): Promise<RunSummary[]>;

  /** Fetch recent active runs (pending/running or failed within last 30 days), excluding archived. */
  getRecentActiveRuns(projectId?: string): Promise<RunSummary[]>;

  /** Check whether a task has a non-terminal run. */
  hasActiveOrPendingRun(taskId: string, projectId?: string): Promise<boolean>;

  /** Get run progress for a run. Returns null if not set. */
  getRunProgress(runId: string): Promise<RunProgressSummary | null>;

  /** Archive a set of runs by their IDs. */
  archiveRuns(runIds: string[], projectId?: string): Promise<number>;
}
