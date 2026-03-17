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

import { readFileSync, writeFileSync, unlinkSync, existsSync, renameSync } from "node:fs";
import { appendFile, mkdir } from "node:fs/promises";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { request as httpRequest } from "node:http";
import { query } from "@anthropic-ai/claude-agent-sdk";
import type { SDKMessage, SDKResultSuccess, SDKResultError } from "@anthropic-ai/claude-agent-sdk";
import { ForemanStore } from "../lib/store.js";
import type { RunProgress } from "../lib/store.js";
import { PIPELINE_TIMEOUTS, PIPELINE_LIMITS } from "../lib/config.js";
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
import { closeSeed, resetSeedToOpen } from "./task-backend-ops.js";
import type { AgentRole, WorkerNotification } from "./types.js";

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

// ── Config ───────────────────────────────────────────────────────────────

interface WorkerConfig {
  runId: string;
  projectId: string;
  seedId: string;
  seedTitle: string;
  seedDescription?: string;
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

// ── Main ─────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const configPath = process.argv[2];
  if (!configPath) {
    console.error("Usage: agent-worker <config-file>");
    process.exit(1);
  }

  // Read and delete config file (contains prompt, not secrets, but clean up)
  const config: WorkerConfig = JSON.parse(readFileSync(configPath, "utf-8"));
  try { unlinkSync(configPath); } catch { /* already deleted */ }

  const { runId, projectId, seedId, seedTitle, model, worktreePath, prompt, resume, pipeline } = config;

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

  // Open store connection
  const store = new ForemanStore();

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

  // Build clean env for SDK
  const env: Record<string, string | undefined> = { ...process.env };

  // ── Pipeline mode: run each phase as a separate SDK session ─────────
  if (pipeline) {
    await runPipeline(config, store, logFile, notifyClient);
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
    const queryOpts: Parameters<typeof query>[0] = resume
      ? {
          prompt,
          options: {
            cwd: worktreePath,
            model: model as any,
            permissionMode: "acceptEdits",
            env,
            resume,
            persistSession: true,
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
          },
        };

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
  }

  store.close();
  log(`Worker exiting for ${seedId}`);
}

// ── Pipeline orchestration ───────────────────────────────────────────────

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
    for await (const message of query({
      prompt,
      options: {
        cwd: config.worktreePath,
        model: roleConfig.model as any,
        permissionMode: roleConfig.permissionMode,
        maxBudgetUsd: roleConfig.maxBudgetUsd,
        disallowedTools,
        env,
        persistSession: false,
      },
    })) {
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

/**
 * Rotate a report file before a phase overwrites it.
 * Renames e.g. REVIEW.md → REVIEW.2026-03-12T19-40-24.md
 * so previous reports are preserved for debugging.
 */
function rotateReport(worktreePath: string, filename: string): void {
  const p = join(worktreePath, filename);
  if (!existsSync(p)) return;
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const ext = filename.endsWith(".md") ? ".md" : "";
  const base = ext ? filename.slice(0, -3) : filename;
  const rotated = join(worktreePath, `${base}.${stamp}${ext}`);
  try {
    renameSync(p, rotated);
  } catch {
    // Non-fatal — report will just be overwritten
  }
}

/**
 * Run git finalization: add, commit, push, and close the seed.
 * Uses execFileSync for safety — no shell interpolation.
 */
async function finalize(config: WorkerConfig, logFile: string): Promise<void> {
  const { seedId, seedTitle, worktreePath } = config;
  const opts = { cwd: worktreePath, stdio: "pipe" as const, timeout: PIPELINE_TIMEOUTS.gitOperationMs };

  const report: string[] = [
    `# Finalize Report: ${seedTitle}`,
    "",
    `## Seed: ${seedId}`,
    `## Timestamp: ${new Date().toISOString()}`,
    "",
  ];

  // Bug scan (pre-commit type check) — 60 s timeout to handle TypeScript cold-start
  const buildOpts = { ...opts, timeout: 60_000 };
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

  // Commit
  let commitHash = "(none)";
  try {
    execFileSync("git", ["add", "-A"], opts);
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

  // Push
  let pushSucceeded = false;
  try {
    execFileSync("git", ["push", "-u", "origin", `foreman/${seedId}`], opts);
    log(`[FINALIZE] Pushed to origin`);
    report.push(`## Push`, `- Status: SUCCESS`, `- Branch: foreman/${seedId}`, "");
    pushSucceeded = true;
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[FINALIZE] Push failed: ${msg.slice(0, 200)}`);
    await appendFile(logFile, `[FINALIZE] Push error: ${msg}\n`);
    report.push(`## Push`, `- Status: FAILED`, `- Error: ${msg.slice(0, 300)}`, "");
  }

  // Enqueue to merge queue (fire-and-forget — must not block finalization)
  if (pushSucceeded) {
    try {
      const enqueueStore = new ForemanStore();
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

  // Close bead (br backend)
  // Pass projectPath (repo root) so br finds .beads/ — the worktree dir has none.
  closeSeed(seedId, config.projectPath);
  log(`[FINALIZE] Closed seed ${seedId}`);
  report.push(`## Seed Close`, `- Status: SUCCESS`, "");

  // Write finalize report
  try {
    rotateReport(worktreePath, "FINALIZE_REPORT.md");
    writeFileSync(join(worktreePath, "FINALIZE_REPORT.md"), report.join("\n"));
  } catch {
    // Non-fatal — finalize report is for debugging
  }
}

const MAX_DEV_RETRIES = PIPELINE_LIMITS.maxDevRetries;

/**
 * Run the full pipeline: Explorer → Developer ⇄ QA → Reviewer → Finalize.
 * Each phase is a separate SDK session. TypeScript orchestrates the loop.
 */
async function runPipeline(config: WorkerConfig, store: ForemanStore, logFile: string, notifyClient: NotificationClient): Promise<void> {
  const { runId, projectId, seedId, seedTitle, worktreePath } = config;
  const description = config.seedDescription ?? "(no description)";

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

  log(`Pipeline starting for ${seedId} [phases: ${config.skipExplore ? "skip-explore" : "explore"} → dev → qa → ${config.skipReview ? "skip-review" : "review"} → finalize]`);
  await appendFile(logFile, `\n[foreman-worker] Pipeline orchestration starting\n`);

  // ── Phase 1: Explorer ──────────────────────────────────────────────
  if (!config.skipExplore) {
    const explorerArtifact = join(worktreePath, "EXPLORER_REPORT.md");
    if (existsSync(explorerArtifact)) {
      log(`[EXPLORER] Skipping — EXPLORER_REPORT.md already exists (resuming from previous run)`);
      await appendFile(logFile, `\n[PHASE: EXPLORER] SKIPPED (artifact already present)\n`);
    } else {
      rotateReport(worktreePath, "EXPLORER_REPORT.md");
      const result = await runPhase("explorer", explorerPrompt(seedId, seedTitle, description), config, progress, logFile, store, notifyClient);
      if (!result.success) {
        await markStuck(store, runId, projectId, seedId, seedTitle, progress, "explorer", result.error ?? "Explorer failed", notifyClient, config.projectPath);
        return;
      }
      store.logEvent(projectId, "complete", { seedId, phase: "explorer", costUsd: result.costUsd }, runId);
    }
  }

  const hasExplorerReport = existsSync(join(worktreePath, "EXPLORER_REPORT.md"));

  // ── Phase 2-3: Developer ⇄ QA loop ────────────────────────────────
  let devRetries = 0;
  let feedbackContext: string | undefined;
  let qaVerdict: "pass" | "fail" | "unknown" = "unknown";

  while (devRetries <= MAX_DEV_RETRIES) {
    // Developer — skip on first pass if artifact already exists (resume after crash)
    const developerArtifact = join(worktreePath, "DEVELOPER_REPORT.md");
    const developerAlreadyDone = devRetries === 0 && existsSync(developerArtifact);
    if (developerAlreadyDone) {
      log(`[DEVELOPER] Skipping — DEVELOPER_REPORT.md already exists (resuming from previous run)`);
      await appendFile(logFile, `\n[PHASE: DEVELOPER] SKIPPED (artifact already present)\n`);
    } else {
      rotateReport(worktreePath, "DEVELOPER_REPORT.md");
      const devResult = await runPhase(
        "developer",
        developerPrompt(seedId, seedTitle, description, hasExplorerReport, feedbackContext),
        config, progress, logFile, store, notifyClient,
      );
      if (!devResult.success) {
        await markStuck(store, runId, projectId, seedId, seedTitle, progress, "developer", devResult.error ?? "Developer failed", notifyClient, config.projectPath);
        return;
      }
      store.logEvent(projectId, "complete", { seedId, phase: "developer", costUsd: devResult.costUsd, retry: devRetries }, runId);
    }

    // QA — skip on first pass if artifact already exists (resume after crash)
    const qaArtifact = join(worktreePath, "QA_REPORT.md");
    const qaAlreadyDone = devRetries === 0 && existsSync(qaArtifact);
    if (qaAlreadyDone) {
      log(`[QA] Skipping — QA_REPORT.md already exists (resuming from previous run)`);
      await appendFile(logFile, `\n[PHASE: QA] SKIPPED (artifact already present)\n`);
    } else {
      rotateReport(worktreePath, "QA_REPORT.md");
      const qaResult = await runPhase("qa", qaPrompt(seedId, seedTitle), config, progress, logFile, store, notifyClient);
      if (!qaResult.success) {
        await markStuck(store, runId, projectId, seedId, seedTitle, progress, "qa", qaResult.error ?? "QA failed", notifyClient, config.projectPath);
        return;
      }
      store.logEvent(projectId, "complete", { seedId, phase: "qa", costUsd: qaResult.costUsd, retry: devRetries }, runId);
    }

    const qaReport = readReport(worktreePath, "QA_REPORT.md");
    qaVerdict = qaReport ? parseVerdict(qaReport) : "unknown";

    if (qaVerdict === "pass" || qaVerdict === "unknown") {
      log(`[QA] Verdict: ${qaVerdict} — proceeding to ${config.skipReview ? "finalize" : "review"}`);
      break;
    }

    // QA failed — retry developer with feedback
    feedbackContext = qaReport ? extractIssues(qaReport) : "(QA failed but no report written)";
    devRetries++;
    if (devRetries <= MAX_DEV_RETRIES) {
      log(`[QA] FAIL — sending back to Developer (retry ${devRetries}/${MAX_DEV_RETRIES})`);
      await appendFile(logFile, `\n[PIPELINE] QA failed, retrying developer (${devRetries}/${MAX_DEV_RETRIES})\n`);
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
    } else {
      rotateReport(worktreePath, "REVIEW.md");
      const reviewResult = await runPhase("reviewer", reviewerPrompt(seedId, seedTitle, description), config, progress, logFile, store, notifyClient);
      if (!reviewResult.success) {
        await markStuck(store, runId, projectId, seedId, seedTitle, progress, "reviewer", reviewResult.error ?? "Reviewer failed", notifyClient, config.projectPath);
        return;
      }
      store.logEvent(projectId, "complete", { seedId, phase: "reviewer", costUsd: reviewResult.costUsd }, runId);
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
      rotateReport(worktreePath, "DEVELOPER_REPORT.md");
      const devResult = await runPhase(
        "developer",
        developerPrompt(seedId, seedTitle, description, hasExplorerReport, reviewFeedback),
        config, progress, logFile, store, notifyClient,
      );
      if (devResult.success) {
        store.logEvent(projectId, "complete", { seedId, phase: "developer", costUsd: devResult.costUsd, retry: devRetries, trigger: "review-feedback" }, runId);

        rotateReport(worktreePath, "QA_REPORT.md");
        const qaResult = await runPhase("qa", qaPrompt(seedId, seedTitle), config, progress, logFile, store, notifyClient);
        if (qaResult.success) {
          store.logEvent(projectId, "complete", { seedId, phase: "qa", costUsd: qaResult.costUsd, retry: devRetries, trigger: "review-feedback" }, runId);
        }
      }
    } else if (reviewVerdict === "fail") {
      log(`[REVIEW] FAIL — max retries exhausted, finalizing with current state`);
    } else {
      log(`[REVIEW] Verdict: ${reviewVerdict} (no actionable issues)`);
    }
  }

  // ── Phase 5: Finalize ──────────────────────────────────────────────
  progress.currentPhase = "finalize";
  store.updateRunProgress(runId, progress);
  await appendFile(logFile, `\n${"─".repeat(40)}\n[PHASE: FINALIZE]\n`);

  await finalize(config, logFile);

  const now = new Date().toISOString();
  store.updateRun(runId, { status: "completed", completed_at: now });
  notifyClient.send({ type: "status", runId, status: "completed", timestamp: now });
  store.logEvent(projectId, "complete", {
    seedId,
    title: seedTitle,
    costUsd: progress.costUsd,
    numTurns: progress.turns,
    toolCalls: progress.toolCalls,
    filesChanged: progress.filesChanged.length,
    phases: config.skipExplore ? "dev→qa→review→finalize" : "explore→dev→qa→review→finalize",
    devRetries,
    qaVerdict,
  }, runId);

  log(`PIPELINE COMPLETED for ${seedId} (${progress.turns} turns, ${progress.toolCalls} tools, ${progress.filesChanged.length} files, $${progress.costUsd.toFixed(4)})`);
  await appendFile(logFile, `\n[PIPELINE] COMPLETED ($${progress.costUsd.toFixed(4)}, ${progress.turns} turns)\n`);
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
  resetSeedToOpen(seedId, projectPath);
  log(`Reset seed ${seedId} back to open`);

  store.close();
}

// ── Helpers ──────────────────────────────────────────────────────────────

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

// ── Entry ────────────────────────────────────────────────────────────────

main().catch((err) => {
  console.error(`[foreman-worker] Fatal: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
