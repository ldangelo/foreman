import { access, stat, rm } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

import type { ForemanStore, Run } from "../lib/store.js";
import { listWorktrees, removeWorktree } from "../lib/git.js";
import { archiveWorktreeReports } from "../lib/archive-reports.js";
import type { CheckResult, DoctorReport } from "./types.js";
import { PIPELINE_TIMEOUTS } from "../lib/config.js";
import type { MergeQueue, MergeQueueEntry } from "./merge-queue.js";
import type { TmuxClient } from "../lib/tmux.js";
import type { ITaskClient } from "../lib/task-client.js";

const execFileAsync = promisify(execFile);

function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function extractPid(sessionKey: string | null): number | null {
  if (!sessionKey) return null;
  const m = sessionKey.match(/pid-(\d+)/);
  return m ? parseInt(m[1], 10) : null;
}

/**
 * Returns true if the run was spawned as an SDK-based agent worker.
 * SDK workers use session_key format: "foreman:sdk:<model>:<runId>[:<suffix>]"
 * These workers do not have a PID in the session_key, so PID-based liveness
 * checks do not apply. Liveness for SDK workers with tmux_session is handled
 * by checkGhostRuns(); those without tmux_session are detected by stale timeouts.
 */
function isSDKBasedRun(sessionKey: string | null): boolean {
  return sessionKey?.startsWith("foreman:sdk:") ?? false;
}

// ── Doctor class ─────────────────────────────────────────────────────────

export class Doctor {
  private mergeQueue?: MergeQueue;
  private tmux?: TmuxClient;
  private taskClient?: ITaskClient;

  constructor(
    private store: ForemanStore,
    private projectPath: string,
    mergeQueue?: MergeQueue,
    tmux?: TmuxClient,
    taskClient?: ITaskClient,
  ) {
    this.mergeQueue = mergeQueue;
    this.tmux = tmux;
    this.taskClient = taskClient;
  }

  // ── System checks ──────────────────────────────────────────────────

  async checkBrBinary(): Promise<CheckResult> {
    const brPath = join(homedir(), ".local", "bin", "br");
    try {
      await access(brPath);
      return {
        name: "br (beads_rust) CLI binary",
        status: "pass",
        message: `Found at ${brPath}`,
      };
    } catch {
      return {
        name: "br (beads_rust) CLI binary",
        status: "fail",
        message: `Not found at ${brPath}. Install via: cargo install beads_rust`,
      };
    }
  }

  async checkBvBinary(): Promise<CheckResult> {
    const bvPath = join(homedir(), ".local", "bin", "bv");
    try {
      await access(bvPath);
      return {
        name: "bv (beads_viewer) CLI binary",
        status: "pass",
        message: `Found at ${bvPath}`,
      };
    } catch {
      return {
        name: "bv (beads_viewer) CLI binary",
        status: "fail",
        message: `Not found at ${bvPath}. Install via: cargo install beads_viewer`,
      };
    }
  }

  async checkGitBinary(): Promise<CheckResult> {
    try {
      await execFileAsync("git", ["--version"]);
      return {
        name: "git binary",
        status: "pass",
        message: "git is available",
      };
    } catch {
      return {
        name: "git binary",
        status: "fail",
        message: "git not found in PATH",
      };
    }
  }

  async checkSystem(): Promise<CheckResult[]> {
    // TRD-024: sd backend removed. Always check br and bv binaries.
    const [brResult, bvResult, gitResult] = await Promise.all([
      this.checkBrBinary(),
      this.checkBvBinary(),
      this.checkGitBinary(),
    ]);
    return [brResult, bvResult, gitResult];
  }

  // ── Repository checks ──────────────────────────────────────────────

  async checkDatabaseFile(): Promise<CheckResult> {
    const dbPath = join(this.projectPath, ".foreman", "foreman.db");
    try {
      await stat(dbPath);
      return {
        name: "foreman database",
        status: "pass",
        message: `Found at ${dbPath}`,
      };
    } catch {
      return {
        name: "foreman database",
        status: "warn",
        message: `Database not yet created at ${dbPath}. It will be created on first use.`,
      };
    }
  }

  async checkProjectRegistered(): Promise<CheckResult> {
    const project = this.store.getProjectByPath(this.projectPath);
    if (project) {
      return {
        name: "project registered in foreman",
        status: "pass",
        message: `Project "${project.name}" (${project.status})`,
      };
    }
    return {
      name: "project registered in foreman",
      status: "fail",
      message: `No project registered for ${this.projectPath}. Run 'foreman init' first.`,
    };
  }

  async checkBeadsInitialized(): Promise<CheckResult> {
    const beadsDir = join(this.projectPath, ".beads");
    if (existsSync(beadsDir)) {
      return {
        name: "beads (.beads/) initialized",
        status: "pass",
        message: ".beads directory found",
      };
    }
    return {
      name: "beads (.beads/) initialized",
      status: "fail",
      message: `No .beads directory at ${beadsDir}. Run 'foreman init' first.`,
    };
  }

  async checkRepository(): Promise<CheckResult[]> {
    // TRD-024: sd backend removed. Always check for .beads initialization.
    const results: CheckResult[] = [];
    results.push(await this.checkDatabaseFile());
    results.push(await this.checkProjectRegistered());
    results.push(await this.checkBeadsInitialized());
    return results;
  }

  // ── Data integrity checks ─────────────────────────────────────────

  async checkOrphanedWorktrees(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult[]> {
    const results: CheckResult[] = [];
    const { fix = false, dryRun = false } = opts;

    let worktrees;
    try {
      worktrees = await listWorktrees(this.projectPath);
    } catch {
      results.push({
        name: "orphaned worktrees",
        status: "warn",
        message: "Could not list worktrees (skipping check)",
      });
      return results;
    }

    const foremanWorktrees = worktrees.filter(
      (wt) => wt.branch && wt.branch.startsWith("foreman/"),
    );

    if (foremanWorktrees.length === 0) {
      results.push({
        name: "orphaned worktrees",
        status: "pass",
        message: "No foreman worktrees found",
      });
      return results;
    }

    for (const wt of foremanWorktrees) {
      const seedId = wt.branch.slice("foreman/".length);
      const runs = this.store.getRunsForSeed(seedId);
      const activeRun = runs.find((r: Run) =>
        ["pending", "running"].includes(r.status) && r.worktree_path === wt.path,
      );
      const completedRun = runs.find((r: Run) => r.status === "completed");
      const mergedRun = runs.find((r: Run) => r.status === "merged");
      const prCreatedRun = runs.find((r: Run) => r.status === "pr-created");
      const failableRun = runs.find((r: Run) =>
        (["failed", "stuck", "conflict", "test-failed"] as Run["status"][]).includes(r.status),
      );

      if (activeRun) {
        results.push({
          name: `worktree: ${seedId}`,
          status: "pass",
          message: `Active run (${activeRun.status}) for seed ${seedId}`,
        });
      } else if (mergedRun) {
        if (dryRun) {
          results.push({
            name: `worktree: ${seedId}`,
            status: "warn",
            message: `Already merged — stale worktree at ${wt.path}. Would remove (dry-run).`,
          });
        } else if (fix) {
          try {
            await archiveWorktreeReports(this.projectPath, wt.path, seedId).catch(() => {});
            await removeWorktree(this.projectPath, wt.path);
            try { await execFileAsync("git", ["worktree", "prune"], { cwd: this.projectPath }); } catch { /* */ }
            results.push({
              name: `worktree: ${seedId}`,
              status: "fixed",
              message: `Already merged — stale worktree`,
              fixApplied: `Removed worktree at ${wt.path}`,
            });
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            results.push({
              name: `worktree: ${seedId}`,
              status: "warn",
              message: `Already merged but could not auto-remove: ${msg}`,
            });
          }
        } else {
          results.push({
            name: `worktree: ${seedId}`,
            status: "warn",
            message: `Already merged — stale worktree. Use --fix to remove.`,
          });
        }
      } else if (completedRun) {
        results.push({
          name: `worktree: ${seedId}`,
          status: "warn",
          message: `Needs merge. Run: foreman merge --seed ${seedId}`,
        });
      } else if (prCreatedRun) {
        results.push({
          name: `worktree: ${seedId}`,
          status: "warn",
          message: `PR open — awaiting manual review/merge (run ${prCreatedRun.id.slice(0, 8)})`,
        });
      } else if (failableRun) {
        const hint = failableRun.status === "failed" || failableRun.status === "test-failed"
          ? "use 'foreman reset' to retry"
          : failableRun.status === "stuck"
            ? "use 'foreman reset' to recover"
            : "resolve merge conflict manually";
        results.push({
          name: `worktree: ${seedId}`,
          status: "warn",
          message: `Run in '${failableRun.status}' state — ${hint}`,
        });
      } else {
        if (dryRun) {
          results.push({
            name: `worktree: ${seedId}`,
            status: "warn",
            message: `Orphaned worktree at ${wt.path} (no runs). Would remove (dry-run).`,
          });
        } else if (fix) {
          try {
            await archiveWorktreeReports(this.projectPath, wt.path, seedId).catch(() => {});
            await removeWorktree(this.projectPath, wt.path);
            try { await execFileAsync("git", ["worktree", "prune"], { cwd: this.projectPath }); } catch { /* */ }
            results.push({
              name: `worktree: ${seedId}`,
              status: "fixed",
              message: `Orphaned worktree (no runs)`,
              fixApplied: `Removed worktree at ${wt.path}`,
            });
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            results.push({
              name: `worktree: ${seedId}`,
              status: "warn",
              message: `Orphaned worktree — could not auto-remove: ${msg}`,
            });
          }
        } else {
          results.push({
            name: `worktree: ${seedId}`,
            status: "warn",
            message: `Orphaned worktree at ${wt.path} (no runs). Use --fix to remove.`,
          });
        }
      }
    }

    return results;
  }

  async checkZombieRuns(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult[]> {
    const { fix = false, dryRun = false } = opts;
    const project = this.store.getProjectByPath(this.projectPath);
    if (!project) return [];

    const runningRuns = this.store.getRunsByStatus("running", project.id);
    if (runningRuns.length === 0) {
      return [
        {
          name: "zombie runs (running, no process)",
          status: "pass",
          message: "No running runs in database",
        },
      ];
    }

    const results: CheckResult[] = [];
    for (const run of runningRuns) {
      // SDK-based workers do not store a PID in session_key.
      // If they have a tmux_session, checkGhostRuns() handles liveness.
      // If they have no tmux_session, they can only be detected by stale timeouts.
      // Either way, PID-based zombie detection does not apply to SDK runs.
      if (isSDKBasedRun(run.session_key)) {
        results.push({
          name: `run: ${run.seed_id} [${run.agent_type}]`,
          status: "pass",
          message: `SDK-based worker — liveness checked via tmux/timeout, not PID`,
        });
        continue;
      }

      const pid = extractPid(run.session_key);
      const isAlive = pid !== null && isProcessAlive(pid);

      if (isAlive) {
        results.push({
          name: `run: ${run.seed_id} [${run.agent_type}]`,
          status: "pass",
          message: `Process pid ${pid} is alive`,
        });
      } else {
        if (dryRun) {
          results.push({
            name: `run: ${run.seed_id} [${run.agent_type}]`,
            status: "warn",
            message: `Zombie run: status=running but no live process${pid ? ` (pid ${pid})` : ""}. Would mark failed (dry-run).`,
          });
        } else if (fix) {
          this.store.updateRun(run.id, {
            status: "failed",
            completed_at: new Date().toISOString(),
          });
          results.push({
            name: `run: ${run.seed_id} [${run.agent_type}]`,
            status: "fixed",
            message: `Zombie run (status=running, no live process${pid ? ` for pid ${pid}` : ""})`,
            fixApplied: "Marked as failed",
          });
        } else {
          results.push({
            name: `run: ${run.seed_id} [${run.agent_type}]`,
            status: "warn",
            message: `Zombie run: status=running but no live process${pid ? ` (pid ${pid})` : ""}. Use --fix to mark failed.`,
          });
        }
      }
    }

    return results;
  }

  async checkStalePendingRuns(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult> {
    const { fix = false, dryRun = false } = opts;
    const project = this.store.getProjectByPath(this.projectPath);
    if (!project) {
      return {
        name: "stale pending runs",
        status: "pass",
        message: "No project registered (skipping)",
      };
    }

    const pendingRuns = this.store.getRunsByStatus("pending", project.id);
    const staleThresholdMs = PIPELINE_TIMEOUTS.staleRunHours * 60 * 60 * 1000;
    const now = Date.now();

    const staleRuns = pendingRuns.filter((r) => {
      const age = now - new Date(r.created_at).getTime();
      return age > staleThresholdMs;
    });

    if (staleRuns.length === 0) {
      return {
        name: `stale pending runs (>${PIPELINE_TIMEOUTS.staleRunHours}h)`,
        status: "pass",
        message: `${pendingRuns.length} pending run(s), none older than ${PIPELINE_TIMEOUTS.staleRunHours}h`,
      };
    }

    if (dryRun) {
      return {
        name: `stale pending runs (>${PIPELINE_TIMEOUTS.staleRunHours}h)`,
        status: "warn",
        message: `${staleRuns.length} stale pending run(s). Would mark failed (dry-run).`,
      };
    }

    if (fix) {
      for (const run of staleRuns) {
        this.store.updateRun(run.id, {
          status: "failed",
          completed_at: new Date().toISOString(),
        });
      }
      return {
        name: `stale pending runs (>${PIPELINE_TIMEOUTS.staleRunHours}h)`,
        status: "fixed",
        message: `${staleRuns.length} stale pending run(s)`,
        fixApplied: `Marked ${staleRuns.length} run(s) as failed`,
      };
    }

    return {
      name: `stale pending runs (>${PIPELINE_TIMEOUTS.staleRunHours}h)`,
      status: "warn",
      message: `${staleRuns.length} pending run(s) older than ${PIPELINE_TIMEOUTS.staleRunHours}h. Use --fix to mark failed.`,
    };
  }

  async checkFailedStuckRuns(): Promise<CheckResult[]> {
    const project = this.store.getProjectByPath(this.projectPath);
    if (!project) return [];

    const results: CheckResult[] = [];

    const failedRuns = this.store.getRunsByStatus("failed", project.id);
    if (failedRuns.length > 0) {
      results.push({
        name: `failed runs`,
        status: "warn",
        message: `${failedRuns.length} failed run(s): ${failedRuns.slice(0, 5).map((r) => r.seed_id).join(", ")}${failedRuns.length > 5 ? "..." : ""}. Use 'foreman reset' to retry.`,
      });
    }

    const stuckRuns = this.store.getRunsByStatus("stuck", project.id);
    if (stuckRuns.length > 0) {
      results.push({
        name: `stuck runs`,
        status: "warn",
        message: `${stuckRuns.length} stuck run(s): ${stuckRuns.slice(0, 5).map((r) => r.seed_id).join(", ")}${stuckRuns.length > 5 ? "..." : ""}. Use 'foreman reset' to retry or 'foreman run --resume' to continue.`,
      });
    }

    if (failedRuns.length === 0 && stuckRuns.length === 0) {
      results.push({
        name: "failed/stuck runs",
        status: "pass",
        message: "No failed or stuck runs",
      });
    }

    return results;
  }

  async checkRunStateConsistency(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult[]> {
    const { fix = false, dryRun = false } = opts;
    const project = this.store.getProjectByPath(this.projectPath);
    if (!project) return [];

    const results: CheckResult[] = [];

    // Check for runs with completed_at set but still in running/pending status
    const activeRuns = this.store.getActiveRuns(project.id);
    const inconsistentRuns = activeRuns.filter((r) => r.completed_at !== null);

    if (inconsistentRuns.length === 0) {
      results.push({
        name: "run state consistency",
        status: "pass",
        message: "All run states are consistent",
      });
    } else {
      for (const run of inconsistentRuns) {
        if (dryRun) {
          results.push({
            name: `run state: ${run.seed_id} [${run.agent_type}]`,
            status: "warn",
            message: `Run has completed_at set but status="${run.status}". Would mark as failed (dry-run).`,
          });
        } else if (fix) {
          this.store.updateRun(run.id, { status: "failed" });
          results.push({
            name: `run state: ${run.seed_id} [${run.agent_type}]`,
            status: "fixed",
            message: `Inconsistent state: completed_at set but status was "${run.status}"`,
            fixApplied: "Marked as failed",
          });
        } else {
          results.push({
            name: `run state: ${run.seed_id} [${run.agent_type}]`,
            status: "warn",
            message: `Inconsistent run state: completed_at set but status="${run.status}". Use --fix to repair.`,
          });
        }
      }
    }

    return results;
  }

  async checkBrRecoveryArtifacts(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult> {
    const { fix = false, dryRun = false } = opts;

    // br doctor --repair creates .br_recovery/ at the project root as a sibling to .beads/
    // It should be removed after successful recovery; stale artifacts indicate incomplete recovery.
    // NOTE: verify this path matches beads_rust behavior — it may also appear at .beads/.br_recovery/
    const recoveryPath = join(this.projectPath, ".br_recovery");
    try {
      await stat(recoveryPath);
      // Directory exists — stale recovery artifacts
      // dryRun takes precedence over fix
      if (dryRun) {
        return {
          name: "br recovery artifacts (.br_recovery/)",
          status: "warn",
          message: `.br_recovery/ directory exists — stale artifacts from incomplete recovery. Would remove (dry-run).`,
        };
      }
      if (fix) {
        try {
          await rm(recoveryPath, { recursive: true, force: true });
          return {
            name: "br recovery artifacts (.br_recovery/)",
            status: "fixed",
            message: "Stale .br_recovery/ directory from incomplete recovery",
            fixApplied: `Removed ${recoveryPath}`,
          };
        } catch (err: unknown) {
          const msg = err instanceof Error ? err.message : String(err);
          return {
            name: "br recovery artifacts (.br_recovery/)",
            status: "warn",
            message: `.br_recovery/ exists but could not auto-remove: ${msg}`,
          };
        }
      }
      return {
        name: "br recovery artifacts (.br_recovery/)",
        status: "warn",
        message: `.br_recovery/ directory exists — stale artifacts detected. If recovery completed successfully, use --fix to remove stale artifacts; otherwise run 'br doctor --repair' to retry.`,
      };
    } catch {
      // Directory does not exist — no stale artifacts
      return {
        name: "br recovery artifacts (.br_recovery/)",
        status: "pass",
        message: "No stale recovery artifacts found",
      };
    }
  }

  async checkBlockedSeeds(): Promise<CheckResult> {
    if (!this.taskClient) {
      return {
        name: "blocked seeds",
        status: "skip",
        message: "No task client configured",
      };
    }

    let openSeeds: Awaited<ReturnType<typeof this.taskClient.list>>;
    let readySeeds: Awaited<ReturnType<typeof this.taskClient.ready>>;
    try {
      [openSeeds, readySeeds] = await Promise.all([
        this.taskClient.list({ status: "open" }),
        this.taskClient.ready(),
      ]);
    } catch {
      return {
        name: "blocked seeds",
        status: "warn",
        message: "Could not list seeds (skipping check)",
      };
    }

    const readyIds = new Set(readySeeds.map((s) => s.id));
    const blockedSeeds = openSeeds.filter((s) => !readyIds.has(s.id));

    if (blockedSeeds.length === 0) {
      return {
        name: "blocked seeds",
        status: "pass",
        message: "No blocked seeds",
      };
    }

    const list = blockedSeeds.map((s) => `${s.id} (${s.title})`).join(", ");
    return {
      name: "blocked seeds",
      status: "warn",
      message: `${blockedSeeds.length} blocked seed(s): ${list}`,
    };
  }

  // ── Merge queue checks ──────────────────────────────────────────────

  /**
   * Check for merge queue entries stuck in pending/merging for >24h (MQ-008).
   */
  async checkStaleMergeQueueEntries(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult> {
    const { fix = false, dryRun = false } = opts;

    if (!this.mergeQueue) {
      return { name: "stale merge queue entries", status: "pass", message: "No merge queue configured (skipping)" };
    }

    const allEntries = this.mergeQueue.list();
    const staleThresholdMs = 24 * 60 * 60 * 1000;
    const now = Date.now();

    const staleEntries = allEntries.filter((e) => {
      if (e.status !== "pending" && e.status !== "merging") return false;
      const timestamp = e.status === "merging" && e.started_at
        ? new Date(e.started_at).getTime()
        : new Date(e.enqueued_at).getTime();
      return now - timestamp > staleThresholdMs;
    });

    if (staleEntries.length === 0) {
      return { name: "stale merge queue entries (>24h)", status: "pass", message: `No stale entries` };
    }

    if (dryRun) {
      return {
        name: "stale merge queue entries (>24h)",
        status: "warn",
        message: `MQ-008: ${staleEntries.length} stale entry(ies). Would mark failed (dry-run).`,
      };
    }

    if (fix) {
      for (const entry of staleEntries) {
        this.mergeQueue.updateStatus(entry.id, "failed", {
          error: "MQ-008: Stale entry auto-failed by doctor",
          completedAt: new Date().toISOString(),
        });
      }
      return {
        name: "stale merge queue entries (>24h)",
        status: "fixed",
        message: `MQ-008: ${staleEntries.length} stale entry(ies)`,
        fixApplied: `Marked ${staleEntries.length} entry(ies) as failed`,
      };
    }

    return {
      name: "stale merge queue entries (>24h)",
      status: "warn",
      message: `MQ-008: ${staleEntries.length} stale entry(ies) in pending/merging >24h. Use --fix to mark failed.`,
    };
  }

  /**
   * Check for duplicate branch entries in the merge queue (MQ-009).
   */
  async checkDuplicateMergeQueueEntries(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult> {
    const { fix = false, dryRun = false } = opts;

    if (!this.mergeQueue) {
      return { name: "duplicate merge queue entries", status: "pass", message: "No merge queue configured (skipping)" };
    }

    const pending = this.mergeQueue.list("pending");
    const branchCounts = new Map<string, MergeQueueEntry[]>();
    for (const entry of pending) {
      const existing = branchCounts.get(entry.branch_name) ?? [];
      existing.push(entry);
      branchCounts.set(entry.branch_name, existing);
    }

    const duplicates = Array.from(branchCounts.entries()).filter(
      ([, entries]) => entries.length > 1,
    );

    if (duplicates.length === 0) {
      return { name: "duplicate merge queue entries", status: "pass", message: "No duplicate branch entries" };
    }

    const dupBranches = duplicates.map(([branch]) => branch).join(", ");

    if (dryRun) {
      return {
        name: "duplicate merge queue entries",
        status: "warn",
        message: `MQ-009: Duplicate entries for: ${dupBranches}. Would remove duplicates (dry-run).`,
      };
    }

    if (fix) {
      let removed = 0;
      for (const [, entries] of duplicates) {
        // Keep max(id), remove others
        const maxId = Math.max(...entries.map((e) => e.id));
        for (const entry of entries) {
          if (entry.id !== maxId) {
            this.mergeQueue.remove(entry.id);
            removed++;
          }
        }
      }
      return {
        name: "duplicate merge queue entries",
        status: "fixed",
        message: `MQ-009: Duplicate entries for: ${dupBranches}`,
        fixApplied: `Removed ${removed} duplicate entry(ies), kept latest`,
      };
    }

    return {
      name: "duplicate merge queue entries",
      status: "warn",
      message: `MQ-009: Duplicate entries for: ${dupBranches}. Use --fix to remove duplicates.`,
    };
  }

  /**
   * Check for merge queue entries referencing non-existent runs (MQ-010).
   */
  async checkOrphanedMergeQueueEntries(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult> {
    const { fix = false, dryRun = false } = opts;

    if (!this.mergeQueue) {
      return { name: "orphaned merge queue entries", status: "pass", message: "No merge queue configured (skipping)" };
    }

    const allEntries = this.mergeQueue.list();
    const orphaned = allEntries.filter((e) => !this.store.getRun(e.run_id));

    if (orphaned.length === 0) {
      return { name: "orphaned merge queue entries", status: "pass", message: "All entries reference existing runs" };
    }

    if (dryRun) {
      return {
        name: "orphaned merge queue entries",
        status: "warn",
        message: `MQ-010: ${orphaned.length} orphaned entry(ies). Would delete (dry-run).`,
      };
    }

    if (fix) {
      for (const entry of orphaned) {
        this.mergeQueue.remove(entry.id);
      }
      return {
        name: "orphaned merge queue entries",
        status: "fixed",
        message: `MQ-010: ${orphaned.length} orphaned entry(ies)`,
        fixApplied: `Deleted ${orphaned.length} entry(ies)`,
      };
    }

    return {
      name: "orphaned merge queue entries",
      status: "warn",
      message: `MQ-010: ${orphaned.length} orphaned entry(ies) referencing non-existent runs. Use --fix to delete.`,
    };
  }

  /**
   * Check for completed runs that are not present in the merge queue (MQ-011).
   * Detects runs that completed but were never enqueued — e.g. because their
   * branch was deleted before reconciliation ran, or because a system crash
   * prevented reconciliation from completing.
   */
  async checkCompletedRunsNotQueued(): Promise<CheckResult> {
    if (!this.mergeQueue) {
      return {
        name: "completed runs queued",
        status: "skip",
        message: "No merge queue configured (skipping)",
      };
    }

    const missing = this.mergeQueue.missingFromQueue();

    if (missing.length === 0) {
      return {
        name: "completed runs queued",
        status: "pass",
        message: "All completed runs are in the merge queue",
      };
    }

    const details = missing.map((r) => `${r.seed_id} (run ${r.run_id})`).join(", ");
    return {
      name: "completed runs queued",
      status: "warn",
      message: `MQ-011: ${missing.length} completed run(s) not in merge queue. Run: foreman merge`,
      details,
    };
  }

  /**
   * Run all merge queue health checks.
   */
  async checkMergeQueueHealth(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult[]> {
    const [stale, duplicates, orphaned, notQueued] = await Promise.all([
      this.checkStaleMergeQueueEntries(opts),
      this.checkDuplicateMergeQueueEntries(opts),
      this.checkOrphanedMergeQueueEntries(opts),
      this.checkCompletedRunsNotQueued(),
    ]);
    return [stale, duplicates, orphaned, notQueued];
  }

  // ── Session Management checks ─────────────────────────────────────

  /**
   * Check if tmux is available and at a supported version (>= 3.0).
   */
  async checkTmuxAvailability(): Promise<CheckResult> {
    if (!this.tmux) {
      return { name: "tmux availability", status: "skip", message: "No tmux client configured" };
    }

    const available = await this.tmux.isAvailable();
    if (!available) {
      return { name: "tmux availability", status: "warn", message: "tmux is not available on this system" };
    }

    const version = await this.tmux.getTmuxVersion();
    if (!version) {
      return { name: "tmux availability", status: "warn", message: "tmux available but version could not be determined" };
    }

    // Parse major version for >= 3.0 check
    const majorMatch = version.match(/^(\d+)/);
    const major = majorMatch ? parseInt(majorMatch[1], 10) : 0;
    if (major < 3) {
      return {
        name: "tmux availability",
        status: "warn",
        message: `tmux version ${version} detected; version >= 3.0 recommended`,
      };
    }

    return { name: "tmux availability", status: "pass", message: `tmux version ${version}` };
  }

  /**
   * Detect orphaned tmux sessions: foreman-* sessions with no matching active run.
   */
  async checkOrphanedTmuxSessions(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult[]> {
    const { fix = false, dryRun = false } = opts;

    if (!this.tmux) {
      return [{ name: "orphaned tmux sessions", status: "skip", message: "No tmux client configured" }];
    }

    const sessions = await this.tmux.listForemanSessions();
    if (sessions.length === 0) {
      return [{ name: "orphaned tmux sessions", status: "pass", message: "No foreman tmux sessions found" }];
    }

    const project = this.store.getProjectByPath(this.projectPath);
    const activeRuns = project ? this.store.getActiveRuns(project.id) : [];
    const activeTmuxSessions = new Set(
      activeRuns
        .filter((r) => r.tmux_session !== null)
        .map((r) => r.tmux_session),
    );

    const results: CheckResult[] = [];
    for (const session of sessions) {
      if (activeTmuxSessions.has(session.sessionName)) {
        results.push({
          name: `tmux session: ${session.sessionName}`,
          status: "pass",
          message: `Active run matches session`,
        });
      } else {
        if (dryRun) {
          results.push({
            name: `tmux session: ${session.sessionName}`,
            status: "warn",
            message: `Orphaned tmux session (no matching active run). Would kill (dry-run).`,
          });
        } else if (fix) {
          await this.tmux.killSession(session.sessionName);
          results.push({
            name: `tmux session: ${session.sessionName}`,
            status: "fixed",
            message: `Orphaned tmux session (no matching active run)`,
            fixApplied: `Killed orphaned tmux session ${session.sessionName}`,
          });
        } else {
          results.push({
            name: `tmux session: ${session.sessionName}`,
            status: "warn",
            message: `Orphaned tmux session (no matching active run). Use --fix to kill.`,
          });
        }
      }
    }

    return results;
  }

  /**
   * Detect ghost runs: active runs with tmux_session where hasSession() returns false.
   */
  async checkGhostRuns(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult[]> {
    const { fix = false, dryRun = false } = opts;

    if (!this.tmux) {
      return [{ name: "ghost runs", status: "skip", message: "No tmux client configured" }];
    }

    const project = this.store.getProjectByPath(this.projectPath);
    const activeRuns = project ? this.store.getActiveRuns(project.id) : [];
    const tmuxRuns = activeRuns.filter((r) => r.tmux_session !== null);

    if (tmuxRuns.length === 0) {
      return [{ name: "ghost runs", status: "pass", message: "No active runs with tmux sessions" }];
    }

    const results: CheckResult[] = [];
    let ghostCount = 0;

    for (const run of tmuxRuns) {
      const alive = await this.tmux.hasSession(run.tmux_session!);
      if (alive) continue;

      ghostCount++;
      if (dryRun) {
        results.push({
          name: `ghost run: ${run.seed_id}`,
          status: "warn",
          message: `Ghost run — tmux session ${run.tmux_session} is dead. Would mark stuck (dry-run).`,
        });
      } else if (fix) {
        this.store.updateRun(run.id, { status: "stuck" });
        results.push({
          name: `ghost run: ${run.seed_id}`,
          status: "fixed",
          message: `Ghost run — tmux session ${run.tmux_session} is dead`,
          fixApplied: `Marked ghost run ${run.seed_id} as stuck`,
        });
      } else {
        results.push({
          name: `ghost run: ${run.seed_id}`,
          status: "warn",
          message: `Ghost run — tmux session ${run.tmux_session} is dead. Use --fix to mark stuck.`,
        });
      }
    }

    if (ghostCount === 0) {
      results.push({
        name: "ghost runs",
        status: "pass",
        message: "All tmux sessions are alive",
      });
    }

    return results;
  }

  /**
   * Run all session management checks (tmux availability, orphans, ghosts).
   */
  async checkSessionManagement(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult[]> {
    if (!this.tmux) {
      return [{ name: "session management", status: "skip", message: "No tmux client configured" }];
    }

    const [availability, orphans, ghosts] = await Promise.all([
      this.checkTmuxAvailability(),
      this.checkOrphanedTmuxSessions(opts),
      this.checkGhostRuns(opts),
    ]);

    return [availability, ...orphans, ...ghosts];
  }

  async checkDataIntegrity(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult[]> {
    const results: CheckResult[] = [];

    const [worktreeResults, zombieResults, staleResult, failedStuckResults, consistencyResults, blockedResult, recoveryResult] =
      await Promise.all([
        this.checkOrphanedWorktrees(opts),
        this.checkZombieRuns(opts),
        this.checkStalePendingRuns(opts),
        this.checkFailedStuckRuns(),
        this.checkRunStateConsistency(opts),
        this.checkBlockedSeeds(),
        this.checkBrRecoveryArtifacts(opts),
      ]);

    results.push(...worktreeResults, ...zombieResults, staleResult, ...failedStuckResults, ...consistencyResults, blockedResult, recoveryResult);

    // Merge queue checks (only when merge queue is configured)
    if (this.mergeQueue) {
      const mqResults = await this.checkMergeQueueHealth(opts);
      results.push(...mqResults);
    }

    // Session management checks (only when tmux client is configured)
    if (this.tmux) {
      const sessionResults = await this.checkSessionManagement(opts);
      results.push(...sessionResults);
    }

    return results;
  }

  async runAll(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<DoctorReport> {
    const [system, repository, dataIntegrity] = await Promise.all([
      this.checkSystem(),
      this.checkRepository(),
      this.checkDataIntegrity(opts),
    ]);

    const all = [...system, ...repository, ...dataIntegrity];
    const summary = {
      pass: all.filter((r) => r.status === "pass").length,
      warn: all.filter((r) => r.status === "warn").length,
      fail: all.filter((r) => r.status === "fail").length,
      fixed: all.filter((r) => r.status === "fixed").length,
      skip: all.filter((r) => r.status === "skip").length,
    };

    return { system, repository, dataIntegrity, summary };
  }
}
