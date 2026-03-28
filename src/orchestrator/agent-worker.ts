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
import { executePipeline } from "./pipeline-executor.js";
import { ForemanStore } from "../lib/store.js";
import type { RunProgress } from "../lib/store.js";
import { PIPELINE_TIMEOUTS } from "../lib/config.js";
import {
  ROLE_CONFIGS,
  getDisallowedTools,
} from "./roles.js";
import { enqueueToMergeQueue } from "./agent-worker-enqueue.js";
import { detectDefaultBranch } from "../lib/git.js";
import { enqueueResetSeedToOpen, enqueueMarkBeadFailed, enqueueAddNotesToBead } from "./task-backend-ops.js";
import type { AgentRole, WorkerNotification } from "./types.js";
import { SqliteMailClient } from "../lib/sqlite-mail-client.js";
import { loadWorkflowConfig, resolveWorkflowName, type WorkflowConfig } from "../lib/workflow-loader.js";
import { autoMerge } from "./auto-merge.js";
import { BeadsRustClient } from "../lib/beads-rust.js";
import { VcsBackendFactory } from "../lib/vcs/index.js";

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
 * Run the full pipeline: Explorer → Developer ⇄ QA → Reviewer → Finalize.
 * Each phase is a separate SDK session. TypeScript orchestrates the loop.
 */
async function runPipeline(config: WorkerConfig, store: ForemanStore, logFile: string, notifyClient: NotificationClient, agentMailClient: AnyMailClient | null): Promise<void> {
  const pipelineProjectPath = config.projectPath ?? join(config.worktreePath, "..", "..");
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

  // Ensure targetBranch is set so finalize rebases onto the correct branch.
  // If not provided by the dispatcher, detect the default branch (e.g. dev).
  if (!config.targetBranch) {
    try {
      config.targetBranch = await detectDefaultBranch(pipelineProjectPath);
    } catch {
      // Non-fatal: falls back to "main" in buildPhasePrompt
    }
  }

  // Initialize VCS backend for prompt templating (TRD-026, TRD-027).
  // Reconstructed from FOREMAN_VCS_BACKEND env var set by dispatcher.
  let vcsBackend;
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

  // Delegate to the generic workflow-driven executor.
  await executePipeline({
    config: { ...config, vcsBackend },
    workflowConfig,
    store,
    logFile,
    notifyClient,
    agentMailClient,
    runPhase,
    registerAgent,
    sendMail,
    sendMailText,
    reserveFiles,
    releaseFiles,
    markStuck,
    log,
    promptOpts: { projectRoot: pipelineProjectPath, workflow: resolvedWorkflow },

    // Finalize post-processing: determine push success, enqueue to merge queue, update run status.
    async onPipelineComplete({ progress }) {
      const { runId, projectId, seedId, seedTitle, worktreePath } = config;

      // Read finalize outcome from agent mail.
      let finalizeSucceeded = false;
      let finalizeRetryable = true;
      if (agentMailClient) {
        const foremanMsgs = await agentMailClient.fetchInbox("foreman");
        const finalizeSender = `finalize-${seedId}`;
        const finalizeMsg = foremanMsgs.find(
          (m) => (m.subject === "phase-complete" || m.subject === "agent-error") &&
                  (m.from === finalizeSender || m.from === "finalize"),
        );
        if (finalizeMsg?.subject === "phase-complete") {
          finalizeSucceeded = true;
          log(`[FINALIZE] phase-complete mail received — push succeeded`);
        } else if (finalizeMsg?.subject === "agent-error") {
          const body = (() => { try { return JSON.parse(finalizeMsg.body ?? "{}") as Record<string, unknown>; } catch { return {} as Record<string, unknown>; } })();
          finalizeRetryable = body["retryable"] !== false;
          const errorDetail = typeof body["error"] === "string" ? body["error"] : "unknown finalize error";
          log(`[FINALIZE] agent-error mail received — error: ${errorDetail}, retryable: ${String(finalizeRetryable)}`);

          // Special case: "nothing to commit" is success for verification/test beads.
          // The finalize agent should already handle this in its prompt, but as a
          // safety net we also check here so verification beads aren't stuck in a
          // reset-to-open loop when the LLM misses the conditional logic.
          if (errorDetail === "nothing_to_commit") {
            const beadType = config.seedType ?? "";
            const beadTitle = config.seedTitle ?? "";
            const isVerificationBead = beadType === "test" ||
              /verify|validate|test/i.test(beadTitle);
            if (isVerificationBead) {
              finalizeSucceeded = true;
              log(`[FINALIZE] nothing_to_commit on verification bead (type="${beadType}", title="${beadTitle}") — treating as success`);
            }
          }
        } else {
          // No finalize-specific mail — assume success if all phases completed
          finalizeSucceeded = true;
          log(`[FINALIZE] No finalize mail found — assuming success`);
        }
      } else {
        finalizeSucceeded = true;
      }

      const now = new Date().toISOString();
      if (finalizeSucceeded) {
        // Mark run as completed BEFORE enqueue/autoMerge — autoMerge looks
        // for completed runs, so this must happen first.
        store.updateRun(runId, { status: "completed", completed_at: now });
        notifyClient.send({ type: "status", runId, status: "completed", timestamp: now });

        try {
          const enqueueStore = ForemanStore.forProject(pipelineProjectPath);
          const enqueueOpts = { cwd: worktreePath, stdio: "pipe" as const, timeout: PIPELINE_TIMEOUTS.gitOperationMs };
          const enqueueResult = enqueueToMergeQueue({
            db: enqueueStore.getDb(),
            seedId,
            runId,
            worktreePath,
            getFilesModified: () => {
              const output = execFileSync("git", ["diff", "--name-only", "main...HEAD"], enqueueOpts).toString().trim();
              return output ? output.split("\n") : [];
            },
          });
          enqueueStore.close();
          if (enqueueResult.success) {
            log(`[FINALIZE] Enqueued to merge queue`);
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
      } else {
        store.updateRun(runId, { status: "stuck", completed_at: now });
        notifyClient.send({ type: "status", runId, status: "stuck", timestamp: now });
        sendMail(agentMailClient, "foreman", "agent-error", {
          seedId, phase: "finalize", error: "Push failed", retryable: finalizeRetryable,
        });
        if (finalizeRetryable) {
          enqueueResetSeedToOpen(store, seedId, "agent-worker-finalize");
        } else {
          log(`[PIPELINE] Deterministic push failure for ${seedId} — seed left stuck (no reset to open)`);
        }
      }

      // Log terminal event
      const completedPhases = workflowConfig.phases.map((p) => p.name).join("→");
      store.logEvent(projectId, finalizeSucceeded ? "complete" : "stuck", {
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
