// ── Orchestrator types ───────────────────────────────────────────────────

export type RuntimeSelection = "claude-code" | "pi" | "codex";

// ── Decomposition types ─────────────────────────────────────────────────

export type TaskComplexity = "low" | "medium" | "high";

export interface TaskPlan {
  title: string;
  description: string;
  priority: "critical" | "high" | "medium" | "low";
  dependencies: string[]; // titles of other tasks this depends on
  estimatedComplexity: TaskComplexity;
}

export interface DecompositionPlan {
  epic: {
    title: string;
    description: string;
  };
  tasks: TaskPlan[];
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
