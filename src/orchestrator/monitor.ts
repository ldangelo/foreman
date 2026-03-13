import type { ForemanStore, Run } from "../lib/store.js";
import type { SeedsClient } from "../lib/seeds.js";
import { removeWorktree, createWorktree } from "../lib/git.js";
import type { MonitorReport } from "./types.js";
import { PIPELINE_LIMITS } from "../lib/config.js";
import type { TmuxClient } from "../lib/tmux.js";

// ── Monitor ──────────────────────────────────────────────────────────────

export class Monitor {
  private tmux?: TmuxClient;

  constructor(
    private store: ForemanStore,
    private seeds: SeedsClient,
    private projectPath: string,
    tmux?: TmuxClient,
  ) {
    this.tmux = tmux;
  }

  /**
   * Check all active runs and categorise them by status.
   * Updates the store for any status transitions detected.
   */
  async checkAll(opts?: {
    stuckTimeoutMinutes?: number;
    projectId?: string;
  }): Promise<MonitorReport> {
    const stuckTimeout = opts?.stuckTimeoutMinutes ?? PIPELINE_LIMITS.stuckDetectionMinutes;
    const activeRuns = this.store.getActiveRuns(opts?.projectId);

    const report: MonitorReport = {
      completed: [],
      stuck: [],
      active: [],
      failed: [],
    };

    const now = Date.now();

    for (const run of activeRuns) {
      try {
        // ── Tmux liveness check (runs BEFORE seed-status check) ──────
        if (this.tmux && run.tmux_session) {
          const tmuxAlive = await this.tmux.hasSession(run.tmux_session);
          if (!tmuxAlive) {
            this.store.updateRun(run.id, { status: "stuck" });
            this.store.logEvent(
              run.project_id,
              "stuck",
              {
                seedId: run.seed_id,
                detectedBy: "tmux-liveness",
                tmuxSession: run.tmux_session,
              },
              run.id,
            );
            report.stuck.push({ ...run, status: "stuck" });
            continue;
          }
        }

        const seedDetail = await this.seeds.show(run.seed_id);

        if (seedDetail.status === "closed" || seedDetail.status === "completed") {
          // Agent finished — mark run as completed
          this.store.updateRun(run.id, {
            status: "completed",
            completed_at: new Date().toISOString(),
          });
          this.store.logEvent(
            run.project_id,
            "complete",
            { seedId: run.seed_id, detectedBy: "monitor" },
            run.id,
          );
          report.completed.push({ ...run, status: "completed" });
          continue;
        }

        // Check for stuck agents
        if (run.started_at) {
          const startedAt = new Date(run.started_at).getTime();
          const elapsedMinutes = (now - startedAt) / (1000 * 60);

          if (elapsedMinutes > stuckTimeout) {
            this.store.updateRun(run.id, { status: "stuck" });
            this.store.logEvent(
              run.project_id,
              "stuck",
              { seedId: run.seed_id, elapsedMinutes: Math.round(elapsedMinutes) },
              run.id,
            );
            report.stuck.push({ ...run, status: "stuck" });
            continue;
          }
        }

        // Still actively running
        report.active.push(run);
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        this.store.updateRun(run.id, {
          status: "failed",
          completed_at: new Date().toISOString(),
        });
        this.store.logEvent(
          run.project_id,
          "fail",
          { seedId: run.seed_id, error: message },
          run.id,
        );
        report.failed.push({ ...run, status: "failed" });
      }
    }

    return report;
  }

  /**
   * Attempt to recover a stuck run by killing the worktree and re-creating it.
   * Returns true if recovered (re-queued as pending), false if max retries exceeded.
   */
  async recoverStuck(run: Run, maxRetries = PIPELINE_LIMITS.maxRecoveryRetries): Promise<boolean> {
    // Count previous recovery attempts from the events log
    const recoverEvents = this.store.getRunEvents(run.id, "recover");
    const retryCount = recoverEvents.length;

    if (retryCount >= maxRetries) {
      this.store.updateRun(run.id, {
        status: "failed",
        completed_at: new Date().toISOString(),
      });
      this.store.logEvent(
        run.project_id,
        "fail",
        { seedId: run.seed_id, reason: `Max retries (${maxRetries}) exceeded` },
        run.id,
      );
      return false;
    }

    // Kill existing worktree
    if (run.worktree_path) {
      try {
        await removeWorktree(this.projectPath, run.worktree_path);
      } catch {
        // Worktree may already be gone — that's fine
      }
    }

    // Recreate worktree
    try {
      const { worktreePath } = await createWorktree(this.projectPath, run.seed_id);

      this.store.updateRun(run.id, {
        status: "pending",
        worktree_path: worktreePath,
        started_at: null,
        completed_at: null,
      });

      this.store.logEvent(
        run.project_id,
        "recover",
        { seedId: run.seed_id, attempt: retryCount + 1, maxRetries },
        run.id,
      );

      return true;
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      this.store.updateRun(run.id, {
        status: "failed",
        completed_at: new Date().toISOString(),
      });
      this.store.logEvent(
        run.project_id,
        "fail",
        { seedId: run.seed_id, reason: `Recovery failed: ${message}` },
        run.id,
      );
      return false;
    }
  }
}
