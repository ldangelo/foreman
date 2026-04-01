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
import { request as httpRequest } from "node:http";
import { runWithPiSdk } from "./pi-sdk-runner.js";
import { createSendMailTool, createGetRunStatusTool, createCloseBeadTool } from "./pi-sdk-tools.js";
import { executePipeline } from "./pipeline-executor.js";
import type { EpicTask } from "./pipeline-executor.js";
import { ForemanStore } from "../lib/store.js";
import type { RunProgress } from "../lib/store.js";
import { NativeTaskStore } from "../lib/task-store.js";
import { PIPELINE_TIMEOUTS } from "../lib/config.js";
import {
  ROLE_CONFIGS,
  getDisallowedTools,
} from "./roles.js";
import { enqueueToMergeQueue } from "./agent-worker-enqueue.js";
import { enqueueResetSeedToOpen, enqueueMarkBeadFailed, enqueueAddNotesToBead, enqueueCloseSeed } from "./task-backend-ops.js";
import type { AgentRole, WorkerNotification } from "./types.js";
import { inferProjectPathFromWorkspacePath } from "../lib/workspace-paths.js";
import { SqliteMailClient } from "../lib/sqlite-mail-client.js";
import { loadWorkflowConfig, resolveWorkflowName, type WorkflowConfig } from "../lib/workflow-loader.js";
import { autoMerge } from "./auto-merge.js";
import { BeadsRustClient } from "../lib/beads-rust.js";
import { VcsBackendFactory } from "../lib/vcs/index.js";
import type { VcsBackend } from "../lib/vcs/interface.js";

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
  /**
   * Bead priority string ("P0"–"P4", "0"–"4", or undefined).
   * Forwarded to the pipeline executor to resolve per-priority models from YAML.
   */
  seedPriority?: string;
  /**
   * Override target branch for auto-merge after finalize.
   * When set, merges into this branch instead of detectDefaultBranch().
   */
  targetBranch?: string;
  /**
   * Ordered list of child tasks for epic execution mode (TRD-2026-007).
   * When set, the worker runs the epic pipeline path.
   */
  epicTasks?: EpicTask[];
  /**
   * Parent epic bead ID (TRD-2026-007).
   * When set, this run is an epic execution.
   */
  epicId?: string;
}

// ── Main ─────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const configPath = process.argv[2];
  if (!configPath) {
    console.error("Usage: agent-worker <config-file>");
    process.exit(1);
  }

  // Read and delete config file (contains env vars including credentials — delete immediately)
  const config: WorkerConfig = JSON.parse(readFileSync(configPath, "utf-8"));
  try { unlinkSync(configPath); } catch { /* already deleted */ }

  const { runId, projectId, seedId, seedTitle, model, worktreePath, projectPath: configProjectPath, prompt, resume, pipeline } = config;

  // Change process cwd to the worktree so agent file operations (read, write,
  // edit, bash) target the correct directory. The spawn cwd is the project root
  // (for tsx module resolution), but the agent must work in the worktree.
  try { process.chdir(worktreePath); } catch { /* worktree may not exist yet */ }

  // Resolve the project-local store path from the config, falling back to the
  // parent of the worktree directory if projectPath is not provided.
  const storeProjectPath = configProjectPath ?? inferProjectPathFromWorkspacePath(worktreePath);

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

        if ((name === "write" || name === "edit" || name === "Write" || name === "Edit") && (input?.path || input?.file_path)) {
          const filePath = String(input.path ?? input.file_path);
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
      enqueueMarkBeadFailed(store, seedId, "agent-worker");
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
      enqueueResetSeedToOpen(store, seedId, "agent-worker");
    } else {
      enqueueMarkBeadFailed(store, seedId, "agent-worker");
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
  tokensIn: number;
  tokensOut: number;
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
  // Use the model resolved by the pipeline executor (from workflow YAML + bead priority).
  // Falls back to ROLE_CONFIGS[role].model for backward compat (no-YAML / direct invocation).
  const resolvedModel: string = config.model || roleConfig.model;
  progress.currentPhase = role;
  store.updateRunProgress(config.runId, progress);

  const disallowedTools = getDisallowedTools(roleConfig);
  const allowedSummary = roleConfig.allowedTools.join(", ");
  await appendFile(logFile, `\n${"─".repeat(40)}\n[PHASE: ${role.toUpperCase()}] Starting (model=${resolvedModel}, maxBudgetUsd=${roleConfig.maxBudgetUsd}, allowedTools=[${allowedSummary}])\n`);
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
      model: resolvedModel,
      allowedTools: roleConfig.allowedTools,
      customTools,
      logFile,
      onToolCall: (name, input) => {
        progress.toolCalls++;
        progress.toolBreakdown[name] = (progress.toolBreakdown[name] ?? 0) + 1;
        progress.lastToolCall = name;
        progress.lastActivity = new Date().toISOString();

        if ((name === "write" || name === "edit" || name === "Write" || name === "Edit") && (input?.path || input?.file_path)) {
          const filePath = String(input.path ?? input.file_path);
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
    progress.tokensIn += phaseResult.tokensIn;
    progress.tokensOut += phaseResult.tokensOut;

    // Record per-phase cost breakdown
    progress.costByPhase ??= {};
    progress.costByPhase[role] = (progress.costByPhase[role] ?? 0) + phaseResult.costUsd;
    progress.agentByPhase ??= {};
    progress.agentByPhase[role] = resolvedModel;

    store.updateRunProgress(config.runId, progress);

    if (phaseResult.success) {
      log(`[${role.toUpperCase()}] Completed (${phaseResult.turns} turns, $${phaseResult.costUsd.toFixed(4)})`);
      await appendFile(logFile, `[PHASE: ${role.toUpperCase()}] COMPLETED ($${phaseResult.costUsd.toFixed(4)})\n`);
      return { success: true, costUsd: phaseResult.costUsd, turns: phaseResult.turns, tokensIn: phaseResult.tokensIn, tokensOut: phaseResult.tokensOut };
    } else {
      const reason = phaseResult.errorMessage ?? "Pi agent ended without success";
      log(`[${role.toUpperCase()}] Failed: ${reason.slice(0, 200)}`);
      await appendFile(logFile, `[PHASE: ${role.toUpperCase()}] FAILED: ${reason}\n`);
      return { success: false, costUsd: phaseResult.costUsd, turns: phaseResult.turns, tokensIn: phaseResult.tokensIn, tokensOut: phaseResult.tokensOut, error: reason };
    }
  } catch (err: unknown) {
    const reason = err instanceof Error ? err.message : String(err);
    const isRateLimit = reason.includes("hit your limit") || reason.includes("rate limit");
    log(`[${role.toUpperCase()}] ${isRateLimit ? "RATE LIMITED" : "ERROR"}: ${reason.slice(0, 200)}`);
    await appendFile(logFile, `[PHASE: ${role.toUpperCase()}] ERROR: ${reason}\n`);
    return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: reason };
  }
}

function readReport(worktreePath: string, filename: string): string | null {
  const p = join(worktreePath, filename);
  try { return readFileSync(p, "utf-8"); } catch { return null; }
}


/**
 * Run the troubleshooter phase as a separate SDK session.
 *
 * Invoked after a pipeline failure when workflowConfig.onFailure is present.
 * The troubleshooter reads failure context (artifacts, run status) and attempts
 * to resolve the issue automatically (fix test failures, resolve conflicts, etc.).
 *
 * Returns true if the troubleshooter reports RESOLVED in its artifact, false otherwise.
 */
async function runTroubleshooterPhase(
  config: WorkerConfig,
  workflowConfig: import("../lib/workflow-loader.js").WorkflowConfig,
  store: ForemanStore,
  logFile: string,
  notifyClient: NotificationClient,
  agentMailClient: AnyMailClient | null,
  failureContext: string,
  pipelineProjectPath: string,
): Promise<boolean> {
  const onFailure = workflowConfig.onFailure;
  if (!onFailure) return false;

  const { runId, seedId: beadId, seedTitle: beadTitle } = config;
  log(`[TROUBLESHOOTER] Activating for ${beadId} — failure context: ${failureContext.slice(0, 120)}`);

  // Build a basic troubleshooter prompt with failure context injected
  const prompt = [
    `# Troubleshooter Agent`,
    ``,
    `**Bead:** ${beadId} — ${beadTitle}`,
    `**Run ID:** ${runId}`,
    `**Failure Context:**`,
    failureContext,
    ``,
    `Use get_run_status, read artifacts, and apply fixes. Write TROUBLESHOOT_REPORT.md when done.`,
    `Use bead terminology in your notes. Include "RESOLVED" in the report if the failure was fixed, or "ESCALATED" if not.`,
  ].join("\n");

  const roleConfig = ROLE_CONFIGS.troubleshooter;
  const resolvedModel = onFailure.models?.["default"] ?? roleConfig.model;

  const customTools: import("@mariozechner/pi-coding-agent").ToolDefinition[] = [];
  if (agentMailClient) {
    customTools.push(createSendMailTool(agentMailClient, `troubleshooter-${beadId}`));
  }
  customTools.push(createGetRunStatusTool(store));
  customTools.push(createCloseBeadTool(pipelineProjectPath));

  try {
    const result = await runWithPiSdk({
      prompt,
      systemPrompt: `You are the troubleshooter agent for Foreman. Your job is to diagnose and fix a pipeline failure for bead: ${beadTitle}`,
      cwd: config.worktreePath,
      model: resolvedModel,
      allowedTools: roleConfig.allowedTools,
      customTools,
      logFile,
      onToolCall: () => { /* no-op */ },
      onTurnEnd: () => { /* no-op */ },
    });

    log(`[TROUBLESHOOTER] Completed (${result.turns} turns, $${result.costUsd.toFixed(4)})`);
    await appendFile(logFile, `[TROUBLESHOOTER] ${result.success ? "COMPLETED" : "FAILED"} ($${result.costUsd.toFixed(4)})\n`);

    // Check if TROUBLESHOOT_REPORT.md contains "RESOLVED"
    const { join: pathJoin } = await import("node:path");
    const { readFileSync: rfs } = await import("node:fs");
    try {
      const report = rfs(pathJoin(config.worktreePath, "TROUBLESHOOT_REPORT.md"), "utf-8");
      const troubleshooterResolved = report.includes("RESOLVED");
      if (troubleshooterResolved) {
        log(`[TROUBLESHOOTER] PIPELINE RECOVERED for ${beadId}`);
        await appendFile(logFile, `[TROUBLESHOOTER] PIPELINE RECOVERED\n`);
        return true;
      }
    } catch {
      // Report not written — escalated
    }
    return false;
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[TROUBLESHOOTER] Error: ${msg}`);
    return false;
  }
}

/**
 * Run the full pipeline: Explorer → Developer ⇄ QA → Reviewer → Finalize.
 * Each phase is a separate SDK session. TypeScript orchestrates the loop.
 */
async function runPipeline(config: WorkerConfig, store: ForemanStore, logFile: string, notifyClient: NotificationClient, agentMailClient: AnyMailClient | null): Promise<void> {
  const pipelineProjectPath = config.projectPath ?? inferProjectPathFromWorkspacePath(config.worktreePath);
  const resolvedWorkflow = resolveWorkflowName(config.seedType ?? "feature", config.seedLabels);
  // Load the workflow config (phase sequence + per-phase overrides).
  let workflowConfig: WorkflowConfig;
  try {
    workflowConfig = loadWorkflowConfig(resolvedWorkflow, pipelineProjectPath);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[PIPELINE] Failed to load workflow config '${resolvedWorkflow}': ${msg}`);
    throw err;
  }

  // Create a NativeTaskStore from the same DB for phase-level visibility (REQ-012).
  // updatePhase() is called after each successful phase transition.
  // No-op when config.taskId is absent (beads fallback mode — REQ-017).
  const taskStore = new NativeTaskStore(store.getDb());

  // Initialize VCS backend for prompt templating (TRD-026, TRD-027).
  // Reconstructed from FOREMAN_VCS_BACKEND env var set by dispatcher.
  let vcsBackend: VcsBackend | undefined;
  try {
    vcsBackend = await VcsBackendFactory.fromEnv(
      pipelineProjectPath,
      process.env.FOREMAN_VCS_BACKEND,
    );
    log(`[PIPELINE] VCS backend: ${vcsBackend.name}`);
  } catch {
    // Non-fatal: falls back to git defaults in buildPhasePrompt
    log(`[PIPELINE] VCS backend init failed — using prompt defaults`);
  }

  // Ensure targetBranch is set so finalize rebases onto the correct branch.
  // If not provided by the dispatcher, detect the default branch from the active backend.
  if (!config.targetBranch && vcsBackend) {
    try {
      config.targetBranch = await vcsBackend.detectDefaultBranch(pipelineProjectPath);
    } catch {
      // Non-fatal: falls back to "main" in buildPhasePrompt
    }
  }

  // Delegate to the generic workflow-driven executor.
  await executePipeline({
    config: { ...config, vcsBackend },
    workflowConfig,
    store,
    logFile,
    notifyClient,
    agentMailClient,
    taskStore,
    epicTasks: config.epicTasks,
    runPhase,
    registerAgent,
    sendMail,
    sendMailText,
    reserveFiles,
    releaseFiles,
    markStuck,
    log,
    promptOpts: { projectRoot: pipelineProjectPath, workflow: resolvedWorkflow },

    // Epic mode: sync child task bead status into br as the pipeline progresses.
    async onTaskStatusChange(taskSeedId, status) {
      const seeds = new BeadsRustClient(pipelineProjectPath);
      if (status === "in_progress") {
        await seeds.update(taskSeedId, { status: "in_progress" });
        log(`[EPIC] br update ${taskSeedId} → in_progress`);
      } else if (status === "completed") {
        await seeds.close(taskSeedId, "Completed via epic pipeline");
        log(`[EPIC] br close ${taskSeedId} (completed)`);
      } else if (status === "failed") {
        await seeds.update(taskSeedId, { status: "failed" });
        log(`[EPIC] br update ${taskSeedId} → failed`);
      }
    },

    // Epic mode: create a bug bead when QA fails on a child task.
    async onTaskQaFailure(taskSeedId, taskTitle, epicId) {
      const seeds = new BeadsRustClient(pipelineProjectPath);
      const bug = await seeds.create(`QA failure: ${taskTitle}`, {
        type: "bug",
        priority: "1",
        parent: epicId,
        description: `QA failed for task ${taskSeedId} (${taskTitle}) during epic pipeline run.`,
      });
      log(`[EPIC] Created bug bead ${bug.id} for QA failure on ${taskSeedId}`);
      return bug.id;
    },

    // Epic mode: close a bug bead when QA passes on retry.
    async onTaskQaPass(bugBeadId) {
      const seeds = new BeadsRustClient(pipelineProjectPath);
      await seeds.close(bugBeadId, "QA passed on retry");
      log(`[EPIC] Closed bug bead ${bugBeadId} (QA passed on retry)`);
    },

    // P1: Rate limit alert callback - log rate limit events for alerting
    onRateLimit(model, phase, error, retryAfterSeconds) {
      // P1: Alert when rate limit detected in logs
      const alertMsg = `[RATE_LIMIT_ALERT] ${phase} phase rate limited on ${model}` +
        (retryAfterSeconds ? ` (Retry-After: ${retryAfterSeconds}s)` : "") +
        ` at ${new Date().toISOString()}`;
      console.error(alertMsg);
      log(alertMsg);

      // P1: Log rate limit event for pattern detection
      store.logRateLimitEvent(config.projectId, model, phase, error, retryAfterSeconds, config.runId);

      // Also send agent-error mail for visibility
      sendMail(agentMailClient, "foreman", "rate-limit-alert", {
        seedId: config.seedId,
        phase,
        model,
        error,
        retryAfterSeconds,
      });
    },

    // Finalize post-processing: determine push success, enqueue to merge queue, update run status.
    // P0 fix: Only send branch-ready if pipeline succeeded AND we're at the finalize phase.
    async onPipelineComplete({ progress, success }) {
      // Guard: only finalize post-processing when the pipeline reached finalize.
      // Earlier phase failures are already handled by markStuck().
      if (progress.currentPhase !== "finalize") {
        log(`[FINALIZE] Skipping branch-ready: success=${String(success)}, currentPhase=${progress.currentPhase}`);
        return;
      }
      const { runId, projectId, seedId, seedTitle, worktreePath } = config;

      // Read finalize outcome from agent mail.
      let finalizeSucceeded = success;
      let finalizeRetryable = true;
      let finalizeFailureReason = success ? "" : "finalize_validation_failed";
      if (agentMailClient) {
        const foremanMsgs = await agentMailClient.fetchInbox("foreman");
        const finalizeSender = `finalize-${seedId}`;
        const finalizeMsg = foremanMsgs.find(
          (m) => (m.subject === "phase-complete" || m.subject === "agent-error") &&
                  (m.from === finalizeSender || m.from === "finalize"),
        );
        if (finalizeMsg?.subject === "phase-complete") {
          const body = (() => { try { return JSON.parse(finalizeMsg.body ?? "{}") as Record<string, unknown>; } catch { return {} as Record<string, unknown>; } })();
          const status = typeof body["status"] === "string" ? body["status"] : "complete";
          finalizeRetryable = body["retryable"] !== false;
          finalizeSucceeded = status === "complete" || status === "completed";
          if (!finalizeSucceeded) {
            finalizeFailureReason = typeof body["note"] === "string"
              ? body["note"]
              : "finalize_phase_reported_failed_status";
          }
          log(`[FINALIZE] phase-complete mail received — status=${status}, retryable=${String(finalizeRetryable)}`);
        } else if (finalizeMsg?.subject === "agent-error") {
          const body = (() => { try { return JSON.parse(finalizeMsg.body ?? "{}") as Record<string, unknown>; } catch { return {} as Record<string, unknown>; } })();
          finalizeRetryable = body["retryable"] !== false;
          const errorDetail = typeof body["error"] === "string" ? body["error"] : "unknown finalize error";
          finalizeFailureReason = errorDetail;
          log(`[FINALIZE] agent-error mail received — error: ${errorDetail}, retryable: ${String(finalizeRetryable)}`);

          // Special case: "nothing to commit" may be normal when a worktree is
          // reused from a previous run (commits already exist). Check if the
          // branch has commits ahead of the target — if so, the work is done.
          // Also handle verification/test beads which genuinely have no changes.
          if (errorDetail === "nothing_to_commit") {
            const beadType = config.seedType ?? "";
            const beadTitle = config.seedTitle ?? "";
            const isVerificationBead = beadType === "test" ||
              /verify|validate|test/i.test(beadTitle);

            // Check if branch has commits ahead of target (reused worktree scenario).
            // Try multiple refs: the remote target branch may not exist if it hasn't
            // been pushed yet. Fall back to the local branch, then origin/dev.
            let hasCommitsAhead = false;
            {
              const candidates: string[] = [];
              if (config.targetBranch) {
                candidates.push(`origin/${config.targetBranch}`, config.targetBranch);
              }
              candidates.push("origin/dev", "origin/main");
              const aheadBackend = vcsBackend ?? await VcsBackendFactory.create({ backend: "auto" }, worktreePath);
              for (const ref of candidates) {
                try {
                  // Use VcsBackend.getChangedFiles() as a proxy for checking if
                  // HEAD has any commits ahead of the given ref. Three-dot
                  // semantics are used for consistency with the rest of the VCS layer.
                  const changedFiles = await aheadBackend.getChangedFiles(worktreePath, ref, "HEAD");
                  hasCommitsAhead = changedFiles.length > 0;
                  break; // First valid ref wins
                } catch {
                  // Ref doesn't exist or git failed — try next
                }
              }
            }

            if (hasCommitsAhead) {
              finalizeSucceeded = true;
              log(`[FINALIZE] nothing_to_commit but branch has prior commits — treating as success (reused worktree)`);
            } else if (isVerificationBead) {
              finalizeSucceeded = true;
              log(`[FINALIZE] nothing_to_commit on verification bead (type="${beadType}", title="${beadTitle}") — treating as success`);
            } else {
              // The pipeline passed developer + QA + reviewer — all phases
              // succeeded. If finalize finds nothing to commit and no commits
              // ahead, the work was already merged into the target branch
              // (e.g. from a previous run). The developer report confirms it.
              // Treat as success rather than getting stuck in a reset loop.
              finalizeSucceeded = true;
              log(`[FINALIZE] nothing_to_commit and no commits ahead — work already on target branch, treating as success`);
            }
          }
        } else {
          // No finalize-specific mail — preserve the pipeline success result.
          // A finalize FAIL verdict may not emit phase-complete or agent-error
          // mail, so assuming success here can incorrectly enqueue failed runs
          // to the merge queue and send branch-ready.
          log(`[FINALIZE] No finalize mail found — preserving pipeline success=${String(finalizeSucceeded)}`);
        }
      }

      // ── Troubleshooter: attempt recovery on failure ──────────────────────
      const shouldSkipTroubleshooter =
        !finalizeSucceeded &&
        !finalizeRetryable &&
        finalizeFailureReason === "tests_failed_pre_existing_issues";
      if (shouldSkipTroubleshooter) {
        log("[TROUBLESHOOTER] Skipping for non-retryable pre-existing finalize test failures");
      }
      const troubleshooterEnabled = !finalizeSucceeded && !!workflowConfig.onFailure && !shouldSkipTroubleshooter;
      let troubleshooterResolved = false;
      if (troubleshooterEnabled) {
        const failureContext = `Pipeline failed at finalize phase. finalizeRetryable=${String(finalizeRetryable)}`;
        troubleshooterResolved = await runTroubleshooterPhase(
          config,
          workflowConfig,
          store,
          logFile,
          notifyClient,
          agentMailClient,
          failureContext,
          pipelineProjectPath,
        );
        if (troubleshooterResolved) {
          // Troubleshooter resolved the issue — treat as success
          finalizeSucceeded = true;
        }
      }

      const now = new Date().toISOString();
      if (finalizeSucceeded) {
        // Mark run as completed BEFORE enqueue/autoMerge — autoMerge looks
        // for completed runs, so this must happen first.
        store.updateRun(runId, { status: "completed", completed_at: now });
        notifyClient.send({ type: "status", runId, status: "completed", timestamp: now });

        let skipMergeQueue = false;
        if (troubleshooterResolved) {
          try {
            const completionBackend = vcsBackend ?? await VcsBackendFactory.create({ backend: "auto" }, worktreePath);
            const completionTargetBranch = config.targetBranch ?? await completionBackend.detectDefaultBranch(worktreePath);
            const changedAgainstTarget = await completionBackend.getChangedFiles(worktreePath, completionTargetBranch, "HEAD");
            if (changedAgainstTarget.length === 0) {
              skipMergeQueue = true;
              log(`[FINALIZE] Branch already matches ${completionTargetBranch} after troubleshooter recovery — skipping branch-ready/merge queue`);
              enqueueCloseSeed(store, seedId, "agent-worker-finalize");
            }
          } catch (alreadyMergedErr: unknown) {
            const alreadyMergedMsg = alreadyMergedErr instanceof Error ? alreadyMergedErr.message : String(alreadyMergedErr);
            log(`[FINALIZE] Unable to verify post-troubleshooter merge state (continuing with merge queue): ${alreadyMergedMsg}`);
          }
        }

        if (!skipMergeQueue) {
          try {
            const enqueueStore = ForemanStore.forProject(pipelineProjectPath);
            // Pre-compute modified files via VcsBackend (async) before calling
            // enqueueToMergeQueue which expects a synchronous getFilesModified callback.
            let enqueueFiles: string[] = [];
            try {
              const enqueueBackend = vcsBackend ?? await VcsBackendFactory.create({ backend: "auto" }, worktreePath);
              const enqueueDefaultBranch = await enqueueBackend.detectDefaultBranch(worktreePath);
              enqueueFiles = await enqueueBackend.getChangedFiles(worktreePath, enqueueDefaultBranch, "HEAD");
            } catch {
              // Non-fatal — proceed with empty file list
            }
            const enqueueResult = enqueueToMergeQueue({
              db: enqueueStore.getDb(),
              seedId,
              runId,
              worktreePath,
              getFilesModified: () => enqueueFiles,
            });
            enqueueStore.close();
            if (enqueueResult.success) {
              log(`[FINALIZE] Enqueued to merge queue`);
              // Guard: Only send branch-ready after successful finalize push (double-check).
              // Primary guard is at function entry, this is defense-in-depth.
              sendMail(agentMailClient, "refinery", "branch-ready", {
                seedId, runId, branch: `foreman/${seedId}`, worktreePath,
              });

              // Trigger autoMerge immediately so the branch is merged even if
              // `foreman run` is no longer active (fixes: bd-0qv2).
              try {
                const mergeStore = ForemanStore.forProject(pipelineProjectPath);
                const mergeTaskClient = new BeadsRustClient(pipelineProjectPath);
                log(`[FINALIZE] Triggering immediate autoMerge for ${seedId}${config.targetBranch ? ` → ${config.targetBranch}` : ""}`);
                const mergeResult = await autoMerge({
                  store: mergeStore,
                  taskClient: mergeTaskClient,
                  projectPath: pipelineProjectPath,
                  targetBranch: config.targetBranch,
                });
                mergeStore.close();
                log(`[FINALIZE] autoMerge result: merged=${mergeResult.merged} conflicts=${mergeResult.conflicts} failed=${mergeResult.failed}`);
              } catch (mergeErr: unknown) {
                const mergeMsg = mergeErr instanceof Error ? mergeErr.message : String(mergeErr);
                log(`[FINALIZE] autoMerge failed (non-fatal): ${mergeMsg}`);
              }
            } else {
              log(`[FINALIZE] Merge queue enqueue failed (non-fatal): ${enqueueResult.error ?? "(unknown)"}`);
            }
          } catch (enqErr: unknown) {
            const enqMsg = enqErr instanceof Error ? enqErr.message : String(enqErr);
            log(`[FINALIZE] Merge queue enqueue failed (non-fatal): ${enqMsg}`);
          }
        }
      } else {
        let alreadyLandedOnTarget = false;
        if (!finalizeRetryable && finalizeFailureReason === "tests_failed_pre_existing_issues") {
          try {
            const completionBackend = vcsBackend ?? await VcsBackendFactory.create({ backend: "auto" }, worktreePath);
            const completionTargetBranch = config.targetBranch ?? await completionBackend.detectDefaultBranch(worktreePath);
            const changedAgainstTarget = await completionBackend.getChangedFiles(worktreePath, completionTargetBranch, "HEAD");
            if (changedAgainstTarget.length === 0) {
              alreadyLandedOnTarget = true;
              store.updateRun(runId, { status: "merged", completed_at: now });
              notifyClient.send({ type: "status", runId, status: "merged", timestamp: now });
              enqueueCloseSeed(store, seedId, "agent-worker-finalize");
              log(`[FINALIZE] Pre-existing test failures but branch already matches ${completionTargetBranch} — treating bead as merged`);
            }
          } catch (alreadyMergedErr: unknown) {
            const alreadyMergedMsg = alreadyMergedErr instanceof Error ? alreadyMergedErr.message : String(alreadyMergedErr);
            log(`[FINALIZE] Unable to verify whether pre-existing test failure run already landed on target: ${alreadyMergedMsg}`);
          }
        }

        if (!alreadyLandedOnTarget) {
          const terminalStatus = finalizeRetryable ? "stuck" : "failed";
          store.updateRun(runId, { status: terminalStatus, completed_at: now });
          notifyClient.send({ type: "status", runId, status: terminalStatus, timestamp: now });
          sendMail(agentMailClient, "foreman", "agent-error", {
            seedId,
            phase: "finalize",
            error: finalizeFailureReason || "Finalize failed",
            retryable: finalizeRetryable,
          });
          if (finalizeRetryable) {
            enqueueResetSeedToOpen(store, seedId, "agent-worker-finalize");
          } else {
            enqueueMarkBeadFailed(store, seedId, "agent-worker-finalize");
            log(`[PIPELINE] Deterministic finalize failure for ${seedId} — marking failed without retry`);
          }
        }
      }

      // Log terminal event
      const completedPhases = workflowConfig.phases.map((p) => p.name).join("→");
      store.logEvent(projectId, finalizeSucceeded ? "complete" : (finalizeRetryable ? "stuck" : "fail"), {
        seedId,
        title: seedTitle,
        costUsd: progress.costUsd,
        numTurns: progress.turns,
        toolCalls: progress.toolCalls,
        filesChanged: progress.filesChanged.length,
        phases: completedPhases,
      }, runId);

      if (finalizeSucceeded) {
        log(`PIPELINE COMPLETED for ${seedId} (${progress.turns} turns, ${progress.toolCalls} tools, $${progress.costUsd.toFixed(4)})`);
        await appendFile(logFile, `\n[PIPELINE] COMPLETED ($${progress.costUsd.toFixed(4)}, ${progress.turns} turns)\n`);
      } else {
        log(`PIPELINE STUCK for ${seedId} — finalize failed ($${progress.costUsd.toFixed(4)})`);
        await appendFile(logFile, `\n[PIPELINE] STUCK — finalize failed ($${progress.costUsd.toFixed(4)})\n`);
      }
    },
  });

}

// NOTE: ~460 lines of hardcoded pipeline code removed.
// Pipeline execution is now driven by workflow YAML via executePipeline() in pipeline-executor.ts.

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
  // Enqueue via the bead write queue instead of calling br directly — the
  // dispatcher drains the queue sequentially, preventing SQLite contention.
  if (isRateLimit) {
    enqueueResetSeedToOpen(store, seedId, "agent-worker-markStuck");
    log(`Enqueued reset-seed for ${seedId} (rate limited — will retry on next dispatch)`);
  } else {
    enqueueMarkBeadFailed(store, seedId, "agent-worker-markStuck");
    log(`Enqueued mark-failed for ${seedId} (permanent failure — manual intervention required)`);
  }

  // Add failure reason as a note on the bead for visibility.
  // This allows anyone looking at the bead to see why it failed without
  // having to dig into log files or SQLite.
  const notePrefix = isRateLimit ? "[RATE_LIMITED]" : "[FAILED]";
  const failureNote = `${notePrefix} [${phase.toUpperCase()}] ${reason}`;
  enqueueAddNotesToBead(store, seedId, failureNote, "agent-worker-markStuck");
  log(`Enqueued add-notes for seed ${seedId}`);
  // Note: do NOT close store here — the caller (main()) owns the store lifecycle.
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
    projectPath = cfg.projectPath ?? (cfg.worktreePath ? inferProjectPathFromWorkspacePath(cfg.worktreePath) : undefined);
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
