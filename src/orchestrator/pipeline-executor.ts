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

import { existsSync, readFileSync } from "node:fs";
import { execSync } from "node:child_process";
import { appendFile } from "node:fs/promises";
import { join, basename } from "node:path";
import type { WorkflowConfig, WorkflowPhaseConfig } from "../lib/workflow-loader.js";
import { resolvePhaseModel } from "../lib/workflow-loader.js";
import { ROLE_CONFIGS } from "./roles.js";
import { buildPhasePrompt, parseVerdict, extractIssues } from "./roles.js";
import { enqueueAddLabelsToBead } from "./task-backend-ops.js";
import { rotateReport } from "./agent-worker-finalize.js";
import { writeSessionLog } from "./session-log.js";
import type { PhaseRecord, SessionLogData } from "./session-log.js";
import type { SqliteMailClient } from "../lib/sqlite-mail-client.js";
import type { ForemanStore, RunProgress } from "../lib/store.js";
import type { VcsBackend } from "../lib/vcs/index.js";
import type { NativeTaskStore } from "../lib/task-store.js";

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
   * Called after the last phase (finalize) completes successfully.
   * Responsible for: reading finalize mail, enqueuing to merge queue,
   * updating run status, resetting seed on failure, sending branch-ready mail.
   */
  onPipelineComplete?: (info: {
    progress: RunProgress;
    phaseRecords: PhaseRecord[];
    retryCounts: Record<string, number>;
  }) => Promise<void>;
}

// ── Helpers ─────────────────────────────────────────────────────────────────

function readReport(worktreePath: string, filename: string): string | null {
  const p = join(worktreePath, filename);
  try { return readFileSync(p, "utf-8"); } catch { return null; }
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

// ── Generic Pipeline Executor ───────────────────────────────────────────────

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
  writeSessionLogSafe(ctx, totalProgress, allPhaseRecords, allRetryCounts, "unknown");

  // ── Pipeline completion ──────────────────────────────────────────────
  if (ctx.onPipelineComplete) {
    await ctx.onPipelineComplete({
      progress: totalProgress,
      phaseRecords: allPhaseRecords,
      retryCounts: allRetryCounts,
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
  writeSessionLogSafe(ctx, result.progress, result.phaseRecords, result.retryCounts, result.qaVerdictForLog);

  // Pipeline completion callback
  if (ctx.onPipelineComplete) {
    await ctx.onPipelineComplete({
      progress: result.progress,
      phaseRecords: result.phaseRecords,
      retryCounts: result.retryCounts,
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
  const { config, store, logFile, notifyClient, agentMailClient } = ctx;
  const { runId, projectId, seedId, seedTitle, worktreePath } = config;
  const description = config.seedDescription ?? "(no description)";
  const comments = config.seedComments;

  const progress = { ...initialProgress };
  const phaseRecords: PhaseRecord[] = [];
  let feedbackContext: string | undefined;
  let qaVerdictForLog: "pass" | "fail" | "unknown" = "unknown";
  const retryCounts: Record<string, number> = {};

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
    let vcsPromptVars: {
      vcsStageCommand?: string;
      vcsCommitCommand?: string;
      vcsPushCommand?: string;
      vcsRebaseCommand?: string;
      vcsBranchVerifyCommand?: string;
      vcsCleanCommand?: string;
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
        vcsPromptVars.vcsRebaseCommand = finalizeCommands.rebaseCommand;
        vcsPromptVars.vcsBranchVerifyCommand = finalizeCommands.branchVerifyCommand;
        vcsPromptVars.vcsCleanCommand = finalizeCommands.cleanCommand;
      }
    }

    const prompt = buildPhasePrompt(phaseName, {
      seedId,
      seedTitle,
      seedDescription: description,
      seedComments: comments,
      seedType: config.seedType,
      runId,
      hasExplorerReport,
      feedbackContext,
      worktreePath,
      baseBranch: config.targetBranch,
      ...vcsPromptVars,
    }, ctx.promptOpts);

    const roleConfigFallback = (ROLE_CONFIGS as Record<string, { model: string } | undefined>)[phaseName];
    const fallbackModel = roleConfigFallback?.model ?? config.model;
    const phaseModel = resolvePhaseModel(phase, config.seedPriority, fallbackModel);
    const phaseConfig = { ...config, model: phaseModel };

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

    // 7. Handle failure
    if (!result.success) {
      ctx.sendMail(agentMailClient, "foreman", "agent-error", {
        seedId, phase: phaseName, error: result.error ?? `${phaseName} failed`, retryable: true,
      });
      await ctx.markStuck(store, runId, projectId, seedId, seedTitle, progress, phaseName, result.error ?? `${phaseName} failed`, notifyClient, config.projectPath);
      return { success: false, phaseRecords, retryCounts, qaVerdictForLog, progress };
    }

    // 8. Verdict handling: parse PASS/FAIL, retry if needed.
    if (phase.verdict && phase.artifact) {
      const report = readReport(worktreePath, phase.artifact);
      const verdict = report ? parseVerdict(report) : "unknown";

      if (phaseName === "qa") {
        qaVerdictForLog = verdict as "pass" | "fail" | "unknown";
      }

      if (verdict === "fail" && phase.retryWith) {
        const retryTarget = phase.retryWith;
        const maxRetries = phase.retryOnFail ?? 0;
        const retryCountKey = phaseName;
        const currentRetries = retryCounts[retryCountKey] ?? 0;

        if (currentRetries < maxRetries) {
          retryCounts[retryCountKey] = currentRetries + 1;

          if (phase.mail?.onFail && report) {
            const feedbackTarget = `${phase.mail.onFail}-${seedId}`;
            ctx.sendMailText(agentMailClient, feedbackTarget, `${phaseName.charAt(0).toUpperCase() + phaseName.slice(1)} Feedback - Retry ${currentRetries + 1}`, report);
          }
          feedbackContext = report ? extractIssues(report) : `(${phaseName} failed but no report)`;

          ctx.log(`[${phaseName.toUpperCase()}] FAIL — looping back to ${retryTarget} (retry ${currentRetries + 1}/${maxRetries})`);
          await appendFile(logFile, `\n[PIPELINE] ${phaseName} failed, retrying ${retryTarget} (retry ${currentRetries + 1}/${maxRetries})\n`);

          const targetIdx = phaseIndex.get(retryTarget);
          if (targetIdx !== undefined) {
            i = targetIdx;
            continue;
          }
          ctx.log(`[${phaseName.toUpperCase()}] retryWith target '${retryTarget}' not found in workflow — continuing`);
        } else {
          ctx.log(`[${phaseName.toUpperCase()}] FAIL — max retries (${maxRetries}) exhausted${failOnRetriesExhausted ? "" : ", continuing"}`);
          await appendFile(logFile, `\n[PIPELINE] ${phaseName} failed after ${maxRetries} retries${failOnRetriesExhausted ? "" : ", continuing"}\n`);
          feedbackContext = undefined;
          if (failOnRetriesExhausted) {
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
    enqueueAddLabelsToBead(store, seedId, [`phase:${phaseName}`], "pipeline-executor");

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

function writeSessionLogSafe(
  ctx: PipelineContext,
  progress: RunProgress,
  phaseRecords: PhaseRecord[],
  retryCounts: Record<string, number>,
  qaVerdictForLog: "pass" | "fail" | "unknown",
): void {
  const { config } = ctx;
  const { seedId, seedTitle, worktreePath } = config;
  const description = config.seedDescription ?? "(no description)";

  try {
    const pipelineProjectPath = config.projectPath ?? join(worktreePath, "..", "..");
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
    // Fire-and-forget — session log is non-critical
    writeSessionLog(worktreePath, sessionLogData)
      .then((p) => ctx.log(`[SESSION LOG] Written: ${p}`))
      .catch((err: unknown) => {
        const msg = err instanceof Error ? err.message : String(err);
        ctx.log(`[SESSION LOG] Failed to write (non-fatal): ${msg}`);
      });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    ctx.log(`[SESSION LOG] Failed to write (non-fatal): ${msg}`);
  }
}
