/**
 * pipeline-executor.ts — Generic workflow-driven pipeline executor.
 *
 * Iterates the phases defined in a WorkflowConfig YAML and executes each
 * one via runPhase(). All phase-specific behavior (mail hooks, artifacts,
 * retry loops, file reservations, verdict parsing) is driven by the YAML
 * config — no hardcoded phase names.
 *
 * This replaces the ~450-line hardcoded runPipeline() in agent-worker.ts.
 */

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { execFile, execSync } from "node:child_process";
import { appendFile } from "node:fs/promises";
import { join, basename } from "node:path";
import type { WorkflowConfig, WorkflowPhaseConfig, WorkflowSandboxConfig } from "../lib/workflow-loader.js";
import type { TaskMeta } from "../lib/interpolate.js";
import type { ProjectHooksConfig } from "../lib/project-config.js";
import { interpolateTaskPlaceholders } from "../lib/interpolate.js";
import { resolvePhaseModel } from "../lib/workflow-loader.js";
import { ROLE_CONFIGS } from "./roles.js";
import {
  buildPhasePrompt,
  parseVerdict,
  extractRepairFeedback,
  parseFinalizeFailureScope,
  parseFinalizeIntegrationStatus,
  parseFinalizeValidationStatus,
  qaReportHasTestEvidence,
} from "./roles.js";
import { rotateReport } from "./agent-worker-finalize.js";
import { updateTerminalRunStatus } from "./agent-worker-run-status.js";
import { writeSessionLog } from "./session-log.js";
import type { PhaseRecord, SessionLogData } from "./session-log.js";
import type { AgentMailClient } from "../lib/agent-mail-client.js";
import type { Event, Run, RunProgress } from "../lib/store.js";
import type { RunProgressSummary } from "./read-models.js";
import type { VcsBackend } from "../lib/vcs/index.js";
import { HeartbeatManager, createHeartbeatManager, type HeartbeatConfig } from "./heartbeat-manager.js";
import { createPhaseRecord, finalizePhaseRecord, generateActivityLog, writeIncrementalPipelineReport, type PhaseRecord as ActivityPhaseRecord } from "./activity-logger.js";
import { RATE_LIMIT_BACKOFF_CONFIG, calculateRateLimitBackoffMs, COOLDOWN_RETRY_CONFIG, PIPELINE_LIMITS } from "../lib/config.js";
import { inferProjectPathFromWorkspacePath } from "../lib/workspace-paths.js";
import { getRunReportsDir, resolveArtifactPath } from "../lib/report-paths.js";
import { loadProjectConfig, resolveSandboxConfig as resolveProjectSandboxConfig } from "../lib/project-config.js";
import { SandboxProviderFactory } from "../lib/sandbox-providers/index.js";
import type { SandboxProviderConfig } from "../lib/sandbox-provider.js";
import type { ControlOutcome } from "./pi-sdk-tools.js";

 // ── Types ──────────────────────────────────────────────────────────────────

type AnyMailClient = AgentMailClient;

/** Function signature matching the runPhase() in agent-worker.ts. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type WorkerStoreCompat = {
  updateRunProgress(runId: string, progress: RunProgress): Promise<void> | void;
  logEvent(projectId: string, eventType: string, data: Record<string, unknown>, runId?: string): Promise<void> | void;
  updateRun?(runId: string, updates: Record<string, unknown>): Promise<void> | void;
  logRateLimitEvent?(projectId: string, model: string, phase: string, error: string, retryAfterSeconds?: number, runId?: string): Promise<void> | void;
  updateTaskStatus?(taskId: string, status: string): Promise<void> | void;
  getRun(runId: string): Run | null;
  getRunProgress(runId: string): RunProgress | null;
  getEvents(projectId?: string, limit?: number, eventType?: string): Event[];
  getRunsByStatus(status: Run["status"], projectId?: string): Promise<Run[]> | Run[];
  getRunsByStatuses(statuses: Run["status"][], projectId?: string): Promise<Run[]> | Run[];
  getRunsByBaseBranch(baseBranch: string, projectId?: string): Promise<Run[]> | Run[];
  close?(): void;
};

export type RunPhaseFn = (
  role: any,
  prompt: string,
  config: any,
  progress: RunProgress,
  logFile: string,
  store: WorkerStoreCompat,
  notifyClient: any,
  agentMailClient?: AnyMailClient | null,
  observability?: PhaseObservabilityInput,
  observabilityWriter?: PipelineObservabilityWriter,
) => Promise<PhaseResult>;

export interface PhaseResult {
  success: boolean;
  costUsd: number;
  turns: number;
  tokensIn: number;
  tokensOut: number;
  error?: string;
  outputText?: string;
  traceFile?: string;
  traceMarkdownFile?: string;
  traceWarnings?: string[];
  commandHonored?: boolean;
  filesChanged?: string[];
  stopPipelineSuccess?: boolean;
  /** Typed control signal from phase control tools (ask_operator, abort_phase, needs_retry). */
  controlOutcome?: ControlOutcome;
}

async function phaseAgentError(
  agentMailClient: AnyMailClient | null | undefined,
  phaseName: string,
  taskId: string,
  sinceIso: string,
): Promise<{ error: string; retryable: boolean } | null> {
  if (!agentMailClient) return null;
  const expectedSenders = new Set([phaseName, `${phaseName}-${taskId}`]);
  const sinceMs = Date.parse(sinceIso);
  const messages = await agentMailClient.fetchInbox("foreman", { limit: 50 });
  const msg = [...messages].reverse().find((candidate) =>
    candidate.subject === "agent-error" &&
    expectedSenders.has(candidate.from) &&
    (!Number.isFinite(sinceMs) || Date.parse(candidate.receivedAt) >= sinceMs)
  );
  if (!msg) return null;
  try {
    const body = JSON.parse(msg.body ?? "{}") as Record<string, unknown>;
    const error = typeof body.error === "string" ? body.error : "agent-error";
    return { error, retryable: body.retryable !== false };
  } catch {
    return { error: msg.body || "agent-error", retryable: true };
  }
}

function isInfrastructureAgentError(error: string): boolean {
  return /\b(auth|connection refused|database|db|disk|environment-blocked|infrastructure|maxTurns|no space|permission denied|provider|rate limit|repository|repo unavailable|sandbox|stale prompt|stale workflow|terminated|timeout|tool unavailable|worktree|workspace)\b/i.test(error);
}

function shouldDeferAgentErrorToVerdictArtifact(input: {
  explicitAgentError: { error: string; retryable: boolean } | null;
  artifactVerdict: "pass" | "fail" | "unknown";
}): boolean {
  return Boolean(
    input.explicitAgentError &&
    input.artifactVerdict === "fail" &&
    !isInfrastructureAgentError(input.explicitAgentError.error),
  );
}

export interface PhaseObservabilityInput {
  phaseType?: "prompt" | "command" | "bash" | "builtin";
  expectedArtifact?: string;
  resolvedCommand?: string;
  workflowName?: string;
  workflowPath?: string;
}

export interface PipelineObservabilityWriter {
  updateProgress?: (progress: RunProgress) => Promise<void> | void;
  logEvent?: (eventType: "phase-start" | "complete" | "heartbeat" | "phase-failed" | "phase-retry" | "phase-skipped" | "phase-verdict" | "phase-nudge" | "phase-report" | "assistant-message" | "tool-call-finished" | "run-completed" | "run-failed" | "task-updated", data: Record<string, unknown>) => Promise<void> | void;
}

/** A child task within an epic pipeline run. */
export interface EpicTask {
  /** Task/task ID of the child task. */
  taskId: string;
  /** Title of the child task task. */
  taskTitle: string;
  /** Description of the child task task. */
  taskDescription?: string;
  /** GitHub issue number for this task (from github_issue_number field). */
  githubIssueNumber?: number;
}

export interface PipelineRunConfig {
  runId: string;
  projectId: string;
  taskId: string;
  taskTitle: string;
  taskDescription?: string;
  taskComments?: string;
  taskType?: string;
  taskLabels?: string[];
  /**
   * Task priority string ("P0"–"P4", "0"–"4", or undefined).
   * Used to select the per-priority model from the workflow YAML models map.
   */
  taskPriority?: string;
  model: string;
  worktreePath: string;
  projectPath?: string;
  env: Record<string, string | undefined>;
  /** Override target branch for finalize rebase/push and auto-merge. */
  targetBranch?: string;
  /** GitHub issue number for this task (from github_issue_number field). */
  githubIssueNumber?: number;
  /**
   * VCS backend instance for computing backend-specific commands.
   * When provided, finalize and reviewer prompts are rendered with
   * backend-specific VCS command variables (TRD-026, TRD-027).
   * Falls back to git defaults when absent.
   */
  vcsBackend?: VcsBackend;
  /**
   * Optional task ID from native task store.
   * When present, pipeline-executor passes it to onTaskPhaseChange(taskId, phaseName)
   * at each phase transition (REQ-012).
   */
  nativeTaskId?: string | null;
  /**
   * Parent epic task ID. When set, this run is part of an epic execution.
   * Used to link child task results back to the parent epic.
   */
  epicId?: string;
  /** Task metadata for placeholder interpolation in bash/command phases (REQ-008). */
  taskMeta?: TaskMeta;
  /** Directory guardrail config (FR-1). Passed through to PiRunOptions.guardrailConfig. */
  guardrailConfig?: {
    mode?: "auto-correct" | "veto" | "disabled";
    expectedCwd?: string;
    allowedPaths?: string[];
  };
  /** Workspace lifecycle hooks for afterRun (passed through from WorkerConfig). */
  hooks?: ProjectHooksConfig;
  /**
   * Target phase to start execution from (kill-switch routing).
   * When set, the pipeline executor skips all phases before this target and
   * starts execution at the specified phase. This enables the kill-switch
   * to route a failed run to a specific recovery phase without re-running
   * completed phases.
   */
  startPhase?: string;
}

export interface PipelineContext {
  config: PipelineRunConfig;
  workflowConfig: WorkflowConfig;
  store: WorkerStoreCompat;
  logFile: string;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  notifyClient: any;
  agentMailClient: AnyMailClient | null;
  /**
   * Optional task lifecycle callback for phase-level visibility.
   * When present, invoked after each successful phase completion with the
   * task ID and phase name.
   */
  onTaskPhaseChange?: (taskId: string | null | undefined, phaseName: string) => Promise<void> | void;
  /**
   * Optional task note callback for append-only phase timeline visibility.
   */
  onTaskPhaseNote?: (
    taskId: string | null | undefined,
    phaseName: string,
    kind: "progress" | "failure" | "qa" | "review" | "final" | "system",
    body: string,
    metadata?: Record<string, unknown>,
  ) => Promise<void> | void;
  /**
   * Optional registered-aware observability writer for the normal single-task
   * phase progress/event path.
   */
  observabilityWriter?: PipelineObservabilityWriter;
  /**
   * Epic mode: ordered list of child tasks to execute.
   * When set, the pipeline executor runs taskPhases for each task
   * instead of running all phases in sequence for a single task.
   */
  epicTasks?: EpicTask[];
  /** The runPhase function from agent-worker.ts */
  runPhase: RunPhaseFn;
  /** Execute a TypeScript builtin phase such as create-pr. */
  runBuiltinPhase?: (phase: WorkflowPhaseConfig, progress?: RunProgress) => Promise<PhaseResult>;
  /** Optional post-success hook for dirty worktree checkpointing. */
  onWorktreeUpdatedAfterPhase?: (phase: WorkflowPhaseConfig, progress: RunProgress) => Promise<void> | void;
  /** Register an agent identity for mail */
  registerAgent: (client: AnyMailClient | null, roleHint: string) => Promise<void>;
  /** Send structured mail */
  sendMail: (client: AnyMailClient | null, to: string, subject: string, body: Record<string, unknown>) => void;
  /** Send plain-text mail */
  sendMailText: (client: AnyMailClient | null, to: string, subject: string, body: string) => void;
  /** Reserve files for an agent */
  reserveFiles: (client: AnyMailClient | null, paths: string[], agentName: string, leaseSecs?: number) => void;
  /** Release file reservations */
  releaseFiles: (client: AnyMailClient | null, paths: string[], agentName: string) => void;
  /** Mark pipeline as stuck */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  markStuck: (...args: any[]) => Promise<void>;
  /** Log function */
  log: (msg: string) => void;
  /** Prompt loader options */
  promptOpts: { projectRoot: string; workflow: string };
  /**
   * Epic mode callback: update a child task task's status.
   * Called when a task starts (in_progress) or completes (closed/failed).
   */
  onTaskStatusChange?: (taskTaskId: string, status: "in_progress" | "completed" | "failed") => Promise<void>;
  /**
   * Epic mode callback: create a bug task when QA fails on a task.
   * Returns the created bug task ID, or undefined if creation fails.
   */
  onTaskQaFailure?: (taskTaskId: string, taskTitle: string, epicId: string) => Promise<string | undefined>;
  /**
   * Epic mode callback: close a bug task when QA passes after retry.
   */
  onTaskQaPass?: (bugTaskId: string) => Promise<void>;
  /**
   * Called when a rate limit (429) is detected.
   * Used for alerting (P1) and per-model rate limit tracking (P2).
   * @param model - The model that was rate limited
   * @param phase - The phase where the rate limit occurred
   * @param error - The error message
   * @param retryAfterSeconds - Optional Retry-After header value
   */
  onRateLimit?: (model: string, phase: string, error: string, retryAfterSeconds?: number) => void;
  /**
   * Called after the last phase (finalize) completes.
   * Responsible for: reading finalize mail, updating run status, and resetting
   * task state on failure. Explicit builtin phases handle PR and merge work.
   * @param info.success - Whether the pipeline completed successfully.
   *                        Only send branch-ready when success=true AND currentPhase=finalize.
   */
  onPipelineComplete?: (info: {
    progress: RunProgress;
    phaseRecords: PhaseRecord[];
    retryCounts: Record<string, number>;
    success: boolean;
    failedPhase?: string;
    failureReason?: string;
    /** Set when an ask_operator control outcome pauses the pipeline for operator input. */
    waitingForOperator?: boolean;
    /** The operator question when waitingForOperator is true. */
    waitingQuestion?: string;
  }) => Promise<void>;
  /**
   * Task metadata for placeholder interpolation in bash/command phases (REQ-008).
   * Passed from the dispatcher via WorkerConfig.taskMeta.
   * Undefined for legacy runs without taskMeta.
   */
  taskMeta?: TaskMeta;
  /**
   * Heartbeat manager for periodic observability events during active phases (FR-3).
   * Created in executePipeline when vcsBackend is available and heartbeat is enabled.
   */
  heartbeatManager?: HeartbeatManager;
  /**
   * Activity log phase records accumulated during pipeline execution (FR-4).
   * Finalized and written as ACTIVITY_LOG.json at pipeline end.
   */
  activityPhases?: ActivityPhaseRecord[];
}

// ── Helpers ─────────────────────────────────────────────────────────────────

function resolvePhaseArtifact(worktreePath: string, artifact: string, projectReportsDir?: string): { path: string; present: boolean } {
  const primaryPath = resolveArtifactPath(worktreePath, artifact);
  if (existsSync(primaryPath)) return { path: primaryPath, present: true };

  if (projectReportsDir) {
    const reportPath = resolveArtifactPath(worktreePath, join(projectReportsDir, basename(artifact)));
    if (reportPath !== primaryPath && existsSync(reportPath)) return { path: reportPath, present: true };
  }

  return { path: primaryPath, present: false };
}

function readReport(worktreePath: string, filename: string, projectReportsDir?: string): string | null {
  const p = resolvePhaseArtifact(worktreePath, filename, projectReportsDir).path;
  try { return readFileSync(p, "utf-8"); } catch { return null; }
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function positiveWorktreeRootArtifactLine(prompt: string, artifactFile: string): string | null {
  const artifactPattern = escapeRegExp(artifactFile);
  const rootWritePattern = new RegExp(
    `\\bwrite\\b[^\\r\\n]*\`?${artifactPattern}\`?[^\\r\\n]*\\b(?:at|in|to)\\s+the\\s+worktree\\s+root\\b`,
    "i",
  );
  const negatedWritePattern = /\b(?:do\s+not|don't|never|must\s+not)\b/i;

  for (const line of prompt.split(/\r?\n/)) {
    if (rootWritePattern.test(line) && !negatedWritePattern.test(line)) {
      return line.trim();
    }
  }

  return null;
}


export function promptArtifactContractError(input: {
  phaseName: string;
  prompt: string;
  artifact: string;
  projectReportsDir: string;
}): string | null {
  const reportsDir = input.projectReportsDir.replace(/\/+$/, "");
  if (!reportsDir || !(input.artifact === reportsDir || input.artifact.startsWith(`${reportsDir}/`))) {
    return null;
  }

  const artifactFile = basename(input.artifact);
  const expectedArtifact = `${reportsDir}/${artifactFile}`;
  const mentionsExpectedArtifact = input.prompt.includes(expectedArtifact);
  const worktreeRootLine = positiveWorktreeRootArtifactLine(input.prompt, artifactFile);

  if (!worktreeRootLine && mentionsExpectedArtifact) {
    return null;
  }

  const reason = worktreeRootLine
    ? `found a positive worktree-root artifact instruction: "${worktreeRootLine}"`
    : "does not mention the configured report artifact path";

  return `Stale ${input.phaseName} prompt: workflow expects artifact at ${expectedArtifact}, but the rendered prompt ${reason}. Run 'foreman doctor --fix' or refresh ~/.foreman/prompts.`;
}


function trimReportValue(value: string | undefined, max = 2_000): string | undefined {
  const trimmed = value?.trim();
  if (!trimmed) return undefined;
  return trimmed.length > max ? `${trimmed.slice(0, max)}…` : trimmed;
}

function extractMarkdownSection(markdown: string, heading: string): string | undefined {
  const escaped = heading.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = markdown.match(new RegExp(`(?:^|\\n)##\\s+${escaped}\\s*\\n([\\s\\S]*?)(?=\\n##\\s+|$)`, "i"));
  return trimReportValue(match?.[1]);
}

function extractVerdict(markdown: string): string | undefined {
  const inline = markdown.match(/^##\s+Verdict\s*:?\s*(.+)$/im)?.[1];
  return trimReportValue(inline ?? extractMarkdownSection(markdown, "Verdict"), 200);
}

async function emitPhaseReportEvent(
  ctx: PipelineContext,
  phaseName: string,
  artifact: string | undefined,
  outcome: "completed" | "failed" | "retry",
  nextPhase?: string,
  retryTarget?: string,
): Promise<void> {
  const projectReportsDir = ctx.taskMeta?.projectReportsDir || getRunReportsDir(ctx.config.projectId, ctx.config.taskId, ctx.config.runId);
  if (!ctx.observabilityWriter?.logEvent || !artifact) return;
  const report = readReport(ctx.config.worktreePath, artifact, projectReportsDir);
  if (!report) return;
  const artifactPath = resolvePhaseArtifact(ctx.config.worktreePath, artifact, projectReportsDir).path;
  const summary = {
    verdict: extractVerdict(report),
    rootCause: extractMarkdownSection(report, "Root Cause"),
    fix: extractMarkdownSection(report, "Fix"),
    filesChanged: extractMarkdownSection(report, "Files Changed"),
    qaHandoff: extractMarkdownSection(report, "QA Handoff"),
    testResults: extractMarkdownSection(report, "Test Results"),
    failures: extractMarkdownSection(report, "Failures") ?? extractMarkdownSection(report, "Issues") ?? extractMarkdownSection(report, "Findings"),
    knownLimitations: extractMarkdownSection(report, "Known Limitations"),
  };
  const compactSummary = Object.fromEntries(Object.entries(summary).filter(([, value]) => value));
  await ctx.observabilityWriter.logEvent("phase-report", {
    run_id: ctx.config.runId,
    runId: ctx.config.runId,
    task_id: ctx.config.taskId,
    taskId: ctx.config.taskId,
    phase: phaseName,
    phase_id: phaseName,
    report_id: `${ctx.config.runId}:${phaseName}:${Date.now()}`,
    status: outcome,
    outcome,
    verdict: summary.verdict,
    summary: compactSummary,
    next_phase: nextPhase,
    nextPhase,
    retry_target: retryTarget,
    retryTarget,
    artifacts: [{ name: artifact, path: artifactPath, content_type: "text/markdown" }],
    created_at: new Date().toISOString(),
  });
}

function readRelativeFile(worktreePath: string, relativePath?: string): string | null {
  if (!relativePath) return null;
  const path = resolveArtifactPath(worktreePath, relativePath);
  try { return readFileSync(path, "utf-8"); } catch { return null; }
}

function sendTraceMail(
  ctx: PipelineContext,
  client: AnyMailClient | null,
  phaseName: string,
  taskId: string,
  worktreePath: string,
  result: PhaseResult,
): void {
  const traceMarkdown = readRelativeFile(worktreePath, result.traceMarkdownFile);
  if (!traceMarkdown) return;
  ctx.sendMailText(
    client,
    "foreman",
    `${phaseName.charAt(0).toUpperCase() + phaseName.slice(1)} Trace`,
    traceMarkdown,
  );
}

/**
 * Detect if an error is a rate limit (429) error.
 * Returns true if the error indicates a rate limit, false otherwise.
 */
export function isRateLimitError(error: string | undefined): boolean {
  if (!error) return false;
  const errorLower = error.toLowerCase();
  return (
    errorLower.includes("rate limit") ||
    errorLower.includes("429") ||
    errorLower.includes("hit your limit") ||
    errorLower.includes("too many requests") ||
    errorLower.includes("rate_limit_exceeded") ||
    errorLower.includes("overloaded_error") ||
    errorLower.includes("529") ||
    errorLower.includes("server is temporarily busy") ||
    errorLower.includes("peak-hour surge")
  );
}

export function isMaxTurnsExceededError(error: string | undefined): boolean {
  return /phase exceeded maxTurns|exceeded max turns|maxTurns/i.test(error ?? "");
}

function failureKind(error: string | undefined): "provider_transient" | "max_turns" | "phase_failed" {
  if (isRateLimitError(error)) return "provider_transient";
  if (isMaxTurnsExceededError(error)) return "max_turns";
  return "phase_failed";
}

/** Return true when a failed phase should enter cooldown retry instead of terminal failure. */
export function shouldUseCooldownRetry(error: string | undefined, phase: Pick<WorkflowPhaseConfig, "retryAfterCooldown">): boolean {
  return Boolean(phase.retryAfterCooldown && isRateLimitError(error));
}

export function retryTargetForFailure(
  phase: Pick<WorkflowPhaseConfig, "retryWith" | "retryWithByReason">,
  reason: string | undefined,
): string | undefined {
  const normalized = reason ?? "";
  for (const [pattern, target] of Object.entries(phase.retryWithByReason ?? {})) {
    if (pattern.startsWith("/") && pattern.endsWith("/")) {
      try {
        if (new RegExp(pattern.slice(1, -1), "i").test(normalized)) return target;
      } catch {
        // Bad workflow regex: ignore and fall back to prefix/static retry.
      }
    } else if (normalized.toLowerCase().startsWith(pattern.toLowerCase())) {
      return target;
    }
  }
  return phase.retryWith;
}

/**
 * Extract Retry-After seconds from an error message if present.
 * Some providers include this in the error message.
 */
function extractRetryAfterSeconds(error: string | undefined): number | undefined {
  if (!error) return undefined;
  // Match patterns like "Retry-After: 30" or "retry after 30 seconds"
  const match = error.match(/retry[- ]?after[:\s]+(\d+)/i);
  if (match) {
    const seconds = parseInt(match[1], 10);
    if (!isNaN(seconds) && seconds > 0) return seconds;
  }
  return undefined;
}

/**
 * Get a fallback model for Haiku when it's rate limited.
 * Haiku fallback to Sonnet (P2 recommendation).
 */
function getHaikuFallbackModel(model: string): string {
  // If using haiku, fall back to sonnet
  if (model.includes("haiku")) {
    return "anthropic/claude-sonnet-4-6";
  }
  return model;
}

/**
 * Sleep utility for implementing backoff delays.
 */
function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function findDebugArtifacts(root: string, max = 20): string[] {
  try {
    const output = execSync("git status --porcelain", { cwd: root, encoding: "utf8" });
    return output
      .split("\n")
      .map((line) => line.slice(3).trim())
      .filter(Boolean)
      .filter((path) => /(^|\/)(?:.*debug.*|scratch.*|tmp.*)(?:\.(?:test\.)?[cm]?[jt]sx?|\.md|\.txt)$/i.test(path))
      .slice(0, max);
  } catch {
    return [];
  }
}

async function writeNormalPhaseProgress(
  store: WorkerStoreCompat,
  runId: string,
  progress: RunProgress,
  observabilityWriter?: PipelineObservabilityWriter,
): Promise<void> {
  if (observabilityWriter?.updateProgress) {
    await observabilityWriter.updateProgress(progress);
    return;
  }

  await Promise.resolve(store.updateRunProgress(runId, progress));
}

async function writeNormalPhaseEvent(
  store: WorkerStoreCompat,
  projectId: string,
  runId: string,
  eventType: "phase-start" | "complete" | "phase-failed" | "phase-retry" | "phase-skipped" | "phase-verdict",
  data: Record<string, unknown>,
  observabilityWriter?: PipelineObservabilityWriter,
): Promise<void> {
  if (observabilityWriter?.logEvent) {
    await observabilityWriter.logEvent(eventType, data);
    return;
  }

  store.logEvent(projectId, eventType, data, runId);
}

async function emitPipelineTerminalFailureEvents(
  ctx: PipelineContext,
  markStuckArgs: unknown[],
): Promise<void> {
  const writer = ctx.observabilityWriter;
  if (!writer?.logEvent) return;

  const runId = typeof markStuckArgs[1] === "string" ? markStuckArgs[1] : ctx.config.runId;
  const taskId = typeof markStuckArgs[3] === "string" ? markStuckArgs[3] : ctx.config.taskId;
  const phase = typeof markStuckArgs[6] === "string" ? markStuckArgs[6] : "pipeline";
  const reason = typeof markStuckArgs[7] === "string" ? markStuckArgs[7] : "pipeline_failed";
  const now = new Date().toISOString();
  const base = {
    run_id: runId,
    runId,
    task_id: taskId,
    taskId,
    phase,
    phase_id: phase,
    status: "failed",
    reason,
    message: reason,
  };

  const events: Array<["phase-failed" | "run-failed" | "task-updated", Record<string, unknown>]> = [
    ["phase-failed", { ...base, failed_at: now }],
    ["run-failed", { ...base, failed_at: now }],
    ["task-updated", { ...base, updated_at: now }],
  ];

  for (const [eventType, payload] of events) {
    try {
      await writer.logEvent(eventType, payload);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      ctx.log(`[pipeline-observability] CRITICAL terminal ${eventType} append failed for run ${runId}: ${msg}`);
    }
  }
  ctx.log(`[pipeline-observability] terminal failure events emitted for run ${runId} phase=${phase} reason=${reason}`);
}

/** Result of running a sequence of phases. */
interface PhaseSequenceResult {
  success: boolean;
  phaseRecords: PhaseRecord[];
  retryCounts: Record<string, number>;
  qaVerdictForLog: "pass" | "fail" | "unknown";
  progress: RunProgress;
  /** Set when a verdict-FAIL exhausted retries (task failed, not stuck). */
  retriesExhausted?: boolean;
  /** Set when a retryable failure was handled via cooldown retry (task in cooldown state). */
  cooldownUntil?: string;
  /** Actual failed phase for terminal events; avoids stale projection/currentPhase fallback. */
  failedPhase?: string;
  /** Concrete failure reason for terminal events. */
  failureReason?: string;
  /** Set when an ask_operator control outcome pauses the pipeline for operator input. */
  waitingForOperator?: boolean;
  /** The operator question when waitingForOperator is true. */
  waitingQuestion?: string;
 }

function isGeneratedWorkflowArtifact(filePath: string): boolean {
  const name = basename(filePath);
  return (
    name.endsWith("_REPORT.md") ||
    name.endsWith("_SESSION_SUMMARY.md") ||
    name === "SESSION_LOG.md" ||
    name === "RUN_LOG.md" ||
    name === "FINALIZE_VALIDATION.md" ||
    name === "TASK.md" ||
    name === "AGENT.md" ||
    name === "AGENTS.md" ||
    name === "BLOCKED.md"
  );
}

// ── Generic Pipeline Executor ───────────────────────────────────────────────

// ── Bash Phase Execution (TRD-004) ─────────────────────────────────────────────

const BASH_PHASE_TIMEOUT_MS = 120_000; // 120 seconds

function toSandboxProviderConfig(config: WorkflowSandboxConfig): SandboxProviderConfig {
  return {
    backend: config.backend ?? "auto",
    image: config.image,
    limits: config.limits,
    network: config.network,
    cleanup: config.cleanup,
  };
}

export function applyEffectiveSandboxConfig(ctx: PipelineContext): void {
  const projectSandbox = ctx.config.projectPath ? loadProjectConfig(ctx.config.projectPath)?.sandbox : undefined;
  const effectiveSandbox = resolveProjectSandboxConfig(ctx.workflowConfig.sandbox, projectSandbox);
  if (!effectiveSandbox) return;

  const hostPhases = ctx.workflowConfig.phases.filter((phase) => !phase.bash).map((phase) => phase.name);
  if (hostPhases.length > 0) {
    throw new Error(`Sandbox is only supported for bash phases; host-executed phases are not isolated: ${hostPhases.join(", ")}`);
  }

  ctx.workflowConfig.sandbox = effectiveSandbox;
}

/**
 * Result of a bash phase execution.
 * Mirrors PhaseResult but includes stdout/stderr for artifact writing.
 */
export interface BashPhaseResult extends PhaseResult {
  stdout: string;
  stderr: string;
}

/**
 * Execute a bash phase via `/bin/sh -c` in the worktree directory.
 *
 * 1. Interpolate `{task.*}` placeholders using taskMeta from PipelineContext
 * 2. Run via execFile with cwd=worktreePath, timeout=120s
 * 3. Capture stdout + stderr
 * 4. Write artifact file if specified
 * 5. Return PASS (exit 0) or FAIL (non-zero exit code or timeout)
 */
export async function runBashPhase(
  bashCommand: string,
  taskMeta: TaskMeta | undefined,
  cwd: string,
  artifactFile?: string,
  timeoutMs = BASH_PHASE_TIMEOUT_MS,
  sandboxConfig?: WorkflowSandboxConfig,
): Promise<BashPhaseResult> {
  // Interpolate placeholders
  const interpolated = taskMeta
    ? interpolateTaskPlaceholders(bashCommand, taskMeta)
    : bashCommand;

  // Interpolate artifact path too (e.g. docs/reports/{task.id}/IMPLEMENT_REPORT.md)
  const interpolatedArtifact = artifactFile
    ? interpolateTaskPlaceholders(artifactFile, taskMeta ?? { id: '', title: '', description: '', type: '', priority: 2 })
    : undefined;

  let stdout = '';
  let stderr = '';
  let exitCode: number | null = null;
  let timedOut = false;

  try {
    if (sandboxConfig) {
      const providerConfig = toSandboxProviderConfig(sandboxConfig);
      const provider = await SandboxProviderFactory.create(providerConfig);
      const sandbox = await provider.createSandbox(cwd, providerConfig.image ?? "ubuntu:22.04", {
        limits: providerConfig.limits,
        mounts: providerConfig.mounts,
        ports: providerConfig.ports,
        network: providerConfig.network,
        user: providerConfig.user,
        cleanup: providerConfig.cleanup,
      });
      try {
        const result = await provider.runInSandbox(sandbox.id, ['/bin/sh', '-c', interpolated], {
          cwd: sandbox.workdir,
          timeoutMs,
        });
        stdout = result.stdout ?? '';
        stderr = result.stderr ?? '';
        exitCode = result.exitCode;
      } finally {
        if (providerConfig.cleanup !== "keep") {
          await provider.destroySandbox(sandbox.id);
        }
      }
    } else {
      const result = await execFilePromise('/bin/sh', ['-c', interpolated], {
        cwd,
        timeout: timeoutMs,
        maxBuffer: 10 * 1024 * 1024, // 10 MB
      });
      stdout = result.stdout ?? '';
      stderr = result.stderr ?? '';
      exitCode = result.status ?? 0;
    }
  } catch (err: unknown) {
    timedOut = err instanceof Error && err.message.includes('timed out');
    if (timedOut) {
      stderr = `Bash phase timed out after ${timeoutMs}ms: ${interpolated}`;
      exitCode = 124; // standard timeout exit code
    } else if (err instanceof Error) {
      // execFile throws NodeJS.ErrnoException with numeric code property
      const code = (err as NodeJS.ErrnoException).code;
      exitCode = typeof code === 'number' ? code : 1;
      stderr = err.message;
    } else {
      stderr = String(err);
      exitCode = 1;
    }
  }

  const success = exitCode === 0 && !timedOut;

  // Write artifact file if specified
  if (interpolatedArtifact && stdout) {
    try {
      writeFileSync(interpolatedArtifact, stdout, 'utf8');
    } catch {
      // Non-fatal: artifact write failure doesn't fail the phase
    }
  }

  return {
    success,
    costUsd: 0,
    turns: 0,
    tokensIn: 0,
    tokensOut: 0,
    error: timedOut
      ? `Timeout after ${timeoutMs}ms`
      : exitCode !== 0
        ? `Exit code ${exitCode}`
        : undefined,
    outputText: stdout || stderr,
    stdout,
    stderr,
  };
}

/**
 * Promise wrapper around execFile with timeout support.
 * Uses child_process execFile with a race between the command and a timeout.
 */
function execFilePromise(
  command: string,
  args: string[],
  options: { cwd?: string; timeout?: number; maxBuffer?: number },
): Promise<{ stdout: string; stderr: string; status: number | null }> {
  const { timeout: timeoutMs, ...restOptions } = options;

  const execPromise: Promise<{ stdout: string; stderr: string; status: number | null }> =
    new Promise((resolve, reject) => {
      const proc = execFile(command, args, restOptions, (error, stdout, stderr) => {
        // error is null on clean exit; Error with numeric code on non-zero exit; Error without code on fatal errors
        if (error && !('code' in error)) {
          reject(error); // fatal error (no exit code)
        } else {
          // Non-zero exit code → resolve with status; zero exit → status 0
          const rawCode = error ? (error as NodeJS.ErrnoException).code : null;
          const status: number | null = typeof rawCode === 'number' ? (rawCode as number) : null;
          resolve({ stdout: stdout ?? '', stderr: stderr ?? '', status });
        }
      });
      if (timeoutMs) {
        proc.on('error', (err) => reject(err));
      }
    });

  if (!timeoutMs) return execPromise;

  const timeoutPromise = new Promise<never>((_, reject) =>
    setTimeout(() => {
      reject(Object.assign(
        new Error(`ETIMEDOUT: ${command} timed out after ${timeoutMs}ms`),
        { code: 'ETIMEDOUT' },
      ));
    }, timeoutMs),
  );

  return Promise.race([execPromise, timeoutPromise]);
}

/**
 * Execute a workflow pipeline driven entirely by the YAML config.
 *
 * Two modes:
 * - **Single-task mode** (default): iterates all `phases` in order for one task.
 * - **Epic mode**: when `ctx.epicTasks` is set AND workflow has `taskPhases`,
 *   iterates child tasks running only `taskPhases` per task (with per-task commits),
 *   then runs `finalPhases` once at the end.
 *
 * Per-phase behavior:
 *  1. Check skipIfArtifact (resume from crash)
 *  2. Register agent mail identity
 *  3. Send phase-started mail (if mail.onStart)
 *  4. Reserve files (if files.reserve)
 *  5. Run the phase via runPhase()
 *  6. Release files
 *  7. Handle success: send phase-complete mail, forward artifact, add labels
 *  8. Handle failure: send error mail, mark stuck
 *  9. If verdict phase: parse PASS/FAIL, handle retryWith loop
 */
export async function executePipeline(ctx: PipelineContext): Promise<void> {
  const { config, workflowConfig } = ctx;
  const epicTasks = ctx.epicTasks;
  applyEffectiveSandboxConfig(ctx);
  ensureTaskMarkdown(ctx);
  const isEpicMode = epicTasks && epicTasks.length > 0 && workflowConfig.taskPhases;
  let terminalFailureEmitted = false;
  const terminalAwareCtx: PipelineContext = {
    ...ctx,
    markStuck: async (...args) => {
      if (!terminalFailureEmitted) {
        terminalFailureEmitted = true;
        await emitPipelineTerminalFailureEvents(ctx, args);
      }
      return ctx.markStuck(...args);
    },
    onPipelineComplete: ctx.onPipelineComplete
      ? async (info) => {
          if (!info.success && !terminalFailureEmitted) {
            terminalFailureEmitted = true;
            const failedPhase = [...info.phaseRecords].reverse().find((phase) => phase.success === false);
            const phaseName = info.failedPhase ?? failedPhase?.name ?? info.progress.currentPhase ?? "pipeline";
            const reason = info.failureReason ?? failedPhase?.error ?? `${phaseName}_failed`;
            await emitPipelineTerminalFailureEvents(ctx, [
              ctx.store,
              config.runId,
              config.projectId,
              config.taskId,
              config.taskTitle,
              info.progress,
              phaseName,
              reason,
              config.projectPath,
              ctx.notifyClient,
            ]);
          }
          return ctx.onPipelineComplete!(info);
        }
      : undefined,
  };

  if (isEpicMode) {
    await executeEpicPipeline(terminalAwareCtx);
  } else {
    await executeSingleTaskPipeline(terminalAwareCtx);
  }
}

function ensureTaskMarkdown(ctx: PipelineContext): void {
  const { config } = ctx;
  const path = join(config.worktreePath, "TASK.md");
  if (existsSync(path)) return;

  const lines = [
    `# ${config.taskId}: ${config.taskTitle}`,
    "",
    "## Task",
    `- ID: ${config.taskId}`,
    `- Title: ${config.taskTitle}`,
    config.taskType ? `- Type: ${config.taskType}` : undefined,
    config.taskPriority ? `- Priority: ${config.taskPriority}` : undefined,
    config.targetBranch ? `- Target branch: ${config.targetBranch}` : undefined,
    "",
    "## Description",
    config.taskDescription?.trim() || "(no description)",
    "",
    config.taskComments?.trim() ? "## Comments" : undefined,
    config.taskComments?.trim() || undefined,
    "",
    "## Instructions",
    "Follow the active workflow phase prompt. Treat this file as task context, not as an implementation plan.",
    "",
  ].filter((line): line is string => line !== undefined);

  try {
    writeFileSync(path, lines.join("\n"), "utf-8");
  } catch (err) {
    ctx.log(`[PIPELINE] Failed to write TASK.md: ${err instanceof Error ? err.message : String(err)}`);
  }
}

// ── Resume detection ────────────────────────────────────────────────────────

/**
 * Parse `git log --oneline` output from an epic worktree and extract
 * the task IDs of tasks that have already been committed.
 *
 * Commit messages follow the format: `<title> (<taskId>)`
 * For example: `Add user auth (task-7)` → extracts `task-7`.
 *
 * @returns A Set of completed task IDs found in the git history.
 */
export function parseCompletedTaskIds(gitLogOutput: string): Set<string> {
  const completed = new Set<string>();
  // Match the trailing parenthesized task ID in each commit line.
  // git log --oneline format: "<hash> <message>"
  // We look for the pattern "(<taskId>)" at the end of each line.
  const regex = /\(([^)]+)\)\s*$/;
  for (const line of gitLogOutput.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const match = regex.exec(trimmed);
    if (match) {
      completed.add(match[1]);
    }
  }
  return completed;
}

/**
 * Read git log from a worktree directory and return completed task IDs.
 * Returns an empty set if the git command fails (e.g. no commits yet).
 *
 * Note: uses execSync with a hardcoded command string (no user input),
 * so shell injection is not a concern here.
 */
function detectCompletedTasks(worktreePath: string): Set<string> {
  try {
    const output = execSync("git log --oneline", {
      cwd: worktreePath,
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 10_000,
    });
    return parseCompletedTaskIds(output);
  } catch {
    // No git history or command failed — no completed tasks
    return new Set<string>();
  }
}

// ── Epic mode executor ──────────────────────────────────────────────────────

/**
 * Epic mode: iterate child tasks, running taskPhases per task with commits
 * between, then finalPhases once at the end.
 *
 * Resume support (TRD-009): on re-dispatch, parses git log to find
 * already-committed task task IDs and skips them.
 */
async function executeEpicPipeline(ctx: PipelineContext): Promise<void> {
  const { config, workflowConfig, store, logFile } = ctx;
  const { runId, taskId, worktreePath } = config;
  let epicTasks = ctx.epicTasks!;
  const taskPhaseNames = workflowConfig.taskPhases!;
  const finalPhaseNames = workflowConfig.finalPhases ?? [];

  // Resolve phase configs for task phases and final phases
  const allPhases = workflowConfig.phases;
  const taskPhases = taskPhaseNames
    .map((name) => allPhases.find((p) => p.name === name))
    .filter((p): p is typeof allPhases[number] => p !== undefined);
  const finalPhases = finalPhaseNames
    .map((name) => allPhases.find((p) => p.name === name))
    .filter((p): p is typeof allPhases[number] => p !== undefined);

  // ── Resume detection (TRD-009) ──────────────────────────────────────
  const totalTaskCount = epicTasks.length;
  const resumedTaskIds = detectCompletedTasks(worktreePath);

  if (resumedTaskIds.size > 0) {
    const remainingTasks = epicTasks.filter((t) => !resumedTaskIds.has(t.taskId));
    const skippedCount = totalTaskCount - remainingTasks.length;

    if (skippedCount > 0) {
      ctx.log(`[EPIC] Resuming from task ${skippedCount + 1} of ${totalTaskCount} (${skippedCount} completed)`);
      await appendFile(logFile, `\n[EPIC] Resume: ${skippedCount} tasks already committed, skipping to task ${skippedCount + 1}\n`);
      epicTasks = remainingTasks;
    }
  }

  const taskPhaseStr = taskPhaseNames.join(" → ");
  const finalPhaseStr = finalPhaseNames.length > 0 ? ` | final: ${finalPhaseNames.join(" → ")}` : "";
  ctx.log(`[EPIC] Starting epic pipeline for ${taskId} — ${epicTasks.length} tasks`);
  ctx.log(`[EPIC] Per-task phases: ${taskPhaseStr}${finalPhaseStr}`);
  await appendFile(logFile, `\n[EPIC] Epic pipeline: ${epicTasks.length} tasks, taskPhases: ${taskPhaseStr}${finalPhaseStr}\n`);

  const allPhaseRecords: PhaseRecord[] = [];
  const allRetryCounts: Record<string, number> = {};
  let totalProgress: RunProgress = {
    toolCalls: 0,
    toolBreakdown: {},
    filesChanged: [],
    turns: 0,
    costUsd: 0,
    tokensIn: 0,
    tokensOut: 0,
    lastToolCall: null,
    lastActivity: new Date().toISOString(),
    currentPhase: "epic-init",
    epicTaskCount: epicTasks.length,
    epicTasksCompleted: 0,
    epicCostByTask: {},
  };

  let completedCount = 0;
  let failedCount = 0;
  const completedTaskIds: string[] = [];

  // ── Outer task loop ──────────────────────────────────────────────────
  const activeBugTaskIds = new Map<string, string>();

  for (let taskIdx = 0; taskIdx < epicTasks.length; taskIdx++) {
    const task = epicTasks[taskIdx];
    ctx.log(`[EPIC] Task ${taskIdx + 1}/${epicTasks.length}: ${task.taskId} — ${task.taskTitle}`);
    await appendFile(logFile, `\n[EPIC] === Task ${taskIdx + 1}/${epicTasks.length}: ${task.taskId} ===\n`);
    const epicTaskCostBefore = totalProgress.costUsd;

    // TRD-012: Update epic progress in RunProgress
    totalProgress.epicCurrentTaskId = task.taskId;
    await writeNormalPhaseProgress(store, runId, totalProgress, ctx.observabilityWriter);

    // TRD-011: Mark task task as in_progress
    if (ctx.onTaskStatusChange) {
      await ctx.onTaskStatusChange(task.taskId, "in_progress").catch(() => {});
    }

    // Build a task-specific config overlay (use task's taskId/title/description for prompts)
    const taskConfig: PipelineRunConfig = {
      ...config,
      // Keep the epic's taskId for run tracking, but pass task info for prompts
      taskDescription: task.taskDescription ?? config.taskDescription,
      taskComments: `Epic task ${taskIdx + 1}/${epicTasks.length}: ${task.taskTitle}\n` +
        (completedTaskIds.length > 0
          ? `Previously completed: ${completedTaskIds.join(", ")}\n`
          : "") +
        (config.taskComments ?? ""),
    };

    // Create a task-scoped context with taskPhases only
    const taskWorkflowConfig = { ...workflowConfig, phases: taskPhases };
    const taskCtx: PipelineContext = {
      ...ctx,
      config: taskConfig,
      workflowConfig: taskWorkflowConfig,
      epicTasks: undefined, // prevent recursion
    };

    // Run the task phases (developer → QA with retry).
    // failOnRetriesExhausted=true: in epic mode, exhausted retries mean the task failed.
    const result = await runPhaseSequence(taskCtx, taskPhases, totalProgress, true, ctx.observabilityWriter);

    // Accumulate progress
    totalProgress = result.progress;
    allPhaseRecords.push(...result.phaseRecords);
    for (const [k, v] of Object.entries(result.retryCounts)) {
      allRetryCounts[k] = (allRetryCounts[k] ?? 0) + v;
    }

    if (result.success) {
      completedCount++;
      completedTaskIds.push(task.taskId);

      // TRD-010: Close bug task if QA passed after retry
      const activeBugTaskId = activeBugTaskIds.get(task.taskId);
      if (activeBugTaskId && ctx.onTaskQaPass) {
        await ctx.onTaskQaPass(activeBugTaskId).catch(() => {});
      }
      activeBugTaskIds.delete(task.taskId);

      // Commit after each successful task (epic mode: one commit per task)
      if (config.vcsBackend) {
        try {
          await config.vcsBackend.commit(worktreePath, `${task.taskTitle} (${task.taskId})`);
          ctx.log(`[EPIC] Committed task ${task.taskId}`);
        } catch (err: unknown) {
          // Non-fatal: commit may fail if no changes (e.g. test-only task)
          const msg = err instanceof Error ? err.message : String(err);
          ctx.log(`[EPIC] Commit for ${task.taskId} skipped: ${msg}`);
        }
      }

      // TRD-011: Mark task task as completed
      if (ctx.onTaskStatusChange) {
        await ctx.onTaskStatusChange(task.taskId, "completed").catch(() => {});
      }

      // TRD-012: Update epic progress
      totalProgress.epicTasksCompleted = completedCount;
      totalProgress.epicCostByTask ??= {};
      totalProgress.epicCostByTask[task.taskId] = result.progress.costUsd - epicTaskCostBefore;
      await writeNormalPhaseProgress(store, runId, totalProgress, ctx.observabilityWriter);

      ctx.log(`[EPIC] Task ${task.taskId} PASSED (${completedCount}/${epicTasks.length} done)`);
      await appendFile(logFile, `\n[EPIC] Task ${task.taskId} PASSED\n`);
    } else {
      failedCount++;

      // TRD-010: Create bug task on QA failure
      if (result.retriesExhausted && ctx.onTaskQaFailure && config.epicId) {
        const activeBugTaskId = await ctx.onTaskQaFailure(task.taskId, task.taskTitle, config.epicId).catch(() => undefined);
        if (activeBugTaskId) {
          activeBugTaskIds.set(task.taskId, activeBugTaskId);
          ctx.log(`[EPIC] Created bug task ${activeBugTaskId} for QA failure on ${task.taskId}`);
        }
      }

      // TRD-011: Mark task task as failed
      if (ctx.onTaskStatusChange) {
        await ctx.onTaskStatusChange(task.taskId, "failed").catch(() => {});
      }

      ctx.log(`[EPIC] Task ${task.taskId} FAILED${result.retriesExhausted ? " (retries exhausted)" : ""}`);
      await appendFile(logFile, `\n[EPIC] Task ${task.taskId} FAILED\n`);

      // Apply onError strategy
      if (workflowConfig.onError === "stop") {
        ctx.log(`[EPIC] onError=stop — halting epic after task ${task.taskId} failure`);
        await appendFile(logFile, `\n[EPIC] Halted (onError=stop)\n`);
        await ctx.markStuck(
          store, runId, config.projectId, taskId, config.taskTitle,
          totalProgress, "epic-task-failed",
          `Task ${task.taskId} failed — epic halted (onError=stop)`,
          config.projectPath, ctx.notifyClient,
        );
        return;
      }
      // onError=continue: skip failed task and continue to next
    }
  }

  ctx.log(`[EPIC] Task loop complete: ${completedCount} passed, ${failedCount} failed`);
  await appendFile(logFile, `\n[EPIC] Task loop complete: ${completedCount}/${epicTasks.length} passed\n`);

  // ── Final phases (finalize) — run once after all tasks ─────────────
  if (finalPhases.length > 0 && completedCount > 0) {
    ctx.log(`[EPIC] Running final phases: ${finalPhaseNames.join(" → ")}`);
    await appendFile(logFile, `\n[EPIC] === Final phases ===\n`);

    const finalWorkflowConfig = { ...workflowConfig, phases: finalPhases };
    const finalCtx: PipelineContext = {
      ...ctx,
      workflowConfig: finalWorkflowConfig,
      epicTasks: undefined,
    };

    const finalResult = await runPhaseSequence(finalCtx, finalPhases, totalProgress, false, ctx.observabilityWriter);
    totalProgress = finalResult.progress;
    allPhaseRecords.push(...finalResult.phaseRecords);
    for (const [k, v] of Object.entries(finalResult.retryCounts)) {
      allRetryCounts[k] = (allRetryCounts[k] ?? 0) + v;
    }

    if (!finalResult.success) {
      ctx.log(`[EPIC] Final phases failed`);
      return; // markStuck already called inside runPhaseSequence
    }
  }

  // ── Session log ──────────────────────────────────────────────────────
  await writeSessionLogSafe(ctx, totalProgress, allPhaseRecords, allRetryCounts, "unknown");

  // ── Pipeline completion ──────────────────────────────────────────────
  // P0 fix: Pass success=false when final phases failed, preventing branch-ready.
  // Epic pipeline success = final phases succeeded (not just task loop completion).
  const pipelineSuccess = true; // Default: final phases succeeded if we reached here
  if (ctx.onPipelineComplete) {
    await ctx.onPipelineComplete({
      progress: totalProgress,
      phaseRecords: allPhaseRecords,
      retryCounts: allRetryCounts,
      success: pipelineSuccess,
    });
  }
}

// ── Single-task mode executor ───────────────────────────────────────────────

/**
 * Original single-task mode: run all phases in sequence for one task.
 * This is the pre-existing behavior, extracted for clarity.
 */
async function executeSingleTaskPipeline(ctx: PipelineContext): Promise<void> {
  const { config, workflowConfig, store, logFile } = ctx;
  const { taskId } = config;

  const progress: RunProgress = {
    toolCalls: 0,
    toolBreakdown: {},
    filesChanged: [],
    turns: 0,
    costUsd: 0,
    tokensIn: 0,
    tokensOut: 0,
    lastToolCall: null,
    lastActivity: new Date().toISOString(),
    currentPhase: workflowConfig.phases[0]?.name ?? "unknown",
  };

  const phaseNames = workflowConfig.phases.map((p) => p.name).join(" → ");
  ctx.log(`Pipeline starting for ${taskId} [workflow: ${workflowConfig.name}]`);
  ctx.log(`[PIPELINE] Phase sequence: ${phaseNames}`);
  await appendFile(logFile, `\n[foreman-worker] Pipeline orchestration starting\n[PIPELINE] Phase sequence: ${phaseNames}\n`);

  // FR-3: Initialize HeartbeatManager for periodic observability events
  const heartbeatConfig: HeartbeatConfig = {
    enabled: true,
    intervalSeconds: 60,
    overwatchEnabled: true,
    overwatchStaleIntervals: 2,
    overwatchMaxNudges: 3,
  };
  const worktreePath = config.worktreePath;
  ctx.heartbeatManager = config.vcsBackend
    ? createHeartbeatManager(heartbeatConfig, store, config.projectId, config.runId, config.vcsBackend, worktreePath, ctx.observabilityWriter, {
      sendNudge: (recipient, subject, body) => ctx.sendMailText(ctx.agentMailClient, recipient, subject, body),
      log: ctx.log,
    }) ?? undefined
    : undefined;
  ctx.heartbeatManager?.setTaskId(taskId);
  ctx.activityPhases = [];

  const result = await runPhaseSequence(ctx, workflowConfig.phases, progress, false, ctx.observabilityWriter);

  // Session log
  await writeSessionLogSafe(ctx, result.progress, result.phaseRecords, result.retryCounts, result.qaVerdictForLog);

  // FR-4: Generate ACTIVITY_LOG.json for self-documenting commits
  if (config.vcsBackend && ctx.activityPhases) {
    try {
      await generateActivityLog({
        worktreePath,
        runId: config.runId,
        taskId: config.taskId,
        phases: ctx.activityPhases,
        vcs: config.vcsBackend,
        targetBranch: config.targetBranch ?? "main",
        includeGitDiffStat: true,
      });
      ctx.log(`[PIPELINE] ACTIVITY_LOG.json written`);
    } catch (err) {
      // Non-fatal — don't fail the pipeline over activity log
      ctx.log(`[PIPELINE] ACTIVITY_LOG.json failed: ${err instanceof Error ? err.message : String(err)}`);
    }
  }

  // Pipeline completion callback
  // P0 fix: Pass result.success to prevent branch-ready on pipeline failure.
  if (ctx.onPipelineComplete) {
    await ctx.onPipelineComplete({
      progress: result.progress,
      phaseRecords: result.phaseRecords,
      retryCounts: result.retryCounts,
      success: result.success,
      failedPhase: result.failedPhase,
      failureReason: result.failureReason,
      waitingForOperator: result.waitingForOperator,
      waitingQuestion: result.waitingQuestion,
    });
  }
}

// ── Phase sequence runner (shared by both modes) ────────────────────────────

/**
 * Run a sequence of phases in order with retry/verdict logic.
 * This is the core phase iteration loop used by both single-task and epic modes.
 */
async function runPhaseSequence(
  ctx: PipelineContext,
  phases: WorkflowPhaseConfig[],
  initialProgress: RunProgress,
  /** When true (epic task mode), exhausted retries return failure instead of continuing. */
  failOnRetriesExhausted: boolean = false,
  observabilityWriter?: PipelineObservabilityWriter,
): Promise<PhaseSequenceResult> {
  const { config, workflowConfig, store, logFile, notifyClient, agentMailClient } = ctx;
  const { runId, projectId, taskId, taskTitle, worktreePath } = config;
  const description = config.taskDescription ?? "(no description)";
  const comments = config.taskComments;

  const progress = { ...initialProgress };
  const phaseRecords: PhaseRecord[] = [];
  let feedbackContext: string | undefined;
  let qaVerdictForLog: "pass" | "fail" | "unknown" = "unknown";
  const retryCounts: Record<string, number> = {};
  // P1: Circuit breaker for the first non-retryOnly phase.
  // Track failures by phase name so custom workflows with different first-phase names work correctly.
  // Falls back to "explorer" for backward compatibility.
  const firstNonRetryOnlyPhase = phases.find((p) => !p.retryOnly);
  const firstPhaseName = firstNonRetryOnlyPhase?.name ?? "explorer";
  const firstPhaseFailures: string[] = [];
  // P1/P2: Rate limit tracking per phase
  const rateLimitRetries: Record<string, number> = {};
  const pipelineStartedAt = Date.now();

  const totalReviewLoops = (): number => Object.values(retryCounts).reduce((sum, count) => sum + count, 0);
  const budgetExceededReason = (): string | undefined => {
    const elapsedMs = Date.now() - pipelineStartedAt;
    if (PIPELINE_LIMITS.maxPipelineWallClockMs > 0 && elapsedMs > PIPELINE_LIMITS.maxPipelineWallClockMs) {
      return `pipeline wall-clock budget exceeded (${elapsedMs}ms > ${PIPELINE_LIMITS.maxPipelineWallClockMs}ms)`;
    }
    if (PIPELINE_LIMITS.maxPipelineCostUsd > 0 && progress.costUsd > PIPELINE_LIMITS.maxPipelineCostUsd) {
      return `pipeline cost budget exceeded ($${progress.costUsd.toFixed(4)} > $${PIPELINE_LIMITS.maxPipelineCostUsd.toFixed(4)})`;
    }
    if (PIPELINE_LIMITS.maxPipelineToolCalls > 0 && progress.toolCalls > PIPELINE_LIMITS.maxPipelineToolCalls) {
      return `pipeline tool-call budget exceeded (${progress.toolCalls} > ${PIPELINE_LIMITS.maxPipelineToolCalls})`;
    }
    const loops = totalReviewLoops();
    if (PIPELINE_LIMITS.maxPipelineReviewLoops > 0 && loops > PIPELINE_LIMITS.maxPipelineReviewLoops) {
      return `pipeline review-loop budget exceeded (${loops} > ${PIPELINE_LIMITS.maxPipelineReviewLoops})`;
    }
    return undefined;
  };

  const writeTaskPhaseNote = async (
    phaseName: string,
    kind: "progress" | "failure" | "qa" | "review" | "final" | "system",
    body: string,
    metadata?: Record<string, unknown>,
  ): Promise<void> => {
    await ctx.onTaskPhaseNote?.(config.nativeTaskId ?? null, phaseName, kind, body, metadata);
  };

  const notifyWorktreeUpdated = async (phase: WorkflowPhaseConfig): Promise<void> => {
    if (phase.checkpointPr !== true) return;
    if (!ctx.onWorktreeUpdatedAfterPhase) return;
    try {
      await ctx.onWorktreeUpdatedAfterPhase(phase, progress);
    } catch (err: unknown) {
      ctx.log(`[PR] post-phase checkpoint callback failed after ${phase.name}: ${err instanceof Error ? err.message : String(err)}`);
    }
  };

  // Build a phase index for retryWith lookups
  const phaseIndex = new Map<string, number>();
  for (let idx = 0; idx < phases.length; idx++) {
    phaseIndex.set(phases[idx].name, idx);
  }

  // Kill-switch routing: skip phases before startPhase target
  let i = 0;
  const retryOnlyActivations = new Set<string>();
  if (config.startPhase) {
    const startIdx = phaseIndex.get(config.startPhase);
    if (startIdx === undefined) {
      // Fail closed: reject unknown route targets rather than silently falling back to phase zero
      ctx.log(`[PIPELINE] ERROR: startPhase '${config.startPhase}' not found in workflow — rejecting route target`);
      throw new Error(`Kill-switch route target '${config.startPhase}' not found in workflow phases. Valid phases are: ${phases.map(p => p.name).join(", ")}`);
    }

    ctx.log(`[PIPELINE] Kill-switch routing: starting from phase '${config.startPhase}' (skipping ${startIdx} phases before it)`);
    const startPhaseConfig = phases[startIdx];
    if (startPhaseConfig.retryOnly) {
      retryOnlyActivations.add(startPhaseConfig.name);
    }

    // Emit authoritative events for each routed skip so projections can derive them
    for (let skippedIdx = 0; skippedIdx < startIdx; skippedIdx++) {
      const skippedPhaseName = phases[skippedIdx].name;
      const routingReason = `kill-switch routed to '${config.startPhase}' — skipping prior phase`;
      await appendFile(logFile, `\n[PHASE: ${skippedPhaseName.toUpperCase()}] SKIPPED (kill-switch routing)\n`);
      await writeNormalPhaseEvent(store, projectId, runId, "phase-skipped", { taskId, phase: skippedPhaseName, reason: routingReason, routedFrom: config.startPhase }, observabilityWriter);
      await writeTaskPhaseNote(skippedPhaseName, "system", routingReason, { routedFrom: config.startPhase, routingType: "kill-switch" });
      phaseRecords.push({ name: skippedPhaseName, skipped: true });
    }
    i = startIdx;
  }
  while (i < phases.length) {
    const phase = phases[i];
    const phaseName = phase.name;
    const prePhaseBudgetReason = budgetExceededReason();
    if (prePhaseBudgetReason) {
      ctx.log(`[PIPELINE] Budget stop before ${phaseName}: ${prePhaseBudgetReason}`);
      await writeTaskPhaseNote(phaseName, "failure", prePhaseBudgetReason, { retryable: false, budget: true });
      await ctx.markStuck(store, runId, projectId, taskId, taskTitle, progress, phaseName, prePhaseBudgetReason, config.projectPath, notifyClient);
      return { success: false, phaseRecords, retryCounts, qaVerdictForLog, progress, failedPhase: phaseName, failureReason: prePhaseBudgetReason };
    }
    const agentName = `${phaseName}-${taskId}`;
    // Check if the first phase's artifact exists (for hasExplorerReport check).
    // Falls back to EXPLORER_REPORT.md for backward compatibility.
    const explorerArtifactPath = firstNonRetryOnlyPhase?.artifact
      ? join(worktreePath, firstNonRetryOnlyPhase.artifact.replace(/^\{task\.projectReportsDir\}/, "").replace(/^\//, ""))
      : join(worktreePath, "EXPLORER_REPORT.md");
    const hasExplorerReport = existsSync(explorerArtifactPath);
    const phaseType = phase.bash
      ? "bash"
      : phase.command
        ? "command"
        : phase.builtin
          ? "builtin"
          : "prompt";
    const phaseMeta: TaskMeta = {
      id: taskId,
      title: taskTitle,
      description,
      type: config.taskType ?? '',
      priority: 2,
      ...ctx.taskMeta,
      projectReportsDir: ctx.taskMeta?.projectReportsDir || getRunReportsDir(projectId, taskId, runId),
    };
    const projectReportsDir = phaseMeta.projectReportsDir ?? getRunReportsDir(projectId, taskId, runId);

    if (phase.retryOnly && !retryOnlyActivations.has(phaseName)) {
      ctx.log(`[${phaseName.toUpperCase()}] Skipping — retryOnly phase not activated by retryWith`);
      await appendFile(logFile, `\n[PHASE: ${phaseName.toUpperCase()}] SKIPPED (retryOnly)\n`);
      await writeNormalPhaseEvent(store, projectId, runId, "phase-skipped", { taskId, phase: phaseName, reason: "retryOnly phase not activated by retryWith" }, observabilityWriter);
      phaseRecords.push({ name: phaseName, skipped: true });
      i++;
      continue;
    }
    retryOnlyActivations.delete(phaseName);

    progress.currentPhase = phaseName;
    await writeNormalPhaseProgress(store, runId, progress, observabilityWriter);

    // 1. Skip if artifact already exists (resume from crash)
    // Interpolate {task.*} placeholders so skipIfArtifact can use
    // {task.projectReportsDir}/{task.id}/PRD.md patterns.
    if (phase.skipIfArtifact) {
      const interpolatedSkip = interpolateTaskPlaceholders(
        phase.skipIfArtifact,
        phaseMeta,
      );
      const artifactPath = resolveArtifactPath(worktreePath, interpolatedSkip);
      if (existsSync(artifactPath)) {
        ctx.log(`[${phaseName.toUpperCase()}] Skipping — ${phase.skipIfArtifact} already exists at ${artifactPath}`);
        await appendFile(logFile, `\n[PHASE: ${phaseName.toUpperCase()}] SKIPPED (artifact already present: ${artifactPath})\n`);
        await writeNormalPhaseEvent(store, projectId, runId, "phase-skipped", { taskId, phase: phaseName, reason: "artifact already present", artifactPath }, observabilityWriter);
        phaseRecords.push({ name: phaseName, skipped: true });
        i++;
        continue;
      }
    }

    // 2. Register agent mail identity
    await ctx.registerAgent(agentMailClient, agentName);

    // 3. Send phase-started mail
    if (phase.mail?.onStart !== false) {
      ctx.sendMail(agentMailClient, "foreman", "phase-started", { taskId, phase: phaseName });
    }

    // 4. Reserve files
    if (phase.files?.reserve) {
      ctx.reserveFiles(agentMailClient, [worktreePath], agentName, phase.files.leaseSecs ?? 600);
    }

    // 5. Rotate and run phase
    // Interpolate {task.*} placeholders in artifact path before use.
    const interpolatedArtifact = phase.artifact
      ? interpolateTaskPlaceholders(phase.artifact, phaseMeta)
      : undefined;
    if (interpolatedArtifact) {
      rotateReport(worktreePath, interpolatedArtifact);
    }

    // Compute VCS-specific prompt variables for finalize and reviewer phases (TRD-026, TRD-027).
    const vcsBackend = config.vcsBackend;
    const baseBranch = config.targetBranch ?? "main";
    const vcsPromptVars: {
      vcsStageCommand?: string;
      vcsCommitCommand?: string;
      vcsPushCommand?: string;
      vcsIntegrateTargetCommand?: string;
      vcsBranchVerifyCommand?: string;
      vcsCleanCommand?: string;
      vcsRestoreTrackedStateCommand?: string;
      qaValidatedTargetRef?: string;
      currentTargetRef?: string;
      shouldRunFinalizeValidation?: string;
      vcsBackendName?: string;
      vcsBranchPrefix?: string;
    } = {};

    if (vcsBackend) {
      vcsPromptVars.vcsBackendName = vcsBackend.name;
      vcsPromptVars.vcsBranchPrefix = "foreman/";

      if (phaseName === "finalize") {
        const finalizeCommands = vcsBackend.getFinalizeCommands({
          taskId,
          taskTitle,
          baseBranch,
          worktreePath,
          githubIssueNumber: config.githubIssueNumber,
        });
        vcsPromptVars.vcsStageCommand = finalizeCommands.stageCommand;
        vcsPromptVars.vcsCommitCommand = finalizeCommands.commitCommand;
        vcsPromptVars.vcsPushCommand = finalizeCommands.pushCommand;
        vcsPromptVars.vcsIntegrateTargetCommand = finalizeCommands.integrateTargetCommand;
        vcsPromptVars.vcsBranchVerifyCommand = finalizeCommands.branchVerifyCommand;
        vcsPromptVars.vcsCleanCommand = finalizeCommands.cleanCommand;
        vcsPromptVars.vcsRestoreTrackedStateCommand = finalizeCommands.restoreTrackedStateCommand;

        const qaValidatedTargetRef = progress.qaValidatedTargetRef;
        let currentTargetRef = "";
        if (qaValidatedTargetRef) {
          const targetCandidates = [`origin/${baseBranch}`, baseBranch];
          for (const candidate of targetCandidates) {
            try {
              currentTargetRef = await vcsBackend.resolveRef(worktreePath, candidate);
              break;
            } catch {
              // Try the next candidate.
            }
          }
        }
        const shouldRunFinalizeValidation = !qaValidatedTargetRef || !currentTargetRef || qaValidatedTargetRef !== currentTargetRef;
        progress.currentTargetRef = currentTargetRef || undefined;
        await writeNormalPhaseProgress(store, runId, progress, observabilityWriter);
        vcsPromptVars.qaValidatedTargetRef = qaValidatedTargetRef ?? "";
        vcsPromptVars.currentTargetRef = currentTargetRef;
        vcsPromptVars.shouldRunFinalizeValidation = shouldRunFinalizeValidation ? "true" : "false";

        try {
          execSync(finalizeCommands.restoreTrackedStateCommand, {
            cwd: worktreePath,
            stdio: "ignore",
            shell: "/bin/bash",
          });
        } catch {
          // Best effort: the finalize prompt also carries the same restore command.
        }
      }
    }

    // TRD-004/TRD-005: Build prompt only for prompt:-based phases.
    // Bash, command, and builtin phases handle their own execution without buildPhasePrompt.
    let prompt = "";
    let promptArtifactError: string | null = null;
    if (!phase.bash && !phase.builtin) {
      prompt = phase.command
        ? interpolateTaskPlaceholders(phase.command, phaseMeta)
        : buildPhasePrompt(phaseName, {
          taskId,
          taskTitle,
          taskDescription: description,
          taskComments: comments,
          taskType: config.taskType,
          runId,
          hasExplorerReport,
          // requiresExplorerReport: true if this is a mutating phase (checkpointPr: true) and explorer report exists.
          // This enables the pre-flight check for explorer report in developer-like phases.
          requiresExplorerReport: hasExplorerReport && phase.checkpointPr === true,
          feedbackContext,
          worktreePath,
          reportDir: projectReportsDir,
          baseBranch: config.targetBranch,
          ...vcsPromptVars,
        }, {
          ...ctx.promptOpts,
          promptName: phase.prompt ? basename(phase.prompt, ".md") : undefined,
        });
      if (interpolatedArtifact) {
        promptArtifactError = promptArtifactContractError({
          phaseName,
          prompt,
          artifact: interpolatedArtifact,
          projectReportsDir,
        });
      }
    }

    const roleConfigFallback = (ROLE_CONFIGS as Record<string, { model: string } | undefined>)[phaseName];
    const fallbackModel = roleConfigFallback?.model ?? config.model;
    let phaseModel = resolvePhaseModel(phase, config.taskPriority, fallbackModel);

    // FR-2: Write phase-start event to store before agent spawns
    await writeNormalPhaseEvent(store, projectId, runId, "phase-start", {
      taskId,
      phase: phaseName,
      worktreePath,
      expectedWorktree: worktreePath,
      model: phaseModel,
      runId,
      targetBranch: config.targetBranch,
    }, observabilityWriter);
    await writeTaskPhaseNote(phaseName, "progress", `${phaseName} started.`, {
      model: phaseModel,
      runId,
      workflow: workflowConfig.name,
    });

    // FR-3: Start heartbeat for this phase
    ctx.heartbeatManager?.start(phaseName);

    // FR-4: Create initial activity phase record
    const activityPhase = createPhaseRecord(phaseName, phaseModel, {
      phaseType,
      commandsRun: phase.bash
        ? [interpolateTaskPlaceholders(phase.bash, phaseMeta)]
        : phase.command
          ? [prompt]
          : undefined,
      artifactExpected: interpolatedArtifact,
      workflowName: workflowConfig.name,
      workflowPath: workflowConfig.sourcePath,
    });

    if (promptArtifactError) {
      const artifactPresent = interpolatedArtifact ? resolvePhaseArtifact(worktreePath, interpolatedArtifact, projectReportsDir).present : undefined;
      ctx.log(`[${phaseName.toUpperCase()}] FAIL — ${promptArtifactError}`);
      await appendFile(logFile, `\n[PIPELINE] ${phaseName} FAIL: ${promptArtifactError}\n`);
      phaseRecords.push({
        name: phaseName,
        phaseType,
        skipped: false,
        success: false,
        costUsd: 0,
        turns: 0,
        error: promptArtifactError,
        artifactExpected: interpolatedArtifact,
        artifactPresent,
      });
      if (phase.files?.reserve) {
        ctx.releaseFiles(agentMailClient, [worktreePath], agentName);
      }
      ctx.sendMail(agentMailClient, "foreman", "agent-error", {
        taskId, phase: phaseName, error: promptArtifactError, retryable: false,
      });
      await writeTaskPhaseNote(phaseName, "failure", `${phaseName} failed: ${promptArtifactError}`, { retryable: false });
      await ctx.markStuck(store, runId, projectId, taskId, taskTitle, progress, phaseName, promptArtifactError, config.projectPath, notifyClient);
      return { success: false, phaseRecords, retryCounts, qaVerdictForLog, progress, failedPhase: phaseName, failureReason: promptArtifactError };
    }

    // P1: Circuit breaker for the first non-retryOnly phase (explorer-like phase).
    // Fail fast if this phase has failed 3 times in the last hour.
    // This prevents empty branch pollution when the first phase keeps failing.
    if (phaseName === firstPhaseName) {
      const recentFirstPhaseFailures = firstPhaseFailures.filter(
        (t) => Date.now() - new Date(t).getTime() < 60 * 60 * 1000, // Within last hour
      );
      if (recentFirstPhaseFailures.length >= 3) {
        ctx.log(`[${firstPhaseName.toUpperCase()}] CIRCUIT BREAKER: ${firstPhaseName} has failed ${recentFirstPhaseFailures.length} times in the last hour — failing fast`);
        await appendFile(logFile, `\n[PIPELINE] ${firstPhaseName.toUpperCase()} CIRCUIT BREAKER: ${recentFirstPhaseFailures.length} failures detected, failing fast\n`);
        const errorMsg = `${firstPhaseName} circuit breaker: ${recentFirstPhaseFailures.length} failures in the last hour`;
        ctx.sendMail(agentMailClient, "foreman", "agent-error", {
          taskId, phase: phaseName, error: errorMsg, retryable: false,
        });
        await writeTaskPhaseNote(phaseName, "failure", `${phaseName} failed: ${errorMsg}`, { retryable: false });
        await ctx.markStuck(store, runId, projectId, taskId, taskTitle, progress, phaseName, errorMsg, config.projectPath, notifyClient);
        return { success: false, phaseRecords, retryCounts, qaVerdictForLog, progress, failedPhase: phaseName, failureReason: errorMsg };
      }
    }

    // P2: Haiku fallback to Sonnet when rate limited
    // Check if we should use Sonnet instead of Haiku due to rate limiting
    if (phaseModel.includes("haiku") && rateLimitRetries[phaseName] !== undefined) {
      const fallbackModelForPhase = getHaikuFallbackModel(phaseModel);
      ctx.log(`[${phaseName.toUpperCase()}] HAIKU FALLBACK: Using ${fallbackModelForPhase} instead of ${phaseModel} due to prior rate limit`);
      await appendFile(logFile, `\n[PIPELINE] ${phaseName} Haiku fallback to ${fallbackModelForPhase}\n`);
      phaseModel = fallbackModelForPhase;
    }

    const phaseConfig = { ...config, model: phaseModel, maxTurns: phase.maxTurns };
    if (phase.tools?.allowed) {
      (phaseConfig as typeof phaseConfig & { allowedTools?: string[] }).allowedTools = phase.tools.allowed;
    }

    if (phase.builtin) {
      if (!ctx.runBuiltinPhase) {
        const errorMsg = `Builtin phase ${phaseName} is not supported by this runner`;
        ctx.log(`[${phaseName.toUpperCase()}] FAIL — ${errorMsg}`);
        await writeTaskPhaseNote(phaseName, "failure", `${phaseName} failed: ${errorMsg}`, { retryable: false });
        await ctx.markStuck(store, runId, projectId, taskId, taskTitle, progress, phaseName, errorMsg, config.projectPath, notifyClient);
        return { success: false, phaseRecords, retryCounts, qaVerdictForLog, progress, failedPhase: phaseName, failureReason: errorMsg };
      }

      const result = await ctx.runBuiltinPhase(phase, progress);
      const artifactProbe = interpolatedArtifact ? resolvePhaseArtifact(worktreePath, interpolatedArtifact, projectReportsDir) : undefined;
      const artifactPresent = artifactProbe?.present;
      const phaseSucceeded = result.success && (!interpolatedArtifact || artifactPresent === true);
      const phaseError = result.error ?? (phaseSucceeded ? undefined : `Expected artifact missing: ${interpolatedArtifact}`);

      phaseRecords.push({
        name: phaseName,
        phaseType,
        skipped: false,
        success: phaseSucceeded,
        costUsd: 0,
        turns: 0,
        error: phaseError,
        artifactExpected: interpolatedArtifact,
        artifactPresent,
      });

      if (ctx.activityPhases) {
        const completedActivityPhase = finalizePhaseRecord(
          { ...activityPhase, artifactPresent },
          {
            success: phaseSucceeded,
            costUsd: 0,
            turns: 0,
            tokensIn: 0,
            tokensOut: 0,
            error: phaseError,
            toolCalls: 0,
            toolBreakdown: {},
            filesChanged: progress.filesChanged ?? [],
            workflowName: workflowConfig.name,
            workflowPath: workflowConfig.sourcePath,
          },
        );
        ctx.activityPhases.push(completedActivityPhase);

        let branchName: string | undefined;
        try {
          branchName = config.vcsBackend?.getCurrentBranch ? await config.vcsBackend.getCurrentBranch(worktreePath) : undefined;
        } catch {
          branchName = undefined;
        }
        writeIncrementalPipelineReport({
          worktreePath,
          taskId,
          runId,
          completedPhases: ctx.activityPhases,
          targetBranch: config.targetBranch,
          vcsBranchName: branchName,
        }).catch((err) => {
          ctx.log(`[PIPELINE] Warning: failed to write incremental report: ${String(err)}`);
        });
      }

      progress.costUsd += 0;
      await writeNormalPhaseProgress(store, runId, progress, observabilityWriter);

      if (!phaseSucceeded) {
        const errorMsg = phaseError ?? `${phaseName} failed`;
        ctx.log(`[${phaseName.toUpperCase()}] FAIL — ${errorMsg}`);
        await appendFile(logFile, `\n[PIPELINE] ${phaseName} FAIL: ${errorMsg}\n`);

        if (isRateLimitError(errorMsg)) {
          ctx.sendMail(agentMailClient, "foreman", "agent-error", {
            taskId, phase: phaseName, error: errorMsg, retryable: true,
          });
          await writeTaskPhaseNote(phaseName, "failure", `${phaseName} rate limited: ${errorMsg}`, { retryable: true });
          await ctx.markStuck(store, runId, projectId, taskId, taskTitle, progress, phaseName, errorMsg, config.projectPath, notifyClient);
          return { success: false, phaseRecords, retryCounts, qaVerdictForLog, progress, failedPhase: phaseName, failureReason: errorMsg };
        }

        const retryTarget = retryTargetForFailure(phase, errorMsg);
        if (retryTarget) {
          const currentRetries = retryCounts[phaseName] ?? 0;
          const maxRetries = phase.retryOnFail ?? 0;
          const artifactContent = interpolatedArtifact ? readReport(worktreePath, interpolatedArtifact, projectReportsDir) : null;
          const feedback = artifactContent ?? result.outputText ?? errorMsg;

          if (currentRetries < maxRetries) {
            retryCounts[phaseName] = currentRetries + 1;
            const feedbackTarget = `${retryTarget}-${taskId}`;
            ctx.sendMailText(agentMailClient, feedbackTarget, `${phaseName.charAt(0).toUpperCase() + phaseName.slice(1)} Feedback - Retry ${currentRetries + 1}`, feedback);
            feedbackContext = feedback;
            ctx.sendMail(agentMailClient, "foreman", "agent-error", {
              taskId, phase: phaseName, error: errorMsg, retryable: true,
            });
            ctx.log(`[${phaseName.toUpperCase()}] FAIL — looping back to ${retryTarget} (retry ${currentRetries + 1}/${maxRetries})`);
            await appendFile(logFile, `\n[PIPELINE] ${phaseName} failed, retrying ${retryTarget} (retry ${currentRetries + 1}/${maxRetries})\n`);
            await emitPhaseReportEvent(ctx, phaseName, interpolatedArtifact, "retry", undefined, retryTarget);
            await writeNormalPhaseEvent(store, config.projectId, runId, "phase-retry", {
              taskId,
              phase: phaseName,
              retryTarget,
              attempt: currentRetries + 1,
              maxRetries,
              artifact_path: interpolatedArtifact ? resolvePhaseArtifact(worktreePath, interpolatedArtifact, projectReportsDir).path : undefined,
              artifact_present: interpolatedArtifact ? resolvePhaseArtifact(worktreePath, interpolatedArtifact, projectReportsDir).present : undefined,
            }, observabilityWriter);
            const targetIdx = phaseIndex.get(retryTarget);
            if (targetIdx !== undefined) {
              retryOnlyActivations.add(retryTarget);
              i = targetIdx;
              continue;
            }
            ctx.log(`[${phaseName.toUpperCase()}] retryWith target '${retryTarget}' not found in workflow — marking stuck`);
          }

          ctx.log(`[${phaseName.toUpperCase()}] FAIL — max retries (${maxRetries}) exhausted`);
          await appendFile(logFile, `\n[PIPELINE] ${phaseName} failed after ${maxRetries} retries\n`);
        }

        ctx.sendMail(agentMailClient, "foreman", "agent-error", {
          taskId, phase: phaseName, error: errorMsg, retryable: false,
        });
        await writeTaskPhaseNote(phaseName, "failure", `${phaseName} failed: ${errorMsg}`, { retryable: false });
        await ctx.markStuck(store, runId, projectId, taskId, taskTitle, progress, phaseName, errorMsg, config.projectPath, notifyClient);
        return { success: false, phaseRecords, retryCounts, qaVerdictForLog, progress, failedPhase: phaseName, failureReason: errorMsg };
      }

      if (phase.mail?.onComplete !== false) {
        ctx.sendMail(agentMailClient, "foreman", "phase-complete", {
          taskId, phase: phaseName, status: "completed", cost: 0, turns: 0,
        });
      }
      await emitPhaseReportEvent(ctx, phaseName, interpolatedArtifact, "completed", phases[i + 1]?.name);
      await writeNormalPhaseEvent(store, config.projectId, runId, "complete", {
        taskId,
        phase: phaseName,
        artifact_path: interpolatedArtifact ? resolvePhaseArtifact(worktreePath, interpolatedArtifact, projectReportsDir).path : undefined,
        artifact_present: artifactPresent,
      }, observabilityWriter);
      await writeTaskPhaseNote(phaseName, "progress", `${phaseName} completed.`, {
        costUsd: 0,
        turns: 0,
        artifactPresent,
      });
      await ctx.onTaskPhaseChange?.(config.nativeTaskId ?? null, phaseName);
      await notifyWorktreeUpdated(phase);
      if (result.stopPipelineSuccess) {
        ctx.log(`[${phaseName.toUpperCase()}] Completed and requested successful pipeline stop`);
        return { success: true, phaseRecords, retryCounts, qaVerdictForLog, progress };
      }
      i++;
      continue;
    }

    // TRD-004: Bash phase — execute via execFile instead of SDK agent
    if (phase.bash) {
      const resolvedBashCommand = interpolateTaskPlaceholders(phase.bash, phaseMeta);
      const bashResult = await runBashPhase(
        phase.bash,
        ctx.taskMeta,
        worktreePath,
        phase.artifact,
        phase.timeoutSecs !== undefined ? phase.timeoutSecs * 1000 : undefined,
        ctx.workflowConfig.sandbox,
      );
      // TRD-004: record phase result (same structure as ctx.runPhase result)
      const result: PhaseResult = {
        success: bashResult.success,
        costUsd: 0,
        turns: 0,
        tokensIn: 0,
        tokensOut: 0,
        error: bashResult.error,
        outputText: bashResult.stdout || bashResult.stderr,
      };
      phaseRecords.push({
        name: phaseName,
        phaseType,
        skipped: false,
        success: result.success,
        costUsd: 0,
        turns: 0,
        error: result.error,
        commandsRun: [resolvedBashCommand],
        artifactPresent: interpolatedArtifact ? resolvePhaseArtifact(worktreePath, interpolatedArtifact, projectReportsDir).present : undefined,
      });
      progress.costUsd += 0;
      await writeNormalPhaseProgress(store, runId, progress, observabilityWriter);
      // Continue to verdict handling below (same as ctx.runPhase path)
      if (!result.success) {
        const errorMsg = result.error ?? `${phaseName} failed`;
        ctx.log(`[${phaseName.toUpperCase()}] FAIL — ${errorMsg}`);
        await appendFile(logFile, `\n[PIPELINE] ${phaseName} FAIL: ${errorMsg}\n`);

        if (isRateLimitError(errorMsg)) {
          ctx.sendMail(agentMailClient, "foreman", "agent-error", {
            taskId, phase: phaseName, error: errorMsg, retryable: true,
          });
          await writeTaskPhaseNote(phaseName, "failure", `${phaseName} rate limited: ${errorMsg}`, { retryable: true });
          await ctx.markStuck(store, runId, projectId, taskId, taskTitle, progress, phaseName, errorMsg, config.projectPath, notifyClient);
          return { success: false, phaseRecords, retryCounts, qaVerdictForLog, progress, failedPhase: phaseName, failureReason: errorMsg };
        }

        const retryTarget = retryTargetForFailure(phase, errorMsg);
        if (retryTarget) {
          const maxRetries = phase.retryOnFail ?? 0;
          const currentRetries = retryCounts[phaseName] ?? 0;
          const feedback = (interpolatedArtifact ? readReport(worktreePath, interpolatedArtifact, projectReportsDir) : null)
            ?? result.outputText
            ?? errorMsg;

          if (currentRetries < maxRetries) {
            retryCounts[phaseName] = currentRetries + 1;
            const feedbackTarget = `${retryTarget}-${taskId}`;
            ctx.sendMailText(agentMailClient, feedbackTarget, `${phaseName.charAt(0).toUpperCase() + phaseName.slice(1)} Feedback - Retry ${currentRetries + 1}`, feedback);
            feedbackContext = feedback;
            ctx.sendMail(agentMailClient, "foreman", "agent-error", {
              taskId, phase: phaseName, error: errorMsg, retryable: true,
            });
            ctx.log(`[${phaseName.toUpperCase()}] FAIL — looping back to ${retryTarget} (retry ${currentRetries + 1}/${maxRetries})`);
            await appendFile(logFile, `\n[PIPELINE] ${phaseName} failed, retrying ${retryTarget} (retry ${currentRetries + 1}/${maxRetries})\n`);
            await emitPhaseReportEvent(ctx, phaseName, interpolatedArtifact, "retry", undefined, retryTarget);
            await writeNormalPhaseEvent(store, config.projectId, runId, "phase-retry", {
              taskId,
              phase: phaseName,
              retryTarget,
              attempt: currentRetries + 1,
              maxRetries,
              reason: errorMsg,
              artifact: interpolatedArtifact,
              artifact_path: interpolatedArtifact ? resolvePhaseArtifact(worktreePath, interpolatedArtifact, projectReportsDir).path : undefined,
              artifact_present: interpolatedArtifact ? resolvePhaseArtifact(worktreePath, interpolatedArtifact, projectReportsDir).present : undefined,
            }, observabilityWriter);
            const targetIdx = phaseIndex.get(retryTarget);
            if (targetIdx !== undefined) {
              retryOnlyActivations.add(retryTarget);
              i = targetIdx;
              continue;
            }
            ctx.log(`[${phaseName.toUpperCase()}] retryWith target '${retryTarget}' not found in workflow — marking stuck`);
          }
        }

        ctx.sendMail(agentMailClient, "foreman", "agent-error", {
          taskId, phase: phaseName, error: errorMsg, retryable: false,
        });
        await writeTaskPhaseNote(phaseName, "failure", `${phaseName} failed: ${errorMsg}`, { retryable: false });
        await ctx.markStuck(store, runId, projectId, taskId, taskTitle, progress, phaseName, errorMsg, config.projectPath, notifyClient);
        return { success: false, phaseRecords, retryCounts, qaVerdictForLog, progress, failedPhase: phaseName, failureReason: errorMsg };
      }
      // Handle verdict if configured
      if (phase.verdict && result.outputText) {
        qaVerdictForLog = parseVerdict(result.outputText);
      }
      // Increment i and continue to next phase
      if (result.success) {
        // AC-6: Capture branch HEAD SHA at finalize success (durable PR identity metadata).
        // This stores the commit_sha on the run record so PR reuse can verify SHA match later.
        if (phaseName === "finalize" && result.success && config.vcsBackend) {
          try {
            const finalizedHead = await config.vcsBackend.getHeadId(worktreePath);
            await Promise.resolve(store.updateRun?.(runId, { commit_sha: finalizedHead }));
          } catch {
            // Best effort — HEAD capture failure should not block pipeline completion.
          }
        }

        if (phase.mail?.onComplete !== false) {
          ctx.sendMail(agentMailClient, "foreman", "phase-complete", {
            taskId, phase: phaseName, status: "completed", cost: result.costUsd, turns: result.turns,
          });
        }
        await writeNormalPhaseEvent(store, config.projectId, runId, "complete", {
          taskId,
          phase: phaseName,
          costUsd: result.costUsd,
          artifact: interpolatedArtifact,
          artifact_path: interpolatedArtifact ? resolvePhaseArtifact(worktreePath, interpolatedArtifact, projectReportsDir).path : undefined,
          artifact_present: interpolatedArtifact ? resolvePhaseArtifact(worktreePath, interpolatedArtifact, projectReportsDir).present : undefined,
        }, observabilityWriter);
        await writeTaskPhaseNote(phaseName, "progress", `${phaseName} completed.`, {
          costUsd: result.costUsd,
          turns: result.turns,
          artifactPresent: interpolatedArtifact ? resolvePhaseArtifact(worktreePath, interpolatedArtifact, projectReportsDir).present : undefined,
        });
        await ctx.onTaskPhaseChange?.(config.nativeTaskId ?? null, phaseName);

        if (phase.mail?.forwardArtifactTo && interpolatedArtifact) {
          const artifactContent = readReport(worktreePath, interpolatedArtifact, projectReportsDir);
          if (artifactContent) {
            const targetAgent = phase.mail.forwardArtifactTo === "foreman"
              ? "foreman"
              : `${phase.mail.forwardArtifactTo}-${taskId}`;
            const subject = phase.mail.forwardArtifactTo === "foreman"
              ? `${phaseName.charAt(0).toUpperCase() + phaseName.slice(1)} Complete`
              : `${phaseName.charAt(0).toUpperCase() + phaseName.slice(1)} Report`;
            ctx.sendMailText(agentMailClient, targetAgent, subject, artifactContent);
          }
        }
      }
      await notifyWorktreeUpdated(phase);
      i++;
      continue;
    }

    const observabilityInput: PhaseObservabilityInput = {
      phaseType,
      expectedArtifact: interpolatedArtifact,
      resolvedCommand: phase.command ? prompt : undefined,
      workflowName: workflowConfig.name,
      workflowPath: workflowConfig.sourcePath,
    };

    const phaseRunStartedAt = new Date().toISOString();
    const result = await ctx.runPhase(
      phaseName, prompt, phaseConfig, progress, logFile, store, notifyClient, agentMailClient,
      observabilityInput,
      observabilityWriter,
    );

    // 5b. Handle control outcomes from phase control tools (ask_operator, abort_phase, needs_retry).
    // Type narrowing uses the discriminated ControlOutcome union — no unchecked casts.
    const controlOutcome = result.controlOutcome;
    if (controlOutcome) {
      // Release files before handling control outcome
      if (phase.files?.reserve) {
        ctx.releaseFiles(agentMailClient, [worktreePath], agentName);
      }

      // Post-phase bookkeeping: stop heartbeat, apply cost/token totals, append
      // PhaseRecord, and persist writeNormalPhaseProgress. Control outcomes
      // short-circuit the normal completion path, so the same bookkeeping
      // must run before any return to keep progress + observability consistent.
      const finishControlOutcome = async (outcome: { phaseSucceeded: boolean; phaseError?: string }): Promise<void> => {
        ctx.heartbeatManager?.stop();
        phaseRecords.push({
          name: feedbackContext ? `${phaseName} (retry)` : phaseName,
          phaseType,
          skipped: false,
          success: outcome.phaseSucceeded,
          costUsd: result.costUsd,
          turns: result.turns,
          error: outcome.phaseError,
          commandsRun: phase.command ? [prompt] : undefined,
          artifactExpected: interpolatedArtifact,
          artifactPresent,
          traceFile: result.traceFile,
          traceMarkdownFile: result.traceMarkdownFile,
          phaseWarnings: result.traceWarnings,
          commandHonored: result.commandHonored,
        });
        progress.costUsd += result.costUsd;
        progress.tokensIn += result.tokensIn;
        progress.tokensOut += result.tokensOut;
        progress.costByPhase ??= {};
        progress.costByPhase[phaseName] = (progress.costByPhase[phaseName] ?? 0) + result.costUsd;
        if (result.filesChanged?.length) {
          for (const file of result.filesChanged) {
            if (!progress.filesChanged.includes(file)) {
              progress.filesChanged.push(file);
            }
          }
        }
        await writeNormalPhaseProgress(store, runId, progress, observabilityWriter);
      };

      if (controlOutcome.type === "ASK_OPERATOR") {
        // Agent requested operator guidance — propagate a distinct waiting-state
        // signal so finalize workflows pause for operator input and are not
        // re-dispatched as failures.
        const question = controlOutcome.question ?? "Operator guidance requested";
        ctx.log(`[${phaseName.toUpperCase()}] ASK_OPERATOR — ${question}`);
        await appendFile(logFile, `\n[PHASE: ${phaseName.toUpperCase()}] ASK_OPERATOR: ${question}\n`);
        await writeTaskPhaseNote(phaseName, "system", `Waiting for operator: ${question}`, { retryable: true, askOperator: true });
        await finishControlOutcome({ phaseSucceeded: false, phaseError: `ask_operator: ${question}` });
        return {
          success: false,
          phaseRecords,
          retryCounts,
          qaVerdictForLog,
          progress,
          waitingForOperator: true,
          waitingQuestion: question,
        };
      }

      if (controlOutcome.type === "ABORTED") {
        // Agent aborted the phase — treat as intentional failure
        const reason = controlOutcome.reason ?? "Phase aborted by agent";
        const suggestion = controlOutcome.suggestion;
        ctx.log(`[${phaseName.toUpperCase()}] ABORTED — ${reason}`);
        await appendFile(logFile, `\n[PHASE: ${phaseName.toUpperCase()}] ABORTED: ${reason}\n`);
        ctx.sendMail(agentMailClient, "foreman", "agent-error", {
          taskId, phase: phaseName, error: reason, suggestion, retryable: false,
        });
        await writeTaskPhaseNote(phaseName, "failure", `Aborted: ${reason}${suggestion ? ` — Suggestion: ${suggestion}` : ""}`, { retryable: false });
        await finishControlOutcome({ phaseSucceeded: false, phaseError: reason });
        await ctx.markStuck(store, runId, projectId, taskId, taskTitle, progress, phaseName, reason, config.projectPath, notifyClient);
        return { success: false, phaseRecords, retryCounts, qaVerdictForLog, progress, failedPhase: phaseName, failureReason: reason };
      }

      if (controlOutcome.type === "NEEDS_RETRY") {
        // Agent requested retry — treat as failure and check retryWith configuration
        const reason = controlOutcome.reason ?? "Retry requested by agent";
        const attemptedApproach = controlOutcome.attemptedApproach;
        const suggestedNextStep = controlOutcome.suggestedNextStep;
        const feedback = [reason, attemptedApproach ? `Attempted: ${attemptedApproach}` : "", suggestedNextStep ? `Next step: ${suggestedNextStep}` : ""].filter(Boolean).join("\n");
        ctx.log(`[${phaseName.toUpperCase()}] NEEDS_RETRY — ${reason}`);
        await appendFile(logFile, `\n[PHASE: ${phaseName.toUpperCase()}] NEEDS_RETRY: ${reason}\n`);

        const retryTarget = retryTargetForFailure(phase, reason);
        if (retryTarget) {
          const currentRetries = retryCounts[phaseName] ?? 0;
          const maxRetries = phase.retryOnFail ?? 0;
          if (currentRetries < maxRetries) {
            retryCounts[phaseName] = currentRetries + 1;
            const feedbackTarget = `${retryTarget}-${taskId}`;
            ctx.sendMailText(agentMailClient, feedbackTarget, `${phaseName.charAt(0).toUpperCase() + phaseName.slice(1)} Feedback - Retry ${currentRetries + 1}`, feedback);
            ctx.sendMail(agentMailClient, "foreman", "agent-error", {
              taskId, phase: phaseName, error: reason, retryable: true,
            });
            ctx.log(`[${phaseName.toUpperCase()}] NEEDS_RETRY — looping back to ${retryTarget} (retry ${currentRetries + 1}/${maxRetries})`);
            await appendFile(logFile, `\n[PIPELINE] ${phaseName} needs_retry, looping back to ${retryTarget} (retry ${currentRetries + 1}/${maxRetries})\n`);
            feedbackContext = feedback;
            // Bookkeeping for the retrying phase: stop heartbeat, persist
            // progress, emit phase-retry event matching the builtin/bash paths.
            await finishControlOutcome({ phaseSucceeded: false, phaseError: reason });
            await emitPhaseReportEvent(ctx, phaseName, interpolatedArtifact, "retry", undefined, retryTarget);
            await writeNormalPhaseEvent(store, config.projectId, runId, "phase-retry", {
              taskId,
              phase: phaseName,
              retryTarget,
              attempt: currentRetries + 1,
              maxRetries,
              reason,
              artifact: interpolatedArtifact,
              artifact_path: interpolatedArtifact ? resolvePhaseArtifact(worktreePath, interpolatedArtifact, projectReportsDir).path : undefined,
              artifact_present: interpolatedArtifact ? resolvePhaseArtifact(worktreePath, interpolatedArtifact, projectReportsDir).present : undefined,
            }, observabilityWriter);
            const targetIdx = phaseIndex.get(retryTarget);
            if (targetIdx !== undefined) {
              retryOnlyActivations.add(retryTarget);
              i = targetIdx;
              continue;
            }
            ctx.log(`[${phaseName.toUpperCase()}] retryWith target '${retryTarget}' not found in workflow — marking stuck`);
          }
        }

        // No retryWith configured or max retries exhausted — treat as terminal failure
        ctx.sendMail(agentMailClient, "foreman", "agent-error", {
          taskId, phase: phaseName, error: reason, retryable: false,
        });
        await writeTaskPhaseNote(phaseName, "failure", `Needs retry exhausted: ${reason}`, { retryable: false });
        await finishControlOutcome({ phaseSucceeded: false, phaseError: reason });
        await ctx.markStuck(store, runId, projectId, taskId, taskTitle, progress, phaseName, reason, config.projectPath, notifyClient);
        return { success: false, phaseRecords, retryCounts, qaVerdictForLog, progress, failedPhase: phaseName, failureReason: reason };
      }
    }

    // 6. Release files
    if (phase.files?.reserve) {
      ctx.releaseFiles(agentMailClient, [worktreePath], agentName);
    }
    const artifactProbe = interpolatedArtifact ? resolvePhaseArtifact(worktreePath, interpolatedArtifact, projectReportsDir) : undefined;
    const artifactPresent = artifactProbe?.present;
    activityPhase.artifactPresent = artifactPresent;
    activityPhase.traceFile = result.traceFile;
    activityPhase.traceMarkdownFile = result.traceMarkdownFile;
    activityPhase.phaseWarnings = result.traceWarnings;
    activityPhase.commandHonored = result.commandHonored;
    if (phase.command && result.success && interpolatedArtifact && artifactPresent === false) {
      const artifactWarning = `[PIPELINE] WARNING — command phase ${phaseName} succeeded without artifact ${interpolatedArtifact}`;
      ctx.log(artifactWarning);
      await appendFile(logFile, `\n${artifactWarning}\n`);
    }

    const commandPhaseContractReasons: string[] = [];
    if (phase.command && result.success) {
      if (result.commandHonored === false && (result.traceWarnings?.length ?? 0) > 0) {
        commandPhaseContractReasons.push(...(result.traceWarnings ?? []));
      }
      if (interpolatedArtifact && artifactPresent === false) {
        const missingArtifactReason = `Expected artifact missing: ${interpolatedArtifact}`;
        if (!commandPhaseContractReasons.includes(missingArtifactReason)) {
          commandPhaseContractReasons.push(missingArtifactReason);
        }
      }
    }

    const commandPhaseContractError = commandPhaseContractReasons.length > 0
      ? `Command phase contract violated: ${commandPhaseContractReasons.join("; ")}`
      : undefined;
    let phaseSucceeded = result.success && !commandPhaseContractError;
    let phaseError = commandPhaseContractError ?? result.error;

    if (phaseName === "documentation" && result.success && interpolatedArtifact && artifactPresent === false) {
      phaseSucceeded = false;
      phaseError = `Expected documentation artifact missing: ${interpolatedArtifact}`;
    }

    const explicitAgentError = await phaseAgentError(agentMailClient, phaseName, taskId, phaseRunStartedAt);
    if (explicitAgentError) {
      phaseSucceeded = false;
      phaseError = explicitAgentError.error;
      ctx.log(`[${phaseName.toUpperCase()}] FAIL — agent-error mail received: ${explicitAgentError.error}`);
      await appendFile(logFile, `\n[PIPELINE] ${phaseName} agent-error: ${explicitAgentError.error}\n`);
    }

    // Check for debug artifacts left by mutating phases (checkpointPr: true).
    if (phaseSucceeded && phase.checkpointPr === true) {
      const debugArtifacts = findDebugArtifacts(worktreePath);
      if (debugArtifacts.length > 0) {
        phaseSucceeded = false;
        phaseError = `Debug artifacts left in worktree: ${debugArtifacts.join(", ")}`;
      }
    }

    if (!phaseSucceeded && !phase.verdict && !commandPhaseContractError && interpolatedArtifact && artifactPresent) {
      const interruptedAfterReport = /terminated|aborted|exceeded maxTurns/i.test(phaseError ?? "");
      if (interruptedAfterReport) {
        phaseSucceeded = true;
        phaseError = undefined;
        ctx.log(`[${phaseName.toUpperCase()}] SDK interrupted after artifact write; accepting ${phaseName} evidence`);
      }
    }

    if (!phaseSucceeded && phase.verdict && !commandPhaseContractError && interpolatedArtifact && artifactPresent) {
      const verdictReport = readReport(worktreePath, interpolatedArtifact, projectReportsDir);
      const artifactVerdict = verdictReport ? parseVerdict(verdictReport) : "unknown";
      const interruptedAfterReport = /terminated|aborted|exceeded maxTurns/i.test(phaseError ?? "");
      if (shouldDeferAgentErrorToVerdictArtifact({ explicitAgentError, artifactVerdict })) {
        phaseSucceeded = true;
        phaseError = undefined;
        ctx.log(`[${phaseName.toUpperCase()}] agent-error ignored because ${basename(interpolatedArtifact)} contains FAIL; verdict retry will handle it`);
      } else if (interruptedAfterReport && artifactVerdict !== "unknown") {
        phaseSucceeded = true;
        phaseError = undefined;
        ctx.log(`[${phaseName.toUpperCase()}] SDK interrupted after a ${artifactVerdict.toUpperCase()} artifact; accepting ${phaseName} evidence`);
      }
    }

    // Record phase result
    phaseRecords.push({
      name: feedbackContext ? `${phaseName} (retry)` : phaseName,
      phaseType,
      skipped: false,
      success: phaseSucceeded,
      costUsd: result.costUsd,
      turns: result.turns,
      error: phaseError,
      commandsRun: phase.command ? [prompt] : undefined,
      artifactExpected: interpolatedArtifact,
      artifactPresent,
      traceFile: result.traceFile,
      traceMarkdownFile: result.traceMarkdownFile,
      phaseWarnings: result.traceWarnings,
      commandHonored: result.commandHonored,
    });

    // FR-3: Update heartbeat with final phase stats before stopping
    ctx.heartbeatManager?.update({
      turns: result.turns,
      toolCalls: progress.toolCalls,
      toolBreakdown: progress.toolBreakdown,
      costUsd: progress.costUsd,
      tokensIn: progress.tokensIn,
      tokensOut: progress.tokensOut,
      lastFileEdited: progress.lastToolCall ?? null,
      lastActivity: new Date().toISOString(),
    });
    // FR-3: Stop heartbeat after phase completes
    ctx.heartbeatManager?.stop();
    // FR-4: Finalize and record activity phase
    if (ctx.activityPhases) {
      const completedActivityPhase = finalizePhaseRecord(activityPhase, {
        success: phaseSucceeded,
        costUsd: result.costUsd,
        turns: result.turns,
        tokensIn: result.tokensIn,
        tokensOut: result.tokensOut,
        error: phaseError,
        toolCalls: progress.toolCalls,
        toolBreakdown: progress.toolBreakdown,
        filesChanged: progress.filesChanged ?? [],
        traceFile: result.traceFile,
        traceMarkdownFile: result.traceMarkdownFile,
        traceWarnings: result.traceWarnings,
        commandHonored: result.commandHonored,
        workflowName: workflowConfig.name,
        workflowPath: workflowConfig.sourcePath,
      });
      ctx.activityPhases.push(completedActivityPhase);

      // Write incremental pipeline report after each phase — provides real-time traceability
      // while pipeline is running, not just at the end.
      let branchName: string | undefined;
      try {
        branchName = config.vcsBackend?.getCurrentBranch ? await config.vcsBackend.getCurrentBranch(worktreePath) : undefined;
      } catch {
        branchName = undefined;
      }
      writeIncrementalPipelineReport({
        worktreePath,
        taskId,
        runId,
        completedPhases: ctx.activityPhases,
        targetBranch: config.targetBranch,
        vcsBranchName: branchName,
      }).catch((err) => {
        ctx.log(`[PIPELINE] Warning: failed to write incremental report: ${String(err)}`);
      });
    }

    progress.costUsd += result.costUsd;
    progress.tokensIn += result.tokensIn;
    progress.tokensOut += result.tokensOut;
    progress.costByPhase ??= {};
    progress.costByPhase[phaseName] = (progress.costByPhase[phaseName] ?? 0) + result.costUsd;
    if (result.filesChanged?.length) {
      for (const file of result.filesChanged) {
        if (!progress.filesChanged.includes(file)) {
          progress.filesChanged.push(file);
        }
      }
    }
    await writeNormalPhaseProgress(store, runId, progress, observabilityWriter);

    const postPhaseBudgetReason = budgetExceededReason();
    if (postPhaseBudgetReason) {
      ctx.log(`[PIPELINE] Budget stop after ${phaseName}: ${postPhaseBudgetReason}`);
      await writeTaskPhaseNote(phaseName, "failure", postPhaseBudgetReason, { retryable: false, budget: true });
      await ctx.markStuck(store, runId, projectId, taskId, taskTitle, progress, phaseName, postPhaseBudgetReason, config.projectPath, notifyClient);
      return { success: false, phaseRecords, retryCounts, qaVerdictForLog, progress, failedPhase: phaseName, failureReason: postPhaseBudgetReason };
    }

    // 7. Handle failure
    if (!phaseSucceeded) {
      const errorMsg = phaseError ?? `${phaseName} failed`;
      const isRateLimit = isRateLimitError(errorMsg);

      // P1: Track first-phase failures for circuit breaker
      if (phaseName === firstPhaseName) {
        firstPhaseFailures.push(new Date().toISOString());
      }

      if (explicitAgentError && !explicitAgentError.retryable) {
        ctx.sendMail(agentMailClient, "foreman", "agent-error", {
          taskId, phase: phaseName, error: errorMsg, retryable: false,
        });
        await writeTaskPhaseNote(phaseName, "failure", `${phaseName} agent-error: ${errorMsg}`, { retryable: false });
        await ctx.markStuck(store, runId, projectId, taskId, taskTitle, progress, phaseName, errorMsg, config.projectPath, notifyClient);
        return { success: false, phaseRecords, retryCounts, qaVerdictForLog, progress, failedPhase: phaseName, failureReason: errorMsg };
      }

      // P1: Rate limit handling with smarter backoff
      if (isRateLimit) {
        const retryAfterSeconds = extractRetryAfterSeconds(errorMsg);
        const currentRetryCount = rateLimitRetries[phaseName] ?? 0;
        rateLimitRetries[phaseName] = currentRetryCount + 1;

        // P1: Alert on rate limit - log and call callback
        const rateLimitAlert = `[RATE_LIMIT_ALERT] ${phaseName} rate limited on ${phaseModel} (attempt ${currentRetryCount + 1}/${RATE_LIMIT_BACKOFF_CONFIG.maxRetries})`;
        ctx.log(rateLimitAlert);
        await appendFile(logFile, `\n${rateLimitAlert}\n`);

        // P1: Log rate limit event for per-model tracking (P2 recommendation)
        await Promise.resolve(store.logRateLimitEvent?.(projectId, phaseModel, phaseName, errorMsg, retryAfterSeconds, runId));

        // P1: Call onRateLimit callback if provided (for alerting)
        ctx.onRateLimit?.(phaseModel, phaseName, errorMsg, retryAfterSeconds);

        // P1: Apply smarter rate limit backoff (30s, 60s, 120s instead of 8s)
        if (currentRetryCount < RATE_LIMIT_BACKOFF_CONFIG.maxRetries) {
          const backoffMs = retryAfterSeconds
            ? retryAfterSeconds * 1000
            : calculateRateLimitBackoffMs(currentRetryCount);

          ctx.log(`[${phaseName.toUpperCase()}] RATE LIMIT — waiting ${backoffMs / 1000}s before retry (${currentRetryCount + 1}/${RATE_LIMIT_BACKOFF_CONFIG.maxRetries})`);
          await appendFile(logFile, `\n[PIPELINE] Rate limit backoff: ${backoffMs / 1000}s delay\n`);
          await sleep(backoffMs);

          // P2: Haiku fallback on rate limit - retry with Sonnet
          if (phaseModel.includes("haiku")) {
            const fallbackModel = getHaikuFallbackModel(phaseModel);
            ctx.log(`[${phaseName.toUpperCase()}] HAIKU FALLBACK: Retrying with ${fallbackModel}`);
            await appendFile(logFile, `\n[PIPELINE] Haiku fallback to ${fallbackModel}\n`);
            // Update phaseModel for the retry
            // Re-run the phase with Sonnet
            // Continue from here by re-running ctx.runPhase with updated model
            const fallbackPhaseConfig = { ...config, model: fallbackModel };
            const fallbackResult = await ctx.runPhase(
              phaseName, prompt, fallbackPhaseConfig, progress, logFile, store, notifyClient, agentMailClient,
              observabilityInput,
              observabilityWriter,
            );

            // Check if fallback succeeded
            if (fallbackResult.success) {
              // Fallback succeeded - record success
              phaseRecords.push({
                name: `${phaseName} (haiku-fallback)`,
                skipped: false,
                success: true,
                costUsd: fallbackResult.costUsd,
                turns: fallbackResult.turns,
                error: undefined,
              });
              progress.costUsd += fallbackResult.costUsd;
              progress.tokensIn += fallbackResult.tokensIn;
              progress.tokensOut += fallbackResult.tokensOut;
              progress.costByPhase ??= {};
              progress.costByPhase[phaseName] = (progress.costByPhase[phaseName] ?? 0) + fallbackResult.costUsd;
              if (fallbackResult.filesChanged?.length) {
                for (const file of fallbackResult.filesChanged) {
                  if (!progress.filesChanged.includes(file)) {
                    progress.filesChanged.push(file);
                  }
                }
              }
              await writeNormalPhaseProgress(store, runId, progress, observabilityWriter);

              // Handle success: send phase-complete, labels, forward artifact.
              if (phase.mail?.onComplete !== false) {
                ctx.sendMail(agentMailClient, "foreman", "phase-complete", {
                  taskId, phase: phaseName, status: "completed", cost: fallbackResult.costUsd, turns: fallbackResult.turns,
                });
              }
              await writeNormalPhaseEvent(store, config.projectId, runId, "complete", { taskId, phase: phaseName, costUsd: fallbackResult.costUsd }, observabilityWriter);
              await writeTaskPhaseNote(phaseName, "progress", `${phaseName} completed after model fallback.`, {
                costUsd: fallbackResult.costUsd,
                turns: fallbackResult.turns,
              });
              await ctx.onTaskPhaseChange?.(config.nativeTaskId ?? null, phaseName);

              if (phase.mail?.forwardArtifactTo && phase.artifact) {
                const interpolatedArtifact = interpolateTaskPlaceholders(
                  phase.artifact,
                  ctx.taskMeta ?? { id: '', title: '', description: '', type: '', priority: 2 },
                );
                const artifactContent = readReport(worktreePath, interpolatedArtifact, projectReportsDir);
                if (artifactContent) {
                  const targetAgent = phase.mail.forwardArtifactTo === "foreman"
                    ? "foreman"
                    : `${phase.mail.forwardArtifactTo}-${taskId}`;
                  const subject = phase.mail.forwardArtifactTo === "foreman"
                    ? `${phaseName.charAt(0).toUpperCase() + phaseName.slice(1)} Complete`
                    : `${phaseName.charAt(0).toUpperCase() + phaseName.slice(1)} Report`;
                  ctx.sendMailText(agentMailClient, targetAgent, subject, artifactContent);
                }
              }
              await notifyWorktreeUpdated(phase);
              i++;
              continue;
            }
            // Fallback also failed - fall through to normal failure handling
            // with updated error message
            ctx.log(`[${phaseName.toUpperCase()}] HAIKU FALLBACK also failed: ${fallbackResult.error}`);
            // Record the fallback attempt as a failure
            phaseRecords.push({
              name: `${phaseName} (haiku-fallback-failed)`,
              skipped: false,
              success: false,
              costUsd: fallbackResult.costUsd,
              turns: fallbackResult.turns,
              error: fallbackResult.error,
            });
            // Continue with normal failure handling
          }

          // Continue to next iteration to retry (or fail if max retries exceeded)
          continue;
        }

        // Max retries exceeded - treat as permanent failure
        ctx.log(`[${phaseName.toUpperCase()}] RATE LIMIT — max retries (${RATE_LIMIT_BACKOFF_CONFIG.maxRetries}) exceeded`);

        // Cooldown retry: when retryAfterCooldown is enabled for this phase,
        // place the task in cooldown state instead of marking it as failed/stuck.
        // The dispatcher will not re-dispatch until the cooldown period expires.
        if (shouldUseCooldownRetry(errorMsg, phase)) {
          const cooldownSeconds = phase.cooldownSeconds ?? COOLDOWN_RETRY_CONFIG.defaultCooldownSeconds;
          const cooldownUntil = new Date(Date.now() + cooldownSeconds * 1000).toISOString();
          const now = new Date().toISOString();

          ctx.log(`[${phaseName.toUpperCase()}] COOLDOWN RETRY — placing task in cooldown until ${cooldownUntil} (${cooldownSeconds}s)`);
          await appendFile(logFile, `\n[PIPELINE] ${phaseName} cooldown retry: cooldown until ${cooldownUntil}\n`);

          // Update run status and set cooldown_until timestamp
          // Using "cooldown" run status (not "stuck") to properly distinguish cooldown state
          const effectiveProjectPath = config.projectPath ?? worktreePath;
          await updateTerminalRunStatus({
            runId,
            projectId,
            projectPath: effectiveProjectPath,
            updates: { status: "cooldown", completed_at: now, cooldown_until: cooldownUntil },
          });

          // Mark task as in cooldown state so dispatcher skips it
          try {
            await Promise.resolve(store.updateTaskStatus?.(taskId, "cooldown"));
            ctx.log(`[${phaseName.toUpperCase()}] Task ${taskId} marked as cooldown until ${cooldownUntil}`);
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            ctx.log(`[${phaseName.toUpperCase()}] Warning: Failed to mark task ${taskId} as cooldown: ${msg.slice(0, 200)}`);
          }

          // Log the cooldown event for tracking
          store.logEvent(projectId, "cooldown", {
            taskId,
            phase: phaseName,
            cooldownUntil,
            cooldownSeconds,
            reason: errorMsg,
          }, runId);

          // Notify the operator
          ctx.sendMail(agentMailClient, "foreman", "agent-error", {
            taskId, phase: phaseName, error: errorMsg, retryable: true,
            cooldownUntil, cooldownSeconds,
          });
          await writeTaskPhaseNote(phaseName, "failure", `${phaseName} failed: ${errorMsg} — cooldown until ${cooldownUntil}`, { retryable: true, cooldownUntil });
          return { success: false, phaseRecords, retryCounts, qaVerdictForLog, progress, cooldownUntil, failedPhase: phaseName, failureReason: errorMsg };
        }
      }

      const kind = failureKind(errorMsg);
      const retryable = kind === "provider_transient";
      ctx.sendMail(agentMailClient, "foreman", "agent-error", {
        taskId, phase: phaseName, error: errorMsg, retryable, failureKind: kind,
      });
      await writeTaskPhaseNote(phaseName, "failure", `${phaseName} failed: ${errorMsg}`, { retryable, failureKind: kind });
      await ctx.markStuck(store, runId, projectId, taskId, taskTitle, progress, phaseName, errorMsg, config.projectPath, notifyClient);
      return { success: false, phaseRecords, retryCounts, qaVerdictForLog, progress, failedPhase: phaseName, failureReason: errorMsg };
    }

    // 8. Verdict handling: parse PASS/FAIL, retry if needed.
    if (phase.verdict && phase.artifact) {
      const interpolatedArtifact = interpolateTaskPlaceholders(
        phase.artifact,
        ctx.taskMeta ?? { id: '', title: '', description: '', type: '', priority: 2 },
      );
      const report = readReport(worktreePath, interpolatedArtifact, projectReportsDir);
      let verdict = report ? parseVerdict(report) : "unknown";

      if (phaseName === "qa" && report && !qaReportHasTestEvidence(report)) {
        verdict = "fail";
        feedbackContext = "QA report invalid: missing explicit test command/output evidence with pass/fail counts.";
        ctx.log("[QA] FAIL — report missing test command evidence");
      }

      if (phaseName === "finalize" && report) {
        const expectedSkippedValidation = !!progress.qaValidatedTargetRef && !!progress.qaValidatedTargetBranch && progress.qaValidatedTargetRef === progress.currentTargetRef;
        const validationStatus = parseFinalizeValidationStatus(report);
        const integrationStatus = parseFinalizeIntegrationStatus(report);
        if (expectedSkippedValidation) {
          if (integrationStatus !== "skipped") {
            verdict = "fail";
            feedbackContext = "Finalize integration contract violated: target branch did not change after QA, so FINALIZE_VALIDATION.md must mark Target Integration as SKIPPED.";
            ctx.log("[FINALIZE] FAIL — expected skipped target integration because target branch was unchanged after QA");
          } else if (validationStatus !== "skipped") {
            verdict = "fail";
            feedbackContext = "Finalize validation contract violated: target branch did not change after QA, so FINALIZE_VALIDATION.md must mark Test Validation as SKIPPED.";
            ctx.log("[FINALIZE] FAIL — expected skipped validation because target branch was unchanged after QA");
          }
        } else {
          if (integrationStatus === "skipped") {
            verdict = "fail";
            feedbackContext = "Finalize integration contract violated: target branch changed after QA, so FINALIZE_VALIDATION.md must not skip target integration.";
            ctx.log("[FINALIZE] FAIL — target integration was skipped even though target branch drifted after QA");
          } else if (integrationStatus !== "success") {
            verdict = "fail";
            feedbackContext = "Finalize integration contract violated: target branch changed after QA, so FINALIZE_VALIDATION.md must record Target Integration as SUCCESS before verdict handling can continue.";
            ctx.log("[FINALIZE] FAIL — target integration did not record SUCCESS after target drift");
          } else if (config.vcsBackend && progress.currentTargetRef) {
            const finalizedHead = await config.vcsBackend.getHeadId(worktreePath).catch(() => "");
            const containsTargetRef = finalizedHead
              ? await config.vcsBackend.isAncestor(worktreePath, progress.currentTargetRef, finalizedHead).catch(() => false)
              : false;
            if (!containsTargetRef) {
              verdict = "fail";
              feedbackContext = "Finalize integration contract violated: target branch drifted after QA, but the finalized branch does not actually contain the current target revision.";
              ctx.log("[FINALIZE] FAIL — finalized branch does not contain the drifted target revision");
            } else if (validationStatus === "skipped") {
              verdict = "fail";
              feedbackContext = "Finalize validation contract violated: target branch changed after QA, so FINALIZE_VALIDATION.md must not skip test validation.";
              ctx.log("[FINALIZE] FAIL — validation was skipped even though target branch drifted after QA");
            }
          } else if (validationStatus === "skipped") {
            verdict = "fail";
            feedbackContext = "Finalize validation contract violated: target branch changed after QA, so FINALIZE_VALIDATION.md must not skip test validation.";
            ctx.log("[FINALIZE] FAIL — validation was skipped even though target branch drifted after QA");
          }
        }
      }

      if (phaseName === "qa") {
        qaVerdictForLog = verdict as "pass" | "fail" | "unknown";
        if (verdict === "pass" && config.vcsBackend) {
          const detectDefaultBranch = (
            config.vcsBackend as Partial<VcsBackend>
          ).detectDefaultBranch;
          const qaTargetBranch = config.targetBranch
            ?? (typeof detectDefaultBranch === "function"
              ? await detectDefaultBranch.call(config.vcsBackend, worktreePath)
              : undefined)
            ?? "main";
          const targetCandidates = [`origin/${qaTargetBranch}`, qaTargetBranch];
          let qaTargetRef = "";
          for (const candidate of targetCandidates) {
            try {
              qaTargetRef = await config.vcsBackend.resolveRef(worktreePath, candidate);
              break;
            } catch {
              // Try local fallback if remote ref is absent.
            }
          }
          try {
            progress.qaValidatedHeadRef = await config.vcsBackend.getHeadId(worktreePath);
          } catch {
            progress.qaValidatedHeadRef = undefined;
          }
          progress.qaValidatedTargetBranch = qaTargetBranch;
          progress.qaValidatedTargetRef = qaTargetRef || undefined;
          await writeNormalPhaseProgress(store, runId, progress, observabilityWriter);
        }
      }

      await writeNormalPhaseEvent(store, config.projectId, runId, "phase-verdict", { taskId, phase: phaseName, verdict, artifact: interpolatedArtifact }, observabilityWriter);

      const verdictRetryTarget = retryTargetForFailure(phase, feedbackContext ?? report ?? `${phaseName}_failed`);
      if (verdict === "fail" && verdictRetryTarget) {
        const retryTarget = verdictRetryTarget;
        const maxRetries = phase.retryOnFail ?? 0;
        const retryCountKey = phaseName;
        const currentRetries = retryCounts[retryCountKey] ?? 0;
        const finalizeFailureScope = phaseName === "finalize" && report
          ? parseFinalizeFailureScope(report)
          : "unknown";

        if (phaseName === "finalize" && finalizeFailureScope === "unrelated_files") {
          ctx.log(`[FINALIZE] FAIL — unrelated/pre-existing test failures detected, skipping developer retry`);
          await appendFile(logFile, `\n[PIPELINE] finalize failed due to unrelated/pre-existing test failures — no developer retry\n`);
          return { success: false, phaseRecords, retryCounts, qaVerdictForLog, progress, failedPhase: phaseName, failureReason: "tests_failed_pre_existing_issues" };
        }

        if (currentRetries < maxRetries) {
          retryCounts[retryCountKey] = currentRetries + 1;

          if (report) {
            const feedbackTarget = `${retryTarget}-${taskId}`;
            ctx.sendMailText(agentMailClient, feedbackTarget, `${phaseName.charAt(0).toUpperCase() + phaseName.slice(1)} Feedback - Retry ${currentRetries + 1}`, report);
          }
          feedbackContext = feedbackContext ?? (report ? extractRepairFeedback(report) : `(${phaseName} failed but no report)`);

          ctx.log(`[${phaseName.toUpperCase()}] FAIL — looping back to ${retryTarget} (retry ${currentRetries + 1}/${maxRetries})`);
          await appendFile(logFile, `\n[PIPELINE] ${phaseName} failed, retrying ${retryTarget} (retry ${currentRetries + 1}/${maxRetries})\n`);
          await emitPhaseReportEvent(ctx, phaseName, interpolatedArtifact, "retry", undefined, retryTarget);
          await writeNormalPhaseEvent(store, config.projectId, runId, "phase-retry", {
            taskId,
            phase: phaseName,
            retryTarget,
            attempt: currentRetries + 1,
            maxRetries,
            reason: feedbackContext ?? `${phaseName} verdict failed`,
            artifact: interpolatedArtifact,
            artifact_path: interpolatedArtifact ? resolvePhaseArtifact(worktreePath, interpolatedArtifact, projectReportsDir).path : undefined,
            artifact_present: interpolatedArtifact ? resolvePhaseArtifact(worktreePath, interpolatedArtifact, projectReportsDir).present : undefined,
          }, observabilityWriter);

          const targetIdx = phaseIndex.get(retryTarget);
          if (targetIdx !== undefined) {
            retryOnlyActivations.add(retryTarget);
            i = targetIdx;
            continue;
          }
          ctx.log(`[${phaseName.toUpperCase()}] retryWith target '${retryTarget}' not found in workflow — continuing`);
        } else {
          const terminalFinalizeFailure = phaseName === "finalize";
          ctx.log(`[${phaseName.toUpperCase()}] FAIL — max retries (${maxRetries}) exhausted${failOnRetriesExhausted || terminalFinalizeFailure ? "" : ", continuing"}`);
          await appendFile(logFile, `\n[PIPELINE] ${phaseName} failed after ${maxRetries} retries${failOnRetriesExhausted || terminalFinalizeFailure ? "" : ", continuing"}\n`);
          feedbackContext = undefined;
          if (failOnRetriesExhausted || terminalFinalizeFailure) {
            return { success: false, phaseRecords, retryCounts, qaVerdictForLog, progress, retriesExhausted: true, failedPhase: phaseName, failureReason: feedbackContext ?? `${phaseName}_failed` };
          }
        }
      } else {
        feedbackContext = undefined;
      }
    } else {
      feedbackContext = undefined;
    }

    // 9. Handle success: send phase-complete, labels, forward artifact.
    if (phase.mail?.onComplete !== false) {
      ctx.sendMail(agentMailClient, "foreman", "phase-complete", {
        taskId, phase: phaseName, status: "completed", cost: result.costUsd, turns: result.turns,
      });
    }
    await emitPhaseReportEvent(ctx, phaseName, interpolatedArtifact, "completed", phases[i + 1]?.name);
    await writeNormalPhaseEvent(store, config.projectId, runId, "complete", {
      taskId,
      phase: phaseName,
      costUsd: result.costUsd,
      artifact: interpolatedArtifact,
      artifact_path: interpolatedArtifact ? resolvePhaseArtifact(worktreePath, interpolatedArtifact, projectReportsDir).path : undefined,
      artifact_present: artifactPresent,
    }, observabilityWriter);
    await writeTaskPhaseNote(phaseName, "progress", `${phaseName} completed.`, {
      costUsd: result.costUsd,
      turns: result.turns,
      artifactPresent,
    });
    await ctx.onTaskPhaseChange?.(config.nativeTaskId ?? null, phaseName);

    if (phase.mail?.forwardArtifactTo && interpolatedArtifact) {
      const artifactContent = readReport(worktreePath, interpolatedArtifact, projectReportsDir);
      if (artifactContent) {
        const targetAgent = phase.mail.forwardArtifactTo === "foreman"
          ? "foreman"
          : `${phase.mail.forwardArtifactTo}-${taskId}`;
        const subject = phase.mail.forwardArtifactTo === "foreman"
          ? `${phaseName.charAt(0).toUpperCase() + phaseName.slice(1)} Complete`
          : `${phaseName.charAt(0).toUpperCase() + phaseName.slice(1)} Report`;
        ctx.sendMailText(agentMailClient, targetAgent, subject, artifactContent);
      }
    }

    await notifyWorktreeUpdated(phase);
    i++;
  }

  return { success: true, phaseRecords, retryCounts, qaVerdictForLog, progress };
}

// ── Session log helper ──────────────────────────────────────────────────────

async function writeSessionLogSafe(
  ctx: PipelineContext,
  progress: RunProgress,
  phaseRecords: PhaseRecord[],
  retryCounts: Record<string, number>,
  qaVerdictForLog: "pass" | "fail" | "unknown",
): Promise<void> {
  const { config } = ctx;
  const { taskId, taskTitle, worktreePath } = config;
  const description = config.taskDescription ?? "(no description)";

  try {
    const pipelineProjectPath = config.projectPath ?? inferProjectPathFromWorkspacePath(worktreePath);
    const sessionLogData: SessionLogData = {
      taskId,
      taskTitle,
      taskDescription: description,
      branchName: `foreman/${taskId}`,
      projectName: basename(pipelineProjectPath),
      phases: phaseRecords,
      totalCostUsd: progress.costUsd,
      totalTurns: progress.turns,
      filesChanged: progress.filesChanged,
      devRetries: retryCounts["developer"] ?? 0,
      qaVerdict: qaVerdictForLog,
    };
    const sessionLogPath = await writeSessionLog(worktreePath, sessionLogData);
    ctx.log(`[SESSION LOG] Written: ${sessionLogPath}`);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    ctx.log(`[SESSION LOG] Failed to write (non-fatal): ${msg}`);
  }
}
