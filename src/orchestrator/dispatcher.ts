import { writeFile, mkdir, open, readdir, unlink } from "node:fs/promises";
import { join, dirname } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { runWithPi } from "./pi-runner.js";

import type { ITaskClient, Issue } from "../lib/task-client.js";
import type { ForemanStore } from "../lib/store.js";
import { STUCK_RETRY_CONFIG, calculateStuckBackoffMs } from "../lib/config.js";
import type { BvClient } from "../lib/bv.js";
import { createWorktree, gitBranchExists } from "../lib/git.js";
import { BeadsRustClient } from "../lib/beads-rust.js";
import { workerAgentMd } from "./templates.js";
import { normalizePriority } from "../lib/priority.js";
import { PLAN_STEP_CONFIG } from "./roles.js";
import { PiRpcSpawnStrategy, isPiAvailable } from "./pi-rpc-spawn-strategy.js";
import { resolveWorkflowType } from "../lib/workflow-config-loader.js";
import type {
  SeedInfo,
  DispatchResult,
  DispatchedTask,
  SkippedTask,
  ResumedTask,
  RuntimeSelection,
  ModelSelection,
  PlanStepDispatched,
} from "./types.js";

// ── Dispatcher ──────────────────────────────────────────────────────────

export class Dispatcher {
  constructor(
    private seeds: ITaskClient,
    private store: ForemanStore,
    private projectPath: string,
    private bvClient?: BvClient | null,
  ) {}

  /**
   * Query ready seeds, create worktrees, write TASK.md, and record runs.
   */
  async dispatch(opts?: {
    maxAgents?: number;
    runtime?: RuntimeSelection;
    model?: ModelSelection;
    dryRun?: boolean;
    telemetry?: boolean;
    projectId?: string;
    pipeline?: boolean;
    skipExplore?: boolean;
    skipReview?: boolean;
    seedId?: string;
    /** URL of the notification server (e.g. "http://127.0.0.1:PORT") */
    notifyUrl?: string;
  }): Promise<DispatchResult> {
    const maxAgents = opts?.maxAgents ?? 5;
    const projectId = opts?.projectId ?? this.resolveProjectId();

    // Determine how many agent slots are available
    const activeRuns = this.store.getActiveRuns(projectId);
    const available = Math.max(0, maxAgents - activeRuns.length);

    let readySeeds = await this.seeds.ready();

    // Sort ready seeds using bv triage scores when available, falling back to priority sort.
    if (!opts?.seedId) {
      if (this.bvClient) {
        const triageResult = await this.bvClient.robotTriage();
        if (triageResult !== null) {
          // Build a score map from bv recommendations
          const scoreMap = new Map<string, number>();
          for (const rec of triageResult.recommendations) {
            scoreMap.set(rec.id, rec.score);
          }
          readySeeds = [...readySeeds].sort((a, b) => {
            const hasA = scoreMap.has(a.id);
            const hasB = scoreMap.has(b.id);
            // Tasks in recommendations come before tasks not in recommendations
            if (hasA && !hasB) return -1;
            if (!hasA && hasB) return 1;
            if (hasA && hasB) {
              // Both ranked: sort by score descending
              return (scoreMap.get(b.id) ?? 0) - (scoreMap.get(a.id) ?? 0);
            }
            // Neither ranked: fall back to priority sort
            return normalizePriority(a.priority) - normalizePriority(b.priority);
          });
          log(`bv triage scored ${readySeeds.length} ready seeds`);
        } else {
          log("bv unavailable, using priority-sort fallback");
          readySeeds = [...readySeeds].sort(
            (a, b) => normalizePriority(a.priority) - normalizePriority(b.priority),
          );
        }
      } else {
        // No bvClient provided — sort by priority
        readySeeds = [...readySeeds].sort(
          (a, b) => normalizePriority(a.priority) - normalizePriority(b.priority),
        );
      }
    }

    // Filter to a specific seed if requested
    if (opts?.seedId) {
      const target = readySeeds.find((b) => b.id === opts.seedId);
      if (!target) {
        let reason = "Not found in ready beads";
        try {
          const bead = await this.seeds.show(opts.seedId);
          if (!bead) {
            reason = `Bead ${opts.seedId} not found`;
          } else if (bead.status === "closed" || bead.status === "completed") {
            reason = `Bead ${opts.seedId} is closed (already completed)`;
          } else if (bead.status === "in_progress") {
            reason = `Bead ${opts.seedId} is already in progress`;
          } else if (bead.status === "open") {
            reason = `Bead ${opts.seedId} is blocked (has unresolved dependencies)`;
          }
        } catch {
          // fall back to default reason
        }
        return {
          dispatched: [],
          skipped: [{ seedId: opts.seedId, title: opts.seedId, reason }],
          resumed: [],
          activeAgents: activeRuns.length,
        };
      }
      readySeeds = [target];
    }

    const dispatched: DispatchedTask[] = [];
    const skipped: SkippedTask[] = [];

    // Skip seeds that already have an active run
    const activeSeedIds = new Set(activeRuns.map((r) => r.seed_id));

    for (const seed of readySeeds) {
      if (activeSeedIds.has(seed.id)) {
        skipped.push({
          seedId: seed.id,
          title: seed.title,
          reason: "Already has an active run",
        });
        continue;
      }

      // Skip seeds that are in exponential backoff after recent stuck runs
      const backoffResult = this.checkStuckBackoff(seed.id, projectId);
      if (backoffResult.inBackoff) {
        skipped.push({
          seedId: seed.id,
          title: seed.title,
          reason: backoffResult.reason ?? "In backoff period after recent stuck runs",
        });
        continue;
      }

      if (dispatched.length >= available) {
        skipped.push({
          seedId: seed.id,
          title: seed.title,
          reason: `Agent limit reached (${maxAgents})`,
        });
        continue;
      }

      // Fetch full issue details (description, notes/comments, labels) for agent context
      let seedDetail: { description?: string | null; notes?: string | null; labels?: string[] } | undefined;
      try {
        seedDetail = await this.seeds.show(seed.id);
      } catch {
        // Non-fatal: if show() fails, proceed without detail context
        log(`Warning: failed to fetch details for seed ${seed.id}`);
      }
      const seedInfo = seedToInfo(seed, seedDetail);
      const runtime: RuntimeSelection = "claude-code";
      const model = opts?.model ?? this.selectModel(seedInfo);

      if (opts?.dryRun) {
        dispatched.push({
          seedId: seed.id,
          title: seed.title,
          runtime,
          model,
          worktreePath: join(this.projectPath, ".foreman-worktrees", seed.id),
          runId: "(dry-run)",
          branchName: `foreman/${seed.id}`,
        });
        continue;
      }

      try {
        // 1. Resolve base branch (may stack on a dependency branch)
        const baseBranch = await resolveBaseBranch(seed.id, this.projectPath, this.store);
        if (baseBranch) {
          log(`[foreman] Stacking ${seed.id} on ${baseBranch}`);
        }

        // 2. Create git worktree (optionally branched from a dependency branch)
        const { worktreePath, branchName } = await createWorktree(
          this.projectPath,
          seed.id,
          baseBranch,
        );

        // 3. Write TASK.md in the worktree (not AGENTS.md — avoids overwriting project file on merge)
        const taskMd = workerAgentMd(seedInfo, worktreePath, model);
        await writeFile(join(worktreePath, "TASK.md"), taskMd, "utf-8");

        // 4. Record run in store (include base_branch for stacking awareness)
        const run = this.store.createRun(
          projectId,
          seed.id,
          model,
          worktreePath,
          { baseBranch: baseBranch ?? null },
        );

        // 5. Log dispatch event
        this.store.logEvent(projectId, "dispatch", {
          seedId: seed.id,
          title: seed.title,
          model,
          worktreePath,
          branchName,
        }, run.id);

        // 6. Mark seed as in_progress before spawning agent
        await this.seeds.update(seed.id, { status: "in_progress" });

        // 7. Spawn the coding agent
        const { sessionKey } = await this.spawnAgent(
          model,
          worktreePath,
          seedInfo,
          run.id,
          opts?.telemetry,
          {
            pipeline: opts?.pipeline,
            skipExplore: opts?.skipExplore,
            skipReview: opts?.skipReview,
          },
          opts?.notifyUrl,
        );

        // Update run with session key
        this.store.updateRun(run.id, {
          session_key: sessionKey,
          status: "running",
          started_at: new Date().toISOString(),
        });

        dispatched.push({
          seedId: seed.id,
          title: seed.title,
          runtime,
          model,
          worktreePath,
          runId: run.id,
          branchName,
        });
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        skipped.push({
          seedId: seed.id,
          title: seed.title,
          reason: `Dispatch failed: ${message}`,
        });
      }
    }

    return {
      dispatched,
      skipped,
      resumed: [],
      activeAgents: activeRuns.length + dispatched.length,
    };
  }

  /**
   * Resume stuck/failed runs from previous dispatches.
   *
   * Finds runs in "stuck" or "failed" status, extracts their SDK session IDs,
   * and resumes them via the SDK's `resume` option. This continues the agent's
   * conversation from where it left off (e.g. after a rate limit).
   */
  async resumeRuns(opts?: {
    maxAgents?: number;
    model?: ModelSelection;
    telemetry?: boolean;
    statuses?: Array<"stuck" | "failed">;
    /** URL of the notification server (e.g. "http://127.0.0.1:PORT") */
    notifyUrl?: string;
  }): Promise<DispatchResult> {
    const maxAgents = opts?.maxAgents ?? 5;
    const projectId = this.resolveProjectId();
    const statuses = opts?.statuses ?? ["stuck"];

    // Find resumable runs
    const resumableRuns = statuses.flatMap(
      (s) => this.store.getRunsByStatus(s, projectId),
    );

    const activeRuns = this.store.getActiveRuns(projectId);
    const available = Math.max(0, maxAgents - activeRuns.length);

    const resumed: ResumedTask[] = [];
    const skipped: SkippedTask[] = [];

    for (const run of resumableRuns) {
      if (resumed.length >= available) {
        skipped.push({
          seedId: run.seed_id,
          title: run.seed_id,
          reason: `Agent limit reached (${maxAgents})`,
        });
        continue;
      }

      // Extract SDK session ID from session_key
      // Format: foreman:sdk:<model>:<runId>:session-<sessionId>
      const sessionId = extractSessionId(run.session_key);
      if (!sessionId) {
        skipped.push({
          seedId: run.seed_id,
          title: run.seed_id,
          reason: "No SDK session ID found — cannot resume (was this a CLI-spawned run?)",
        });
        continue;
      }

      // Check worktree still exists
      if (!run.worktree_path) {
        skipped.push({
          seedId: run.seed_id,
          title: run.seed_id,
          reason: "No worktree path — cannot resume",
        });
        continue;
      }

      const model = (opts?.model ?? run.agent_type) as ModelSelection;
      const previousStatus = run.status;

      log(`Resuming agent for ${run.seed_id} [${model}] session=${sessionId}`);

      // Create a new run record for the resumed attempt
      const newRun = this.store.createRun(
        projectId,
        run.seed_id,
        model,
        run.worktree_path,
      );

      // Log resume event
      this.store.logEvent(projectId, "restart", {
        seedId: run.seed_id,
        model,
        previousRunId: run.id,
        previousStatus,
        sessionId,
      }, newRun.id);

      // Mark old run as restarted
      this.store.updateRun(run.id, {
        status: "failed",
        completed_at: new Date().toISOString(),
      });

      // Mark seed as in_progress before spawning resumed agent
      await this.seeds.update(run.seed_id, { status: "in_progress" });

      // Spawn the resumed agent
      const { sessionKey } = await this.resumeAgent(
        model,
        run.worktree_path,
        { id: run.seed_id, title: run.seed_id },
        newRun.id,
        sessionId,
        opts?.telemetry,
        opts?.notifyUrl,
      );

      this.store.updateRun(newRun.id, {
        session_key: sessionKey,
        status: "running",
        started_at: new Date().toISOString(),
      });

      resumed.push({
        seedId: run.seed_id,
        title: run.seed_id,
        model,
        runId: newRun.id,
        sessionId,
        previousStatus,
      });
    }

    return {
      dispatched: [],
      skipped,
      resumed,
      activeAgents: activeRuns.length + resumed.length,
    };
  }

  /**
   * Dispatch a planning step (PRD/TRD) without creating a worktree.
   * Runs Claude Code via SDK and waits for completion.
   */
  async dispatchPlanStep(
    projectId: string,
    seed: SeedInfo,
    ensembleCommand: string,
    input: string,
    outputDir: string,
  ): Promise<PlanStepDispatched> {
    // 1. Record run in store
    const run = this.store.createRun(projectId, seed.id, "claude-code");

    // 2. Log dispatch event
    this.store.logEvent(projectId, "dispatch", {
      seedId: seed.id,
      title: seed.title,
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

    // 4. Build clean env for Pi (strip CLAUDECODE, ensure PATH includes homebrew)
    const piEnv: Record<string, string> = {};
    for (const [k, v] of Object.entries(process.env)) {
      if (k !== "CLAUDECODE" && v !== undefined) piEnv[k] = v;
    }
    piEnv.PATH = `/opt/homebrew/bin:${piEnv.PATH ?? ""}`;

    try {
      const planResult = await runWithPi({
        prompt,
        systemPrompt: `You are a planning agent. ${ensembleCommand} for the task: ${seed.title}`,
        cwd: this.projectPath,
        model: PLAN_STEP_CONFIG.model,
        env: piEnv,
      });

      if (planResult.success) {
        this.store.updateRun(run.id, {
          status: "completed",
          completed_at: new Date().toISOString(),
        });
        this.store.logEvent(projectId, "complete", {
          seedId: seed.id,
          title: seed.title,
          costUsd: planResult.costUsd,
          numTurns: planResult.turns,
        }, run.id);
      } else {
        const reason = planResult.errorMessage ?? "Pi plan step failed";
        this.store.updateRun(run.id, {
          status: "failed",
          completed_at: new Date().toISOString(),
        });
        this.store.logEvent(projectId, "fail", {
          seedId: seed.id,
          reason,
          costUsd: planResult.costUsd,
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
          seedId: seed.id,
          reason: message,
        }, run.id);
      }
      throw err;
    }

    return {
      seedId: seed.id,
      title: seed.title,
      runId: run.id,
      sessionKey,
    };
  }

  /**
   * Pick a Claude model based on task complexity signals.
   *
   * - Opus: P0 critical tasks, or keywords: refactor, architect, design, complex, migrate, overhaul
   * - Haiku: P3/P4 low-priority tasks with light keywords, or typo/config/rename/etc.
   * - Sonnet: default for most implementation tasks
   *
   * Priority comparisons use normalizePriority() to handle both "P0"–"P4" and "0"–"4" formats.
   */
  selectModel(task: SeedInfo): ModelSelection {
    const text = `${task.title} ${task.description ?? ""}`.toLowerCase();
    const priority = normalizePriority(task.priority ?? "P2");

    // P0 critical tasks always get the most capable model
    if (priority === 0) {
      return "claude-opus-4-6";
    }

    const heavy = ["refactor", "architect", "design", "complex", "migrate", "overhaul"];
    if (heavy.some((kw) => text.includes(kw))) {
      return "claude-opus-4-6";
    }

    const light = ["typo", "rename", "config", "bump version", "update readme"];
    // Only use haiku for non-critical (P1+) light tasks
    if (light.some((kw) => text.includes(kw)) && priority >= 1) {
      return "claude-haiku-4-5-20251001";
    }

    return "claude-sonnet-4-6";
  }

  /**
   * Build the TASK.md content for a seed (exposed for testing).
   */
  generateAgentInstructions(seed: SeedInfo, worktreePath: string): string {
    const model = this.selectModel(seed);
    return workerAgentMd(seed, worktreePath, model);
  }

  // ── Agent Spawning ─────────────────────────────────────────────────────

  /**
   * Build the spawn prompt for an agent (exposed for testing — TRD-012).
   * Returns the multi-line string passed to the worker as its initial prompt.
   */
  buildSpawnPrompt(seedId: string, seedTitle: string): string {
    return [
      `Read TASK.md and implement the task described.`,
      `Use br (beads_rust) to track your progress.`,
      `When completely finished:`,
      `  Save your session log to SessionLogs/session-$(date +%d%m%y-%H:%M).md (mkdir -p SessionLogs first)`,
      `  br sync --flush-only`,
      `  git add .`,
      `  git commit -m "${seedTitle} (${seedId})"`,
      `  git push -u origin foreman/${seedId}`,
      `NOTE: Do NOT close the bead manually — it will be closed automatically after the branch merges to main.`,
    ].join("\n");
  }

  /**
   * Build the resume prompt for an agent (exposed for testing — TRD-012).
   */
  buildResumePrompt(seedId: string, seedTitle: string): string {
    return [
      `You were previously working on this task but were interrupted (likely by a rate limit).`,
      `Continue where you left off. Check your progress so far and complete the remaining work.`,
      `When completely finished:`,
      `  Save your session log to SessionLogs/session-$(date +%d%m%y-%H:%M).md (mkdir -p SessionLogs first)`,
      `  br sync --flush-only`,
      `  git add .`,
      `  git commit -m "${seedTitle} (${seedId})"`,
      `  git push -u origin foreman/${seedId}`,
      `NOTE: Do NOT close the bead manually — it will be closed automatically after the branch merges to main.`,
    ].join("\n");
  }

  /**
   * Spawn a coding agent as a detached worker process.
   *
   * Writes a WorkerConfig JSON file and spawns `agent-worker.ts` as a
   * detached child process that survives the parent foreman process exiting.
   * The worker runs the SDK `query()` loop independently and updates the
   * SQLite store with progress/completion.
   */
  private async spawnAgent(
    model: ModelSelection,
    worktreePath: string,
    seed: SeedInfo,
    runId: string,
    telemetry?: boolean,
    pipelineOpts?: {
      pipeline?: boolean;
      skipExplore?: boolean;
      skipReview?: boolean;
    },
    notifyUrl?: string,
  ): Promise<{ sessionKey: string }> {
    const prompt = this.buildSpawnPrompt(seed.id, seed.title);

    const env = buildWorkerEnv(telemetry, seed.id, runId, model, notifyUrl);
    const sessionKey = `foreman:sdk:${model}:${runId}`;
    const usePipeline = pipelineOpts?.pipeline ?? true;  // Pipeline by default

    log(`Spawning ${usePipeline ? "pipeline" : "worker"} for ${seed.id} [${model}] in ${worktreePath}`);

    const seedType = resolveWorkflowType(seed.type ?? "feature", seed.labels);

    await spawnWorkerProcess({
      runId,
      projectId: this.resolveProjectId(),
      seedId: seed.id,
      seedTitle: seed.title,
      seedDescription: seed.description,
      seedComments: seed.comments ?? undefined,
      model,
      worktreePath,
      projectPath: this.projectPath,
      prompt,
      env,
      pipeline: usePipeline,
      skipExplore: pipelineOpts?.skipExplore,
      skipReview: pipelineOpts?.skipReview,
      dbPath: join(this.projectPath, ".foreman", "foreman.db"),
      seedType,
    });

    return { sessionKey };
  }

  // ── Session Resume ───────────────────────────────────────────────────

  /**
   * Resume a previously started agent session via a detached worker process.
   * The worker uses the SDK's `resume` option to continue the conversation.
   */
  private async resumeAgent(
    model: ModelSelection,
    worktreePath: string,
    seed: SeedInfo,
    runId: string,
    sdkSessionId: string,
    telemetry?: boolean,
    notifyUrl?: string,
  ): Promise<{ sessionKey: string }> {
    const resumePrompt = this.buildResumePrompt(seed.id, seed.title);

    const env = buildWorkerEnv(telemetry, seed.id, runId, model, notifyUrl);
    const sessionKey = `foreman:sdk:${model}:${runId}:session-${sdkSessionId}`;

    log(`Resuming worker for ${seed.id} [${model}] session=${sdkSessionId}`);

    await spawnWorkerProcess({
      runId,
      projectId: this.resolveProjectId(),
      seedId: seed.id,
      seedTitle: seed.title,
      model,
      worktreePath,
      prompt: resumePrompt,
      env,
      resume: sdkSessionId,
      dbPath: join(this.projectPath, ".foreman", "foreman.db"),
    });

    return { sessionKey };
  }

  // ── Private helpers ───────────────────────────────────────────────────

  /**
   * Return recent stuck runs for a seed within the configured time window.
   * Ordered by created_at DESC (most recent first).
   */
  private getRecentStuckRuns(seedId: string, projectId: string) {
    const cutoff = new Date(Date.now() - STUCK_RETRY_CONFIG.windowMs).toISOString();
    const allRuns = this.store.getRunsForSeed(seedId, projectId);
    return allRuns.filter(
      (r) => r.status === "stuck" && r.created_at >= cutoff,
    );
  }

  /**
   * Check whether a seed is currently in exponential backoff due to recent
   * stuck runs. Returns `{ inBackoff: false }` if the seed may be dispatched,
   * or `{ inBackoff: true, reason }` if it must be skipped this cycle.
   */
  private checkStuckBackoff(
    seedId: string,
    projectId: string,
  ): { inBackoff: boolean; reason?: string } {
    const recentStuck = this.getRecentStuckRuns(seedId, projectId);
    const stuckCount = recentStuck.length;

    if (stuckCount === 0) return { inBackoff: false };

    // If the seed has hit the hard limit, block it until the window rolls over
    if (stuckCount >= STUCK_RETRY_CONFIG.maxRetries) {
      return {
        inBackoff: true,
        reason: `Max stuck retries reached (${stuckCount}/${STUCK_RETRY_CONFIG.maxRetries} in window) — will retry after window resets`,
      };
    }

    // Calculate required backoff based on how many times it has been stuck
    const requiredDelayMs = calculateStuckBackoffMs(stuckCount);

    // Use the most recent stuck run's completed_at (or created_at) as the
    // reference timestamp for the backoff clock
    const lastRun = recentStuck[0]; // DESC order → first = most recent
    const refTimestamp = lastRun.completed_at ?? lastRun.created_at;
    const elapsedMs = Date.now() - new Date(refTimestamp).getTime();

    if (elapsedMs < requiredDelayMs) {
      const remainingSec = Math.ceil((requiredDelayMs - elapsedMs) / 1000);
      return {
        inBackoff: true,
        reason: `Stuck backoff active (attempt ${stuckCount}/${STUCK_RETRY_CONFIG.maxRetries}) — retry in ${remainingSec}s`,
      };
    }

    return { inBackoff: false };
  }

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
 * Resolve the base branch for a seed's worktree.
 *
 * If any of the seed's blocking dependencies have an unmerged local branch
 * (i.e. a `foreman/<depId>` branch exists locally and its latest run is
 * "completed" but not yet "merged"), stack the new worktree on top of that
 * dependency branch instead of the default branch.
 *
 * This allows agent B to build on top of agent A's work before A is merged.
 * After A merges, the refinery will rebase B onto main.
 *
 * Returns the dependency branch name (e.g. "foreman/story-1") or undefined
 * when no stacking is needed.
 */
export async function resolveBaseBranch(
  seedId: string,
  projectPath: string,
  store: Pick<ForemanStore, "getRunsForSeed">,
): Promise<string | undefined> {
  const brClient = new BeadsRustClient(projectPath);
  try {
    const detail = await brClient.show(seedId);
    // detail.dependencies is string[] of dep IDs that this seed depends on
    for (const depId of detail.dependencies ?? []) {
      const depBranch = `foreman/${depId}`;
      // Check if this branch exists locally
      const branchExists = await gitBranchExists(projectPath, depBranch);
      if (!branchExists) continue;
      // Check if the dep's most recent run is "completed" (done but not yet merged)
      const depRuns = store.getRunsForSeed(depId);
      const latestDepRun = depRuns[0]; // DESC order → first = most recent
      if (latestDepRun && latestDepRun.status === "completed") {
        return depBranch; // Stack on this dependency branch
      }
    }
  } catch {
    // br may not be initialized or the seed may not have dependency info — ignore
  }
  return undefined; // Default: branch from main/current
}

// ── Worker Config (must match agent-worker.ts interface) ────────────────

export interface WorkerConfig {
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
  resume?: string;
  pipeline?: boolean;
  skipExplore?: boolean;
  skipReview?: boolean;
  /** Absolute path to the SQLite DB file (e.g. .foreman/foreman.db) */
  dbPath?: string;
  /**
   * Resolved workflow type (e.g. "smoke", "feature", "bug").
   * Derived from label-based override or bead type field.
   * Used for prompt-loader workflow scoping and spawn strategy selection.
   */
  seedType?: string;
}

// ── Spawn Strategy Pattern ──────────────────────────────────────────────

/** Result returned by a SpawnStrategy */
export interface SpawnResult {
}

/** Strategy interface for spawning worker processes */
export interface SpawnStrategy {
  spawn(config: WorkerConfig): Promise<SpawnResult>;
}

/**
 * Resolve common paths needed by both spawn strategies.
 */
function resolveWorkerPaths(): { tsxBin: string; workerScript: string; logDir: string } {
  const __filename = fileURLToPath(import.meta.url);
  const __dirname = dirname(__filename);
  const projectRoot = join(__dirname, "..", "..");
  return {
    tsxBin: join(projectRoot, "node_modules", ".bin", "tsx"),
    workerScript: join(__dirname, "agent-worker.ts"),
    logDir: join(process.env.HOME ?? "/tmp", ".foreman", "logs"),
  };
}


/**
 * Spawn worker as a detached child process (original behavior).
 */
export class DetachedSpawnStrategy implements SpawnStrategy {
  async spawn(config: WorkerConfig): Promise<SpawnResult> {
    const { tsxBin, workerScript, logDir } = resolveWorkerPaths();

    // Write config to temp file (worker reads + deletes it)
    const configDir = join(process.env.HOME ?? "/tmp", ".foreman", "tmp");
    await mkdir(configDir, { recursive: true });
    const configPath = join(configDir, `worker-${config.runId}.json`);
    await writeFile(configPath, JSON.stringify(config), "utf-8");

    await mkdir(logDir, { recursive: true });
    const outFd = await open(join(logDir, `${config.runId}.out`), "w");
    const errFd = await open(join(logDir, `${config.runId}.err`), "w");

    // Use the fully-constructed env from config (includes ~/.local/bin prefix from buildWorkerEnv)
    // Strip CLAUDECODE so the worker can spawn its own Claude SDK session
    const spawnEnv: Record<string, string | undefined> = { ...config.env };
    delete spawnEnv.CLAUDECODE;

    const child = spawn(tsxBin, [workerScript, configPath], {
      detached: true,
      stdio: ["ignore", outFd.fd, errFd.fd],
      cwd: config.worktreePath,
      env: spawnEnv,
    });

    child.unref();

    // Close parent's file handles — child process has inherited its own copies of the fds
    await outFd.close();
    await errFd.close();

    log(`  Worker pid=${child.pid} for ${config.seedId}`);
    return {};
  }
}

/**
 * Spawn agent-worker using the best available strategy.
 *
 * Strategy selection:
 * 1. If `pi` binary is available, use PiRpcSpawnStrategy (always preferred)
 * 2. Fallback: DetachedSpawnStrategy (runs agent-worker.js as a detached child)
 *
 * Smoke seeds get FOREMAN_SMOKE_TEST=true injected into env before spawning.
 */
export async function spawnWorkerProcess(config: WorkerConfig): Promise<SpawnResult> {
  // Inject FOREMAN_SMOKE_TEST for smoke seeds before dispatching to any strategy
  const effectiveConfig: WorkerConfig =
    config.seedType === "smoke"
      ? { ...config, env: { ...config.env, FOREMAN_SMOKE_TEST: "true" } }
      : config;

  if (isPiAvailable()) {
    log(`[foreman] pi binary found — using PiRpcSpawnStrategy for ${effectiveConfig.seedId}`);
    return new PiRpcSpawnStrategy().spawn(effectiveConfig);
  }

  // Pi not available — fall back to detached child process
  return new DetachedSpawnStrategy().spawn(effectiveConfig);
}

/**
 * Build a clean env record (string values only) for worker config.
 * Removes CLAUDECODE to allow nested Claude sessions.
 */
function buildWorkerEnv(
  telemetry: boolean | undefined,
  seedId: string,
  runId: string,
  model: string,
  notifyUrl?: string,
): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value !== undefined && key !== "CLAUDECODE") {
      env[key] = value;
    }
  }
  const home = process.env.HOME ?? "/home/nobody";
  env.PATH = `${home}/.local/bin:/opt/homebrew/bin:${env.PATH ?? ""}`;

  if (notifyUrl) {
    env.FOREMAN_NOTIFY_URL = notifyUrl;
  }

  if (telemetry) {
    env.CLAUDE_CODE_ENABLE_TELEMETRY = "1";
    env.OTEL_RESOURCE_ATTRIBUTES = [
      process.env.OTEL_RESOURCE_ATTRIBUTES,
      `foreman.seed_id=${seedId}`,
      `foreman.run_id=${runId}`,
      `foreman.model=${model}`,
    ].filter(Boolean).join(",");
  }

  return env;
}

function log(msg: string): void {
  const ts = new Date().toISOString().slice(11, 23);
  console.error(`[foreman ${ts}] ${msg}`);
}

/**
 * Extract the SDK session ID from a foreman session key.
 * Format: foreman:sdk:<model>:<runId>:session-<sessionId>
 */
function extractSessionId(sessionKey: string | null): string | null {
  if (!sessionKey) return null;
  const m = sessionKey.match(/session-(.+)$/);
  return m ? m[1] : null;
}

function seedToInfo(seed: Issue, detail?: { description?: string | null; notes?: string | null; labels?: string[] }): SeedInfo {
  return {
    id: seed.id,
    title: seed.title,
    description: detail?.description ?? seed.description ?? undefined,
    priority: seed.priority,
    type: seed.type,
    labels: detail?.labels ?? seed.labels,
    comments: detail?.notes ?? undefined,
  };
}

// ── Worker config file cleanup ────────────────────────────────────────────────

/**
 * Return the directory where worker config JSON files are written.
 */
export function workerConfigDir(): string {
  return join(homedir(), ".foreman", "tmp");
}

/**
 * Delete the worker config file for a specific run (if it still exists).
 * Safe to call even if the file has already been deleted by the worker.
 */
export async function deleteWorkerConfigFile(runId: string): Promise<void> {
  const configPath = join(workerConfigDir(), `worker-${runId}.json`);
  try {
    await unlink(configPath);
  } catch {
    // Already deleted or never created — ignore
  }
}

/**
 * Purge stale worker config files from ~/.foreman/tmp/ for runs that are no
 * longer active in the database.
 *
 * Worker config files are written by the dispatcher and deleted by the worker
 * on startup.  When a run is killed externally, the worker never starts and
 * the config file is never cleaned up.  This function removes orphaned files
 * for runs that are in a terminal state (failed, stuck, completed, etc.) or
 * are entirely absent from the DB.
 *
 * Returns the number of files deleted.
 */
export async function purgeOrphanedWorkerConfigs(
  store: Pick<import("../lib/store.js").ForemanStore, "getRun">,
): Promise<number> {
  const dir = workerConfigDir();
  let entries: string[];
  try {
    entries = await readdir(dir);
  } catch {
    // Directory does not exist — nothing to purge
    return 0;
  }

  const activeStatuses = new Set(["pending", "running"]);
  let deleted = 0;

  for (const entry of entries) {
    if (!entry.startsWith("worker-") || !entry.endsWith(".json")) continue;
    // Extract runId from filename: worker-<runId>.json
    const runId = entry.slice("worker-".length, -".json".length);
    if (!runId) continue;

    const run = store.getRun(runId);
    // Delete if the run is terminal, unknown, or absent from the DB
    if (!run || !activeStatuses.has(run.status)) {
      try {
        await unlink(join(dir, entry));
        deleted++;
      } catch {
        // Already gone — ignore
      }
    }
  }

  return deleted;
}
