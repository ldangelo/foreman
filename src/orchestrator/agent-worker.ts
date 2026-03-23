#!/usr/bin/env node
/**
 * Agent Worker — standalone process that runs a single SDK agent.
 *
 * Spawned as a detached child process by the dispatcher. Survives parent exit.
 * Reads config from a JSON file passed as argv[2], runs the SDK query(),
 * and updates the SQLite store with progress/completion.
 *
 * Usage: tsx agent-worker.ts <config-file>
 */

import { readFileSync, unlinkSync, existsSync } from "node:fs";
import { appendFile, mkdir } from "node:fs/promises";
import { join, basename } from "node:path";
import { execFileSync } from "node:child_process";
import { request as httpRequest } from "node:http";
import { runWithPiSdk } from "./pi-sdk-runner.js";
import { createSendMailTool } from "./pi-sdk-tools.js";
import { ForemanStore } from "../lib/store.js";
import type { RunProgress } from "../lib/store.js";
import { PIPELINE_TIMEOUTS, PIPELINE_LIMITS, getSessionLogBudget } from "../lib/config.js";
import {
  ROLE_CONFIGS,
  getDisallowedTools,
  explorerPrompt,
  developerPrompt,
  qaPrompt,
  reviewerPrompt,
  finalizePrompt,
  parseVerdict,
  extractIssues,
  hasActionableIssues,
} from "./roles.js";
import { enqueueToMergeQueue } from "./agent-worker-enqueue.js";
import { rotateReport } from "./agent-worker-finalize.js";
import { resetSeedToOpen, markBeadFailed, addLabelsToBead, addNotesToBead } from "./task-backend-ops.js";
import { writeSessionLog } from "./session-log.js";
import type { PhaseRecord, SessionLogData } from "./session-log.js";
import type { AgentRole, WorkerNotification } from "./types.js";
import { SqliteMailClient } from "../lib/sqlite-mail-client.js";
import { loadWorkflowConfig, resolveWorkflowName, type WorkflowConfig } from "../lib/workflow-loader.js";

// ── Notification Client ───────────────────────────────────────────────────

/**
 * Lightweight HTTP client that POSTs worker notifications to the
 * NotificationServer running in the parent foreman process.
 *
 * Fire-and-forget: errors are silently swallowed so a dead/missing server
 * never blocks or crashes the worker. The polling fallback handles updates
 * whenever the server isn't reachable.
 */
class NotificationClient {
  constructor(private notifyUrl: string | undefined) {}

  /** Send a notification. Non-blocking — errors are silently ignored. */
  send(notification: WorkerNotification): void {
    if (!this.notifyUrl) return;
    try {
      const body = JSON.stringify(notification);
      const url = new URL("/notify", this.notifyUrl);
      const req = httpRequest(
        {
          hostname: url.hostname,
          port: url.port,
          path: url.pathname,
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Content-Length": Buffer.byteLength(body),
          },
          // Aggressive timeout — worker must not block on notification delivery
          timeout: 500,
        },
        (res) => {
          // Drain the response body so the socket can be reused
          res.resume();
        },
      );
      req.on("error", () => { /* silently ignore */ });
      req.on("timeout", () => { req.destroy(); });
      req.end(body);
    } catch {
      // Silently ignore any synchronous errors (e.g. invalid URL)
    }
  }
}

// ── Agent Mail helper ─────────────────────────────────────────────────────────

/** Mail client type. */
type AnyMailClient = SqliteMailClient;

/**
 * Fire-and-forget wrapper for AgentMailClient.sendMessage.
 * Never throws — failures are logged but do not affect the pipeline.
 */
function sendMail(
  client: AnyMailClient | null,
  to: string,
  subject: string,
  body: Record<string, unknown>,
): void {
  if (!client) return;
  client.sendMessage(to, subject, JSON.stringify(body)).catch((err: unknown) => {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[agent-mail] send failed (non-fatal): ${msg}`);
  });
}

/**
 * Fire-and-forget wrapper for AgentMailClient.sendMessage with plain string body.
 * Used to send report content (Explorer report, QA feedback, Review result).
 * Never throws.
 */
function sendMailText(
  client: AnyMailClient | null,
  to: string,
  subject: string,
  body: string,
): void {
  if (!client) return;
  client.sendMessage(to, subject, body).catch((err: unknown) => {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[agent-mail] send failed (non-fatal): ${msg}`);
  });
}

/**
 * Register agent identity for a phase and set as the sending identity on the client.
 * Uses ensureAgentRegistered so the auto-generated name is cached and used as sender_name.
 * Never throws — failures are logged but do not affect the pipeline.
 */
async function registerAgent(client: AnyMailClient | null, roleHint: string): Promise<void> {
  if (!client) return;
  try {
    const generatedName = await client.ensureAgentRegistered(roleHint);
    // Set the generated name as the current sending identity
    if (generatedName) {
      client.agentName = generatedName;
      log(`[agent-mail] Registered as '${generatedName}' (role: ${roleHint})`);
    }
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[agent-mail] registerAgent failed (non-fatal): ${msg}`);
  }
}

/**
 * Fire-and-forget wrapper for file reservation.
 * Never throws — failures are logged but do not affect the pipeline.
 */
function reserveFiles(
  client: AnyMailClient | null,
  paths: string[],
  agentName: string,
  leaseSecs?: number,
): void {
  if (!client || paths.length === 0) return;
  client.reserveFiles(paths, agentName, leaseSecs).catch((err: unknown) => {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[agent-mail] reserveFiles failed (non-fatal): ${msg}`);
  });
}

/**
 * Fire-and-forget wrapper for releasing file reservations.
 * Never throws — failures are logged but do not affect the pipeline.
 */
function releaseFiles(
  client: AnyMailClient | null,
  paths: string[],
  agentName: string,
): void {
  if (!client || paths.length === 0) return;
  client.releaseFiles(paths, agentName).catch((err: unknown) => {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[agent-mail] releaseFiles failed (non-fatal): ${msg}`);
  });
}

// ── Module-level phase tracker ───────────────────────────────────────────────
// Updated by main() and runPipeline() as phases progress so the fatal error
// handler can report the correct phase in its Agent Mail message.
let currentPhase = "startup";

// ── Config ───────────────────────────────────────────────────────────────────

interface WorkerConfig {
  runId: string;
  projectId: string;
  seedId: string;
  seedTitle: string;
  seedDescription?: string;
  seedComments?: string;
  model: string;
  worktreePath: string;
  /** Project root directory (contains .beads/). Used as cwd for br commands. */
  projectPath?: string;
  prompt: string;
  env: Record<string, string>;
  resume?: string;  // SDK session ID to resume
  pipeline?: boolean;  // Run as lead pipeline (explorer → developer → qa → reviewer)
  skipExplore?: boolean;
  skipReview?: boolean;
  /**
   * Bead type field (e.g. "feature", "bug", "task", "smoke").
   * Used to resolve the workflow name when no `workflow:<name>` label is set.
   */
  seedType?: string;
  /**
   * Labels from the bead. Used to resolve `workflow:<name>` overrides.
   * e.g. ["phase:explorer", "workflow:smoke"]
   */
  seedLabels?: string[];
}

// ── Main ─────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const configPath = process.argv[2];
  if (!configPath) {
    console.error("Usage: agent-worker <config-file>");
    process.exit(1);
  }

  // Read and delete config file (contains prompt, not secrets, but clean up)
  const config: WorkerConfig = JSON.parse(readFileSync(configPath, "utf-8"));
  try { unlinkSync(configPath); } catch { /* already deleted */ }

  const { runId, projectId, seedId, seedTitle, model, worktreePath, projectPath: configProjectPath, prompt, resume, pipeline } = config;

  // Resolve the project-local store path from the config, falling back to the
  // parent of the worktree directory if projectPath is not provided.
  const storeProjectPath = configProjectPath ?? join(worktreePath, "..", "..");

  // Set up logging
  const logDir = join(process.env.HOME ?? "/tmp", ".foreman", "logs");
  await mkdir(logDir, { recursive: true });
  const logFile = join(logDir, `${runId}.log`);

  const mode = pipeline ? "pipeline" : (resume ? "resume" : "worker");
  const header = [
    `[foreman-worker] Agent ${mode.toUpperCase()} at ${new Date().toISOString()}`,
    `  seed:      ${seedId} — ${seedTitle}`,
    `  model:     ${model}`,
    `  run:       ${runId}`,
    `  worktree:  ${worktreePath}`,
    `  pid:       ${process.pid}`,
    `  method:    ${pipeline ? "Pipeline (explorer→developer→qa→reviewer)" : "Pi (detached worker)"}`,
    resume ? `  resume:    ${resume}` : null,
    "─".repeat(80),
    "",
  ].filter(Boolean).join("\n");
  await appendFile(logFile, header);

  log(`Worker started for ${seedId} [${model}] pid=${process.pid} mode=${mode}`);
  currentPhase = "init";

  // Open store connection (project-local database)
  const store = ForemanStore.forProject(storeProjectPath);

  // Apply worker env vars.
  // NOTE: `ROLE_CONFIGS` in roles.ts is materialised at module load time,
  // which happens before this point.  Therefore any `FOREMAN_*_MODEL` values
  // supplied via `config.env` have NO effect on model selection — they arrive
  // too late.  Per-phase model overrides must be set in the *parent* process
  // environment before the worker is spawned.  The env vars here are passed
  // through to the SDK query() call for other purposes (e.g. API keys).
  for (const [key, value] of Object.entries(config.env)) {
    process.env[key] = value;
  }

  // Create notification client using FOREMAN_NOTIFY_URL (set in env above if provided by dispatcher)
  const notifyClient = new NotificationClient(process.env.FOREMAN_NOTIFY_URL);

  // Create SQLite-backed mail client (no external dependencies)
  let agentMailClient: AnyMailClient | null = null;
  try {
    const sqliteClient = new SqliteMailClient();
    await sqliteClient.ensureProject(storeProjectPath);
    sqliteClient.setRunId(runId);
    agentMailClient = sqliteClient;
    log(`[agent-mail] Using SqliteMailClient (scoped to run ${runId})`);
  } catch {
    // Non-fatal — mail is optional infrastructure
  }

  // Build clean env for SDK
  const env: Record<string, string | undefined> = { ...process.env };

  // ── Pipeline mode: run each phase as a separate SDK session ─────────
  if (pipeline) {
    await runPipeline(config, store, logFile, notifyClient, agentMailClient);
    store.close();
    log(`Pipeline worker exiting for ${seedId}`);
    return;
  }

  // ── Single-agent mode: run via Pi RPC ──────────────────────────────
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
  };

  let progressDirty = false;
  const flushProgress = () => {
    if (progressDirty) {
      store.updateRunProgress(runId, progress);
      progressDirty = false;
    }
  };
  const progressTimer = setInterval(flushProgress, PIPELINE_TIMEOUTS.progressFlushMs);
  progressTimer.unref();

  try {
    // Build clean env for Pi (strip CLAUDECODE, convert to string-only map)
    const piResult = await runWithPiSdk({
      prompt,
      systemPrompt: `You are an agent working on task: ${seedTitle}`,
      cwd: worktreePath,
      model,
      logFile,
      onToolCall: (name: string, input: Record<string, unknown>) => {
        progress.toolCalls++;
        progress.toolBreakdown[name] = (progress.toolBreakdown[name] ?? 0) + 1;
        progress.lastToolCall = name;
        progress.lastActivity = new Date().toISOString();

        if ((name === "Write" || name === "Edit") && input?.file_path) {
          const filePath = String(input.file_path);
          if (!progress.filesChanged.includes(filePath)) {
            progress.filesChanged.push(filePath);
          }
        }
        progressDirty = true;
      },
      onTurnEnd: (turn: number) => {
        progress.turns = turn;
        progress.lastActivity = new Date().toISOString();
        progressDirty = true;
      },
    });

    clearInterval(progressTimer);
    progress.costUsd = piResult.costUsd;
    progress.turns = piResult.turns;
    progress.toolCalls = piResult.toolCalls;
    progress.toolBreakdown = piResult.toolBreakdown;
    store.updateRunProgress(runId, progress);

    const now = new Date().toISOString();

    if (piResult.success) {
      store.updateRun(runId, { status: "completed", completed_at: now });
      notifyClient.send({ type: "status", runId, status: "completed", timestamp: now });
      store.logEvent(projectId, "complete", {
        seedId,
        title: seedTitle,
        costUsd: progress.costUsd,
        numTurns: progress.turns,
        toolCalls: progress.toolCalls,
        filesChanged: progress.filesChanged.length,
        resumed: !!resume,
      }, runId);
      log(`COMPLETED (${progress.turns} turns, ${progress.toolCalls} tools, ${progress.filesChanged.length} files, $${progress.costUsd.toFixed(4)})`);
    } else {
      const reason = piResult.errorMessage ?? "Pi agent failed";
      store.updateRun(runId, { status: "failed", completed_at: now });
      notifyClient.send({ type: "status", runId, status: "failed", timestamp: now, details: { reason } });
      store.logEvent(projectId, "fail", {
        seedId,
        reason,
        costUsd: progress.costUsd,
        numTurns: progress.turns,
        resumed: !!resume,
      }, runId);
      log(`FAILED: ${reason.slice(0, 300)}`);
      // Permanent failure — mark bead as 'failed' so it is NOT auto-retried.
      await markBeadFailed(seedId, storeProjectPath);
    }
  } catch (err: unknown) {
    clearInterval(progressTimer);
    store.updateRunProgress(runId, progress);
    const reason = err instanceof Error ? err.message : String(err);
    const isRateLimit = reason.includes("hit your limit") || reason.includes("rate limit");

    const now = new Date().toISOString();
    const catchStatus = isRateLimit ? "stuck" : "failed";
    store.updateRun(runId, {
      status: catchStatus,
      completed_at: now,
    });
    notifyClient.send({ type: "status", runId, status: catchStatus, timestamp: now, details: { reason } });
    store.logEvent(projectId, isRateLimit ? "stuck" : "fail", {
      seedId,
      reason,
      costUsd: progress.costUsd,
      numTurns: progress.turns,
      rateLimit: isRateLimit,
      resumed: !!resume,
    }, runId);
    log(`${isRateLimit ? "RATE LIMITED" : "ERROR"}: ${reason.slice(0, 200)}`);
    await appendFile(logFile, `\n[foreman-worker] ${isRateLimit ? "RATE LIMITED" : "ERROR"}: ${reason}\n`);
    // Transient (rate limit) → reset to 'open' for retry; permanent → mark 'failed'.
    if (isRateLimit) {
      await resetSeedToOpen(seedId, storeProjectPath);
    } else {
      await markBeadFailed(seedId, storeProjectPath);
    }
  }

  store.close();
  log(`Worker exiting for ${seedId}`);
}

// ── Pipeline orchestration ───────────────────────────────────────────────────

interface PhaseResult {
  success: boolean;
  costUsd: number;
  turns: number;
  error?: string;
}

/**
 * Run a single pipeline phase as a separate SDK session.
 */
async function runPhase(
  role: Exclude<AgentRole, "lead" | "worker" | "sentinel">,
  prompt: string,
  config: WorkerConfig,
  progress: RunProgress,
  logFile: string,
  store: ForemanStore,
  notifyClient: NotificationClient,
  agentMailClient?: AnyMailClient | null,
): Promise<PhaseResult> {
  const roleConfig = ROLE_CONFIGS[role];
  progress.currentPhase = role;
  store.updateRunProgress(config.runId, progress);

  const disallowedTools = getDisallowedTools(roleConfig);
  const allowedSummary = roleConfig.allowedTools.join(", ");
  await appendFile(logFile, `\n${"─".repeat(40)}\n[PHASE: ${role.toUpperCase()}] Starting (model=${roleConfig.model}, maxBudgetUsd=${roleConfig.maxBudgetUsd}, allowedTools=[${allowedSummary}])\n`);
  log(`[${role.toUpperCase()}] Starting phase for ${config.seedId} (${roleConfig.allowedTools.length} allowed tools, ${disallowedTools.length} disallowed)`);

  // Build custom tools for this phase (e.g. send_mail).
  const customTools = [];
  if (agentMailClient) {
    customTools.push(createSendMailTool(agentMailClient, `${role}-${config.seedId}`));
  }

  try {
    const phaseResult = await runWithPiSdk({
      prompt,
      systemPrompt: `You are the ${role} agent in the Foreman pipeline for task: ${config.seedTitle}`,
      cwd: config.worktreePath,
      model: roleConfig.model,
      allowedTools: roleConfig.allowedTools,
      customTools,
      logFile,
      onToolCall: (name, input) => {
        progress.toolCalls++;
        progress.toolBreakdown[name] = (progress.toolBreakdown[name] ?? 0) + 1;
        progress.lastToolCall = name;
        progress.lastActivity = new Date().toISOString();

        if ((name === "Write" || name === "Edit") && input?.file_path) {
          const filePath = String(input.file_path);
          if (!progress.filesChanged.includes(filePath)) {
            progress.filesChanged.push(filePath);
          }
        }
      },
      onTurnEnd: (turn) => {
        progress.turns = turn;
        progress.lastActivity = new Date().toISOString();
        store.updateRunProgress(config.runId, progress);
        notifyClient.send({
          type: "progress",
          runId: config.runId,
          progress: { ...progress },
          timestamp: new Date().toISOString(),
        });
      },
    });

    progress.costUsd += phaseResult.costUsd;

    // Record per-phase cost breakdown
    progress.costByPhase ??= {};
    progress.costByPhase[role] = (progress.costByPhase[role] ?? 0) + phaseResult.costUsd;
    progress.agentByPhase ??= {};
    progress.agentByPhase[role] = roleConfig.model;

    store.updateRunProgress(config.runId, progress);

    if (phaseResult.success) {
      log(`[${role.toUpperCase()}] Completed (${phaseResult.turns} turns, $${phaseResult.costUsd.toFixed(4)})`);
      await appendFile(logFile, `[PHASE: ${role.toUpperCase()}] COMPLETED ($${phaseResult.costUsd.toFixed(4)})\n`);
      return { success: true, costUsd: phaseResult.costUsd, turns: phaseResult.turns };
    } else {
      const reason = phaseResult.errorMessage ?? "Pi agent ended without success";
      log(`[${role.toUpperCase()}] Failed: ${reason.slice(0, 200)}`);
      await appendFile(logFile, `[PHASE: ${role.toUpperCase()}] FAILED: ${reason}\n`);
      return { success: false, costUsd: phaseResult.costUsd, turns: phaseResult.turns, error: reason };
    }
  } catch (err: unknown) {
    const reason = err instanceof Error ? err.message : String(err);
    const isRateLimit = reason.includes("hit your limit") || reason.includes("rate limit");
    log(`[${role.toUpperCase()}] ${isRateLimit ? "RATE LIMITED" : "ERROR"}: ${reason.slice(0, 200)}`);
    await appendFile(logFile, `[PHASE: ${role.toUpperCase()}] ERROR: ${reason}\n`);
    return { success: false, costUsd: 0, turns: 0, error: reason };
  }
}

function readReport(worktreePath: string, filename: string): string | null {
  const p = join(worktreePath, filename);
  try { return readFileSync(p, "utf-8"); } catch { return null; }
}


const MAX_DEV_RETRIES = PIPELINE_LIMITS.maxDevRetries;

/**
 * Run the full pipeline: Explorer → Developer ⇄ QA → Reviewer → Finalize.
 * Each phase is a separate SDK session. TypeScript orchestrates the loop.
 */
async function runPipeline(config: WorkerConfig, store: ForemanStore, logFile: string, notifyClient: NotificationClient, agentMailClient: AnyMailClient | null): Promise<void> {
  const { runId, projectId, seedId, seedTitle, worktreePath } = config;
  const description = config.seedDescription ?? "(no description)";
  const comments = config.seedComments;

  // Prompt loader options: when projectPath is available, use unified loader
  // so that project-local overrides are respected and missing prompts cause a clear error.
  //
  // Workflow selection: resolved from `workflow:<name>` labels or bead type.
  // The workflow YAML defines the phase sequence; defaults live in
  // src/defaults/workflows/ and are installed by `foreman init`.
  const pipelineProjectPath = config.projectPath ?? join(worktreePath, "..", "..");
  const resolvedWorkflow = resolveWorkflowName(config.seedType ?? "feature", config.seedLabels);
  const promptOpts = {
    projectRoot: pipelineProjectPath,
    workflow: resolvedWorkflow,
  };

  // Load the workflow config (phase sequence + per-phase overrides).
  // Falls back to bundled defaults if the project-local file is missing.
  let workflowConfig: WorkflowConfig;
  try {
    workflowConfig = loadWorkflowConfig(resolvedWorkflow, pipelineProjectPath);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[PIPELINE] Failed to load workflow config '${resolvedWorkflow}': ${msg}`);
    log(`[PIPELINE] Falling back to hardcoded phase sequence`);
    // Construct a minimal default WorkflowConfig matching the old hardcoded sequence.
    workflowConfig = {
      name: resolvedWorkflow,
      phases: [
        { name: "explorer", prompt: "explorer.md", skipIfArtifact: "EXPLORER_REPORT.md" },
        { name: "developer", prompt: "developer.md" },
        { name: "qa", prompt: "qa.md", retryOnFail: 2 },
        { name: "reviewer", prompt: "reviewer.md" },
        { name: "finalize", prompt: "finalize.md" },
      ],
    };
  }

  // Derive skipExplore / skipReview from the workflow phase list,
  // while still respecting explicit config overrides from the dispatcher.
  const workflowHasExplorer = workflowConfig.phases.some((p) => p.name === "explorer");
  const workflowHasReviewer = workflowConfig.phases.some((p) => p.name === "reviewer");
  const skipExplore = config.skipExplore ?? !workflowHasExplorer;
  const skipReview = config.skipReview ?? !workflowHasReviewer;

  // Extract per-phase overrides from the workflow config.
  const qaPhaseConfig = workflowConfig.phases.find((p) => p.name === "qa");
  const workflowMaxDevRetries = qaPhaseConfig?.retryOnFail ?? MAX_DEV_RETRIES;

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
    currentPhase: "explorer",
  };

  const pipelineStartedAt = new Date().toISOString();
  currentPhase = "pipeline";

  const phaseNames = workflowConfig.phases.map((p) => p.name).join(" → ");
  log(`Pipeline starting for ${seedId} [workflow: ${resolvedWorkflow}]`);
  log(`[PIPELINE] Phase sequence: ${phaseNames}`);
  await appendFile(logFile, `\n[foreman-worker] Pipeline orchestration starting\n[PIPELINE] Phase sequence: ${phaseNames}\n`);

  // Accumulate phase records for the session log written at pipeline completion.
  // /ensemble:sessionlog is a human-only Claude Code skill (not reachable from
  // SDK query()), so the pipeline generates the session log directly from this data.
  const phaseRecords: PhaseRecord[] = [];

  // ── Phase 1: Explorer ──────────────────────────────────────────────
  if (!skipExplore) {
    const explorerArtifact = join(worktreePath, "EXPLORER_REPORT.md");
    if (existsSync(explorerArtifact)) {
      log(`[EXPLORER] Skipping — EXPLORER_REPORT.md already exists (resuming from previous run)`);
      await appendFile(logFile, `\n[PHASE: EXPLORER] SKIPPED (artifact already present)\n`);
      phaseRecords.push({ name: "explorer", skipped: true });
    } else {
      // AC-006-1: Register the explorer agent with Agent Mail before the phase starts.
      await registerAgent(agentMailClient, `explorer-${seedId}`);
      sendMail(agentMailClient, "foreman", "phase-started", { seedId, phase: "explorer" });
      rotateReport(worktreePath, "EXPLORER_REPORT.md");
      const result = await runPhase("explorer", explorerPrompt(seedId, seedTitle, description, comments, runId, promptOpts), config, progress, logFile, store, notifyClient, agentMailClient);
      phaseRecords.push({
        name: "explorer",
        skipped: false,
        success: result.success,
        costUsd: result.costUsd,
        turns: result.turns,
        error: result.error,
      });
      if (!result.success) {
        sendMail(agentMailClient, "foreman", "agent-error", {
          seedId, phase: "explorer", error: result.error ?? "Explorer failed", retryable: true,
        });
        await markStuck(store, runId, projectId, seedId, seedTitle, progress, "explorer", result.error ?? "Explorer failed", notifyClient, config.projectPath);
        return;
      }
      sendMail(agentMailClient, "foreman", "phase-complete", {
        seedId, phase: "explorer", status: "completed", cost: result.costUsd, turns: result.turns,
      });
      store.logEvent(projectId, "complete", { seedId, phase: "explorer", costUsd: result.costUsd }, runId);
      addLabelsToBead(seedId, ["phase:explorer"], config.projectPath);
      // AC-010-1: Send explorer report content as a message to developer's inbox.
      const explorerReport = readReport(worktreePath, "EXPLORER_REPORT.md");
      if (explorerReport) {
        sendMailText(agentMailClient, `developer-${seedId}`, "Explorer Report", explorerReport);
      }
    }
  } else {
    phaseRecords.push({ name: "explorer", skipped: true });
  }

  const hasExplorerReport = existsSync(join(worktreePath, "EXPLORER_REPORT.md"));

  // ── Phase 2-3: Developer ⇄ QA loop ────────────────────────────────
  let devRetries = 0;
  let feedbackContext: string | undefined;
  let qaVerdict: "pass" | "fail" | "unknown" = "unknown";
  let pipelineStatus = "ALL_CHECKS_PASSED";

  const MAX_ATTEMPTS = workflowMaxDevRetries + 1; // e.g. retryOnFail=2 → 3 total attempts
  let attempt = 0;
  while (attempt < MAX_ATTEMPTS) {
    attempt++;
    log(`[PIPELINE] Developer/QA attempt ${attempt}/${MAX_ATTEMPTS}`);
    // Developer — skip on first pass if artifact already exists (resume after crash)
    const developerArtifact = join(worktreePath, "DEVELOPER_REPORT.md");
    const developerAlreadyDone = devRetries === 0 && existsSync(developerArtifact);
    if (developerAlreadyDone) {
      log(`[DEVELOPER] Skipping — DEVELOPER_REPORT.md already exists (resuming from previous run)`);
      await appendFile(logFile, `\n[PHASE: DEVELOPER] SKIPPED (artifact already present)\n`);
      phaseRecords.push({ name: "developer", skipped: true });
    } else {
      // AC-006-1: Register the developer agent with Agent Mail before the phase starts.
      const developerAgentName = `developer-${seedId}`;
      await registerAgent(agentMailClient, developerAgentName);
      sendMail(agentMailClient, "foreman", "phase-started", { seedId, phase: "developer" });
      // REQ-007 / AC-007-1: Reserve the worktree path before Developer edits files.
      // Lease 10 minutes (600 s) — generous to cover typical developer phase duration.
      reserveFiles(agentMailClient, [worktreePath], developerAgentName, 600);
      rotateReport(worktreePath, "DEVELOPER_REPORT.md");
      const devResult = await runPhase(
        "developer",
        developerPrompt(seedId, seedTitle, description, hasExplorerReport, feedbackContext, comments, runId, promptOpts),
        config, progress, logFile, store, notifyClient, agentMailClient,
      );
      // AC-007-3: Release file reservations on phase completion or failure.
      releaseFiles(agentMailClient, [worktreePath], developerAgentName);
      phaseRecords.push({
        name: devRetries === 0 ? "developer" : `developer (retry ${devRetries})`,
        skipped: false,
        success: devResult.success,
        costUsd: devResult.costUsd,
        turns: devResult.turns,
        error: devResult.error,
      });
      if (!devResult.success) {
        sendMail(agentMailClient, "foreman", "agent-error", {
          seedId, phase: "developer", error: devResult.error ?? "Developer failed", retryable: true,
        });
        await markStuck(store, runId, projectId, seedId, seedTitle, progress, "developer", devResult.error ?? "Developer failed", notifyClient, config.projectPath);
        return;
      }
      sendMail(agentMailClient, "foreman", "phase-complete", {
        seedId, phase: "developer", status: "completed", cost: devResult.costUsd, turns: devResult.turns,
      });
      store.logEvent(projectId, "complete", { seedId, phase: "developer", costUsd: devResult.costUsd, retry: devRetries }, runId);
      addLabelsToBead(seedId, ["phase:developer"], config.projectPath);
    }

    // QA — skip on first pass if artifact already exists (resume after crash)
    const qaArtifact = join(worktreePath, "QA_REPORT.md");
    const qaAlreadyDone = devRetries === 0 && existsSync(qaArtifact);
    if (qaAlreadyDone) {
      log(`[QA] Skipping — QA_REPORT.md already exists (resuming from previous run)`);
      await appendFile(logFile, `\n[PHASE: QA] SKIPPED (artifact already present)\n`);
      phaseRecords.push({ name: "qa", skipped: true });
    } else {
      // AC-006-1: Register the QA agent with Agent Mail before the phase starts.
      await registerAgent(agentMailClient, `qa-${seedId}`);
      rotateReport(worktreePath, "QA_REPORT.md");
      const qaResult = await runPhase("qa", qaPrompt(seedId, seedTitle, runId, promptOpts), config, progress, logFile, store, notifyClient, agentMailClient);
      phaseRecords.push({
        name: devRetries === 0 ? "qa" : `qa (retry ${devRetries})`,
        skipped: false,
        success: qaResult.success,
        costUsd: qaResult.costUsd,
        turns: qaResult.turns,
        error: qaResult.error,
      });
      if (!qaResult.success) {
        sendMail(agentMailClient, "foreman", "agent-error", {
          seedId, phase: "qa", error: qaResult.error ?? "QA failed", retryable: true,
        });
        await markStuck(store, runId, projectId, seedId, seedTitle, progress, "qa", qaResult.error ?? "QA failed", notifyClient, config.projectPath);
        return;
      }
      sendMail(agentMailClient, "foreman", "phase-complete", {
        seedId, phase: "qa", status: "completed", cost: qaResult.costUsd, turns: qaResult.turns,
      });
      store.logEvent(projectId, "complete", { seedId, phase: "qa", costUsd: qaResult.costUsd, retry: devRetries }, runId);
      addLabelsToBead(seedId, ["phase:qa"], config.projectPath);
    }

    const qaReport = readReport(worktreePath, "QA_REPORT.md");
    qaVerdict = qaReport ? parseVerdict(qaReport) : "unknown";

    if (qaVerdict === "pass" || qaVerdict === "unknown") {
      log(`[QA] Verdict: ${qaVerdict} — proceeding to ${skipReview ? "finalize" : "review"}`);
      break;
    }

    // QA failed — decide whether to retry developer with feedback.
    // AC-010-2: Send QA feedback as a message to developer's inbox before retry.
    feedbackContext = qaReport ? extractIssues(qaReport) : "(QA failed but no report written)";
    devRetries++;
    if (attempt < MAX_ATTEMPTS) {
      log(`[QA] FAIL — sending back to Developer (attempt ${attempt}/${MAX_ATTEMPTS}, retry ${devRetries}/${workflowMaxDevRetries})`);
      await appendFile(logFile, `\n[PIPELINE] QA failed, retrying developer (attempt ${attempt}/${MAX_ATTEMPTS})\n`);
      if (qaReport) {
        sendMailText(agentMailClient, `developer-${seedId}`, `QA Feedback - Retry ${devRetries}`, qaReport);
      }
    } else {
      log(`[QA] FAIL — max attempts (${MAX_ATTEMPTS}) exhausted, proceeding with current state`);
      await appendFile(logFile, `\n[PIPELINE] QA failed after ${MAX_ATTEMPTS} attempts (${workflowMaxDevRetries} retries), proceeding anyway\n`);
    }
  }

  // ── Phase 4: Reviewer ──────────────────────────────────────────────
  if (!skipReview) {
    const reviewerArtifact = join(worktreePath, "REVIEW.md");
    const reviewerAlreadyDone = existsSync(reviewerArtifact);
    if (reviewerAlreadyDone) {
      log(`[REVIEWER] Skipping — REVIEW.md already exists (resuming from previous run)`);
      await appendFile(logFile, `\n[PHASE: REVIEWER] SKIPPED (artifact already present)\n`);
      phaseRecords.push({ name: "reviewer", skipped: true });
    } else {
      // AC-006-1: Register the reviewer agent with Agent Mail before the phase starts.
      await registerAgent(agentMailClient, `reviewer-${seedId}`);
      rotateReport(worktreePath, "REVIEW.md");
      const reviewResult = await runPhase("reviewer", reviewerPrompt(seedId, seedTitle, description, comments, runId, promptOpts), config, progress, logFile, store, notifyClient, agentMailClient);
      phaseRecords.push({
        name: "reviewer",
        skipped: false,
        success: reviewResult.success,
        costUsd: reviewResult.costUsd,
        turns: reviewResult.turns,
        error: reviewResult.error,
      });
      if (!reviewResult.success) {
        sendMail(agentMailClient, "foreman", "agent-error", {
          seedId, phase: "reviewer", error: reviewResult.error ?? "Reviewer failed", retryable: true,
        });
        await markStuck(store, runId, projectId, seedId, seedTitle, progress, "reviewer", reviewResult.error ?? "Reviewer failed", notifyClient, config.projectPath);
        return;
      }
      sendMail(agentMailClient, "foreman", "phase-complete", {
        seedId, phase: "reviewer", status: "completed", cost: reviewResult.costUsd, turns: reviewResult.turns,
      });
      store.logEvent(projectId, "complete", { seedId, phase: "reviewer", costUsd: reviewResult.costUsd }, runId);
      addLabelsToBead(seedId, ["phase:reviewer"], config.projectPath);
      // AC-010-3: Send review content and verdict to foreman inbox after REVIEW.md is written.
      const reviewReport = readReport(worktreePath, "REVIEW.md");
      if (reviewReport) {
        const reviewVerdictForMail = parseVerdict(reviewReport);
        const reviewBody = `${reviewReport}\n\n---\n**Verdict:** ${reviewVerdictForMail}`;
        sendMailText(agentMailClient, "foreman", "Review Complete", reviewBody);
      }
    }

    const reviewReport = readReport(worktreePath, "REVIEW.md");
    const reviewVerdict = reviewReport ? parseVerdict(reviewReport) : "unknown";

    const hasIssues = reviewReport ? hasActionableIssues(reviewReport) : false;

    if ((reviewVerdict === "fail" || (reviewVerdict === "pass" && hasIssues)) && devRetries < workflowMaxDevRetries) {
      const reviewFeedback = reviewReport ? extractIssues(reviewReport) : "(Review failed but no issues listed)";
      const issueCount = reviewReport ? (reviewReport.match(/\*\*\[(CRITICAL|WARNING)\]\*\*/g) ?? []).length : 0;
      const reason = reviewVerdict === "fail" ? "FAIL" : "PASS with issues";
      // Flaw C fix: log clearly when review feedback triggers a dev/QA re-run
      log(`[REVIEW] Verdict ${reviewVerdict} with ${issueCount} issues — sending developer back for review feedback (attempt ${devRetries + 1}/${workflowMaxDevRetries})`);
      await appendFile(logFile, `\n[PIPELINE] Review ${reason}, retrying developer with review feedback\n`);
      devRetries++;

      // One more dev → QA cycle to address review feedback
      // AC-006-1: Register the developer agent; AC-007-1: Reserve files before editing.
      const reviewFeedbackDevAgent = `developer-${seedId}`;
      await registerAgent(agentMailClient, reviewFeedbackDevAgent);
      reserveFiles(agentMailClient, [worktreePath], reviewFeedbackDevAgent, 600);
      rotateReport(worktreePath, "DEVELOPER_REPORT.md");
      const devResult = await runPhase(
        "developer",
        developerPrompt(seedId, seedTitle, description, hasExplorerReport, reviewFeedback, comments, runId, promptOpts),
        config, progress, logFile, store, notifyClient, agentMailClient,
      );
      // AC-007-3: Release file reservations on phase completion or failure.
      releaseFiles(agentMailClient, [worktreePath], reviewFeedbackDevAgent);
      phaseRecords.push({
        name: `developer (review-feedback)`,
        skipped: false,
        success: devResult.success,
        costUsd: devResult.costUsd,
        turns: devResult.turns,
        error: devResult.error,
      });
      // Flaw A fix: if developer fails during review-feedback cycle, mark stuck and return
      if (!devResult.success) {
        sendMail(agentMailClient, "foreman", "agent-error", {
          seedId, phase: "developer-review-feedback", error: devResult.error ?? "Developer failed during review feedback", retryable: true,
        });
        await markStuck(store, runId, projectId, seedId, seedTitle, progress, "developer-review-feedback", devResult.error ?? "Developer failed during review feedback", notifyClient, config.projectPath);
        return;
      }
      sendMail(agentMailClient, "foreman", "phase-complete", {
        seedId, phase: "developer", status: "completed", cost: devResult.costUsd, turns: devResult.turns,
      });
      store.logEvent(projectId, "complete", { seedId, phase: "developer", costUsd: devResult.costUsd, retry: devRetries, trigger: "review-feedback" }, runId);
      addLabelsToBead(seedId, ["phase:developer"], config.projectPath);

      rotateReport(worktreePath, "QA_REPORT.md");
      const qaResult = await runPhase("qa", qaPrompt(seedId, seedTitle, runId, promptOpts), config, progress, logFile, store, notifyClient, agentMailClient);
      phaseRecords.push({
        name: `qa (review-feedback)`,
        skipped: false,
        success: qaResult.success,
        costUsd: qaResult.costUsd,
        turns: qaResult.turns,
        error: qaResult.error,
      });
      // Flaw A fix: if QA fails during review-feedback cycle, mark stuck and return
      if (!qaResult.success) {
        sendMail(agentMailClient, "foreman", "agent-error", {
          seedId, phase: "qa-review-feedback", error: qaResult.error ?? "QA failed during review feedback", retryable: true,
        });
        await markStuck(store, runId, projectId, seedId, seedTitle, progress, "qa-review-feedback", qaResult.error ?? "QA failed during review feedback", notifyClient, config.projectPath);
        return;
      }
      sendMail(agentMailClient, "foreman", "phase-complete", {
        seedId, phase: "qa", status: "completed", cost: qaResult.costUsd, turns: qaResult.turns,
      });
      store.logEvent(projectId, "complete", { seedId, phase: "qa", costUsd: qaResult.costUsd, retry: devRetries, trigger: "review-feedback" }, runId);
      addLabelsToBead(seedId, ["phase:qa"], config.projectPath);
    } else if (reviewVerdict === "fail") {
      log(`[REVIEW] FAIL — max retries exhausted, finalizing with current state`);
      pipelineStatus = "PIPELINE_COMPLETE (REVIEWER FAIL — no retries remaining)";
    } else {
      log(`[REVIEW] Verdict: ${reviewVerdict} (no actionable issues)`);
    }
  } else {
    phaseRecords.push({ name: "reviewer", skipped: true });
  }

  // ── Session log ────────────────────────────────────────────────────
  // Write before finalize() so `git add -A` picks it up and commits it.
  // This replaces /ensemble:sessionlog which is only available in interactive
  // Claude Code (not reachable from the SDK's query() method).
  try {
    const sessionLogData: SessionLogData = {
      seedId,
      seedTitle,
      seedDescription: description,
      branchName: `foreman/${seedId}`,
      // Foreman worktrees live at <project>/.foreman-worktrees/<seed-id>/,
      // so ascending two levels from the worktree path reaches the project root
      // when config.projectPath is not explicitly set.
      projectName: basename(config.projectPath ?? join(worktreePath, "..", "..")),
      phases: phaseRecords,
      totalCostUsd: progress.costUsd,
      totalTurns: progress.turns,
      filesChanged: progress.filesChanged,
      devRetries,
      qaVerdict,
    };
    const sessionLogPath = await writeSessionLog(worktreePath, sessionLogData);
    log(`[SESSION LOG] Written: ${sessionLogPath}`);
    await appendFile(logFile, `[SESSION LOG] Written: ${sessionLogPath}\n`);
  } catch (err: unknown) {
    // Non-fatal — session log failure must not block finalization
    const msg = err instanceof Error ? err.message : String(err);
    log(`[SESSION LOG] Failed to write (non-fatal): ${msg}`);
    await appendFile(logFile, `[SESSION LOG] Write failed (non-fatal): ${msg}\n`);
  }

  // Downgrade status if QA never passed (retries exhausted)
  if (qaVerdict === "fail" && pipelineStatus === "ALL_CHECKS_PASSED") {
    pipelineStatus = "PIPELINE_COMPLETE (QA FAILED — retries exhausted)";
  }

  // ── Phase 5: Finalize ──────────────────────────────────────────────
  // Finalize is now a prompt-driven agent phase (finalize.md), not a builtin TypeScript function.
  // The agent commits, pushes, and sends phase-complete or agent-error mail.
  progress.currentPhase = "finalize";
  store.updateRunProgress(runId, progress);
  await appendFile(logFile, `\n${"─".repeat(40)}\n[PHASE: FINALIZE]\n`);

  await registerAgent(agentMailClient, `finalize-${seedId}`);
  const finalizePhaseResult = await runPhase(
    "finalize",
    finalizePrompt(seedId, seedTitle, runId, undefined, promptOpts),
    config, progress, logFile, store, notifyClient, agentMailClient,
  );
  phaseRecords.push({
    name: "finalize",
    skipped: false,
    success: finalizePhaseResult.success,
    costUsd: finalizePhaseResult.costUsd,
    turns: finalizePhaseResult.turns,
    error: finalizePhaseResult.error,
  });

  // Read the finalize outcome from agent mail.
  // The agent sends phase-complete (success) or agent-error (failure) to "foreman".
  // If agentMailClient is null, fall back to using runPhase success directly.
  let finalizeSucceeded = false;
  let finalizeRetryable = true; // default: transient failures are retryable
  if (agentMailClient) {
    const foremanMsgs = await agentMailClient.fetchInbox("foreman");
    const finalizeMsg = foremanMsgs.find(
      (m) => (m.subject === "phase-complete" || m.subject === "agent-error") &&
              m.from === "finalize",
    );
    if (finalizeMsg?.subject === "phase-complete") {
      finalizeSucceeded = true;
      log(`[FINALIZE] phase-complete mail received — push succeeded`);
    } else if (finalizeMsg?.subject === "agent-error") {
      const body = (() => { try { return JSON.parse(finalizeMsg.body ?? "{}") as Record<string, unknown>; } catch { return {} as Record<string, unknown>; } })();
      finalizeRetryable = body["retryable"] !== false; // default retryable unless explicitly false
      const errorDetail = typeof body["error"] === "string" ? body["error"] : "unknown finalize error";
      log(`[FINALIZE] agent-error mail received — error: ${errorDetail}, retryable: ${String(finalizeRetryable)}`);
    } else {
      // No mail found — fall back to runPhase success flag
      log(`[FINALIZE] No phase-complete or agent-error mail found — using runPhase result (success=${String(finalizePhaseResult.success)})`);
      finalizeSucceeded = finalizePhaseResult.success;
    }
  } else {
    // No mail client — fall back to runPhase success
    log(`[FINALIZE] agentMailClient is null — using runPhase result (success=${String(finalizePhaseResult.success)})`);
    finalizeSucceeded = finalizePhaseResult.success;
  }

  const now = new Date().toISOString();
  if (finalizeSucceeded) {
    // Enqueue the completed branch to the merge queue
    try {
      const enqueueStore = ForemanStore.forProject(pipelineProjectPath);
      const opts = { cwd: worktreePath, stdio: "pipe" as const, timeout: PIPELINE_TIMEOUTS.gitOperationMs };
      const enqueueResult = enqueueToMergeQueue({
        db: enqueueStore.getDb(),
        seedId,
        runId,
        worktreePath,
        getFilesModified: () => {
          const output = execFileSync("git", ["diff", "--name-only", "main...HEAD"], opts).toString().trim();
          return output ? output.split("\n") : [];
        },
      });
      enqueueStore.close();
      if (enqueueResult.success) {
        log(`[FINALIZE] Enqueued to merge queue`);
        sendMail(agentMailClient, "refinery", "branch-ready", {
          seedId, runId, branch: `foreman/${seedId}`, worktreePath,
        });
      } else {
        log(`[FINALIZE] Merge queue enqueue failed (non-fatal): ${enqueueResult.error ?? "(unknown)"}`);
      }
    } catch (enqErr: unknown) {
      const enqMsg = enqErr instanceof Error ? enqErr.message : String(enqErr);
      log(`[FINALIZE] Merge queue enqueue failed (non-fatal): ${enqMsg}`);
    }
    store.updateRun(runId, { status: "completed", completed_at: now });
    notifyClient.send({ type: "status", runId, status: "completed", timestamp: now });
  } else {
    // Push failed — mark the run as stuck.
    store.updateRun(runId, { status: "stuck", completed_at: now });
    notifyClient.send({ type: "status", runId, status: "stuck", timestamp: now });
    sendMail(agentMailClient, "foreman", "agent-error", {
      seedId, phase: "finalize", error: finalizePhaseResult.error ?? "Push failed", retryable: finalizeRetryable,
    });
    // Only reset the seed to "open" for retryable failures (e.g. transient network
    // errors).  Deterministic failures — like a diverged history that could not be
    // rebased — must NOT trigger a reset, because that would cause the dispatcher
    // to immediately re-dispatch the seed, observe the same push failure, and loop
    // indefinitely (observed: bd-qtqs accumulated 151 stuck runs in ~20 minutes).
    if (finalizeRetryable) {
      await resetSeedToOpen(seedId, config.projectPath);
    } else {
      log(`[PIPELINE] Deterministic push failure for ${seedId} — seed left stuck (no reset to open)`);
    }
  }
  const completedPhases = workflowConfig.phases.map((p) => p.name).join("→");

  // Log the terminal event with the correct type so analytics / retry logic
  // can distinguish completed runs from stuck ones by querying the event log.
  store.logEvent(projectId, finalizeSucceeded ? "complete" : "stuck", {
    seedId,
    title: seedTitle,
    costUsd: progress.costUsd,
    numTurns: progress.turns,
    toolCalls: progress.toolCalls,
    filesChanged: progress.filesChanged.length,
    phases: completedPhases,
    devRetries,
    qaVerdict,
  }, runId);

  if (finalizeSucceeded) {
    log(`PIPELINE COMPLETED for ${seedId} (${progress.turns} turns, ${progress.toolCalls} tools, ${progress.filesChanged.length} files, $${progress.costUsd.toFixed(4)})`);
    await appendFile(logFile, `\n[PIPELINE] COMPLETED ($${progress.costUsd.toFixed(4)}, ${progress.turns} turns)\n`);
  } else {
    log(`PIPELINE STUCK for ${seedId} — finalize failed (${progress.turns} turns, $${progress.costUsd.toFixed(4)})`);
    await appendFile(logFile, `\n[PIPELINE] STUCK — finalize failed ($${progress.costUsd.toFixed(4)}, ${progress.turns} turns)\n`);
  }
}

async function markStuck(
  store: ForemanStore,
  runId: string,
  projectId: string,
  seedId: string,
  seedTitle: string,
  progress: RunProgress,
  phase: string,
  reason: string,
  notifyClient?: NotificationClient,
  projectPath?: string,
): Promise<void> {
  const isRateLimit = reason.includes("hit your limit") || reason.includes("rate limit");
  const now = new Date().toISOString();
  const stuckStatus = isRateLimit ? "stuck" : "failed";
  store.updateRunProgress(runId, progress);
  store.updateRun(runId, { status: stuckStatus, completed_at: now });
  notifyClient?.send({ type: "status", runId, status: stuckStatus, timestamp: now, details: { phase, reason } });
  store.logEvent(projectId, isRateLimit ? "stuck" : "fail", {
    seedId,
    title: seedTitle,
    phase,
    reason,
    costUsd: progress.costUsd,
    rateLimit: isRateLimit,
  }, runId);

  // For transient errors (rate limits), reset to 'open' so the task re-enters
  // the ready queue for automatic retry.
  // For permanent failures, mark as 'failed' so the task is NOT auto-retried —
  // the operator must investigate and re-open it manually.
  // Pass projectPath (repo root) so br finds .beads/ — the worktree has none.
  if (isRateLimit) {
    await resetSeedToOpen(seedId, projectPath);
    log(`Reset seed ${seedId} back to open (rate limited — will retry)`);
  } else {
    await markBeadFailed(seedId, projectPath);
    log(`Marked seed ${seedId} as failed (permanent failure — manual intervention required)`);
  }

  // Add failure reason as a note on the bead for visibility.
  // This allows anyone looking at the bead to see why it failed without
  // having to dig into log files or SQLite.
  const notePrefix = isRateLimit ? "[RATE_LIMITED]" : "[FAILED]";
  const failureNote = `${notePrefix} [${phase.toUpperCase()}] ${reason}`;
  addNotesToBead(seedId, failureNote, projectPath);
  log(`Added failure note to seed ${seedId}`);

  store.close();
}

// ── Helpers ──────────────────────────────────────────────────────────────────


function log(msg: string): void {
  const ts = new Date().toISOString().slice(11, 23);
  console.error(`[foreman-worker ${ts}] ${msg}`);
}

// ── Entry ────────────────────────────────────────────────────────────────────

/**
 * Top-level fatal error handler.
 *
 * When main() rejects (e.g. config parse failure, ForemanStore.forProject()
 * throws, or runPipeline() propagates an uncaught error), we attempt to:
 *   1. Update the run status to "failed" in SQLite so the run is not left stuck.
 *   2. Send an Agent Mail "worker-error" message to the "foreman" mailbox so
 *      the operator can see the error without having to grep log files.
 *
 * Both operations are best-effort — if Agent Mail is unavailable or the store
 * cannot be opened, we log and exit cleanly rather than masking the original
 * error.
 *
 * The config is re-read from argv[2] if it still exists on disk (worker
 * crashed before unlinking it), or parsed from what we can infer.  We attempt
 * to load runId/seedId from the config so we can target the correct DB row.
 */
async function fatalHandler(err: unknown): Promise<void> {
  const msg = err instanceof Error ? err.message : String(err);
  console.error(`[foreman-worker] Fatal: ${msg}`);

  // Try to recover enough context to update SQLite + send Agent Mail.
  const configPath = process.argv[2];
  if (!configPath) {
    process.exit(1);
  }

  let runId: string | undefined;
  let seedId: string | undefined;
  let projectPath: string | undefined;

  // Config may have already been deleted by main(); re-read if still present.
  try {
    const raw = readFileSync(configPath, "utf-8");
    const cfg = JSON.parse(raw) as Partial<WorkerConfig>;
    runId = cfg.runId;
    seedId = cfg.seedId;
    projectPath = cfg.projectPath ?? (cfg.worktreePath ? join(cfg.worktreePath, "..", "..") : undefined);
  } catch {
    // Config already deleted (worker started successfully but crashed later).
    // We cannot recover context from disk at this point.
  }

  if (runId && projectPath) {
    // Update SQLite so the run is not left permanently in "running" status.
    try {
      const store = ForemanStore.forProject(projectPath);
      store.updateRun(runId, {
        status: "failed",
        completed_at: new Date().toISOString(),
      });
      store.close();
    } catch (storeErr: unknown) {
      const storeMsg = storeErr instanceof Error ? storeErr.message : String(storeErr);
      console.error(`[foreman-worker] Could not update run status: ${storeMsg}`);
    }

    // Send SQLite mail notification so the run record reflects the fatal error.
    // agentMailClient is not in scope here — create a fresh one.
    if (seedId && runId) {
      try {
        const mailCandidate = new SqliteMailClient();
        await mailCandidate.ensureProject(projectPath);
        mailCandidate.setRunId(runId);
        await mailCandidate.sendMessage(
          "foreman",
          "worker-error",
          JSON.stringify({
            runId,
            seedId,
            error: msg,
            phase: currentPhase,
          }),
        );
      } catch {
        // Mail unavailable — SQLite update above is sufficient.
      }
    }
  }

  process.exit(1);
}

main().catch(fatalHandler);
