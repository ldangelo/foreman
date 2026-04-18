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
import type { WorkflowConfig, WorkflowPhaseConfig } from "../lib/workflow-loader.js";
import type { TaskMeta } from "../lib/interpolate.js";
import { interpolateTaskPlaceholders } from "../lib/interpolate.js";
import { resolvePhaseModel } from "../lib/workflow-loader.js";
import { ROLE_CONFIGS } from "./roles.js";
import {
  buildPhasePrompt,
  parseVerdict,
  extractIssues,
  parseFinalizeFailureScope,
  parseFinalizeIntegrationStatus,
  parseFinalizeValidationStatus,
  qaReportHasTestEvidence,
} from "./roles.js";
import { rotateReport } from "./agent-worker-finalize.js";
import { writeSessionLog } from "./session-log.js";
import type { PhaseRecord, SessionLogData } from "./session-log.js";
import type { SqliteMailClient } from "../lib/sqlite-mail-client.js";
import type { ForemanStore, RunProgress } from "../lib/store.js";
import type { VcsBackend } from "../lib/vcs/index.js";
import type { NativeTaskStore } from "../lib/task-store.js";
import { RATE_LIMIT_BACKOFF_CONFIG, calculateRateLimitBackoffMs } from "../lib/config.js";
import { inferProjectPathFromWorkspacePath } from "../lib/workspace-paths.js";

// ── Types ──────────────────────────────────────────────────────────────────

type AnyMailClient = SqliteMailClient;

/** Function signature matching the runPhase() in agent-worker.ts. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type RunPhaseFn = (
  role: any,
  prompt: string,
  config: any,
  progress: RunProgress,
  logFile: string,
  store: ForemanStore,
  notifyClient: any,
  agentMailClient?: AnyMailClient | null,
) => Promise<PhaseResult>;

export interface PhaseResult {
  success: boolean;
  costUsd: number;
  turns: number;
  tokensIn: number;
  tokensOut: number;
  error?: string;
  outputText?: string;
}

/** A child task within an epic pipeline run. */
export interface EpicTask {
  /** Bead/seed ID of the child task. */
  seedId: string;
  /** Title of the child task bead. */
  seedTitle: string;
  /** Description of the child task bead. */
  seedDescription?: string;
}

export interface PipelineRunConfig {
  runId: string;
  projectId: string;
  seedId: string;
  seedTitle: string;
  seedDescription?: string;
  seedComments?: string;
  seedType?: string;
  seedLabels?: string[];
  /**
   * Bead priority string ("P0"–"P4", "0"–"4", or undefined).
   * Used to select the per-priority model from the workflow YAML models map.
   */
  seedPriority?: string;
  model: string;
  worktreePath: string;
  projectPath?: string;
  skipExplore?: boolean;
  skipReview?: boolean;
  env: Record<string, string | undefined>;
  /** Override target branch for finalize rebase/push and auto-merge. */
  targetBranch?: string;
  /**
   * VCS backend instance for computing backend-specific commands.
   * When provided, finalize and reviewer prompts are rendered with
   * backend-specific VCS command variables (TRD-026, TRD-027).
   * Falls back to git defaults when absent.
   */
  vcsBackend?: VcsBackend;
  /**
   * Optional task ID from native task store.
   * When present, pipeline-executor calls taskStore?.updatePhase(taskId, phaseName)
   * at each phase transition (REQ-012). Null/undefined in beads fallback mode.
   */
  taskId?: string | null;
  /**
   * Parent epic bead ID. When set, this run is part of an epic execution.
   * Used to link child task results back to the parent epic.
   */
  epicId?: string;
  /** Task metadata for placeholder interpolation in bash/command phases (REQ-008). */
  taskMeta?: TaskMeta;
}

export interface PipelineContext {
  config: PipelineRunConfig;
  workflowConfig: WorkflowConfig;
  store: ForemanStore;
  logFile: string;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  notifyClient: any;
  agentMailClient: AnyMailClient | null;
  /**
   * Optional native task store for phase-level visibility (REQ-012).
   * When present and config.taskId is set, updatePhase() is called at each
   * phase transition. No-op if absent or if config.taskId is null/undefined.
   */
  taskStore?: NativeTaskStore;
  /**
   * Epic mode: ordered list of child tasks to execute.
   * When set, the pipeline executor runs taskPhases for each task
   * instead of running all phases in sequence for a single task.
   */
  epicTasks?: EpicTask[];
  /** The runPhase function from agent-worker.ts */
  runPhase: RunPhaseFn;
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
   * Epic mode callback: update a child task bead's status.
   * Called when a task starts (in_progress) or completes (closed/failed).
   */
  onTaskStatusChange?: (taskSeedId: string, status: "in_progress" | "completed" | "failed") => Promise<void>;
  /**
   * Epic mode callback: create a bug bead when QA fails on a task.
   * Returns the created bug bead ID, or undefined if creation fails.
   */
  onTaskQaFailure?: (taskSeedId: string, taskTitle: string, epicId: string) => Promise<string | undefined>;
  /**
   * Epic mode callback: close a bug bead when QA passes after retry.
   */
  onTaskQaPass?: (bugBeadId: string) => Promise<void>;
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
   * Responsible for: reading finalize mail, enqueuing to merge queue,
   * updating run status, resetting seed on failure, sending branch-ready mail.
   * @param info.success - Whether the pipeline completed successfully.
   *                        Only send branch-ready when success=true AND currentPhase=finalize.
   */
  onPipelineComplete?: (info: {
    progress: RunProgress;
    phaseRecords: PhaseRecord[];
    retryCounts: Record<string, number>;
    success: boolean;
  }) => Promise<void>;
  /**
   * Task metadata for placeholder interpolation in bash/command phases (REQ-008).
   * Passed from the dispatcher via WorkerConfig.taskMeta.
   * Undefined for legacy runs without taskMeta.
   */
  taskMeta?: TaskMeta;
}

// ── Helpers ─────────────────────────────────────────────────────────────────

function readReport(worktreePath: string, filename: string): string | null {
  const p = join(worktreePath, filename);
  try { return readFileSync(p, "utf-8"); } catch { return null; }
}

/**
 * Detect if an error is a rate limit (429) error.
 * Returns true if the error indicates a rate limit, false otherwise.
 */
function isRateLimitError(error: string | undefined): boolean {
  if (!error) return false;
  const errorLower = error.toLowerCase();
  return (
    errorLower.includes("rate limit") ||
    errorLower.includes("429") ||
    errorLower.includes("hit your limit") ||
    errorLower.includes("too many requests") ||
    errorLower.includes("rate_limit_exceeded")
  );
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

/** Result of running a sequence of phases. */
interface PhaseSequenceResult {
  success: boolean;
  phaseRecords: PhaseRecord[];
  retryCounts: Record<string, number>;
  qaVerdictForLog: "pass" | "fail" | "unknown";
  progress: RunProgress;
  /** Set when a verdict-FAIL exhausted retries (task failed, not stuck). */
  retriesExhausted?: boolean;
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
): Promise<BashPhaseResult> {
  // Interpolate placeholders
  const interpolated = taskMeta
    ? interpolateTaskPlaceholders(bashCommand, taskMeta)
    : bashCommand;

  let stdout = '';
  let stderr = '';
  let exitCode: number | null = null;
  let timedOut = false;

  try {
    const result = await execFilePromise('/bin/sh', ['-c', interpolated], {
      cwd,
      timeout: timeoutMs,
      maxBuffer: 10 * 1024 * 1024, // 10 MB
    });
    stdout = result.stdout ?? '';
    stderr = result.stderr ?? '';
    exitCode = result.status ?? 0;
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
  if (artifactFile && stdout) {
    try {
      writeFileSync(artifactFile, stdout, 'utf8');
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
  const isEpicMode = epicTasks && epicTasks.length > 0 && workflowConfig.taskPhases;

  if (isEpicMode) {
    await executeEpicPipeline(ctx);
  } else {
    await executeSingleTaskPipeline(ctx);
  }
}

// ── Resume detection ────────────────────────────────────────────────────────

/**
 * Parse `git log --oneline` output from an epic worktree and extract
 * the bead/seed IDs of tasks that have already been committed.
 *
 * Commit messages follow the format: `<title> (<beadId>)`
 * For example: `Add user auth (task-7)` → extracts `task-7`.
 *
 * @returns A Set of completed task seed IDs found in the git history.
 */
export function parseCompletedTaskIds(gitLogOutput: string): Set<string> {
  const completed = new Set<string>();
  // Match the trailing parenthesized bead ID in each commit line.
  // git log --oneline format: "<hash> <message>"
  // We look for the pattern "(<beadId>)" at the end of each line.
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
 * already-committed task bead IDs and skips them.
 */
async function executeEpicPipeline(ctx: PipelineContext): Promise<void> {
  const { config, workflowConfig, store, logFile } = ctx;
  const { runId, seedId, worktreePath } = config;
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
    const remainingTasks = epicTasks.filter((t) => !resumedTaskIds.has(t.seedId));
    const skippedCount = totalTaskCount - remainingTasks.length;

    if (skippedCount > 0) {
      ctx.log(`[EPIC] Resuming from task ${skippedCount + 1} of ${totalTaskCount} (${skippedCount} completed)`);
      await appendFile(logFile, `\n[EPIC] Resume: ${skippedCount} tasks already committed, skipping to task ${skippedCount + 1}\n`);
      epicTasks = remainingTasks;
    }
  }

  const taskPhaseStr = taskPhaseNames.join(" → ");
  const finalPhaseStr = finalPhaseNames.length > 0 ? ` | final: ${finalPhaseNames.join(" → ")}` : "";
  ctx.log(`[EPIC] Starting epic pipeline for ${seedId} — ${epicTasks.length} tasks`);
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
  let activeBugBeadId: string | undefined;

  for (let taskIdx = 0; taskIdx < epicTasks.length; taskIdx++) {
    const task = epicTasks[taskIdx];
    ctx.log(`[EPIC] Task ${taskIdx + 1}/${epicTasks.length}: ${task.seedId} — ${task.seedTitle}`);
    await appendFile(logFile, `\n[EPIC] === Task ${taskIdx + 1}/${epicTasks.length}: ${task.seedId} ===\n`);

    // TRD-012: Update epic progress in RunProgress
    totalProgress.epicCurrentTaskId = task.seedId;
    store.updateRunProgress(runId, totalProgress);

    // TRD-011: Mark task bead as in_progress
    if (ctx.onTaskStatusChange) {
      await ctx.onTaskStatusChange(task.seedId, "in_progress").catch(() => {});
    }

    // Build a task-specific config overlay (use task's seedId/title/description for prompts)
    const taskConfig: PipelineRunConfig = {
      ...config,
      // Keep the epic's seedId for run tracking, but pass task info for prompts
      seedDescription: task.seedDescription ?? config.seedDescription,
      seedComments: `Epic task ${taskIdx + 1}/${epicTasks.length}: ${task.seedTitle}\n` +
        (completedTaskIds.length > 0
          ? `Previously completed: ${completedTaskIds.join(", ")}\n`
          : "") +
        (config.seedComments ?? ""),
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
    const result = await runPhaseSequence(taskCtx, taskPhases, totalProgress, true);

    // Accumulate progress
    totalProgress = result.progress;
    allPhaseRecords.push(...result.phaseRecords);
    for (const [k, v] of Object.entries(result.retryCounts)) {
      allRetryCounts[k] = (allRetryCounts[k] ?? 0) + v;
    }

    if (result.success) {
      completedCount++;
      completedTaskIds.push(task.seedId);

      // TRD-010: Close bug bead if QA passed after retry
      if (activeBugBeadId && ctx.onTaskQaPass) {
        await ctx.onTaskQaPass(activeBugBeadId).catch(() => {});
        activeBugBeadId = undefined;
      }

      // Commit after each successful task (epic mode: one commit per task)
      if (config.vcsBackend) {
        try {
          await config.vcsBackend.commit(worktreePath, `${task.seedTitle} (${task.seedId})`);
          ctx.log(`[EPIC] Committed task ${task.seedId}`);
        } catch (err: unknown) {
          // Non-fatal: commit may fail if no changes (e.g. test-only task)
          const msg = err instanceof Error ? err.message : String(err);
          ctx.log(`[EPIC] Commit for ${task.seedId} skipped: ${msg}`);
        }
      }

      // TRD-011: Mark task bead as completed
      if (ctx.onTaskStatusChange) {
        await ctx.onTaskStatusChange(task.seedId, "completed").catch(() => {});
      }

      // TRD-012: Update epic progress
      totalProgress.epicTasksCompleted = completedCount;
      totalProgress.epicCostByTask ??= {};
      totalProgress.epicCostByTask[task.seedId] = result.progress.costUsd - (totalProgress.costUsd - result.progress.costUsd);
      store.updateRunProgress(runId, totalProgress);

      ctx.log(`[EPIC] Task ${task.seedId} PASSED (${completedCount}/${epicTasks.length} done)`);
      await appendFile(logFile, `\n[EPIC] Task ${task.seedId} PASSED\n`);
    } else {
      failedCount++;

      // TRD-010: Create bug bead on QA failure
      if (result.retriesExhausted && ctx.onTaskQaFailure && config.epicId) {
        activeBugBeadId = await ctx.onTaskQaFailure(task.seedId, task.seedTitle, config.epicId).catch(() => undefined);
        if (activeBugBeadId) {
          ctx.log(`[EPIC] Created bug bead ${activeBugBeadId} for QA failure on ${task.seedId}`);
        }
      }

      // TRD-011: Mark task bead as failed
      if (ctx.onTaskStatusChange) {
        await ctx.onTaskStatusChange(task.seedId, "failed").catch(() => {});
      }

      ctx.log(`[EPIC] Task ${task.seedId} FAILED${result.retriesExhausted ? " (retries exhausted)" : ""}`);
      await appendFile(logFile, `\n[EPIC] Task ${task.seedId} FAILED\n`);

      // Apply onError strategy
      if (workflowConfig.onError === "stop") {
        ctx.log(`[EPIC] onError=stop — halting epic after task ${task.seedId} failure`);
        await appendFile(logFile, `\n[EPIC] Halted (onError=stop)\n`);
        await ctx.markStuck(
          store, runId, config.projectId, seedId, config.seedTitle,
          totalProgress, "epic-task-failed",
          `Task ${task.seedId} failed — epic halted (onError=stop)`,
          ctx.notifyClient, config.projectPath,
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

    const finalResult = await runPhaseSequence(finalCtx, finalPhases, totalProgress);
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
  const { seedId } = config;

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
  ctx.log(`Pipeline starting for ${seedId} [workflow: ${workflowConfig.name}]`);
  ctx.log(`[PIPELINE] Phase sequence: ${phaseNames}`);
  await appendFile(logFile, `\n[foreman-worker] Pipeline orchestration starting\n[PIPELINE] Phase sequence: ${phaseNames}\n`);

  const result = await runPhaseSequence(ctx, workflowConfig.phases, progress);

  // Session log
  await writeSessionLogSafe(ctx, result.progress, result.phaseRecords, result.retryCounts, result.qaVerdictForLog);

  // Pipeline completion callback
  // P0 fix: Pass result.success to prevent branch-ready on pipeline failure.
  if (ctx.onPipelineComplete) {
    await ctx.onPipelineComplete({
      progress: result.progress,
      phaseRecords: result.phaseRecords,
      retryCounts: result.retryCounts,
      success: result.success,
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
  phases: import("../lib/workflow-loader.js").WorkflowPhaseConfig[],
  initialProgress: RunProgress,
  /** When true (epic task mode), exhausted retries return failure instead of continuing. */
  failOnRetriesExhausted: boolean = false,
): Promise<PhaseSequenceResult> {
  const { config, workflowConfig, store, logFile, notifyClient, agentMailClient } = ctx;
  const { runId, projectId, seedId, seedTitle, worktreePath } = config;
  const description = config.seedDescription ?? "(no description)";
  const comments = config.seedComments;

  const progress = { ...initialProgress };
  const phaseRecords: PhaseRecord[] = [];
  let feedbackContext: string | undefined;
  let qaVerdictForLog: "pass" | "fail" | "unknown" = "unknown";
  const retryCounts: Record<string, number> = {};
  // P1: Explorer circuit breaker - track Explorer failures to fail fast after 3
  const explorerFailures: string[] = [];
  // P1/P2: Rate limit tracking per phase
  const rateLimitRetries: Record<string, number> = {};

  // Build a phase index for retryWith lookups
  const phaseIndex = new Map<string, number>();
  for (let idx = 0; idx < phases.length; idx++) {
    phaseIndex.set(phases[idx].name, idx);
  }

  let i = 0;
  while (i < phases.length) {
    const phase = phases[i];
    const phaseName = phase.name;
    const agentName = `${phaseName}-${seedId}`;
    const hasExplorerReport = existsSync(join(worktreePath, "EXPLORER_REPORT.md"));

    progress.currentPhase = phaseName;
    store.updateRunProgress(runId, progress);

    // 1. Skip if artifact already exists (resume from crash)
    if (phase.skipIfArtifact) {
      const artifactPath = join(worktreePath, phase.skipIfArtifact);
      if (existsSync(artifactPath)) {
        ctx.log(`[${phaseName.toUpperCase()}] Skipping — ${phase.skipIfArtifact} already exists`);
        await appendFile(logFile, `\n[PHASE: ${phaseName.toUpperCase()}] SKIPPED (artifact already present)\n`);
        phaseRecords.push({ name: phaseName, skipped: true });
        i++;
        continue;
      }
    }

    // 2. Register agent mail identity
    await ctx.registerAgent(agentMailClient, agentName);

    // 3. Send phase-started mail
    if (phase.mail?.onStart !== false) {
      ctx.sendMail(agentMailClient, "foreman", "phase-started", { seedId, phase: phaseName });
    }

    // 4. Reserve files
    if (phase.files?.reserve) {
      ctx.reserveFiles(agentMailClient, [worktreePath], agentName, phase.files.leaseSecs ?? 600);
    }

    // 5. Rotate and run phase
    if (phase.artifact) {
      rotateReport(worktreePath, phase.artifact);
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
          seedId,
          seedTitle,
          baseBranch,
          worktreePath,
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
        store.updateRunProgress(runId, progress);
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

    // TRD-005: Command phase — use interpolated command string as prompt (no file load)
    const prompt = phase.command
      ? interpolateTaskPlaceholders(phase.command, ctx.taskMeta ?? { id: '', title: '', description: '', type: '', priority: 2 })
      : buildPhasePrompt(phaseName, {
      seedId,
      seedTitle,
      seedDescription: description,
      seedComments: comments,
      seedType: config.seedType,
      runId,
      hasExplorerReport,
      requiresExplorerReport: workflowConfig.name === "default" && phaseName === "developer",
      feedbackContext,
      worktreePath,
      baseBranch: config.targetBranch,
      ...vcsPromptVars,
    }, ctx.promptOpts);

    const roleConfigFallback = (ROLE_CONFIGS as Record<string, { model: string } | undefined>)[phaseName];
    const fallbackModel = roleConfigFallback?.model ?? config.model;
    let phaseModel = resolvePhaseModel(phase, config.seedPriority, fallbackModel);

    // P1: Explorer circuit breaker - fail fast if Explorer has failed 3 times
    // This prevents empty branch pollution when Explorer keeps failing
    if (phaseName === "explorer") {
      const recentExplorerFailures = explorerFailures.filter(
        (t) => Date.now() - new Date(t).getTime() < 60 * 60 * 1000, // Within last hour
      );
      if (recentExplorerFailures.length >= 3) {
        ctx.log(`[EXPLORER] CIRCUIT BREAKER: Explorer has failed ${recentExplorerFailures.length} times in the last hour — failing fast`);
        await appendFile(logFile, `\n[PIPELINE] EXPLORER CIRCUIT BREAKER: ${recentExplorerFailures.length} failures detected, failing fast\n`);
        const errorMsg = `Explorer circuit breaker: ${recentExplorerFailures.length} failures in the last hour`;
        ctx.sendMail(agentMailClient, "foreman", "agent-error", {
          seedId, phase: phaseName, error: errorMsg, retryable: false,
        });
        await ctx.markStuck(store, runId, projectId, seedId, seedTitle, progress, phaseName, errorMsg, notifyClient, config.projectPath);
        return { success: false, phaseRecords, retryCounts, qaVerdictForLog, progress };
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

    const phaseConfig = { ...config, model: phaseModel };

    // TRD-004: Bash phase — execute via execFile instead of SDK agent
    if (phase.bash) {
      const bashResult = await runBashPhase(
        phase.bash,
        ctx.taskMeta,
        worktreePath,
        phase.artifact,
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
        skipped: false,
        success: result.success,
        costUsd: 0,
        turns: 0,
        error: result.error,
      });
      progress.costUsd += 0;
      store.updateRunProgress(runId, progress);
      // Continue to verdict handling below (same as ctx.runPhase path)
      if (!result.success) {
        const errorMsg = result.error ?? `${phaseName} failed`;
        ctx.log(`[${phaseName.toUpperCase()}] FAIL — ${errorMsg}`);
        await appendFile(logFile, `\n[PIPELINE] ${phaseName} FAIL: ${errorMsg}\n`);
        ctx.sendMail(agentMailClient, "foreman", "agent-error", {
          seedId, phase: phaseName, error: errorMsg, retryable: false,
        });
        if (phase.retryWith && retryCounts[phaseName] < (phase.retryOnFail ?? 0)) {
          retryCounts[phaseName] = (retryCounts[phaseName] ?? 0) + 1;
          ctx.log(`[${phaseName.toUpperCase()}] Retry ${retryCounts[phaseName]}/${phase.retryOnFail}`);
          await appendFile(logFile, `\n[PIPELINE] ${phaseName} retry ${retryCounts[phaseName]}\n`);
          // fall through to retry
        } else {
          await ctx.markStuck(store, runId, projectId, seedId, seedTitle, progress, phaseName, errorMsg, notifyClient, config.projectPath);
          return { success: false, phaseRecords, retryCounts, qaVerdictForLog, progress };
        }
      }
      // Handle verdict if configured
      if (phase.verdict && result.outputText) {
        qaVerdictForLog = parseVerdict(result.outputText);
      }
      // Increment i and continue to next phase
      i++;
      continue;
    }

    const result = await ctx.runPhase(
      phaseName, prompt, phaseConfig, progress, logFile, store, notifyClient, agentMailClient,
    );

    // 6. Release files
    if (phase.files?.reserve) {
      ctx.releaseFiles(agentMailClient, [worktreePath], agentName);
    }

    // Record phase result
    phaseRecords.push({
      name: feedbackContext ? `${phaseName} (retry)` : phaseName,
      skipped: false,
      success: result.success,
      costUsd: result.costUsd,
      turns: result.turns,
      error: result.error,
    });

    progress.costUsd += result.costUsd;
    progress.tokensIn += result.tokensIn;
    progress.tokensOut += result.tokensOut;
    progress.costByPhase ??= {};
    progress.costByPhase[phaseName] = (progress.costByPhase[phaseName] ?? 0) + result.costUsd;
    store.updateRunProgress(runId, progress);

    const phaseArtifactContent = phase.artifact ? readReport(worktreePath, phase.artifact) : null;

    if (phase.artifact && !phaseArtifactContent) {
      const errorMsg = `${phaseName} completed without required artifact ${phase.artifact}`;
      ctx.log(`[${phaseName.toUpperCase()}] FAIL — ${errorMsg}`);
      await appendFile(logFile, `\n[PIPELINE] ${errorMsg}\n`);
      ctx.sendMail(agentMailClient, "foreman", "agent-error", {
        seedId,
        phase: phaseName,
        error: errorMsg,
        retryable: false,
      });
      await ctx.markStuck(
        store,
        runId,
        projectId,
        seedId,
        seedTitle,
        progress,
        phaseName,
        errorMsg,
        notifyClient,
        config.projectPath,
      );
      return { success: false, phaseRecords, retryCounts, qaVerdictForLog, progress };
    }

    // 7. Handle failure
    if (!result.success) {
      const errorMsg = result.error ?? `${phaseName} failed`;
      const isRateLimit = isRateLimitError(errorMsg);

      // P1: Track Explorer failures for circuit breaker
      if (phaseName === "explorer") {
        explorerFailures.push(new Date().toISOString());
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
        store.logRateLimitEvent(projectId, phaseModel, phaseName, errorMsg, retryAfterSeconds, runId);

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
              store.updateRunProgress(runId, progress);

              // Handle success: send phase-complete, labels, forward artifact.
              if (phase.mail?.onComplete !== false) {
                ctx.sendMail(agentMailClient, "foreman", "phase-complete", {
                  seedId, phase: phaseName, status: "completed", cost: fallbackResult.costUsd, turns: fallbackResult.turns,
                });
              }
              store.logEvent(config.projectId, "complete", { seedId, phase: phaseName, costUsd: fallbackResult.costUsd }, runId);
              ctx.taskStore?.updatePhase(config.taskId ?? null, phaseName);

              if (phase.mail?.forwardArtifactTo && phase.artifact) {
                const artifactContent = readReport(worktreePath, phase.artifact);
                if (artifactContent) {
                  const targetAgent = phase.mail.forwardArtifactTo === "foreman"
                    ? "foreman"
                    : `${phase.mail.forwardArtifactTo}-${seedId}`;
                  const subject = phase.mail.forwardArtifactTo === "foreman"
                    ? `${phaseName.charAt(0).toUpperCase() + phaseName.slice(1)} Complete`
                    : `${phaseName.charAt(0).toUpperCase() + phaseName.slice(1)} Report`;
                  ctx.sendMailText(agentMailClient, targetAgent, subject, artifactContent);
                }
              }
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
      }

      ctx.sendMail(agentMailClient, "foreman", "agent-error", {
        seedId, phase: phaseName, error: errorMsg, retryable: !isRateLimit,
      });
      await ctx.markStuck(store, runId, projectId, seedId, seedTitle, progress, phaseName, errorMsg, notifyClient, config.projectPath);
      return { success: false, phaseRecords, retryCounts, qaVerdictForLog, progress };
    }

    // 8. Verdict handling: parse PASS/FAIL, retry if needed.
    if (phase.verdict && phase.artifact) {
      const report = readReport(worktreePath, phase.artifact);
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
          store.updateRunProgress(runId, progress);
        }
      }

      if (verdict === "fail" && phase.retryWith) {
        const retryTarget = phase.retryWith;
        const maxRetries = phase.retryOnFail ?? 0;
        const retryCountKey = phaseName;
        const currentRetries = retryCounts[retryCountKey] ?? 0;
        const finalizeFailureScope = phaseName === "finalize" && report
          ? parseFinalizeFailureScope(report)
          : "unknown";

        if (phaseName === "finalize" && finalizeFailureScope === "unrelated_files") {
          ctx.log(`[FINALIZE] FAIL — unrelated/pre-existing test failures detected, skipping developer retry`);
          await appendFile(logFile, `\n[PIPELINE] finalize failed due to unrelated/pre-existing test failures — no developer retry\n`);
          return { success: false, phaseRecords, retryCounts, qaVerdictForLog, progress };
        }

        if (currentRetries < maxRetries) {
          retryCounts[retryCountKey] = currentRetries + 1;

          if (phase.mail?.onFail && report) {
            const feedbackTarget = `${phase.mail.onFail}-${seedId}`;
            ctx.sendMailText(agentMailClient, feedbackTarget, `${phaseName.charAt(0).toUpperCase() + phaseName.slice(1)} Feedback - Retry ${currentRetries + 1}`, report);
          }
          feedbackContext = feedbackContext ?? (report ? extractIssues(report) : `(${phaseName} failed but no report)`);

          ctx.log(`[${phaseName.toUpperCase()}] FAIL — looping back to ${retryTarget} (retry ${currentRetries + 1}/${maxRetries})`);
          await appendFile(logFile, `\n[PIPELINE] ${phaseName} failed, retrying ${retryTarget} (retry ${currentRetries + 1}/${maxRetries})\n`);

          const targetIdx = phaseIndex.get(retryTarget);
          if (targetIdx !== undefined) {
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
            return { success: false, phaseRecords, retryCounts, qaVerdictForLog, progress, retriesExhausted: true };
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
        seedId, phase: phaseName, status: "completed", cost: result.costUsd, turns: result.turns,
      });
    }
    store.logEvent(config.projectId, "complete", { seedId, phase: phaseName, costUsd: result.costUsd }, runId);
    ctx.taskStore?.updatePhase(config.taskId ?? null, phaseName);

    if (phase.mail?.forwardArtifactTo && phase.artifact) {
      const artifactContent = readReport(worktreePath, phase.artifact);
      if (artifactContent) {
        const targetAgent = phase.mail.forwardArtifactTo === "foreman"
          ? "foreman"
          : `${phase.mail.forwardArtifactTo}-${seedId}`;
        const subject = phase.mail.forwardArtifactTo === "foreman"
          ? `${phaseName.charAt(0).toUpperCase() + phaseName.slice(1)} Complete`
          : `${phaseName.charAt(0).toUpperCase() + phaseName.slice(1)} Report`;
        ctx.sendMailText(agentMailClient, targetAgent, subject, artifactContent);
      }
    }

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
  const { seedId, seedTitle, worktreePath } = config;
  const description = config.seedDescription ?? "(no description)";

  try {
    const pipelineProjectPath = config.projectPath ?? inferProjectPathFromWorkspacePath(worktreePath);
    const sessionLogData: SessionLogData = {
      seedId,
      seedTitle,
      seedDescription: description,
      branchName: `foreman/${seedId}`,
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
