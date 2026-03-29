// ── Orchestrator types ───────────────────────────────────────────────────

export type RuntimeSelection = "claude-code";

export type ModelSelection = "anthropic/claude-opus-4-6" | "anthropic/claude-sonnet-4-6" | "anthropic/claude-haiku-4-5";

export type AgentRole = "lead" | "explorer" | "developer" | "qa" | "reviewer" | "finalize" | "worker" | "sentinel" | "troubleshooter";

export type Priority = "critical" | "high" | "medium" | "low";

export interface SeedInfo {
  id: string;
  title: string;
  description?: string;
  priority?: string;
  type?: string;
  labels?: string[];
  comments?: string | null;
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
  resolvedTiers?: Map<string, number>;
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

// ── Sling types ─────────────────────────────────────────────────────────

export type TrdTaskStatus = "open" | "in_progress" | "completed";
export type RiskLevel = "high" | "medium";

export interface TrdTask {
  trdId: string;
  title: string;
  estimateHours: number;
  dependencies: string[];
  files: string[];
  status: TrdTaskStatus;
  riskLevel?: RiskLevel;
}

export interface TrdStory {
  title: string;
  frNumber?: string;
  tasks: TrdTask[];
  acceptanceCriteria?: string;
}

export interface TrdSprint {
  number: number;
  title: string;
  goal: string;
  priority: Priority;
  stories: TrdStory[];
  summary?: {
    focus: string;
    estimatedHours: number;
    deliverables: string;
  };
}

export interface SlingPlan {
  epic: {
    title: string;
    description: string;
    documentId: string;
    qualityNotes?: string;
  };
  sprints: TrdSprint[];
  acceptanceCriteria: Map<string, string>;
  riskMap: Map<string, RiskLevel>;
}

export interface ParallelGroup {
  label: string;
  sprintIndices: number[];
}

export interface ParallelResult {
  groups: ParallelGroup[];
  warnings: string[];
}

export interface SlingOptions {
  dryRun: boolean;
  auto: boolean;
  json: boolean;
  sdOnly: boolean;
  brOnly: boolean;
  skipCompleted: boolean;
  closeCompleted: boolean;
  noParallel: boolean;
  force: boolean;
  noRisks: boolean;
  noQuality: boolean;
  priorityMap?: Record<string, string>;
}

export interface TrackerResult {
  created: number;
  skipped: number;
  failed: number;
  epicId: string | null;
  errors: string[];
}

export interface SlingResult {
  sd: TrackerResult | null;
  br: TrackerResult | null;
  depErrors: string[];
}

// ── Sentinel types ───────────────────────────────────────────────────────

export interface SentinelConfig {
  branch: string;
  testCommand: string;
  intervalMinutes: number;
  failureThreshold: number;
  enabled: boolean;
}

export interface SentinelRunRecord {
  id: string;
  project_id: string;
  branch: string;
  commit_hash: string | null;
  status: "running" | "passed" | "failed" | "error";
  test_command: string;
  output: string | null;
  failure_count: number;
  started_at: string;
  completed_at: string | null;
}

export interface SentinelResult {
  id: string;
  status: "passed" | "failed" | "error";
  commitHash: string | null;
  output: string;
  durationMs: number;
}

// ── Doctor types ────────────────────────────────────────────────────────

export type CheckStatus = "pass" | "warn" | "fail" | "fixed" | "skip";

export interface CheckResult {
  name: string;
  status: CheckStatus;
  message: string;
  fixApplied?: string;
  details?: string;
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
