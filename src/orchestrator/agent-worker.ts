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

import { readFileSync, unlinkSync } from "node:fs";
import { appendFile, mkdir } from "node:fs/promises";
import { join } from "node:path";
import { query } from "@anthropic-ai/claude-agent-sdk";
import type { SDKMessage, SDKResultSuccess, SDKResultError } from "@anthropic-ai/claude-agent-sdk";
import { ForemanStore } from "../lib/store.js";
import type { RunProgress } from "../lib/store.js";

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

  // ── Team mode: run lead agent that orchestrates sub-agents ──────────
  if (pipeline) {
    const { leadPrompt } = await import("./lead-prompt.js");

    const teamPrompt = leadPrompt({
      beadId,
      beadTitle,
      beadDescription: config.beadDescription ?? "(no description)",
      skipExplore: config.skipExplore,
      skipReview: config.skipReview,
    });

    log(`Starting lead agent for ${beadId} [${model}] with team orchestration`);
    await appendFile(logFile, `\n[foreman-worker] Lead agent starting with team mode\n`);

    // Run the lead as a single SDK session — it spawns sub-agents via Agent tool
    // Fall through to the standard single-agent mode below with the team prompt
    config.prompt = teamPrompt;
    // Don't override model — let the dispatcher's model selection stand
    // The lead prompt tells it to use Agent tool for sub-agents
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
