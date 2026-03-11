/**
 * Pipeline Runner — orchestrates the Explorer → Developer → QA → Reviewer pipeline.
 *
 * Each phase runs a separate SDK query() call sequentially in the same worktree.
 * Communication between phases is via report files (EXPLORER_REPORT.md, QA_REPORT.md, REVIEW.md).
 * The pipeline handles retry logic: if QA or Reviewer fails, Developer gets another pass.
 */

import { readFile, appendFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { query } from "@anthropic-ai/claude-agent-sdk";
import type { SDKResultSuccess, SDKResultError } from "@anthropic-ai/claude-agent-sdk";
import type { ForemanStore, RunProgress } from "../lib/store.js";
import type { ModelSelection } from "./types.js";
import {
  ROLE_CONFIGS,
  explorerPrompt,
  developerPrompt,
  qaPrompt,
  reviewerPrompt,
  parseVerdict,
  extractIssues,
} from "./roles.js";

// ── Types ───────────────────────────────────────────────────────────────

export interface PipelineConfig {
  runId: string;
  projectId: string;
  beadId: string;
  beadTitle: string;
  beadDescription: string;
  model: ModelSelection;  // base model — overridden per role
  worktreePath: string;
  env: Record<string, string | undefined>;
  logFile: string;
  skipExplore?: boolean;
  skipReview?: boolean;
}

interface PhaseResult {
  success: boolean;
  costUsd: number;
  turns: number;
  tokensIn: number;
  tokensOut: number;
  durationMs: number;
  error?: string;
}

// ── Pipeline ────────────────────────────────────────────────────────────

const MAX_DEVELOPER_RETRIES = 2;

export async function runPipeline(
  config: PipelineConfig,
  store: ForemanStore,
  progress: RunProgress,
): Promise<void> {
  const { runId, projectId, beadId, beadTitle, beadDescription, worktreePath, logFile } = config;

  const logPhase = (phase: string, msg: string) => {
    const ts = new Date().toISOString().slice(11, 23);
    console.error(`[foreman-pipeline ${ts}] [${phase}] ${msg}`);
    appendFile(logFile, `[${ts}] [${phase}] ${msg}\n`).catch(() => {});
  };

  // Helper to accumulate costs across phases
  const addPhaseCosts = (result: PhaseResult) => {
    progress.costUsd += result.costUsd;
    progress.tokensIn += result.tokensIn;
    progress.tokensOut += result.tokensOut;
    progress.turns += result.turns;
    progress.lastActivity = new Date().toISOString();
  };

  await appendFile(logFile, `\n${"═".repeat(80)}\n[pipeline] Starting pipeline for ${beadId}\n${"═".repeat(80)}\n`);

  // ── Phase 1: Explorer ──────────────────────────────────────────────
  if (!config.skipExplore) {
    logPhase("explorer", "Starting exploration...");
    store.updateRunProgress(runId, { ...progress, lastToolCall: "explorer:start" });

    const explorerResult = await runPhase(
      explorerPrompt(beadId, beadTitle, beadDescription),
      ROLE_CONFIGS.explorer.model,
      ROLE_CONFIGS.explorer.maxTurns,
      config,
      logFile,
      "explorer",
    );

    addPhaseCosts(explorerResult);
    store.updateRunProgress(runId, progress);

    if (!explorerResult.success) {
      logPhase("explorer", `FAILED: ${explorerResult.error}`);
      // Explorer failure is non-fatal — developer can work without it
    } else {
      logPhase("explorer", `Done (${explorerResult.turns} turns, $${explorerResult.costUsd.toFixed(4)})`);
    }
  } else {
    logPhase("explorer", "Skipped (--skip-explore)");
  }

  // ── Phase 2+: Developer → QA → Reviewer (with retries) ────────────
  let developerRetries = 0;
  let feedbackContext: string | undefined;

  while (developerRetries <= MAX_DEVELOPER_RETRIES) {
    const attempt = developerRetries > 0 ? ` (retry ${developerRetries})` : "";

    // ── Developer ────────────────────────────────────────────────────
    logPhase("developer", `Starting implementation${attempt}...`);
    store.updateRunProgress(runId, { ...progress, lastToolCall: `developer:start${attempt}` });

    const hasExplorerReport = existsSync(join(worktreePath, "EXPLORER_REPORT.md"));
    const devResult = await runPhase(
      developerPrompt(beadId, beadTitle, beadDescription, hasExplorerReport, feedbackContext),
      selectDeveloperModel(config.model, beadTitle, beadDescription),
      ROLE_CONFIGS.developer.maxTurns,
      config,
      logFile,
      "developer",
    );

    addPhaseCosts(devResult);
    store.updateRunProgress(runId, progress);

    if (!devResult.success) {
      logPhase("developer", `FAILED: ${devResult.error}`);
      failPipeline(store, runId, projectId, beadId, progress, devResult.error ?? "Developer failed");
      return;
    }
    logPhase("developer", `Done (${devResult.turns} turns, $${devResult.costUsd.toFixed(4)})`);

    // ── QA ───────────────────────────────────────────────────────────
    logPhase("qa", "Starting QA...");
    store.updateRunProgress(runId, { ...progress, lastToolCall: "qa:start" });

    const qaResult = await runPhase(
      qaPrompt(beadId, beadTitle),
      ROLE_CONFIGS.qa.model,
      ROLE_CONFIGS.qa.maxTurns,
      config,
      logFile,
      "qa",
    );

    addPhaseCosts(qaResult);
    store.updateRunProgress(runId, progress);

    if (!qaResult.success) {
      logPhase("qa", `FAILED: ${qaResult.error}`);
      // QA agent itself crashed — retry developer
      feedbackContext = `QA agent crashed: ${qaResult.error}`;
      developerRetries++;
      continue;
    }
    logPhase("qa", `Done (${qaResult.turns} turns, $${qaResult.costUsd.toFixed(4)})`);

    // Check QA verdict
    const qaVerdict = await readVerdict(join(worktreePath, "QA_REPORT.md"));
    if (qaVerdict === "fail" && developerRetries < MAX_DEVELOPER_RETRIES) {
      const qaIssues = await readIssues(join(worktreePath, "QA_REPORT.md"));
      logPhase("qa", `VERDICT: FAIL — sending Developer back with feedback`);
      feedbackContext = `QA found issues:\n${qaIssues}`;
      developerRetries++;
      continue;
    }

    // ── Reviewer ─────────────────────────────────────────────────────
    if (!config.skipReview) {
      logPhase("reviewer", "Starting code review...");
      store.updateRunProgress(runId, { ...progress, lastToolCall: "reviewer:start" });

      const reviewResult = await runPhase(
        reviewerPrompt(beadId, beadTitle, beadDescription),
        ROLE_CONFIGS.reviewer.model,
        ROLE_CONFIGS.reviewer.maxTurns,
        config,
        logFile,
        "reviewer",
      );

      addPhaseCosts(reviewResult);
      store.updateRunProgress(runId, progress);

      if (!reviewResult.success) {
        logPhase("reviewer", `FAILED: ${reviewResult.error}`);
        // Reviewer crash is non-fatal — proceed with commit
      } else {
        logPhase("reviewer", `Done (${reviewResult.turns} turns, $${reviewResult.costUsd.toFixed(4)})`);

        // Check review verdict
        const reviewVerdict = await readVerdict(join(worktreePath, "REVIEW.md"));
        if (reviewVerdict === "fail" && developerRetries < MAX_DEVELOPER_RETRIES) {
          const reviewIssues = await readIssues(join(worktreePath, "REVIEW.md"));
          logPhase("reviewer", `VERDICT: FAIL — sending Developer back with feedback`);
          feedbackContext = `Code review found issues:\n${reviewIssues}`;
          developerRetries++;
          continue;
        }
      }
    } else {
      logPhase("reviewer", "Skipped (--skip-review)");
    }

    // ── All phases passed — break the retry loop ─────────────────────
    break;
  }

  // ── Final: commit, push, close bead ────────────────────────────────
  logPhase("finalize", "Running final commit...");
  store.updateRunProgress(runId, { ...progress, lastToolCall: "finalize:start" });

  const finalizePrompt = [
    `You are the finalizer. The implementation, QA, and review are complete.`,
    `Do the following steps in order:`,
    `1. Run 'git add -A' to stage all changes`,
    `2. Run 'git commit -m "${beadTitle} (${beadId})"'`,
    `3. Run 'git push -u origin foreman/${beadId}'`,
    `4. Run 'bd close ${beadId} --reason "Completed via pipeline"'`,
    `Do NOT modify any code. Just commit, push, and close.`,
  ].join("\n");

  const finalResult = await runPhase(
    finalizePrompt,
    "claude-haiku-4-5-20251001",
    10,
    config,
    logFile,
    "finalize",
  );

  addPhaseCosts(finalResult);
  store.updateRunProgress(runId, progress);

  if (finalResult.success) {
    logPhase("finalize", `Pipeline complete ($${progress.costUsd.toFixed(4)} total, ${progress.turns} turns)`);
    const now = new Date().toISOString();
    store.updateRun(runId, { status: "completed", completed_at: now });
    store.logEvent(projectId, "complete", {
      beadId,
      title: beadTitle,
      costUsd: progress.costUsd,
      numTurns: progress.turns,
      toolCalls: progress.toolCalls,
      filesChanged: progress.filesChanged.length,
      pipeline: true,
      retries: developerRetries,
    }, runId);
  } else {
    logPhase("finalize", `Failed to commit: ${finalResult.error}`);
    failPipeline(store, runId, projectId, beadId, progress, finalResult.error ?? "Finalize failed");
  }
}

// ── Phase runner ────────────────────────────────────────────────────────

async function runPhase(
  prompt: string,
  model: ModelSelection,
  maxTurns: number,
  config: PipelineConfig,
  logFile: string,
  phaseName: string,
): Promise<PhaseResult> {
  const ts = () => new Date().toISOString().slice(11, 23);

  try {
    let result: SDKResultSuccess | SDKResultError | undefined;

    for await (const message of query({
      prompt,
      options: {
        cwd: config.worktreePath,
        model,
        permissionMode: "bypassPermissions",
        allowDangerouslySkipPermissions: true,
        maxTurns,
        env: config.env,
        persistSession: false,  // Sub-agents don't need session persistence
      },
    })) {
      if (message.type === "assistant") {
        const toolUses = message.message.content
          .filter((b: { type: string }) => b.type === "tool_use") as Array<{ type: "tool_use"; name: string }>;
        if (toolUses.length > 0) {
          await appendFile(logFile, `[${ts()}] [${phaseName}] tools=[${toolUses.map(t => t.name).join(", ")}]\n`);
        }
      }

      if (message.type === "result") {
        result = message as SDKResultSuccess | SDKResultError;
      }
    }

    if (!result) {
      return {
        success: false,
        costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, durationMs: 0,
        error: "SDK generator ended without result",
      };
    }

    const base = {
      costUsd: result.total_cost_usd,
      turns: result.num_turns,
      tokensIn: result.usage.input_tokens,
      tokensOut: result.usage.output_tokens,
      durationMs: result.duration_ms,
    };

    if (result.subtype === "success") {
      await appendFile(logFile, `[${ts()}] [${phaseName}] result: success turns=${result.num_turns} cost=$${result.total_cost_usd.toFixed(4)}\n`);
      return { success: true, ...base };
    } else {
      const errResult = result as SDKResultError;
      const reason = errResult.errors?.join("; ") ?? errResult.subtype;
      await appendFile(logFile, `[${ts()}] [${phaseName}] result: ${errResult.subtype} — ${reason.slice(0, 300)}\n`);
      return { success: false, ...base, error: reason };
    }
  } catch (err: unknown) {
    const reason = err instanceof Error ? err.message : String(err);
    await appendFile(logFile, `[${ts()}] [${phaseName}] ERROR: ${reason.slice(0, 300)}\n`);
    return {
      success: false,
      costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, durationMs: 0,
      error: reason,
    };
  }
}

// ── Helpers ─────────────────────────────────────────────────────────────

function failPipeline(
  store: ForemanStore,
  runId: string,
  projectId: string,
  beadId: string,
  progress: RunProgress,
  reason: string,
): void {
  const now = new Date().toISOString();
  store.updateRun(runId, { status: "failed", completed_at: now });
  store.logEvent(projectId, "fail", {
    beadId,
    reason,
    costUsd: progress.costUsd,
    numTurns: progress.turns,
    pipeline: true,
  }, runId);
}

async function readVerdict(reportPath: string): Promise<"pass" | "fail" | "unknown"> {
  try {
    const content = await readFile(reportPath, "utf-8");
    return parseVerdict(content);
  } catch {
    return "unknown";
  }
}

async function readIssues(reportPath: string): Promise<string> {
  try {
    const content = await readFile(reportPath, "utf-8");
    return extractIssues(content);
  } catch {
    return "(could not read report)";
  }
}

/**
 * Select model for developer phase. Uses Opus for complex tasks, Sonnet otherwise.
 */
function selectDeveloperModel(
  baseModel: ModelSelection,
  title: string,
  description: string,
): ModelSelection {
  // If dispatcher already selected Opus, use it
  if (baseModel === "claude-opus-4-6") return baseModel;

  const text = `${title} ${description}`.toLowerCase();
  const heavy = ["refactor", "architect", "design", "complex", "migrate", "overhaul"];
  if (heavy.some((kw) => text.includes(kw))) {
    return "claude-opus-4-6";
  }

  return "claude-sonnet-4-6";
}
