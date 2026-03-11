import { writeFile } from "node:fs/promises";
import { join } from "node:path";

import type { BeadsClient, Bead } from "../lib/beads.js";
import type { ForemanStore } from "../lib/store.js";
import { createWorktree } from "../lib/git.js";
import { workerAgentMd } from "./templates.js";
import type {
  BeadInfo,
  DispatchResult,
  DispatchedTask,
  SkippedTask,
  RuntimeSelection,
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
    dryRun?: boolean;
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
      const runtime = opts?.runtime ?? this.selectRuntime(beadInfo);

      if (opts?.dryRun) {
        dispatched.push({
          beadId: bead.id,
          title: bead.title,
          runtime,
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

        // 2. Write AGENTS.md in the worktree
        const agentsMd = workerAgentMd(beadInfo, worktreePath, runtime);
        await writeFile(join(worktreePath, "AGENTS.md"), agentsMd, "utf-8");

        // 3. Record run in store
        const run = this.store.createRun(
          projectId,
          bead.id,
          runtime,
          worktreePath,
        );

        // 4. Log dispatch event
        this.store.logEvent(projectId, "dispatch", {
          beadId: bead.id,
          title: bead.title,
          runtime,
          worktreePath,
          branchName,
        }, run.id);

        // 5. Mark bead as in_progress before spawning agent
        try {
          await this.beads.update(bead.id, { status: "in_progress" });
        } catch {
          // Non-fatal: agent can still work even if status update fails
        }

        // 6. Spawn the coding agent
        const sessionKey = await this.spawnAgent(
          runtime,
          worktreePath,
          beadInfo,
          run.id,
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
   * Runs Claude Code synchronously and waits for completion.
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

    // 4. Spawn Claude Code synchronously (blocking — plan steps are sequential)
    const { execFile } = await import("node:child_process");
    const { promisify } = await import("node:util");
    const execFileAsync = promisify(execFile);

    const claudePath = process.env.CLAUDE_PATH || "/opt/homebrew/bin/claude";

    const sessionKey = `foreman:plan:${run.id}`;
    this.store.updateRun(run.id, {
      session_key: sessionKey,
      status: "running",
      started_at: new Date().toISOString(),
    });

    try {
      await execFileAsync(
        claudePath,
        ["--permission-mode", "bypassPermissions", "--print", prompt],
        {
          cwd: this.projectPath,
          timeout: 600_000, // 10 minute timeout per step
          maxBuffer: 10 * 1024 * 1024,
          env: { ...process.env, PATH: `/opt/homebrew/bin:${process.env.PATH}` },
        },
      );

      this.store.updateRun(run.id, {
        status: "completed",
        completed_at: new Date().toISOString(),
      });
      this.store.logEvent(projectId, "complete", {
        beadId: bead.id,
        title: bead.title,
      }, run.id);
    } catch (err: unknown) {
      const error = err as { killed?: boolean; stderr?: string; stdout?: string; message?: string };
      if (error.killed) {
        this.store.updateRun(run.id, {
          status: "failed",
          completed_at: new Date().toISOString(),
        });
        this.store.logEvent(projectId, "fail", {
          beadId: bead.id,
          reason: "Timed out after 10 minutes",
        }, run.id);
        throw new Error("Timed out after 10 minutes");
      }
      // Claude Code may exit non-zero but still produce output
      if (error.stderr && !error.stdout) {
        this.store.updateRun(run.id, {
          status: "failed",
          completed_at: new Date().toISOString(),
        });
        this.store.logEvent(projectId, "fail", {
          beadId: bead.id,
          reason: error.stderr,
        }, run.id);
        throw new Error(error.stderr);
      }
      // Had stdout — treat as success with warnings
      this.store.updateRun(run.id, {
        status: "completed",
        completed_at: new Date().toISOString(),
      });
      this.store.logEvent(projectId, "complete", {
        beadId: bead.id,
        title: bead.title,
        warnings: true,
      }, run.id);
    }

    return {
      beadId: bead.id,
      title: bead.title,
      runId: run.id,
      sessionKey,
    };
  }

  /**
   * Simple heuristic to pick a runtime based on task title keywords.
   */
  selectRuntime(task: BeadInfo): RuntimeSelection {
    const title = task.title.toLowerCase();

    const lightweight = ["test", "doc", "fix"];
    if (lightweight.some((kw) => title.includes(kw))) {
      return "pi";
    }

    const heavy = ["refactor", "architect", "design", "complex"];
    if (heavy.some((kw) => title.includes(kw))) {
      return "claude-code";
    }

    return "claude-code";
  }

  /**
   * Build the AGENTS.md content for a bead (exposed for testing).
   */
  generateAgentInstructions(bead: BeadInfo, worktreePath: string): string {
    const runtime = this.selectRuntime(bead);
    return workerAgentMd(bead, worktreePath, runtime);
  }

  // ── Agent Spawning ─────────────────────────────────────────────────────

  /**
   * Spawn a coding agent in the given worktree.
   * Uses Claude Code CLI in --print mode (non-interactive).
   * Returns a session identifier for tracking.
   */
  private async spawnAgent(
    runtime: RuntimeSelection,
    worktreePath: string,
    bead: BeadInfo,
    runId: string,
  ): Promise<string> {
    const { execFile } = await import("node:child_process");

    const task = [
      `Read AGENTS.md and implement the task described.`,
      `Use bd to track your progress.`,
      `When completely finished:`,
      `  bd close ${bead.id} --reason "Completed"`,
      `  git add -A`,
      `  git commit -m "${bead.title} (${bead.id})"`,
      `  git push -u origin foreman/${bead.id}`,
    ].join("\n");

    // Build a clean env that allows nested Claude sessions.
    // CLAUDECODE=1 prevents spawning Claude inside a Claude session.
    const cleanEnv: Record<string, string | undefined> = { ...process.env, PATH: `/opt/homebrew/bin:${process.env.PATH}` };
    delete cleanEnv.CLAUDECODE;

    const runtimeArgs: Record<string, { cmd: string; args: string[] }> = {
      "claude-code": {
        cmd: process.env.CLAUDE_PATH || "/opt/homebrew/bin/claude",
        args: ["--permission-mode", "bypassPermissions", "--print", task],
      },
      "pi": {
        cmd: "pi",
        args: [task],
      },
      "codex": {
        cmd: "codex",
        args: ["exec", "--full-auto", task],
      },
    };

    const config = runtimeArgs[runtime];
    if (!config) {
      throw new Error(`Unknown runtime: ${runtime}`);
    }

    const child = execFile(
      config.cmd,
      config.args,
      {
        cwd: worktreePath,
        timeout: 1_800_000, // 30 minute timeout
        maxBuffer: 10 * 1024 * 1024,
        env: cleanEnv,
      },
    );

    // Capture agent completion/failure for store updates
    child.on("exit", (code) => {
      try {
        if (code === 0) {
          this.store.updateRun(runId, {
            status: "completed",
            completed_at: new Date().toISOString(),
          });
        } else {
          this.store.updateRun(runId, {
            status: "failed",
            completed_at: new Date().toISOString(),
          });
        }
      } catch {
        // Store may be closed if foreman exited — ignore
      }
    });

    child.on("error", (err) => {
      try {
        this.store.updateRun(runId, {
          status: "failed",
          completed_at: new Date().toISOString(),
        });
        this.store.logEvent(this.resolveProjectId(), "fail", {
          beadId: bead.id,
          reason: err.message,
        }, runId);
      } catch {
        // Store may be closed — ignore
      }
    });

    // Detach — don't wait for completion
    child.unref();

    return `foreman:${runtime}:${runId}:pid-${child.pid}`;
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

function beadToInfo(bead: Bead): BeadInfo {
  return {
    id: bead.id,
    title: bead.title,
    priority: bead.priority,
    type: bead.type,
  };
}
