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
import { query } from "@anthropic-ai/claude-agent-sdk";
import type { SDKMessage, SDKResultSuccess, SDKResultError } from "@anthropic-ai/claude-agent-sdk";
import { ForemanStore } from "../lib/store.js";
import type { RunProgress } from "../lib/store.js";
import {
  ROLE_CONFIGS,
  explorerPrompt,
  developerPrompt,
  qaPrompt,
  reviewerPrompt,
  parseVerdict,
  extractIssues,
  hasActionableIssues,
} from "./roles.js";
import type { AgentRole } from "./types.js";

// ── Config ───────────────────────────────────────────────────────────────

interface WorkerConfig {
  runId: string;
  projectId: string;
  beadId: string;
  beadTitle: string;
  beadDescription?: string;
  model: string;
  worktreePath: string;
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

  const { runId, projectId, beadId, beadTitle, model, worktreePath, prompt, resume, pipeline } = config;

  // Set up logging
  const logDir = join(process.env.HOME ?? "/tmp", ".foreman", "logs");
  await mkdir(logDir, { recursive: true });
  const logFile = join(logDir, `${runId}.log`);

  const mode = pipeline ? "pipeline" : (resume ? "resume" : "worker");
  const header = [
    `[foreman-worker] Agent ${mode.toUpperCase()} at ${new Date().toISOString()}`,
    `  bead:      ${beadId} — ${beadTitle}`,
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

  log(`Worker started for ${beadId} [${model}] pid=${process.pid} mode=${mode}`);

  // Open store connection
  const store = new ForemanStore();

  // Apply worker env vars
  for (const [key, value] of Object.entries(config.env)) {
    process.env[key] = value;
  }

  // Build clean env for SDK
  const env: Record<string, string | undefined> = { ...process.env };

  // ── Pipeline mode: run each phase as a separate SDK session ─────────
  if (pipeline) {
    await runPipeline(config, store, logFile);
    store.close();
    log(`Pipeline worker exiting for ${beadId}`);
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
  const progressTimer = setInterval(flushProgress, 2_000);
  progressTimer.unref();

  try {
    const queryOpts: Parameters<typeof query>[0] = resume
      ? {
          prompt,
          options: {
            cwd: worktreePath,
            model: model as any,
            permissionMode: "bypassPermissions",
            allowDangerouslySkipPermissions: true,
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
            permissionMode: "bypassPermissions",
            allowDangerouslySkipPermissions: true,
            env,
            persistSession: true,
          },
        };

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
          store.logEvent(projectId, "complete", {
            beadId,
            title: beadTitle,
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

          store.updateRun(runId, {
            status: isRateLimit ? "stuck" : "failed",
            completed_at: now,
          });
          store.logEvent(projectId, isRateLimit ? "stuck" : "fail", {
            beadId,
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
      store.logEvent(projectId, "stuck", {
        beadId,
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
    store.updateRun(runId, {
      status: isRateLimit ? "stuck" : "failed",
      completed_at: now,
    });
    store.logEvent(projectId, isRateLimit ? "stuck" : "fail", {
      beadId,
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
  log(`Worker exiting for ${beadId}`);
}

// ── Pipeline orchestration ───────────────────────────────────────────────

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
  role: Exclude<AgentRole, "lead" | "worker">,
  prompt: string,
  config: WorkerConfig,
  progress: RunProgress,
  logFile: string,
  store: ForemanStore,
): Promise<PhaseResult> {
  const roleConfig = ROLE_CONFIGS[role];
  progress.currentPhase = role;
  store.updateRunProgress(config.runId, progress);

  await appendFile(logFile, `\n${"─".repeat(40)}\n[PHASE: ${role.toUpperCase()}] Starting (model=${roleConfig.model}, maxBudgetUsd=${roleConfig.maxBudgetUsd})\n`);
  log(`[${role.toUpperCase()}] Starting phase for ${config.beadId}`);

  const env: Record<string, string | undefined> = { ...config.env };

  try {
    let phaseResult: SDKResultSuccess | SDKResultError | undefined;

    for await (const message of query({
      prompt,
      options: {
        cwd: config.worktreePath,
        model: roleConfig.model as any,
        permissionMode: "bypassPermissions",
        allowDangerouslySkipPermissions: true,
        maxBudgetUsd: roleConfig.maxBudgetUsd,
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
      }

      if (message.type === "result") {
        phaseResult = message as SDKResultSuccess | SDKResultError;
      }
    }

    if (phaseResult) {
      progress.costUsd += phaseResult.total_cost_usd;
      progress.tokensIn += phaseResult.usage.input_tokens;
      progress.tokensOut += phaseResult.usage.output_tokens;
      store.updateRunProgress(config.runId, progress);

      if (phaseResult.subtype === "success") {
        log(`[${role.toUpperCase()}] Completed (${phaseResult.num_turns} turns, $${phaseResult.total_cost_usd.toFixed(4)})`);
        await appendFile(logFile, `[PHASE: ${role.toUpperCase()}] COMPLETED ($${phaseResult.total_cost_usd.toFixed(4)})\n`);
        return { success: true, costUsd: phaseResult.total_cost_usd, turns: phaseResult.num_turns, tokensIn: phaseResult.usage.input_tokens, tokensOut: phaseResult.usage.output_tokens };
      } else {
        const errResult = phaseResult as SDKResultError;
        const reason = errResult.errors?.join("; ") ?? errResult.subtype;
        log(`[${role.toUpperCase()}] Failed: ${reason.slice(0, 200)}`);
        await appendFile(logFile, `[PHASE: ${role.toUpperCase()}] FAILED: ${reason}\n`);
        return { success: false, costUsd: phaseResult.total_cost_usd, turns: phaseResult.num_turns, tokensIn: phaseResult.usage.input_tokens, tokensOut: phaseResult.usage.output_tokens, error: reason };
      }
    }

    log(`[${role.toUpperCase()}] SDK ended without result`);
    return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: "SDK stream ended without result" };
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
 * Run git finalization: add, commit, push, and close the bead.
 * Uses execFileSync for safety — no shell interpolation.
 */
async function finalize(config: WorkerConfig, logFile: string): Promise<void> {
  const { beadId, beadTitle, worktreePath } = config;
  const opts = { cwd: worktreePath, stdio: "pipe" as const, timeout: 30_000 };

  const report: string[] = [
    `# Finalize Report: ${beadTitle}`,
    "",
    `## Bead: ${beadId}`,
    `## Timestamp: ${new Date().toISOString()}`,
    "",
  ];

  // Commit
  let commitHash = "(none)";
  try {
    execFileSync("git", ["add", "-A"], opts);
    execFileSync("git", ["commit", "-m", `${beadTitle} (${beadId})`], opts);
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
  try {
    execFileSync("git", ["push", "-u", "origin", `foreman/${beadId}`], opts);
    log(`[FINALIZE] Pushed to origin`);
    report.push(`## Push`, `- Status: SUCCESS`, `- Branch: foreman/${beadId}`, "");
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[FINALIZE] Push failed: ${msg.slice(0, 200)}`);
    await appendFile(logFile, `[FINALIZE] Push error: ${msg}\n`);
    report.push(`## Push`, `- Status: FAILED`, `- Error: ${msg.slice(0, 300)}`, "");
  }

  // Close seed
  try {
    const sdPath = join(process.env.HOME ?? "~", ".bun", "bin", "sd");
    execFileSync(sdPath, ["close", beadId, "--reason", "Completed via pipeline"], opts);
    log(`[FINALIZE] Closed seed ${beadId}`);
    report.push(`## Seed Close`, `- Status: SUCCESS`, "");
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[FINALIZE] sd close failed: ${msg.slice(0, 200)}`);
    await appendFile(logFile, `[FINALIZE] sd close error: ${msg}\n`);
    report.push(`## Seed Close`, `- Status: FAILED`, `- Error: ${msg.slice(0, 300)}`, "");
  }

  // Write finalize report
  try {
    rotateReport(worktreePath, "FINALIZE_REPORT.md");
    writeFileSync(join(worktreePath, "FINALIZE_REPORT.md"), report.join("\n"));
  } catch {
    // Non-fatal — finalize report is for debugging
  }
}

const MAX_DEV_RETRIES = 2;

/**
 * Run the full pipeline: Explorer → Developer ⇄ QA → Reviewer → Finalize.
 * Each phase is a separate SDK session. TypeScript orchestrates the loop.
 */
async function runPipeline(config: WorkerConfig, store: ForemanStore, logFile: string): Promise<void> {
  const { runId, projectId, beadId, beadTitle, worktreePath } = config;
  const description = config.beadDescription ?? "(no description)";

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

  log(`Pipeline starting for ${beadId} [phases: ${config.skipExplore ? "skip-explore" : "explore"} → dev → qa → ${config.skipReview ? "skip-review" : "review"} → finalize]`);
  await appendFile(logFile, `\n[foreman-worker] Pipeline orchestration starting\n`);

  // ── Phase 1: Explorer ──────────────────────────────────────────────
  if (!config.skipExplore) {
    rotateReport(worktreePath, "EXPLORER_REPORT.md");
    const result = await runPhase("explorer", explorerPrompt(beadId, beadTitle, description), config, progress, logFile, store);
    if (!result.success) {
      await markStuck(store, runId, projectId, beadId, beadTitle, progress, "explorer", result.error ?? "Explorer failed");
      return;
    }
    store.logEvent(projectId, "complete", { beadId, phase: "explorer", costUsd: result.costUsd }, runId);
    store.recordPhaseCost(runId, "explorer", ROLE_CONFIGS.explorer.model, result.tokensIn, result.tokensOut, 0, result.costUsd);
    progress.phaseCosts = { ...progress.phaseCosts, explorer: (progress.phaseCosts?.explorer ?? 0) + result.costUsd };
    store.updateRunProgress(runId, progress);
  }

  const hasExplorerReport = existsSync(join(worktreePath, "EXPLORER_REPORT.md"));

  // ── Phase 2-3: Developer ⇄ QA loop ────────────────────────────────
  let devRetries = 0;
  let feedbackContext: string | undefined;
  let qaVerdict: "pass" | "fail" | "unknown" = "unknown";

  while (devRetries <= MAX_DEV_RETRIES) {
    // Developer
    rotateReport(worktreePath, "DEVELOPER_REPORT.md");
    const devResult = await runPhase(
      "developer",
      developerPrompt(beadId, beadTitle, description, hasExplorerReport, feedbackContext),
      config, progress, logFile, store,
    );
    if (!devResult.success) {
      await markStuck(store, runId, projectId, beadId, beadTitle, progress, "developer", devResult.error ?? "Developer failed");
      return;
    }
    store.logEvent(projectId, "complete", { beadId, phase: "developer", costUsd: devResult.costUsd, retry: devRetries }, runId);
    store.recordPhaseCost(runId, "developer", ROLE_CONFIGS.developer.model, devResult.tokensIn, devResult.tokensOut, 0, devResult.costUsd);
    progress.phaseCosts = { ...progress.phaseCosts, developer: (progress.phaseCosts?.developer ?? 0) + devResult.costUsd };
    store.updateRunProgress(runId, progress);

    // QA
    rotateReport(worktreePath, "QA_REPORT.md");
    const qaResult = await runPhase("qa", qaPrompt(beadId, beadTitle), config, progress, logFile, store);
    // Record phase cost regardless of success — the QA phase consumed real tokens even on failure.
    if (qaResult.costUsd > 0) {
      store.recordPhaseCost(runId, "qa", ROLE_CONFIGS.qa.model, qaResult.tokensIn, qaResult.tokensOut, 0, qaResult.costUsd);
      progress.phaseCosts = { ...progress.phaseCosts, qa: (progress.phaseCosts?.qa ?? 0) + qaResult.costUsd };
      store.updateRunProgress(runId, progress);
    }
    if (!qaResult.success) {
      await markStuck(store, runId, projectId, beadId, beadTitle, progress, "qa", qaResult.error ?? "QA failed");
      return;
    }
    store.logEvent(projectId, "complete", { beadId, phase: "qa", costUsd: qaResult.costUsd, retry: devRetries }, runId);

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
    rotateReport(worktreePath, "REVIEW.md");
    const reviewResult = await runPhase("reviewer", reviewerPrompt(beadId, beadTitle, description), config, progress, logFile, store);
    if (!reviewResult.success) {
      await markStuck(store, runId, projectId, beadId, beadTitle, progress, "reviewer", reviewResult.error ?? "Reviewer failed");
      return;
    }
    store.logEvent(projectId, "complete", { beadId, phase: "reviewer", costUsd: reviewResult.costUsd }, runId);
    store.recordPhaseCost(runId, "reviewer", ROLE_CONFIGS.reviewer.model, reviewResult.tokensIn, reviewResult.tokensOut, 0, reviewResult.costUsd);
    progress.phaseCosts = { ...progress.phaseCosts, reviewer: (progress.phaseCosts?.reviewer ?? 0) + reviewResult.costUsd };
    store.updateRunProgress(runId, progress);

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
        developerPrompt(beadId, beadTitle, description, hasExplorerReport, reviewFeedback),
        config, progress, logFile, store,
      );
      if (devResult.success) {
        store.logEvent(projectId, "complete", { beadId, phase: "developer", costUsd: devResult.costUsd, retry: devRetries, trigger: "review-feedback" }, runId);
        store.recordPhaseCost(runId, "developer", ROLE_CONFIGS.developer.model, devResult.tokensIn, devResult.tokensOut, 0, devResult.costUsd);
        progress.phaseCosts = { ...progress.phaseCosts, developer: (progress.phaseCosts?.developer ?? 0) + devResult.costUsd };
        store.updateRunProgress(runId, progress);

        rotateReport(worktreePath, "QA_REPORT.md");
        const qaResult = await runPhase("qa", qaPrompt(beadId, beadTitle), config, progress, logFile, store);
        // Record phase cost regardless of success — the QA phase consumed real tokens even on failure.
        if (qaResult.costUsd > 0) {
          store.recordPhaseCost(runId, "qa", ROLE_CONFIGS.qa.model, qaResult.tokensIn, qaResult.tokensOut, 0, qaResult.costUsd);
          progress.phaseCosts = { ...progress.phaseCosts, qa: (progress.phaseCosts?.qa ?? 0) + qaResult.costUsd };
          store.updateRunProgress(runId, progress);
        }
        if (qaResult.success) {
          store.logEvent(projectId, "complete", { beadId, phase: "qa", costUsd: qaResult.costUsd, retry: devRetries, trigger: "review-feedback" }, runId);
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
  store.logEvent(projectId, "complete", {
    beadId,
    title: beadTitle,
    costUsd: progress.costUsd,
    numTurns: progress.turns,
    toolCalls: progress.toolCalls,
    filesChanged: progress.filesChanged.length,
    phases: config.skipExplore ? "dev→qa→review→finalize" : "explore→dev→qa→review→finalize",
    devRetries,
    qaVerdict,
  }, runId);

  log(`PIPELINE COMPLETED for ${beadId} (${progress.turns} turns, ${progress.toolCalls} tools, ${progress.filesChanged.length} files, $${progress.costUsd.toFixed(4)})`);
  await appendFile(logFile, `\n[PIPELINE] COMPLETED ($${progress.costUsd.toFixed(4)}, ${progress.turns} turns)\n`);
}

async function markStuck(
  store: ForemanStore,
  runId: string,
  projectId: string,
  beadId: string,
  beadTitle: string,
  progress: RunProgress,
  phase: string,
  reason: string,
): Promise<void> {
  const isRateLimit = reason.includes("hit your limit") || reason.includes("rate limit");
  const now = new Date().toISOString();
  store.updateRunProgress(runId, progress);
  store.updateRun(runId, { status: isRateLimit ? "stuck" : "failed", completed_at: now });
  store.logEvent(projectId, isRateLimit ? "stuck" : "fail", {
    beadId,
    title: beadTitle,
    phase,
    reason,
    costUsd: progress.costUsd,
    rateLimit: isRateLimit,
  }, runId);

  // Reset seed back to open so it appears in sd ready for retry
  const sdPath = join(process.env.HOME ?? "~", ".bun", "bin", "sd");
  try {
    execFileSync(sdPath, ["update", beadId, "--status", "open"], { stdio: "pipe", timeout: 10_000 });
    log(`Reset bead ${beadId} back to open`);
  } catch {
    log(`Warning: could not reset bead ${beadId} to open`);
  }

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
