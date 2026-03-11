import { writeFile, rm, symlink, stat, mkdir } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { query } from "@anthropic-ai/claude-agent-sdk";
import type { SDKResultSuccess, SDKResultError } from "@anthropic-ai/claude-agent-sdk";

import type { BeadsClient, Bead } from "../lib/beads.js";
import type { ForemanStore } from "../lib/store.js";
import { createWorktree } from "../lib/git.js";
import { workerAgentMd } from "./templates.js";
import type {
  BeadInfo,
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
    pipeline?: boolean;
    skipExplore?: boolean;
    skipReview?: boolean;
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

        // 7. Spawn the coding agent
        const sessionKey = await this.spawnAgent(
          model,
          worktreePath,
          beadInfo,
          run.id,
          opts?.telemetry,
          {
            pipeline: opts?.pipeline,
            skipExplore: opts?.skipExplore,
            skipReview: opts?.skipReview,
          },
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
          beadId: run.bead_id,
          title: run.bead_id,
          reason: `Agent limit reached (${maxAgents})`,
        });
        continue;
      }

      // Extract SDK session ID from session_key
      // Format: foreman:sdk:<model>:<runId>:session-<sessionId>
      const sessionId = extractSessionId(run.session_key);
      if (!sessionId) {
        skipped.push({
          beadId: run.bead_id,
          title: run.bead_id,
          reason: "No SDK session ID found — cannot resume (was this a CLI-spawned run?)",
        });
        continue;
      }

      // Check worktree still exists
      if (!run.worktree_path) {
        skipped.push({
          beadId: run.bead_id,
          title: run.bead_id,
          reason: "No worktree path — cannot resume",
        });
        continue;
      }

      const model = (opts?.model ?? run.agent_type) as ModelSelection;
      const previousStatus = run.status;

      log(`Resuming agent for ${run.bead_id} [${model}] session=${sessionId}`);

      // Create a new run record for the resumed attempt
      const newRun = this.store.createRun(
        projectId,
        run.bead_id,
        model,
        run.worktree_path,
      );

      // Log resume event
      this.store.logEvent(projectId, "restart", {
        beadId: run.bead_id,
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
      const sessionKey = await this.resumeAgent(
        model,
        run.worktree_path,
        { id: run.bead_id, title: run.bead_id },
        newRun.id,
        sessionId,
        opts?.telemetry,
      );

      this.store.updateRun(newRun.id, {
        session_key: sessionKey,
        status: "running",
        started_at: new Date().toISOString(),
      });

      resumed.push({
        beadId: run.bead_id,
        title: run.bead_id,
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
    const env: Record<string, string | undefined> = { ...process.env };
    delete env.CLAUDECODE;
    env.PATH = `/opt/homebrew/bin:${env.PATH}`;

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
    bead: BeadInfo,
    runId: string,
    telemetry?: boolean,
    pipelineOpts?: {
      pipeline?: boolean;
      skipExplore?: boolean;
      skipReview?: boolean;
    },
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

    const env = buildWorkerEnv(telemetry, bead.id, runId, model);
    const sessionKey = `foreman:sdk:${model}:${runId}`;
    const usePipeline = pipelineOpts?.pipeline ?? true;  // Pipeline by default

    log(`Spawning detached ${usePipeline ? "pipeline" : "worker"} for ${bead.id} [${model}] in ${worktreePath}`);

    await spawnWorkerProcess({
      runId,
      projectId: this.resolveProjectId(),
      beadId: bead.id,
      beadTitle: bead.title,
      beadDescription: bead.description,
      model,
      worktreePath,
      prompt,
      env,
      pipeline: usePipeline,
      skipExplore: pipelineOpts?.skipExplore,
      skipReview: pipelineOpts?.skipReview,
    });

    return sessionKey;
  }

  // ── Session Resume ───────────────────────────────────────────────────

  /**
   * Resume a previously started agent session via a detached worker process.
   * The worker uses the SDK's `resume` option to continue the conversation.
   */
  private async resumeAgent(
    model: ModelSelection,
    worktreePath: string,
    bead: BeadInfo,
    runId: string,
    sdkSessionId: string,
    telemetry?: boolean,
  ): Promise<string> {
    const resumePrompt = [
      `You were previously working on this task but were interrupted (likely by a rate limit).`,
      `Continue where you left off. Check your progress so far and complete the remaining work.`,
      `When completely finished:`,
      `  bd close ${bead.id} --reason "Completed"`,
      `  git add -A`,
      `  git commit -m "${bead.title} (${bead.id})"`,
      `  git push -u origin foreman/${bead.id}`,
    ].join("\n");

    const env = buildWorkerEnv(telemetry, bead.id, runId, model);
    const sessionKey = `foreman:sdk:${model}:${runId}:session-${sdkSessionId}`;

    log(`Resuming detached worker for ${bead.id} [${model}] session=${sdkSessionId}`);

    await spawnWorkerProcess({
      runId,
      projectId: this.resolveProjectId(),
      beadId: bead.id,
      beadTitle: bead.title,
      model,
      worktreePath,
      prompt: resumePrompt,
      env,
      resume: sdkSessionId,
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

// ── Worker Config (must match agent-worker.ts interface) ────────────────

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
  resume?: string;
  pipeline?: boolean;
  skipExplore?: boolean;
  skipReview?: boolean;
}

/**
 * Spawn agent-worker.ts as a fully detached child process.
 *
 * Writes config to a temp JSON file, spawns tsx with detached: true,
 * then unrefs the child so the foreman process can exit freely.
 * The worker updates SQLite with progress/completion independently.
 */
async function spawnWorkerProcess(config: WorkerConfig): Promise<void> {
  // Write config to temp file (worker reads + deletes it)
  const configDir = join(process.env.HOME ?? "/tmp", ".foreman", "tmp");
  await mkdir(configDir, { recursive: true });
  const configPath = join(configDir, `worker-${config.runId}.json`);
  await writeFile(configPath, JSON.stringify(config), "utf-8");

  // Resolve paths to tsx and worker script
  const __filename = fileURLToPath(import.meta.url);
  const __dirname = dirname(__filename);
  const projectRoot = join(__dirname, "..", "..");
  const tsxBin = join(projectRoot, "node_modules", ".bin", "tsx");
  const workerScript = join(__dirname, "agent-worker.ts");

  const child = spawn(tsxBin, [workerScript, configPath], {
    detached: true,
    stdio: "ignore",
    cwd: config.worktreePath,
    env: { ...process.env, PATH: `/opt/homebrew/bin:${process.env.PATH}` },
  });

  child.unref();
  log(`  Worker pid=${child.pid} for ${config.beadId}`);
}

/**
 * Build a clean env record (string values only) for worker config.
 * Removes CLAUDECODE to allow nested Claude sessions.
 */
function buildWorkerEnv(
  telemetry: boolean | undefined,
  beadId: string,
  runId: string,
  model: string,
): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value !== undefined && key !== "CLAUDECODE") {
      env[key] = value;
    }
  }
  env.PATH = `/opt/homebrew/bin:${env.PATH ?? ""}`;

  if (telemetry) {
    env.CLAUDE_CODE_ENABLE_TELEMETRY = "1";
    env.OTEL_RESOURCE_ATTRIBUTES = [
      process.env.OTEL_RESOURCE_ATTRIBUTES,
      `foreman.bead_id=${beadId}`,
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

function beadToInfo(bead: Bead): BeadInfo {
  return {
    id: bead.id,
    title: bead.title,
    priority: bead.priority,
    type: bead.type,
  };
}
