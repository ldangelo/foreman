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
import { appendFile } from "node:fs/promises";
import { join, basename } from "node:path";
import type { WorkflowConfig, WorkflowPhaseConfig } from "../lib/workflow-loader.js";
import { resolvePhaseModel } from "../lib/workflow-loader.js";
import type { PipelineEventBus } from "./pipeline-events.js";
import { ROLE_CONFIGS } from "./roles.js";
import { buildPhasePrompt, parseVerdict, extractIssues } from "./roles.js";
import { enqueueAddLabelsToBead } from "./task-backend-ops.js";
import { rotateReport } from "./agent-worker-finalize.js";
import { writeSessionLog } from "./session-log.js";
import type { PhaseRecord, SessionLogData } from "./session-log.js";
import type { SqliteMailClient } from "../lib/sqlite-mail-client.js";
import type { ForemanStore, RunProgress } from "../lib/store.js";
import type { VcsBackend } from "../lib/vcs/index.js";

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
}

export interface PipelineContext {
  config: PipelineRunConfig;
  workflowConfig: WorkflowConfig;
  store: ForemanStore;
  logFile: string;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  notifyClient: any;
  agentMailClient: AnyMailClient | null;
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
   * Optional event bus for pipeline lifecycle events.
   *
   * When provided, the executor emits typed PipelineEvent values at each
   * phase lifecycle boundary (phase:start, phase:complete, phase:fail,
   * pipeline:complete, pipeline:fail). All registered handlers receive
   * strongly-typed event objects.
   *
   * This replaces the onPipelineComplete/onPipelineFailure callback pattern.
   * Callers should register handlers on the event bus in agent-worker.ts.
   */
  eventBus?: PipelineEventBus;
  /**
   * Called after the last phase (finalize) completes successfully.
   * Responsible for: reading finalize mail, enqueuing to merge queue,
   * updating run status, resetting seed on failure, sending branch-ready mail.
   *
   * @deprecated Prefer registering a pipeline:complete handler on eventBus.
   *             This callback remains for backward compatibility with callers
   *             that have not yet migrated to the event-driven model.
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

// ── Generic Pipeline Executor ───────────────────────────────────────────────

/**
 * Execute a workflow pipeline driven entirely by the YAML config.
 *
 * Iterates workflowConfig.phases in order. For each phase:
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
  const { config, workflowConfig, store, logFile, notifyClient, agentMailClient } = ctx;
  const { runId, projectId, seedId, seedTitle, worktreePath } = config;
  const description = config.seedDescription ?? "(no description)";
  const comments = config.seedComments;

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

  const phaseRecords: PhaseRecord[] = [];

  // Track feedback context for retry loops (QA/reviewer → developer)
  let feedbackContext: string | undefined;
  // Track QA verdict for session log
  let qaVerdictForLog: "pass" | "fail" | "unknown" = "unknown";
  // Track retry counts per retryWith target (e.g. "developer" → count)
  const retryCounts: Record<string, number> = {};

  // Build a phase index for retryWith lookups
  const phaseIndex = new Map<string, number>();
  for (let i = 0; i < workflowConfig.phases.length; i++) {
    phaseIndex.set(workflowConfig.phases[i].name, i);
  }

  let i = 0;
  while (i < workflowConfig.phases.length) {
    const phase = workflowConfig.phases[i];
    const phaseName = phase.name;
    const agentName = `${phaseName}-${seedId}`;
    const hasExplorerReport = existsSync(join(worktreePath, "EXPLORER_REPORT.md"));

    progress.currentPhase = phaseName;
    store.updateRunProgress(runId, progress);

    // Emit phase:start for all phases (including skipped — emitted before skip check)
    ctx.eventBus?.safeEmit({ type: "phase:start", runId, phase: phaseName, worktreePath });

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
      // All phases get vcsBackendName and vcsBranchPrefix (TRD-027 for reviewer)
      vcsPromptVars.vcsBackendName = vcsBackend.name;
      vcsPromptVars.vcsBranchPrefix = "foreman/";

      // Finalize phase gets all 6 VCS command variables (TRD-026)
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

    // Resolve the model for this phase from the workflow YAML + bead priority.
    // Falls back to ROLE_CONFIGS[phaseName] if the phase has no models map.
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
      ctx.eventBus?.safeEmit({
        type: "phase:fail",
        runId,
        phase: phaseName,
        error: result.error ?? `${phaseName} failed`,
        retryable: true,
      });
      ctx.sendMail(agentMailClient, "foreman", "agent-error", {
        seedId, phase: phaseName, error: result.error ?? `${phaseName} failed`, retryable: true,
      });
      await ctx.markStuck(store, runId, projectId, seedId, seedTitle, progress, phaseName, result.error ?? `${phaseName} failed`, notifyClient, config.projectPath);
      ctx.eventBus?.safeEmit({ type: "pipeline:fail", runId, error: result.error ?? `${phaseName} failed` });
      return;
    }

    // Emit phase:complete
    ctx.eventBus?.safeEmit({ type: "phase:complete", runId, phase: phaseName, worktreePath, cost: result.costUsd });

    // 8. Handle success: send phase-complete, labels, forward artifact
    if (phase.mail?.onComplete !== false) {
      ctx.sendMail(agentMailClient, "foreman", "phase-complete", {
        seedId, phase: phaseName, status: "completed", cost: result.costUsd, turns: result.turns,
      });
    }
    store.logEvent(projectId, "complete", { seedId, phase: phaseName, costUsd: result.costUsd }, runId);
    enqueueAddLabelsToBead(store, seedId, [`phase:${phaseName}`], "pipeline-executor");

    // Forward artifact to another agent's inbox
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

    // 9. Verdict handling: parse PASS/FAIL, retry if needed
    if (phase.verdict && phase.artifact) {
      const report = readReport(worktreePath, phase.artifact);
      const verdict = report ? parseVerdict(report) : "unknown";

      // Track QA verdict for session log
      if (phaseName === "qa") {
        qaVerdictForLog = verdict as "pass" | "fail" | "unknown";
      }

      if (verdict === "fail" && phase.retryWith) {
        const retryTarget = phase.retryWith;
        const maxRetries = phase.retryOnFail ?? 0;
        // Key retry counter by the phase performing the verdict check (e.g. "qa", "reviewer")
        // NOT by the retry target ("developer"), so QA and Reviewer have independent retry budgets.
        const retryCountKey = phaseName;
        const currentRetries = retryCounts[retryCountKey] ?? 0;

        if (currentRetries < maxRetries) {
          retryCounts[retryCountKey] = currentRetries + 1;

          // Send failure feedback to retry target
          if (phase.mail?.onFail && report) {
            const feedbackTarget = `${phase.mail.onFail}-${seedId}`;
            ctx.sendMailText(agentMailClient, feedbackTarget, `${phaseName.charAt(0).toUpperCase() + phaseName.slice(1)} Feedback - Retry ${currentRetries + 1}`, report);
          }
          feedbackContext = report ? extractIssues(report) : `(${phaseName} failed but no report)`;

          ctx.log(`[${phaseName.toUpperCase()}] FAIL — looping back to ${retryTarget} (retry ${currentRetries + 1}/${maxRetries})`);
          await appendFile(logFile, `\n[PIPELINE] ${phaseName} failed, retrying ${retryTarget} (retry ${currentRetries + 1}/${maxRetries})\n`);

          // Jump back to the retryWith phase
          const targetIdx = phaseIndex.get(retryTarget);
          if (targetIdx !== undefined) {
            i = targetIdx;
            continue;
          }
          // If retryWith target not found, fall through
          ctx.log(`[${phaseName.toUpperCase()}] retryWith target '${retryTarget}' not found in workflow — continuing`);
        } else {
          ctx.log(`[${phaseName.toUpperCase()}] FAIL — max retries (${maxRetries}) exhausted, continuing`);
          await appendFile(logFile, `\n[PIPELINE] ${phaseName} failed after ${maxRetries} retries, continuing\n`);
          // Clear feedback for subsequent phases
          feedbackContext = undefined;
        }
      } else {
        // Verdict passed or no retry config — clear feedback
        feedbackContext = undefined;
      }
    } else {
      // Non-verdict phase — clear feedback
      feedbackContext = undefined;
    }

    i++;
  }

  // ── Session log ──────────────────────────────────────────────────────
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
    const sessionLogPath = await writeSessionLog(worktreePath, sessionLogData);
    ctx.log(`[SESSION LOG] Written: ${sessionLogPath}`);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    ctx.log(`[SESSION LOG] Failed to write (non-fatal): ${msg}`);
  }

  // ── Pipeline completion ──────────────────────────────────────────────
  // Emit pipeline:complete before invoking the completion callback so that
  // event-bus handlers (e.g. RebaseHook) can observe completion before
  // merge-queue enqueue.
  ctx.eventBus?.safeEmit({ type: "pipeline:complete", runId, status: "completed" });

  // Delegate finalize-specific post-processing (merge queue, run status)
  // to the caller via the onPipelineComplete callback.
  if (ctx.onPipelineComplete) {
    await ctx.onPipelineComplete({ progress, phaseRecords, retryCounts });
  }
}
