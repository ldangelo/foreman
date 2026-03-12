// ── Orchestrator types ───────────────────────────────────────────────────

export type RuntimeSelection = "claude-code";

export type ModelSelection = "claude-opus-4-6" | "claude-sonnet-4-6" | "claude-haiku-4-5-20251001";

export type AgentRole = "lead" | "explorer" | "developer" | "qa" | "reviewer" | "worker";

// ── Decomposition types ─────────────────────────────────────────────────

export type TaskComplexity = "low" | "medium" | "high";
export type IssueType = "task" | "spike" | "test";
export type Priority = "critical" | "high" | "medium" | "low";

export interface TaskPlan {
  title: string;
  description: string;
  type: IssueType;
  priority: Priority;
  dependencies: string[]; // titles of other tasks this depends on
  estimatedComplexity: TaskComplexity;
}

export interface StoryPlan {
  title: string;
  description: string;
  priority: Priority;
  tasks: TaskPlan[];
}

export interface SprintPlan {
  title: string;
  goal: string;
  stories: StoryPlan[];
}

export interface DecompositionPlan {
  epic: {
    title: string;
    description: string;
  };
  sprints: SprintPlan[];
}

export interface SeedInfo {
  id: string;
  title: string;
  description?: string;
  priority?: string;
  type?: string;
}

/** @deprecated Use SeedInfo instead */
export type BeadInfo = SeedInfo;

export interface DispatchedTask {
  seedId: string;
  title: string;
  runtime: RuntimeSelection;
  model: ModelSelection;
  worktreePath: string;
  runId: string;
  branchName: string;
}

export interface SkippedTask {
  seedId: string;
  title: string;
  reason: string;
}

export interface DispatchResult {
  dispatched: DispatchedTask[];
  skipped: SkippedTask[];
  resumed: ResumedTask[];
  activeAgents: number;
}

export interface ResumedTask {
  seedId: string;
  title: string;
  model: ModelSelection;
  runId: string;
  sessionId: string;
  previousStatus: string;
}

// ── Plan step types ───────────────────────────────────────────────────

export interface PlanStepDefinition {
  name: string;
  command: string;
  description: string;
  input: string;
}

export interface PlanStepDispatched {
  seedId: string;
  title: string;
  runId: string;
  sessionKey: string;
}

// ── Monitor types ──────────────────────────────────────────────────────

export interface MonitorReport {
  completed: import("../lib/store.js").Run[];
  stuck: import("../lib/store.js").Run[];
  active: import("../lib/store.js").Run[];
  failed: import("../lib/store.js").Run[];
}

// ── Refinery types ─────────────────────────────────────────────────────

export interface MergedRun {
  runId: string;
  seedId: string;
  branchName: string;
}

export interface ConflictRun {
  runId: string;
  seedId: string;
  branchName: string;
  conflictFiles: string[];
}

export interface FailedRun {
  runId: string;
  seedId: string;
  branchName: string;
  error: string;
}

export interface MergeReport {
  merged: MergedRun[];
  conflicts: ConflictRun[];
  testFailures: FailedRun[];
  /** PRs created for branches that had code conflicts */
  prsCreated: CreatedPr[];
}

export interface CreatedPr {
  runId: string;
  seedId: string;
  branchName: string;
  prUrl: string;
}

export interface PrReport {
  created: CreatedPr[];
  failed: FailedRun[];
}

// ── Worker Notification types ─────────────────────────────────────────────

export interface WorkerStatusNotification {
  type: "status";
  runId: string;
  status: import("../lib/store.js").Run["status"];
  timestamp: string;
  details?: Record<string, unknown>;
}

export interface WorkerProgressNotification {
  type: "progress";
  runId: string;
  progress: import("../lib/store.js").RunProgress;
  timestamp: string;
}

export type WorkerNotification = WorkerStatusNotification | WorkerProgressNotification;

// ── Doctor types ────────────────────────────────────────────────────────

export type CheckStatus = "pass" | "warn" | "fail" | "fixed" | "skip";

export interface CheckResult {
  name: string;
  status: CheckStatus;
  message: string;
  fixApplied?: string;
}

export interface DoctorReport {
  system: CheckResult[];
  repository: CheckResult[];
  dataIntegrity: CheckResult[];
  summary: {
    pass: number;
    warn: number;
    fail: number;
    fixed: number;
    skip: number;
  };
}
