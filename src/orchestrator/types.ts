// ── Orchestrator types ───────────────────────────────────────────────────

export type RuntimeSelection = "claude-code" | "pi" | "codex";

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

export interface BeadInfo {
  id: string;
  title: string;
  description?: string;
  priority?: string;
  type?: string;
}

export interface DispatchedTask {
  beadId: string;
  title: string;
  runtime: RuntimeSelection;
  worktreePath: string;
  runId: string;
  branchName: string;
}

export interface SkippedTask {
  beadId: string;
  title: string;
  reason: string;
}

export interface DispatchResult {
  dispatched: DispatchedTask[];
  skipped: SkippedTask[];
  activeAgents: number;
}

// ── Plan step types ───────────────────────────────────────────────────

export interface PlanStepDefinition {
  name: string;
  command: string;
  description: string;
  input: string;
}

export interface PlanStepDispatched {
  beadId: string;
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
  beadId: string;
  branchName: string;
}

export interface ConflictRun {
  runId: string;
  beadId: string;
  branchName: string;
  conflictFiles: string[];
}

export interface FailedRun {
  runId: string;
  beadId: string;
  branchName: string;
  error: string;
}

export interface MergeReport {
  merged: MergedRun[];
  conflicts: ConflictRun[];
  testFailures: FailedRun[];
}
