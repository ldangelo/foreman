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

import { readFileSync, writeFileSync, unlinkSync, existsSync } from "node:fs";
import { appendFile, mkdir } from "node:fs/promises";
import { join, basename } from "node:path";
import { execFileSync } from "node:child_process";
import { request as httpRequest } from "node:http";
import { query } from "@anthropic-ai/claude-agent-sdk";
import type { SDKMessage, SDKResultSuccess, SDKResultError } from "@anthropic-ai/claude-agent-sdk";
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
  parseVerdict,
  extractIssues,
  hasActionableIssues,
} from "./roles.js";
import { enqueueToMergeQueue } from "./agent-worker-enqueue.js";
import { rotateReport, type FinalizeResult } from "./agent-worker-finalize.js";
import { resetSeedToOpen, addLabelsToBead, addNotesToBead } from "./task-backend-ops.js";
import { writeSessionLog } from "./session-log.js";
import type { PhaseRecord, SessionLogData } from "./session-log.js";
import type { AgentRole, WorkerNotification } from "./types.js";
import { AgentMailClient } from "./agent-mail-client.js";
import { SqliteMailClient } from "../lib/sqlite-mail-client.js";

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

/** Union type for either mail client implementation. */
type AnyMailClient = AgentMailClient | SqliteMailClient;

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
    `  method:    ${pipeline ? "Pipeline (explorer→developer→qa→reviewer)" : "Claude Agent SDK (detached worker)"}`,
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

  // Create mail client. SqliteMailClient is the default (always available).
  // AgentMailClient (HTTP) is used only when FOREMAN_AGENT_MAIL_URL is explicitly set.
  let agentMailClient: AnyMailClient | null = null;
  if (process.env.FOREMAN_AGENT_MAIL_URL) {
    // Opt-in: use external HTTP Agent Mail server
    try {
      const candidate = new AgentMailClient({ baseUrl: process.env.FOREMAN_AGENT_MAIL_URL });
      const reachable = await candidate.healthCheck();
      if (reachable) {
        await candidate.ensureProject(storeProjectPath);
        agentMailClient = candidate;
        log(`[agent-mail] Using HTTP AgentMailClient at ${process.env.FOREMAN_AGENT_MAIL_URL}`);
      }
    } catch {
      // Non-fatal — fall through to SqliteMailClient
    }
  }

  // Default: use SQLite-backed mail client (no external dependencies)
  if (!agentMailClient) {
    try {
      const sqliteClient = new SqliteMailClient();
      await sqliteClient.ensureProject(storeProjectPath);
      sqliteClient.setRunId(runId);
      agentMailClient = sqliteClient;
      log(`[agent-mail] Using SqliteMailClient (scoped to run ${runId})`);
    } catch {
      // Non-fatal — mail is optional infrastructure
    }
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

  // ── Single-agent mode: run a single SDK query ───────────────────────
  let sessionId = resume ?? "";
  let resultHandled = false;

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
    // DCG (Destructive Command Guard): use acceptEdits instead of bypassPermissions.
    // This guards against destructive tool calls (rm -rf, DROP TABLE, etc.) while
    // still allowing file edits and reads that agent tasks legitimately require.
    // sessionLogDir is a valid SDK option but not yet present in the type definitions.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const queryOpts = (resume
      ? {
          prompt,
          options: {
            cwd: worktreePath,
            model: model as any,
            permissionMode: "acceptEdits",
            env,
            resume,
            persistSession: true,
            sessionLogDir: worktreePath,
          },
        }
      : {
          prompt,
          options: {
            cwd: worktreePath,
            model: model as any,
            permissionMode: "acceptEdits",
            env,
            persistSession: true,
            sessionLogDir: worktreePath,
          },
        }) as unknown as Parameters<typeof query>[0];

    // NOTE: Single-agent (non-pipeline) mode emits only terminal status notifications
    // (completed, failed, stuck) — not progress notifications after each assistant turn.
    // Pipeline mode (runPhase) emits a progress notification after every assistant turn.
    // The asymmetry is intentional: single-agent progress is already flushed to SQLite
    // every 2 s via the flushProgress() timer, so the live-UI benefit is preserved via
    // polling fallback. Aligning the two paths is deferred to a follow-up task.
    for await (const message of query(queryOpts)) {
      await logMessage(logFile, message);
      progress.lastActivity = new Date().toISOString();

      // Track session ID
      if ("session_id" in message && message.session_id && !sessionId) {
        sessionId = message.session_id;
        store.updateRun(runId, {
          session_key: `foreman:sdk:${model}:${runId}:session-${sessionId}`,
        });
        log(`  Session: ${sessionId}`);
      }

      // Track tool usage
      if (message.type === "assistant") {
        progress.turns++;
        const toolUses = message.message.content.filter(
          (b: { type: string }) => b.type === "tool_use",
        ) as Array<{ type: "tool_use"; name: string; input: Record<string, unknown> }>;

        for (const tool of toolUses) {
          progress.toolCalls++;
          progress.toolBreakdown[tool.name] = (progress.toolBreakdown[tool.name] ?? 0) + 1;
          progress.lastToolCall = tool.name;

          if ((tool.name === "Write" || tool.name === "Edit") && tool.input?.file_path) {
            const filePath = String(tool.input.file_path);
            if (!progress.filesChanged.includes(filePath)) {
              progress.filesChanged.push(filePath);
            }
          }
        }
        progressDirty = true;
      }

      // Handle completion
      if (message.type === "result") {
        const result = message as SDKResultSuccess | SDKResultError;
        progress.turns = result.num_turns;
        progress.costUsd = result.total_cost_usd;
        progress.tokensIn = result.usage.input_tokens;
        progress.tokensOut = result.usage.output_tokens;
        const now = new Date().toISOString();

        clearInterval(progressTimer);
        store.updateRunProgress(runId, progress);
        resultHandled = true;

        if (result.subtype === "success") {
          store.updateRun(runId, { status: "completed", completed_at: now });
          notifyClient.send({ type: "status", runId, status: "completed", timestamp: now });
          store.logEvent(projectId, "complete", {
            seedId,
            title: seedTitle,
            costUsd: progress.costUsd,
            numTurns: progress.turns,
            toolCalls: progress.toolCalls,
            filesChanged: progress.filesChanged.length,
            durationMs: result.duration_ms,
            sessionId,
            resumed: !!resume,
          }, runId);
          log(`COMPLETED (${progress.turns} turns, ${progress.toolCalls} tools, ${progress.filesChanged.length} files, $${progress.costUsd.toFixed(4)})`);
        } else {
          const errResult = result as SDKResultError;
          const reason = errResult.errors?.join("; ") ?? errResult.subtype;
          const isRateLimit = reason.includes("hit your limit")
            || reason.includes("rate limit")
            || errResult.subtype === "error_max_budget_usd";

          const finalStatus = isRateLimit ? "stuck" : "failed";
          store.updateRun(runId, {
            status: finalStatus,
            completed_at: now,
          });
          notifyClient.send({ type: "status", runId, status: finalStatus, timestamp: now, details: { reason } });
          store.logEvent(projectId, isRateLimit ? "stuck" : "fail", {
            seedId,
            reason,
            costUsd: progress.costUsd,
            numTurns: progress.turns,
            rateLimit: isRateLimit,
            sessionId,
            resumed: !!resume,
          }, runId);
          log(`${isRateLimit ? "RATE LIMITED" : "FAILED"}: ${reason.slice(0, 300)}`);
          // Reset seed back to open so it can be retried
          await resetSeedToOpen(seedId, storeProjectPath);
        }
      }
    }

    // Guard: SDK generator ended without result message
    if (!resultHandled) {
      clearInterval(progressTimer);
      store.updateRunProgress(runId, progress);
      const now = new Date().toISOString();
      store.updateRun(runId, { status: "stuck", completed_at: now });
      notifyClient.send({ type: "status", runId, status: "stuck", timestamp: now });
      store.logEvent(projectId, "stuck", {
        seedId,
        reason: "SDK generator ended without result (connection drop or silent rate limit)",
        costUsd: progress.costUsd,
        numTurns: progress.turns,
        toolCalls: progress.toolCalls,
        sessionId,
        resumed: !!resume,
      }, runId);
      log(`STUCK: SDK stream ended without result after ${progress.turns} turns — can resume later`);
      await appendFile(logFile, `\n[foreman-worker] STUCK: SDK generator ended without result.\n`);
      // Reset seed back to open so it can be retried
      await resetSeedToOpen(seedId, storeProjectPath);
    }
  } catch (err: unknown) {
    clearInterval(progressTimer);
    store.updateRunProgress(runId, progress);
    const reason = err instanceof Error ? err.message : String(err);
    const isRateLimit = reason.includes("hit your limit") || reason.includes("rate limit");

    if (resultHandled) {
      log(`Post-result error (ignored): ${reason.slice(0, 200)}`);
      await appendFile(logFile, `\n[foreman-worker] Post-result error (ignored): ${reason}\n`);
      store.close();
      return;
    }

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
      sessionId,
      resumed: !!resume,
    }, runId);
    log(`${isRateLimit ? "RATE LIMITED" : "ERROR"}: ${reason.slice(0, 200)}`);
    await appendFile(logFile, `\n[foreman-worker] ${isRateLimit ? "RATE LIMITED" : "ERROR"}: ${reason}\n`);
    // Reset seed back to open so it can be retried
    await resetSeedToOpen(seedId, storeProjectPath);
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
): Promise<PhaseResult> {
  // ── SMOKE TEST BYPASS ────────────────────────────────────────────────────────
  // When FOREMAN_SMOKE_TEST === "true", skip the real SDK call and write a
  // synthetic pass report.  This exercises pipeline orchestration (phase ordering,
  // artifact gating, verdict parsing, retry loops) without spending API budget.
  if (process.env.FOREMAN_SMOKE_TEST === "true") {
    const smokeArtifacts: Record<string, string> = {
      explorer: "EXPLORER_REPORT.md",
      developer: "DEVELOPER_REPORT.md",
      qa: "QA_REPORT.md",
      reviewer: "REVIEW.md",
      reproducer: "REPRODUCER_REPORT.md",
    };
    const artifact = smokeArtifacts[role];
    if (artifact) {
      const verdictLine = role === "developer" ? "## Status: COMPLETE" : "## Verdict: PASS";
      writeFileSync(
        join(config.worktreePath, artifact),
        `# ${role.charAt(0).toUpperCase() + role.slice(1)} Report\n\n${verdictLine}\n\nSmoke test noop — no real ${role} work performed.\n`,
      );
    }
    log(`[${role.toUpperCase()}] SMOKE NOOP — bypassing SDK call, writing ${artifact ?? "(no artifact)"}`);
    await appendFile(logFile, `\n${"─".repeat(40)}\n[PHASE: ${role.toUpperCase()}] SMOKE NOOP — skipping SDK call\n`);
    return { success: true, costUsd: 0, turns: 1 };
  }
  // ── END SMOKE TEST BYPASS ────────────────────────────────────────────────────

  const roleConfig = ROLE_CONFIGS[role];
  progress.currentPhase = role;
  store.updateRunProgress(config.runId, progress);

  const disallowedTools = getDisallowedTools(roleConfig);
  const allowedSummary = roleConfig.allowedTools.join(", ");
  await appendFile(logFile, `\n${"─".repeat(40)}\n[PHASE: ${role.toUpperCase()}] Starting (model=${roleConfig.model}, maxBudgetUsd=${roleConfig.maxBudgetUsd}, allowedTools=[${allowedSummary}])\n`);
  log(`[${role.toUpperCase()}] Starting phase for ${config.seedId} (${roleConfig.allowedTools.length} allowed tools, ${disallowedTools.length} disallowed)`);

  const env: Record<string, string | undefined> = { ...config.env };

  try {
    let phaseResult: SDKResultSuccess | SDKResultError | undefined;

    // DCG: use the role's configured permissionMode instead of blanket bypassPermissions.
    for await (const message of query(({
      prompt,
      options: {
        cwd: config.worktreePath,
        model: roleConfig.model as any,
        permissionMode: roleConfig.permissionMode,
        maxBudgetUsd: roleConfig.maxBudgetUsd,
        disallowedTools,
        env,
        persistSession: false,
        sessionLogDir: config.worktreePath,
      },
    }) as unknown as Parameters<typeof query>[0])) {
      await logMessage(logFile, message);
      progress.lastActivity = new Date().toISOString();

      if (message.type === "assistant") {
        progress.turns++;
        const toolUses = message.message.content.filter(
          (b: { type: string }) => b.type === "tool_use",
        ) as Array<{ type: "tool_use"; name: string; input: Record<string, unknown> }>;

        for (const tool of toolUses) {
          progress.toolCalls++;
          progress.toolBreakdown[tool.name] = (progress.toolBreakdown[tool.name] ?? 0) + 1;
          progress.lastToolCall = tool.name;

          if ((tool.name === "Write" || tool.name === "Edit") && tool.input?.file_path) {
            const filePath = String(tool.input.file_path);
            if (!progress.filesChanged.includes(filePath)) {
              progress.filesChanged.push(filePath);
            }
          }
        }
        store.updateRunProgress(config.runId, progress);
        notifyClient.send({
          type: "progress",
          runId: config.runId,
          progress: { ...progress },
          timestamp: new Date().toISOString(),
        });
      }

      if (message.type === "result") {
        phaseResult = message as SDKResultSuccess | SDKResultError;
      }
    }

    if (phaseResult) {
      progress.costUsd += phaseResult.total_cost_usd;
      progress.tokensIn += phaseResult.usage.input_tokens;
      progress.tokensOut += phaseResult.usage.output_tokens;

      // Record per-phase cost breakdown
      progress.costByPhase ??= {};
      progress.costByPhase[role] = (progress.costByPhase[role] ?? 0) + phaseResult.total_cost_usd;
      progress.agentByPhase ??= {};
      progress.agentByPhase[role] = roleConfig.model;

      store.updateRunProgress(config.runId, progress);

      if (phaseResult.subtype === "success") {
        log(`[${role.toUpperCase()}] Completed (${phaseResult.num_turns} turns, $${phaseResult.total_cost_usd.toFixed(4)})`);
        await appendFile(logFile, `[PHASE: ${role.toUpperCase()}] COMPLETED ($${phaseResult.total_cost_usd.toFixed(4)})\n`);
        return { success: true, costUsd: phaseResult.total_cost_usd, turns: phaseResult.num_turns };
      } else {
        const errResult = phaseResult as SDKResultError;
        const reason = errResult.errors?.join("; ") ?? errResult.subtype;
        log(`[${role.toUpperCase()}] Failed: ${reason.slice(0, 200)}`);
        await appendFile(logFile, `[PHASE: ${role.toUpperCase()}] FAILED: ${reason}\n`);
        return { success: false, costUsd: phaseResult.total_cost_usd, turns: phaseResult.num_turns, error: reason };
      }
    }

    log(`[${role.toUpperCase()}] SDK ended without result`);
    return { success: false, costUsd: 0, turns: 0, error: "SDK stream ended without result" };
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

// FinalizeResult is imported from "./agent-worker-finalize.js" — see that module for the type definition.

async function finalize(
  config: WorkerConfig,
  logFile: string,
  progress: RunProgress,
  pipelineStartedAt: string,
  pipelineStatus = "ALL_CHECKS_PASSED",
  agentMailClient: AnyMailClient | null = null,
): Promise<FinalizeResult> {
  const { seedId, seedTitle, worktreePath } = config;

  // ── SMOKE TEST BYPASS ────────────────────────────────────────────────────────
  // Skip git/npm/push operations entirely; write a synthetic FINALIZE_REPORT.md.
  if (process.env.FOREMAN_SMOKE_TEST === "true") {
    await appendFile(logFile, `\n${"─".repeat(40)}\n[FINALIZE] SMOKE NOOP — skipping git/npm/push\n`);
    log(`[FINALIZE] SMOKE NOOP — skipping git/npm/push`);
    writeFileSync(
      join(worktreePath, "FINALIZE_REPORT.md"),
      `# Finalize Report: ${seedTitle}\n\n## Seed: ${seedId}\n## Status: COMPLETE\n\nSmoke test noop — no git operations performed.\n`,
    );
    return { success: true, retryable: false };
  }
  // ── END SMOKE TEST BYPASS ────────────────────────────────────────────────────

  const storeProjectPath = config.projectPath ?? join(worktreePath, "..", "..");
  const opts = { cwd: worktreePath, stdio: "pipe" as const, timeout: PIPELINE_TIMEOUTS.gitOperationMs };

  const report: string[] = [
    `# Finalize Report: ${seedTitle}`,
    "",
    `## Seed: ${seedId}`,
    `## Timestamp: ${new Date().toISOString()}`,
    "",
  ];

  // Dependency install — required before type check so tsc can resolve module types.
  // Use npm ci (clean install) for deterministic, lock-file-based installs.
  // Allow up to 120 s to handle slow network / large dependency trees.
  const installOpts = { ...opts, timeout: 120_000 };
  let installSucceeded = false;
  try {
    execFileSync("npm", ["ci"], installOpts);
    log(`[FINALIZE] npm ci succeeded`);
    report.push(`## Dependency Install`, `- Status: SUCCESS`, "");
    installSucceeded = true;
  } catch (err: unknown) {
    const rawMsg = err instanceof Error ? err.message : String(err);
    const stderr =
      err instanceof Error && "stderr" in err
        ? String((err as NodeJS.ErrnoException & { stderr?: Buffer }).stderr ?? "")
        : "";
    const detail = (stderr || rawMsg).slice(0, 500);
    log(`[FINALIZE] npm ci failed: ${detail.slice(0, 200)}`);
    await appendFile(logFile, `[FINALIZE] npm ci error:\n${detail}\n`);
    report.push(`## Dependency Install`, `- Status: FAILED`, `- Errors:`, "```", detail, "```", "");
  }

  // Bug scan (pre-commit type check) — 60 s timeout to handle TypeScript cold-start.
  // Skip if npm ci failed: without node_modules tsc will always fail with "Cannot find module".
  const buildOpts = { ...opts, timeout: 60_000 };
  if (!installSucceeded) {
    log(`[FINALIZE] Skipping type check — dependency install failed`);
    report.push(`## Build / Type Check`, `- Status: SKIPPED (dependency install failed)`, "");
  } else {
    try {
      execFileSync("npx", ["tsc", "--noEmit"], buildOpts);
      log(`[FINALIZE] Type check passed`);
      report.push(`## Build / Type Check`, `- Status: SUCCESS`, "");
    } catch (err: unknown) {
      const rawMsg = err instanceof Error ? err.message : String(err);
      // execFileSync throws with stderr in the message when stdio:"pipe"
      const stderr =
        err instanceof Error && "stderr" in err
          ? String((err as NodeJS.ErrnoException & { stderr?: Buffer }).stderr ?? "")
          : "";
      const detail = (stderr || rawMsg).slice(0, 500);
      log(`[FINALIZE] Type check failed: ${detail.slice(0, 200)}`);
      await appendFile(logFile, `[FINALIZE] Type check error:\n${detail}\n`);
      report.push(`## Build / Type Check`, `- Status: FAILED`, `- Errors:`, "```", detail, "```", "");
    }
  }

  // Commit
  let commitHash = "(none)";
  try {
    execFileSync("git", ["add", "-A"], opts);

    // Detect silently-ignored new files (files skipped by git add -A due to .gitignore)
    try {
      const ignoredOutput = execFileSync(
        "git",
        ["ls-files", "--others", "--ignored", "--exclude-standard"],
        opts,
      )
        .toString()
        .trim();
      if (ignoredOutput) {
        const ignoredFiles = ignoredOutput.split("\n").filter(Boolean);
        // Fast-path guard: if the list is very large (e.g., node_modules/ was enumerated),
        // skip detailed reporting to avoid slow log writes and high memory use.
        // The inner try/catch ensures this is non-fatal either way.
        if (ignoredFiles.length > 500) {
          log(`[FINALIZE] Detected ${ignoredFiles.length} silently-ignored file(s) — too many to log individually`);
          report.push(
            `## Silently Ignored Files`,
            `- Count: ${ignoredFiles.length} (truncated — too many to display)`,
            `- Note: A large ignored directory (e.g. node_modules/) may be present in the worktree`,
            "",
          );
        } else {
          // Truncate to avoid bloating the report
          const displayFiles = ignoredFiles.slice(0, 50);
          const truncated = ignoredFiles.length > 50 ? ` (showing first 50 of ${ignoredFiles.length})` : "";
          log(`[FINALIZE] Detected ${ignoredFiles.length} silently-ignored file(s)${truncated}`);
          await appendFile(logFile, `[FINALIZE] Silently-ignored files:\n${ignoredFiles.join("\n")}\n`);
          report.push(
            `## Silently Ignored Files`,
            `- Count: ${ignoredFiles.length}${truncated}`,
            `- Files:`,
            ...displayFiles.map((f) => `  - ${f}`),
            "",
          );
        }
      } else {
        report.push(`## Silently Ignored Files`, `- Count: 0`, "");
      }
    } catch {
      // Detection is non-fatal — log and continue
      log(`[FINALIZE] Could not detect silently-ignored files (non-fatal)`);
    }

    execFileSync("git", ["commit", "-m", `${seedTitle} (${seedId})`], opts);
    commitHash = execFileSync("git", ["rev-parse", "--short", "HEAD"], opts).toString().trim();
    log(`[FINALIZE] Committed ${commitHash}`);
    report.push(`## Commit`, `- Status: SUCCESS`, `- Hash: ${commitHash}`, "");
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    if (msg.includes("nothing to commit")) {
      log(`[FINALIZE] Nothing to commit`);
      report.push(`## Commit`, `- Status: SKIPPED (nothing to commit)`, "");
    } else {
      log(`[FINALIZE] Commit failed: ${msg.slice(0, 200)}`);
      await appendFile(logFile, `[FINALIZE] Commit error: ${msg}\n`);
      report.push(`## Commit`, `- Status: FAILED`, `- Error: ${msg.slice(0, 300)}`, "");
    }
  }

  // Branch Verification — ensure we're on the correct branch before pushing.
  // Worktrees can end up in detached HEAD or on a wrong branch (e.g. after a
  // failed rebase or manual intervention), causing `git push foreman/<seedId>`
  // to fail with "src refspec does not match any".
  const expectedBranch = `foreman/${seedId}`;
  let branchVerified = false;
  try {
    const currentBranch = execFileSync("git", ["rev-parse", "--abbrev-ref", "HEAD"], opts)
      .toString()
      .trim();
    if (currentBranch !== expectedBranch) {
      log(`[FINALIZE] Branch mismatch: on '${currentBranch}', expected '${expectedBranch}' — attempting checkout`);
      execFileSync("git", ["checkout", expectedBranch], opts);
      log(`[FINALIZE] Checked out ${expectedBranch}`);
      report.push(
        `## Branch Verification`,
        `- Was: ${currentBranch}`,
        `- Expected: ${expectedBranch}`,
        `- Status: RECOVERED (checkout succeeded)`,
        "",
      );
    } else {
      log(`[FINALIZE] Branch verified: ${currentBranch}`);
      report.push(
        `## Branch Verification`,
        `- Current: ${currentBranch}`,
        `- Status: OK`,
        "",
      );
    }
    branchVerified = true;
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[FINALIZE] Branch verification failed: ${msg.slice(0, 200)}`);
    await appendFile(logFile, `[FINALIZE] Branch verification error: ${msg}\n`);
    report.push(
      `## Branch Verification`,
      `- Expected: ${expectedBranch}`,
      `- Status: FAILED`,
      `- Error: ${msg.slice(0, 300)}`,
      "",
    );
  }

  // Push — with automatic rebase recovery on non-fast-forward rejections.
  //
  // Non-fast-forward errors are deterministic (diverged history) and will
  // always fail on retry unless the local branch is rebased onto the remote.
  // Attempting git pull --rebase here resolves the common case where origin
  // received a commit (e.g. from a previous partial run) while the worktree
  // continued on a different history.  If the rebase itself fails (real
  // conflicts), we return retryable=false so runPipeline() does NOT reset the
  // seed to open — preventing the infinite re-dispatch loop described in bd-zwtr.
  let pushSucceeded = false;
  let pushRetryable = true; // default: transient failures may be retried
  if (!branchVerified) {
    log(`[FINALIZE] Skipping push (branch verification failed)`);
    report.push(`## Push`, `- Status: SKIPPED (branch verification failed)`, "");
  } else {
    try {
      execFileSync("git", ["push", "-u", "origin", expectedBranch], opts);
      log(`[FINALIZE] Pushed to origin`);
      report.push(`## Push`, `- Status: SUCCESS`, `- Branch: ${expectedBranch}`, "");
      pushSucceeded = true;
    } catch (pushErr: unknown) {
      const pushMsg = pushErr instanceof Error ? pushErr.message : String(pushErr);
      // "non-fast-forward" covers the standard rejection message.
      // "fetch first" covers the case where git phrases it differently (e.g. older git versions).
      // We do NOT trigger rebase for other rejection types (permission errors, missing refs, etc.).
      const isNonFastForward =
        pushMsg.includes("non-fast-forward") ||
        pushMsg.includes("fetch first");

      if (isNonFastForward) {
        log(`[FINALIZE] Push rejected (non-fast-forward) — attempting git pull --rebase`);
        await appendFile(logFile, `[FINALIZE] Push rejected (non-fast-forward): ${pushMsg}\n`);
        report.push(`## Push`, `- Status: REJECTED (non-fast-forward) — attempting rebase`, "");

        // Attempt rebase. A failed rebase is deterministic — do NOT reset seed to open.
        let rebaseSucceeded = false;
        try {
          execFileSync("git", ["pull", "--rebase", "origin", expectedBranch], opts);
          log(`[FINALIZE] Rebase succeeded — retrying push`);
          report.push(`## Rebase`, `- Status: SUCCESS`, "");
          rebaseSucceeded = true;
        } catch (rebaseErr: unknown) {
          const rebaseMsg = rebaseErr instanceof Error ? rebaseErr.message : String(rebaseErr);
          log(`[FINALIZE] Rebase failed: ${rebaseMsg.slice(0, 200)}`);
          await appendFile(logFile, `[FINALIZE] Rebase error: ${rebaseMsg}\n`);
          report.push(`## Rebase`, `- Status: FAILED`, `- Error: ${rebaseMsg.slice(0, 300)}`, "");
          report.push(`## Push`, `- Status: FAILED (rebase could not resolve diverged history)`, "");
          // Abort any partial rebase to leave the worktree clean
          try { execFileSync("git", ["rebase", "--abort"], opts); } catch { /* already clean */ }
          // Deterministic failure — do NOT reset seed to open (prevents infinite loop)
          pushRetryable = false;
        }

        // Retry push only if rebase succeeded. A post-rebase push failure is treated
        // as transient (retryable=true) — it is distinct from a rebase conflict.
        if (rebaseSucceeded) {
          try {
            execFileSync("git", ["push", "-u", "origin", expectedBranch], opts);
            log(`[FINALIZE] Pushed to origin (after rebase)`);
            report.push(`## Push`, `- Status: SUCCESS (after rebase)`, `- Branch: ${expectedBranch}`, "");
            pushSucceeded = true;
          } catch (retryPushErr: unknown) {
            const retryMsg = retryPushErr instanceof Error ? retryPushErr.message : String(retryPushErr);
            log(`[FINALIZE] Push failed after rebase: ${retryMsg.slice(0, 200)}`);
            await appendFile(logFile, `[FINALIZE] Post-rebase push error: ${retryMsg}\n`);
            report.push(`## Push`, `- Status: FAILED (after rebase)`, `- Error: ${retryMsg.slice(0, 300)}`, "");
            // Transient failure — allow retry
            pushRetryable = true;
          }
        }
      } else {
        log(`[FINALIZE] Push failed: ${pushMsg.slice(0, 200)}`);
        await appendFile(logFile, `[FINALIZE] Push error: ${pushMsg}\n`);
        report.push(`## Push`, `- Status: FAILED`, `- Error: ${pushMsg.slice(0, 300)}`, "");
        // Non-classification failures (network, permissions, etc.) may be transient
        pushRetryable = true;
      }
    }
  }

  // Enqueue to merge queue (fire-and-forget — must not block finalization)
  if (pushSucceeded) {
    try {
      const enqueueStore = ForemanStore.forProject(storeProjectPath);
      const enqueueResult = enqueueToMergeQueue({
        db: enqueueStore.getDb(),
        seedId,
        runId: config.runId,
        worktreePath,
        getFilesModified: () => {
          const output = execFileSync("git", ["diff", "--name-only", "main...HEAD"], opts).toString().trim();
          return output ? output.split("\n") : [];
        },
      });
      enqueueStore.close();

      if (enqueueResult.success) {
        log(`[FINALIZE] Enqueued to merge queue`);
        report.push(`## Merge Queue`, `- Status: ENQUEUED`, "");
        sendMail(agentMailClient, "refinery", "branch-ready", {
          seedId,
          runId: config.runId,
          branch: `foreman/${seedId}`,
          worktreePath,
        });
      } else {
        log(`[FINALIZE] Merge queue enqueue failed (non-fatal): ${enqueueResult.error}`);
        report.push(`## Merge Queue`, `- Status: FAILED (non-fatal)`, `- Error: ${enqueueResult.error?.slice(0, 300)}`, "");
      }
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      log(`[FINALIZE] Merge queue enqueue failed (non-fatal): ${msg}`);
      report.push(`## Merge Queue`, `- Status: FAILED (non-fatal)`, `- Error: ${msg.slice(0, 300)}`, "");
    }
  }

  // NOTE: We do NOT close the bead here. The bead is closed only after the code
  // has successfully landed in main branch (i.e., after autoMerge() calls
  // refinery.mergeCompleted() and the merge succeeds). Closing here would
  // falsely mark the bead as done even if the merge later fails with conflicts
  // or test failures. See: refinery.ts mergeCompleted() and resolveConflict().

  // Create session transcript in SessionLogs/
  try {
    const logData: import("./session-log.js").SessionLogData = {
      seedId,
      seedTitle,
      seedDescription: config.seedDescription ?? "",
      branchName: `foreman/${seedId}`,
      projectName: config.projectPath ? config.projectPath.split("/").pop() : undefined,
      phases: [],
      totalCostUsd: progress.costUsd ?? 0,
      totalTurns: progress.turns ?? 0,
      filesChanged: commitHash !== "(none)" ? (() => {
        try {
          return execFileSync("git", ["diff", "--name-only", "HEAD~1", "HEAD"], opts).toString().trim().split("\n").filter(Boolean);
        } catch { return []; }
      })() : [],
      devRetries: 0,
      qaVerdict: pipelineStatus === "ALL_CHECKS_PASSED" ? "pass" : "fail",
    };
    const sessionLogPath = await writeSessionLog(worktreePath, logData);
    log(`[FINALIZE] Session log written: ${sessionLogPath}`);
    report.push(`## Session Log`, `- Status: CREATED`, `- Path: ${sessionLogPath}`, "");
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[FINALIZE] Session log creation failed (non-fatal): ${msg}`);
    report.push(`## Session Log`, `- Status: FAILED (non-fatal)`, `- Error: ${msg.slice(0, 300)}`, "");
  }

  // Write finalize report
  try {
    rotateReport(worktreePath, "FINALIZE_REPORT.md");
    writeFileSync(join(worktreePath, "FINALIZE_REPORT.md"), report.join("\n"));
  } catch {
    // Non-fatal — finalize report is for debugging
  }

  return { success: pushSucceeded, retryable: pushRetryable };
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

  log(`Pipeline starting for ${seedId} [phases: ${config.skipExplore ? "skip-explore" : "explore"} → dev → qa → ${config.skipReview ? "skip-review" : "review"} → finalize]`);
  await appendFile(logFile, `\n[foreman-worker] Pipeline orchestration starting\n`);

  // Accumulate phase records for the session log written at pipeline completion.
  // /ensemble:sessionlog is a human-only Claude Code skill (not reachable from
  // SDK query()), so the pipeline generates the session log directly from this data.
  const phaseRecords: PhaseRecord[] = [];

  // ── Phase 1: Explorer ──────────────────────────────────────────────
  if (!config.skipExplore) {
    const explorerArtifact = join(worktreePath, "EXPLORER_REPORT.md");
    if (existsSync(explorerArtifact)) {
      log(`[EXPLORER] Skipping — EXPLORER_REPORT.md already exists (resuming from previous run)`);
      await appendFile(logFile, `\n[PHASE: EXPLORER] SKIPPED (artifact already present)\n`);
      phaseRecords.push({ name: "explorer", skipped: true });
    } else {
      // AC-006-1: Register the explorer agent with Agent Mail before the phase starts.
      await registerAgent(agentMailClient, `explorer-${seedId}`);
      rotateReport(worktreePath, "EXPLORER_REPORT.md");
      const result = await runPhase("explorer", explorerPrompt(seedId, seedTitle, description, comments), config, progress, logFile, store, notifyClient);
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

  while (devRetries <= MAX_DEV_RETRIES) {
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
      // REQ-007 / AC-007-1: Reserve the worktree path before Developer edits files.
      // Lease 10 minutes (600 s) — generous to cover typical developer phase duration.
      reserveFiles(agentMailClient, [worktreePath], developerAgentName, 600);
      rotateReport(worktreePath, "DEVELOPER_REPORT.md");
      const devResult = await runPhase(
        "developer",
        developerPrompt(seedId, seedTitle, description, hasExplorerReport, feedbackContext, comments),
        config, progress, logFile, store, notifyClient,
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
      const qaResult = await runPhase("qa", qaPrompt(seedId, seedTitle), config, progress, logFile, store, notifyClient);
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
      log(`[QA] Verdict: ${qaVerdict} — proceeding to ${config.skipReview ? "finalize" : "review"}`);
      break;
    }

    // QA failed — retry developer with feedback.
    // AC-010-2: Send QA feedback as a message to developer's inbox before retry.
    feedbackContext = qaReport ? extractIssues(qaReport) : "(QA failed but no report written)";
    devRetries++;
    if (devRetries <= MAX_DEV_RETRIES) {
      log(`[QA] FAIL — sending back to Developer (retry ${devRetries}/${MAX_DEV_RETRIES})`);
      await appendFile(logFile, `\n[PIPELINE] QA failed, retrying developer (${devRetries}/${MAX_DEV_RETRIES})\n`);
      if (qaReport) {
        sendMailText(agentMailClient, `developer-${seedId}`, `QA Feedback - Retry ${devRetries}`, qaReport);
      }
    } else {
      log(`[QA] FAIL — max retries exhausted, proceeding with current state`);
      await appendFile(logFile, `\n[PIPELINE] QA failed after ${MAX_DEV_RETRIES} retries, proceeding anyway\n`);
    }
  }

  // ── Phase 4: Reviewer ──────────────────────────────────────────────
  if (!config.skipReview) {
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
      const reviewResult = await runPhase("reviewer", reviewerPrompt(seedId, seedTitle, description, comments), config, progress, logFile, store, notifyClient);
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

    if ((reviewVerdict === "fail" || (reviewVerdict === "pass" && hasIssues)) && devRetries < MAX_DEV_RETRIES) {
      const reviewFeedback = reviewReport ? extractIssues(reviewReport) : "(Review failed but no issues listed)";
      const reason = reviewVerdict === "fail" ? "FAIL" : "PASS with issues";
      log(`[REVIEW] ${reason} — sending back to Developer with review feedback`);
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
        developerPrompt(seedId, seedTitle, description, hasExplorerReport, reviewFeedback, comments),
        config, progress, logFile, store, notifyClient,
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
      if (devResult.success) {
        sendMail(agentMailClient, "foreman", "phase-complete", {
          seedId, phase: "developer", status: "completed", cost: devResult.costUsd, turns: devResult.turns,
        });
        store.logEvent(projectId, "complete", { seedId, phase: "developer", costUsd: devResult.costUsd, retry: devRetries, trigger: "review-feedback" }, runId);
        addLabelsToBead(seedId, ["phase:developer"], config.projectPath);

        rotateReport(worktreePath, "QA_REPORT.md");
        const qaResult = await runPhase("qa", qaPrompt(seedId, seedTitle), config, progress, logFile, store, notifyClient);
        phaseRecords.push({
          name: `qa (review-feedback)`,
          skipped: false,
          success: qaResult.success,
          costUsd: qaResult.costUsd,
          turns: qaResult.turns,
          error: qaResult.error,
        });
        if (qaResult.success) {
          sendMail(agentMailClient, "foreman", "phase-complete", {
            seedId, phase: "qa", status: "completed", cost: qaResult.costUsd, turns: qaResult.turns,
          });
          store.logEvent(projectId, "complete", { seedId, phase: "qa", costUsd: qaResult.costUsd, retry: devRetries, trigger: "review-feedback" }, runId);
          addLabelsToBead(seedId, ["phase:qa"], config.projectPath);
        }
      }
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
  progress.currentPhase = "finalize";
  store.updateRunProgress(runId, progress);
  await appendFile(logFile, `\n${"─".repeat(40)}\n[PHASE: FINALIZE]\n`);

  const finalizeResult = await finalize(config, logFile, progress, pipelineStartedAt, pipelineStatus, agentMailClient);
  const finalizeSucceeded = finalizeResult.success;

  const now = new Date().toISOString();
  if (finalizeSucceeded) {
    store.updateRun(runId, { status: "completed", completed_at: now });
    notifyClient.send({ type: "status", runId, status: "completed", timestamp: now });
  } else {
    // Push failed — mark the run as stuck.
    store.updateRun(runId, { status: "stuck", completed_at: now });
    notifyClient.send({ type: "status", runId, status: "stuck", timestamp: now });
    sendMail(agentMailClient, "foreman", "agent-error", {
      seedId, phase: "finalize", error: "Push failed", retryable: finalizeResult.retryable,
    });
    // Only reset the seed to "open" for retryable failures (e.g. transient network
    // errors).  Deterministic failures — like a diverged history that could not be
    // rebased — must NOT trigger a reset, because that would cause the dispatcher
    // to immediately re-dispatch the seed, observe the same push failure, and loop
    // indefinitely (observed: bd-qtqs accumulated 151 stuck runs in ~20 minutes).
    if (finalizeResult.retryable) {
      await resetSeedToOpen(seedId, config.projectPath);
    } else {
      log(`[PIPELINE] Deterministic push failure for ${seedId} — seed left stuck (no reset to open)`);
    }
  }
  const phaseList: string[] = [];
  if (!config.skipExplore) phaseList.push("explore");
  phaseList.push("dev", "qa");
  if (!config.skipReview) phaseList.push("review");
  phaseList.push("finalize");
  const completedPhases = phaseList.join("→");

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
    log(`PIPELINE STUCK for ${seedId} — push failed (${progress.turns} turns, $${progress.costUsd.toFixed(4)})`);
    await appendFile(logFile, `\n[PIPELINE] STUCK — push failed ($${progress.costUsd.toFixed(4)}, ${progress.turns} turns)\n`);
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

  // Reset seed back to open so it appears in the ready queue for retry.
  // Pass projectPath (repo root) so br finds .beads/ — the worktree has none.
  await resetSeedToOpen(seedId, projectPath);
  log(`Reset seed ${seedId} back to open`);

  // Add failure reason as a note on the bead for visibility.
  // This allows anyone looking at the bead to see why it was reset without
  // having to dig into log files or SQLite.
  const notePrefix = isRateLimit ? "[RATE_LIMITED]" : "[FAILED]";
  const failureNote = `${notePrefix} [${phase.toUpperCase()}] ${reason}`;
  addNotesToBead(seedId, failureNote, projectPath);
  log(`Added failure note to seed ${seedId}`);

  store.close();
}

// ── Helpers ──────────────────────────────────────────────────────────────────

async function logMessage(logFile: string, message: SDKMessage): Promise<void> {
  const ts = new Date().toISOString().slice(11, 23);

  switch (message.type) {
    case "assistant": {
      const toolUses = message.message.content
        .filter((b: { type: string }): b is { type: "tool_use"; name: string; id: string } => b.type === "tool_use")
        .map((b: { name: string }) => b.name);
      if (toolUses.length > 0) {
        await appendFile(logFile, `[${ts}] assistant: tools=[${toolUses.join(", ")}]\n`);
      }
      break;
    }
    case "result": {
      const r = message as SDKResultSuccess | SDKResultError;
      await appendFile(logFile, `[${ts}] result: subtype=${r.subtype} turns=${r.num_turns} cost=$${r.total_cost_usd.toFixed(4)} duration=${r.duration_ms}ms\n`);
      if (r.subtype === "success") {
        await appendFile(logFile, `[${ts}] output: ${(r as SDKResultSuccess).result.slice(0, 500)}\n`);
      } else {
        await appendFile(logFile, `[${ts}] errors: ${(r as SDKResultError).errors?.join("; ") ?? "unknown"}\n`);
      }
      break;
    }
    default:
      break;
  }
}

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

    // Send Agent Mail notification so foreman knows this worker died.
    // agentMailClient is not in scope here — create a fresh one.
    if (seedId) {
      try {
        const mailCandidate = new AgentMailClient();
        const reachable = await mailCandidate.healthCheck();
        if (reachable) {
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
        }
      } catch {
        // Agent Mail unavailable — SQLite update above is sufficient.
      }
    }
  }

  process.exit(1);
}

main().catch(fatalHandler);
