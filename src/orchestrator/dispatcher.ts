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

        // TODO: Spawn the actual agent session via OpenClaw
        // e.g. await openclaw.sessionsSpawn({ runtime, worktreePath, agentsMd })

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
