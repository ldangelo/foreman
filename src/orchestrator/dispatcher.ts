import { writeFile, mkdir, open } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { query } from "@anthropic-ai/claude-agent-sdk";
import type { SDKResultSuccess, SDKResultError } from "@anthropic-ai/claude-agent-sdk";

import type { ITaskClient, Issue } from "../lib/task-client.js";
import type { ForemanStore } from "../lib/store.js";
import type { BvClient } from "../lib/bv.js";
import { createWorktree } from "../lib/git.js";
import { workerAgentMd } from "./templates.js";
import { normalizePriority } from "../lib/priority.js";
import { PLAN_STEP_CONFIG } from "./roles.js";
import { TmuxClient, tmuxSessionName } from "../lib/tmux.js";
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
        return {
          dispatched: [],
          skipped: [{ seedId: opts.seedId, title: opts.seedId, reason: "Not found in ready seeds" }],
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

      if (dispatched.length >= available) {
        skipped.push({
          seedId: seed.id,
          title: seed.title,
          reason: `Agent limit reached (${maxAgents})`,
        });
        continue;
      }

      const seedInfo = seedToInfo(seed);
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
        // 1. Create git worktree
        const { worktreePath, branchName } = await createWorktree(
          this.projectPath,
          seed.id,
        );

        // 2. Write TASK.md in the worktree (not AGENTS.md — avoids overwriting project file on merge)
        const taskMd = workerAgentMd(seedInfo, worktreePath, model);
        await writeFile(join(worktreePath, "TASK.md"), taskMd, "utf-8");

        // 4. Record run in store
        const run = this.store.createRun(
          projectId,
          seed.id,
          model,
          worktreePath,
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
        const { sessionKey, tmuxSession } = await this.spawnAgent(
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

        // Update run with session key (AT-T015: persist tmux_session if present)
        this.store.updateRun(run.id, {
          session_key: sessionKey,
          status: "running",
          started_at: new Date().toISOString(),
          ...(tmuxSession ? { tmux_session: tmuxSession } : {}),
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

      // Spawn the resumed agent
      const { sessionKey, tmuxSession } = await this.resumeAgent(
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
        ...(tmuxSession ? { tmux_session: tmuxSession } : {}),
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

    // 4. Build env with telemetry tags
    const env: Record<string, string | undefined> = { ...process.env };
    delete env.CLAUDECODE;
    env.PATH = `/opt/homebrew/bin:${env.PATH}`;

    try {
      let resultMsg: SDKResultSuccess | SDKResultError | undefined;

      for await (const message of query({
        prompt,
        options: {
          cwd: this.projectPath,
          model: PLAN_STEP_CONFIG.model,
          permissionMode: "bypassPermissions",
          allowDangerouslySkipPermissions: true,
          maxBudgetUsd: PLAN_STEP_CONFIG.maxBudgetUsd,
          maxTurns: PLAN_STEP_CONFIG.maxTurns,
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
          seedId: seed.id,
          title: seed.title,
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
          seedId: seed.id,
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
      `  br close ${seedId} --reason "Completed"`,
      `  git add -A`,
      `  git commit -m "${seedTitle} (${seedId})"`,
      `  git push -u origin foreman/${seedId}`,
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
      `  br close ${seedId} --reason "Completed"`,
      `  git add -A`,
      `  git commit -m "${seedTitle} (${seedId})"`,
      `  git push -u origin foreman/${seedId}`,
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
  ): Promise<{ sessionKey: string; tmuxSession?: string }> {
    const prompt = this.buildSpawnPrompt(seed.id, seed.title);

    const env = buildWorkerEnv(telemetry, seed.id, runId, model, notifyUrl);
    const sessionKey = `foreman:sdk:${model}:${runId}`;
    const usePipeline = pipelineOpts?.pipeline ?? true;  // Pipeline by default

    log(`Spawning ${usePipeline ? "pipeline" : "worker"} for ${seed.id} [${model}] in ${worktreePath}`);

    const spawnResult = await spawnWorkerProcess({
      runId,
      projectId: this.resolveProjectId(),
      seedId: seed.id,
      seedTitle: seed.title,
      seedDescription: seed.description,
      model,
      worktreePath,
      projectPath: this.projectPath,
      prompt,
      env,
      pipeline: usePipeline,
      skipExplore: pipelineOpts?.skipExplore,
      skipReview: pipelineOpts?.skipReview,
    });

    return { sessionKey, tmuxSession: spawnResult.tmuxSession };
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
  ): Promise<{ sessionKey: string; tmuxSession?: string }> {
    const resumePrompt = this.buildResumePrompt(seed.id, seed.title);

    const env = buildWorkerEnv(telemetry, seed.id, runId, model, notifyUrl);
    const sessionKey = `foreman:sdk:${model}:${runId}:session-${sdkSessionId}`;

    log(`Resuming worker for ${seed.id} [${model}] session=${sdkSessionId}`);

    const spawnResult = await spawnWorkerProcess({
      runId,
      projectId: this.resolveProjectId(),
      seedId: seed.id,
      seedTitle: seed.title,
      model,
      worktreePath,
      prompt: resumePrompt,
      env,
      resume: sdkSessionId,
    });

    return { sessionKey, tmuxSession: spawnResult.tmuxSession };
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

// ── Worker Config (must match agent-worker.ts interface) ────────────────

export interface WorkerConfig {
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
  resume?: string;
  pipeline?: boolean;
  skipExplore?: boolean;
  skipReview?: boolean;
}

// ── Spawn Strategy Pattern ──────────────────────────────────────────────

/** Result returned by a SpawnStrategy */
export interface SpawnResult {
  tmuxSession?: string;
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
 * Spawn worker inside a tmux session.
 * Builds a shell command string that tmux will execute.
 */
export class TmuxSpawnStrategy implements SpawnStrategy {
  private tmux = new TmuxClient();

  async spawn(config: WorkerConfig): Promise<SpawnResult> {
    const { tsxBin, workerScript, logDir } = resolveWorkerPaths();
    const sessionName = tmuxSessionName(config.seedId);

    // Write config to temp file (worker reads + deletes it)
    const configDir = join(process.env.HOME ?? "/tmp", ".foreman", "tmp");
    await mkdir(configDir, { recursive: true });
    const configPath = join(configDir, `worker-${config.runId}.json`);
    await writeFile(configPath, JSON.stringify(config), "utf-8");

    await mkdir(logDir, { recursive: true });
    const outLog = join(logDir, `${config.runId}.out`);
    const errLog = join(logDir, `${config.runId}.err`);

    // AT-T014: Kill stale session with same name before creating new one
    const killed = await this.tmux.killSession(sessionName);
    if (killed) {
      log(`[foreman] Killed stale tmux session ${sessionName}`);
    }

    // Build the command string for tmux
    const command = `${tsxBin} ${workerScript} ${configPath} > ${outLog} 2> ${errLog}`;

    const result = await this.tmux.createSession({
      sessionName,
      command,
      cwd: config.worktreePath,
      env: config.env,
    });

    if (!result.created) {
      // AT-T016: Log warning and signal failure so caller falls back
      log(`[foreman] tmux session creation failed -- falling back to detached process`);
      return {};
    }

    log(`  Worker tmux session=${sessionName} for ${config.seedId}`);
    return { tmuxSession: sessionName };
  }
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
 * Spawn agent-worker.ts using the best available strategy.
 *
 * Strategy selection:
 * 1. If tmux is available, use TmuxSpawnStrategy (AT-T013)
 * 2. If tmux creation fails, fall back to DetachedSpawnStrategy (AT-T016)
 * 3. If tmux is unavailable, use DetachedSpawnStrategy directly
 *
 * Returns the spawn result including optional tmux session name.
 */
export async function spawnWorkerProcess(config: WorkerConfig): Promise<SpawnResult> {
  const tmux = new TmuxClient();
  const available = await tmux.isAvailable();

  if (available) {
    const tmuxStrategy = new TmuxSpawnStrategy();
    const result = await tmuxStrategy.spawn(config);

    // AT-T016: If tmux creation failed, fall back to detached spawn
    if (result.tmuxSession) {
      return result;
    }

    // Tmux was available but session creation failed — fall back
    const detachedStrategy = new DetachedSpawnStrategy();
    return detachedStrategy.spawn(config);
  }

  // Tmux not available — use detached spawn directly
  const detachedStrategy = new DetachedSpawnStrategy();
  return detachedStrategy.spawn(config);
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

function seedToInfo(seed: Issue): SeedInfo {
  return {
    id: seed.id,
    title: seed.title,
    priority: seed.priority,
    type: seed.type,
  };
}
