import { writeFile, rm, symlink, stat, mkdir, appendFile } from "node:fs/promises";
import { join } from "node:path";
import { query } from "@anthropic-ai/claude-agent-sdk";
import type { SDKMessage, SDKResultSuccess, SDKResultError } from "@anthropic-ai/claude-agent-sdk";

import type { BeadsClient, Bead } from "../lib/beads.js";
import type { ForemanStore, RunProgress } from "../lib/store.js";
import { createWorktree } from "../lib/git.js";
import { workerAgentMd } from "./templates.js";
import type {
  BeadInfo,
  DispatchResult,
  DispatchedTask,
  SkippedTask,
  RuntimeSelection,
  ModelSelection,
  PlanStepDispatched,
} from "./types.js";

// ── Dispatcher ──────────────────────────────────────────────────────────

export class Dispatcher {
  constructor(
    private beads: BeadsClient,
    private store: ForemanStore,
    private projectPath: string,
  ) {}

  /**
   * Query ready beads, create worktrees, write AGENTS.md, and record runs.
   */
  async dispatch(opts?: {
    maxAgents?: number;
    runtime?: RuntimeSelection;
    model?: ModelSelection;
    dryRun?: boolean;
    telemetry?: boolean;
    projectId?: string;
  }): Promise<DispatchResult> {
    const maxAgents = opts?.maxAgents ?? 5;
    const projectId = opts?.projectId ?? this.resolveProjectId();

    // Determine how many agent slots are available
    const activeRuns = this.store.getActiveRuns(projectId);
    const available = Math.max(0, maxAgents - activeRuns.length);

    const readyBeads = await this.beads.ready();

    const dispatched: DispatchedTask[] = [];
    const skipped: SkippedTask[] = [];

    // Skip beads that already have an active run
    const activeBeadIds = new Set(activeRuns.map((r) => r.bead_id));

    for (const bead of readyBeads) {
      if (activeBeadIds.has(bead.id)) {
        skipped.push({
          beadId: bead.id,
          title: bead.title,
          reason: "Already has an active run",
        });
        continue;
      }

      if (dispatched.length >= available) {
        skipped.push({
          beadId: bead.id,
          title: bead.title,
          reason: `Agent limit reached (${maxAgents})`,
        });
        continue;
      }

      const beadInfo = beadToInfo(bead);
      const runtime: RuntimeSelection = "claude-code";
      const model = opts?.model ?? this.selectModel(beadInfo);

      if (opts?.dryRun) {
        dispatched.push({
          beadId: bead.id,
          title: bead.title,
          runtime,
          model,
          worktreePath: join(this.projectPath, ".foreman-worktrees", bead.id),
          runId: "(dry-run)",
          branchName: `foreman/${bead.id}`,
        });
        continue;
      }

      try {
        // 1. Create git worktree
        const { worktreePath, branchName } = await createWorktree(
          this.projectPath,
          bead.id,
        );

        // 2. Symlink .beads/ from main repo so agents share the same database
        await linkBeadsDir(this.projectPath, worktreePath);

        // 3. Write AGENTS.md in the worktree
        const agentsMd = workerAgentMd(beadInfo, worktreePath, model);
        await writeFile(join(worktreePath, "AGENTS.md"), agentsMd, "utf-8");

        // 4. Record run in store
        const run = this.store.createRun(
          projectId,
          bead.id,
          model,
          worktreePath,
        );

        // 5. Log dispatch event
        this.store.logEvent(projectId, "dispatch", {
          beadId: bead.id,
          title: bead.title,
          model,
          worktreePath,
          branchName,
        }, run.id);

        // 6. Mark bead as in_progress before spawning agent
        await this.beads.update(bead.id, { status: "in_progress" });

        // 7. Spawn the coding agent via SDK
        const sessionKey = await this.spawnAgent(
          model,
          worktreePath,
          beadInfo,
          run.id,
          opts?.telemetry,
        );

        // Update run with session key
        this.store.updateRun(run.id, {
          session_key: sessionKey,
          status: "running",
          started_at: new Date().toISOString(),
        });

        dispatched.push({
          beadId: bead.id,
          title: bead.title,
          runtime,
          model,
          worktreePath,
          runId: run.id,
          branchName,
        });
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        skipped.push({
          beadId: bead.id,
          title: bead.title,
          reason: `Dispatch failed: ${message}`,
        });
      }
    }

    return {
      dispatched,
      skipped,
      activeAgents: activeRuns.length + dispatched.length,
    };
  }

  /**
   * Dispatch a planning step (PRD/TRD) without creating a worktree.
   * Runs Claude Code via SDK and waits for completion.
   */
  async dispatchPlanStep(
    projectId: string,
    bead: BeadInfo,
    ensembleCommand: string,
    input: string,
    outputDir: string,
  ): Promise<PlanStepDispatched> {
    // 1. Record run in store
    const run = this.store.createRun(projectId, bead.id, "claude-code");

    // 2. Log dispatch event
    this.store.logEvent(projectId, "dispatch", {
      beadId: bead.id,
      title: bead.title,
      ensembleCommand,
      outputDir,
      type: "plan-step",
    }, run.id);

    // 3. Build the prompt
    const prompt = `${ensembleCommand} ${input}\n\nSave all outputs to the ${outputDir}/ directory.`;

    const sessionKey = `foreman:plan:${run.id}`;
    this.store.updateRun(run.id, {
      session_key: sessionKey,
      status: "running",
      started_at: new Date().toISOString(),
    });

    // 4. Build env with telemetry tags
    const env = buildCleanEnv();

    try {
      let resultMsg: SDKResultSuccess | SDKResultError | undefined;

      for await (const message of query({
        prompt,
        options: {
          cwd: this.projectPath,
          model: "claude-sonnet-4-6",
          permissionMode: "bypassPermissions",
          allowDangerouslySkipPermissions: true,
          maxTurns: 50,
          env,
          persistSession: false,
        },
      })) {
        if (message.type === "result") {
          resultMsg = message as SDKResultSuccess | SDKResultError;
        }
      }

      if (resultMsg && resultMsg.subtype === "success") {
        this.store.updateRun(run.id, {
          status: "completed",
          completed_at: new Date().toISOString(),
        });
        this.store.logEvent(projectId, "complete", {
          beadId: bead.id,
          title: bead.title,
          costUsd: resultMsg.total_cost_usd,
          numTurns: resultMsg.num_turns,
          durationMs: resultMsg.duration_ms,
        }, run.id);
      } else if (resultMsg) {
        const errResult = resultMsg as SDKResultError;
        const reason = errResult.errors?.join("; ") ?? errResult.subtype;
        this.store.updateRun(run.id, {
          status: "failed",
          completed_at: new Date().toISOString(),
        });
        this.store.logEvent(projectId, "fail", {
          beadId: bead.id,
          reason,
          costUsd: errResult.total_cost_usd,
        }, run.id);
        throw new Error(reason);
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      // Only update if not already updated by the result handler above
      const currentRun = this.store.getRun(run.id);
      if (currentRun?.status === "running") {
        this.store.updateRun(run.id, {
          status: "failed",
          completed_at: new Date().toISOString(),
        });
        this.store.logEvent(projectId, "fail", {
          beadId: bead.id,
          reason: message,
        }, run.id);
      }
      throw err;
    }

    return {
      beadId: bead.id,
      title: bead.title,
      runId: run.id,
      sessionKey,
    };
  }

  /**
   * Pick a Claude model based on task complexity signals.
   *
   * - Opus: refactor, architect, design, complex, multi-step features
   * - Sonnet: default for most implementation tasks
   * - Haiku: simple config, docs-only, typo fixes
   */
  selectModel(task: BeadInfo): ModelSelection {
    const text = `${task.title} ${task.description ?? ""}`.toLowerCase();

    const heavy = ["refactor", "architect", "design", "complex", "migrate", "overhaul"];
    if (heavy.some((kw) => text.includes(kw))) {
      return "claude-opus-4-6";
    }

    const light = ["typo", "rename", "config", "bump version", "update readme"];
    if (light.some((kw) => text.includes(kw))) {
      return "claude-haiku-4-5-20251001";
    }

    return "claude-sonnet-4-6";
  }

  /**
   * Build the AGENTS.md content for a bead (exposed for testing).
   */
  generateAgentInstructions(bead: BeadInfo, worktreePath: string): string {
    const model = this.selectModel(bead);
    return workerAgentMd(bead, worktreePath, model);
  }

  // ── Agent Spawning ─────────────────────────────────────────────────────

  /**
   * Spawn a coding agent in the given worktree using the Claude Agent SDK.
   *
   * The SDK runs Claude Code as a library — no subprocess, no stdio pipes,
   * no shell execution. Structured messages stream via an async generator.
   *
   * The agent runs in a background Promise so dispatch returns immediately.
   * Progress and completion are logged to ~/.foreman/logs/<runId>.log and
   * the store is updated as events arrive.
   */
  private async spawnAgent(
    model: ModelSelection,
    worktreePath: string,
    bead: BeadInfo,
    runId: string,
    telemetry?: boolean,
  ): Promise<string> {
    const prompt = [
      `Read AGENTS.md and implement the task described.`,
      `Use bd to track your progress.`,
      `When completely finished:`,
      `  bd close ${bead.id} --reason "Completed"`,
      `  git add -A`,
      `  git commit -m "${bead.title} (${bead.id})"`,
      `  git push -u origin foreman/${bead.id}`,
    ].join("\n");

    // Build a clean env that allows nested Claude sessions
    const env = buildCleanEnv();

    // Tag agent spans with bead/run metadata for OTEL/LangSmith
    if (telemetry) {
      env.CLAUDE_CODE_ENABLE_TELEMETRY = "1";
      env.OTEL_RESOURCE_ATTRIBUTES = [
        process.env.OTEL_RESOURCE_ATTRIBUTES,
        `foreman.bead_id=${bead.id}`,
        `foreman.run_id=${runId}`,
        `foreman.model=${model}`,
      ].filter(Boolean).join(",");
    }

    // Create log directory
    const logDir = join(process.env.HOME ?? "/tmp", ".foreman", "logs");
    await mkdir(logDir, { recursive: true });
    const logFile = join(logDir, `${runId}.log`);

    const header = [
      `[foreman] Agent spawn at ${new Date().toISOString()}`,
      `  bead:      ${bead.id} — ${bead.title}`,
      `  model:     ${model}`,
      `  run:       ${runId}`,
      `  worktree:  ${worktreePath}`,
      `  method:    Claude Agent SDK (query)`,
      "─".repeat(80),
      "",
    ].join("\n");
    await appendFile(logFile, header);

    log(`Spawning agent for ${bead.id} [${model}] in ${worktreePath}`);
    log(`  method: Claude Agent SDK`);

    const projectId = this.resolveProjectId();
    const sessionKey = `foreman:sdk:${model}:${runId}`;

    // Launch the SDK query in a background Promise — don't await.
    // The async generator is consumed in the background, updating the store
    // progress and log file as messages arrive.
    const agentPromise = (async () => {
      let sessionId = "";
      let resultHandled = false; // Guard against post-result errors overwriting status

      // Live progress tracking — updated on every SDK message
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

      // Throttle progress writes to avoid hammering SQLite on every message
      let progressDirty = false;
      const flushProgress = () => {
        if (progressDirty) {
          this.store.updateRunProgress(runId, progress);
          progressDirty = false;
        }
      };
      const progressTimer = setInterval(flushProgress, 2_000);
      progressTimer.unref();

      try {
        for await (const message of query({
          prompt,
          options: {
            cwd: worktreePath,
            model,
            permissionMode: "bypassPermissions",
            allowDangerouslySkipPermissions: true,
            env,
            persistSession: true,
          },
        })) {
          await logMessage(logFile, message);
          progress.lastActivity = new Date().toISOString();

          // Track session ID from first message
          if ("session_id" in message && message.session_id && !sessionId) {
            sessionId = message.session_id;
            this.store.updateRun(runId, {
              session_key: `foreman:sdk:${model}:${runId}:session-${sessionId}`,
            });
            log(`  Agent ${bead.id} session: ${sessionId}`);
          }

          // Track tool usage from assistant messages
          if (message.type === "assistant") {
            progress.turns++;
            const toolUses = message.message.content.filter(
              (b: { type: string }) => b.type === "tool_use",
            ) as Array<{ type: "tool_use"; name: string; input: Record<string, unknown> }>;

            for (const tool of toolUses) {
              progress.toolCalls++;
              progress.toolBreakdown[tool.name] = (progress.toolBreakdown[tool.name] ?? 0) + 1;
              progress.lastToolCall = tool.name;

              // Track files changed via Write/Edit tools
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

            // Final progress flush
            clearInterval(progressTimer);
            this.store.updateRunProgress(runId, progress);
            resultHandled = true;

            if (result.subtype === "success") {
              this.store.updateRun(runId, { status: "completed", completed_at: now });
              this.store.logEvent(projectId, "complete", {
                beadId: bead.id,
                title: bead.title,
                costUsd: progress.costUsd,
                numTurns: progress.turns,
                toolCalls: progress.toolCalls,
                filesChanged: progress.filesChanged.length,
                durationMs: result.duration_ms,
                sessionId,
              }, runId);
              log(`Agent for ${bead.id} completed (${progress.turns} turns, ${progress.toolCalls} tools, ${progress.filesChanged.length} files, $${progress.costUsd.toFixed(4)})`);
            } else {
              const errResult = result as SDKResultError;
              const reason = errResult.errors?.join("; ") ?? errResult.subtype;

              // Detect rate limit errors
              const isRateLimit = reason.includes("hit your limit")
                || reason.includes("rate limit")
                || errResult.subtype === "error_max_budget_usd";

              this.store.updateRun(runId, {
                status: isRateLimit ? "stuck" : "failed",
                completed_at: now,
              });
              this.store.logEvent(projectId, isRateLimit ? "stuck" : "fail", {
                beadId: bead.id,
                reason,
                costUsd: progress.costUsd,
                numTurns: progress.turns,
                toolCalls: progress.toolCalls,
                durationMs: result.duration_ms,
                sessionId,
                rateLimit: isRateLimit,
              }, runId);
              if (isRateLimit) {
                log(`Agent for ${bead.id} RATE LIMITED after ${progress.turns} turns ($${progress.costUsd.toFixed(4)}) — can resume later`);
              } else {
                log(`Agent for ${bead.id} FAILED (${errResult.subtype}): ${reason.slice(0, 300)}`);
              }
            }
          }
        }
      } catch (err: unknown) {
        clearInterval(progressTimer);
        this.store.updateRunProgress(runId, progress);
        const reason = err instanceof Error ? err.message : String(err);
        const isRateLimit = reason.includes("hit your limit") || reason.includes("rate limit");

        // Don't overwrite a successful result with a post-exit error.
        // The SDK sometimes throws after yielding subtype=success when the
        // process exits with code 1 (e.g. rate limit hit after completion).
        if (resultHandled) {
          log(`Agent for ${bead.id} post-result error (ignored — already ${isRateLimit ? "rate limited" : "completed"}): ${reason.slice(0, 200)}`);
          await appendFile(logFile, `\n[foreman] Post-result error (ignored): ${reason}\n`);
          return;
        }

        const now = new Date().toISOString();

        if (isRateLimit) {
          // Rate limited before completing — mark as stuck so it can be resumed
          this.store.updateRun(runId, { status: "stuck", completed_at: now });
          this.store.logEvent(projectId, "stuck", {
            beadId: bead.id,
            reason,
            costUsd: progress.costUsd,
            numTurns: progress.turns,
            rateLimit: true,
          }, runId);
          log(`Agent for ${bead.id} RATE LIMITED mid-work (${progress.turns} turns, $${progress.costUsd.toFixed(4)}) — can resume later`);
          await appendFile(logFile, `\n[foreman] RATE LIMITED: ${reason}\n`);
        } else {
          this.store.updateRun(runId, { status: "failed", completed_at: now });
          this.store.logEvent(projectId, "fail", {
            beadId: bead.id,
            reason,
            costUsd: progress.costUsd,
            numTurns: progress.turns,
          }, runId);
          log(`Agent for ${bead.id} ERROR: ${reason}`);
          await appendFile(logFile, `\n[foreman] ERROR: ${reason}\n`);
        }
      }
    })();

    // Don't await — let the agent run in the background.
    // Catch unhandled rejections so they don't crash foreman.
    agentPromise.catch((err) => {
      log(`Agent for ${bead.id} unhandled rejection: ${err instanceof Error ? err.message : String(err)}`);
    });

    return sessionKey;
  }

  // ── Private helpers ───────────────────────────────────────────────────

  private resolveProjectId(): string {
    const project = this.store.getProjectByPath(this.projectPath);
    if (!project) {
      throw new Error(
        `No project registered for path ${this.projectPath}. Run 'foreman init' first.`,
      );
    }
    return project.id;
  }
}

// ── Utility ─────────────────────────────────────────────────────────────

/**
 * Replace the worktree's .beads/ directory with a symlink to the main repo's
 * .beads/ so agents share the same Dolt database and issue tracker.
 */
async function linkBeadsDir(
  projectPath: string,
  worktreePath: string,
): Promise<void> {
  const mainBeads = join(projectPath, ".beads");
  const wtBeads = join(worktreePath, ".beads");

  // Only link if main repo has .beads/
  try {
    await stat(mainBeads);
  } catch (err: unknown) {
    const code = (err as NodeJS.ErrnoException).code;
    if (code === "ENOENT") return; // No .beads/ in main repo — nothing to link
    throw err; // Permission error, etc. — don't swallow
  }

  // Remove the git-checked-out .beads/ in the worktree and replace with symlink
  // rm force:true handles ENOENT, but will still throw on permission errors
  await rm(wtBeads, { recursive: true, force: true });
  await symlink(mainBeads, wtBeads);
}

/**
 * Build a clean env for agent sessions.
 * Removes CLAUDECODE to allow nested Claude sessions.
 */
function buildCleanEnv(): Record<string, string | undefined> {
  const env: Record<string, string | undefined> = {
    ...process.env,
    PATH: `/opt/homebrew/bin:${process.env.PATH}`,
  };
  delete env.CLAUDECODE;
  return env;
}

/**
 * Append an SDK message summary to the log file.
 * Only logs meaningful events — skips partial/streaming noise.
 */
async function logMessage(logFile: string, message: SDKMessage): Promise<void> {
  const ts = new Date().toISOString().slice(11, 23);

  switch (message.type) {
    case "assistant": {
      // Log tool use summaries from assistant messages
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
      // Skip system, partial, streaming, etc. — too noisy for log files
      break;
  }
}

function log(msg: string): void {
  const ts = new Date().toISOString().slice(11, 23);
  console.error(`[foreman ${ts}] ${msg}`);
}

function beadToInfo(bead: Bead): BeadInfo {
  return {
    id: bead.id,
    title: bead.title,
    priority: bead.priority,
    type: bead.type,
  };
}
