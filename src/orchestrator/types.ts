// ── Orchestrator types ───────────────────────────────────────────────────

export type RuntimeSelection = "claude-code";

export type ModelSelection = "claude-opus-4-6" | "claude-sonnet-4-6" | "claude-haiku-4-5-20251001";

// ── Provider/Gateway types ────────────────────────────────────────────────

/**
 * Configuration for a gateway provider (e.g., z.ai, OpenRouter, self-hosted proxy).
 *
 * Providers override the default Anthropic API endpoint and/or API key.
 * The SDK reads ANTHROPIC_BASE_URL and ANTHROPIC_API_KEY from the environment,
 * so provider configs specify how to populate those variables per-phase.
 */
export interface ProviderConfig {
  /** Base URL for the API endpoint (e.g., "https://api.z.ai/anthropic").
   *  Injected as ANTHROPIC_BASE_URL in the SDK env. */
  baseUrl?: string;
  /** Name of the environment variable holding the API key for this provider.
   *  The value of that env var will be injected as ANTHROPIC_API_KEY. */
  apiKeyEnvVar?: string;
  /** Optional mapping from foreman model IDs to provider-specific model IDs.
   *  e.g., { "claude-sonnet-4-6": "anthropic/claude-sonnet-4-6" } for OpenRouter */
  modelIdMap?: Record<string, string>;
}

/** Map of provider IDs (e.g., "z-ai", "openrouter") to their configurations. */
export type GatewayProviders = Record<string, ProviderConfig>;

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
