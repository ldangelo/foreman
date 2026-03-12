import { access, stat } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

import type { ForemanStore } from "../lib/store.js";
import { listWorktrees, removeWorktree } from "../lib/git.js";
import type { CheckResult, DoctorReport } from "./types.js";
import { PIPELINE_TIMEOUTS } from "../lib/config.js";

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

// ── Doctor class ─────────────────────────────────────────────────────────

export class Doctor {
  constructor(
    private store: ForemanStore,
    private projectPath: string,
  ) {}

  // ── System checks ──────────────────────────────────────────────────

  async checkSdBinary(): Promise<CheckResult> {
    const sdPath = join(homedir(), ".bun", "bin", "sd");
    try {
      await access(sdPath);
      return {
        name: "sd (seeds) CLI binary",
        status: "pass",
        message: `Found at ${sdPath}`,
      };
    } catch {
      return {
        name: "sd (seeds) CLI binary",
        status: "fail",
        message: `Not found at ${sdPath}. Install via: bun install -g @os-eco/seeds-cli`,
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
    const [sdResult, gitResult] = await Promise.all([
      this.checkSdBinary(),
      this.checkGitBinary(),
    ]);
    return [sdResult, gitResult];
  }

  // ── Repository checks ──────────────────────────────────────────────

  async checkDatabaseFile(): Promise<CheckResult> {
    const dbPath = join(homedir(), ".foreman", "foreman.db");
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

  async checkSeedsInitialized(): Promise<CheckResult> {
    const seedsDir = join(this.projectPath, ".seeds");
    if (existsSync(seedsDir)) {
      return {
        name: "seeds (.seeds/) initialized",
        status: "pass",
        message: ".seeds directory found",
      };
    }
    return {
      name: "seeds (.seeds/) initialized",
      status: "fail",
      message: `No .seeds directory at ${seedsDir}. Run 'foreman init' first.`,
    };
  }

  async checkRepository(): Promise<CheckResult[]> {
    const results: CheckResult[] = [];
    results.push(await this.checkDatabaseFile());
    results.push(await this.checkProjectRegistered());
    results.push(await this.checkSeedsInitialized());
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
      const activeRun = runs.find((r: any) =>
        ["pending", "running"].includes(r.status) && r.worktree_path === wt.path,
      );
      const completedRun = runs.find((r: any) => r.status === "completed");
      const mergedRun = runs.find((r: any) => r.status === "merged");

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
      } else {
        if (dryRun) {
          results.push({
            name: `worktree: ${seedId}`,
            status: "warn",
            message: `Orphaned worktree at ${wt.path} (no runs). Would remove (dry-run).`,
          });
        } else if (fix) {
          try {
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

  async checkBlockedSeeds(): Promise<CheckResult> {
    const sdPath = join(homedir(), ".bun", "bin", "sd");
    try {
      const { stdout } = await execFileAsync(sdPath, ["blocked", "--json"], {
        cwd: this.projectPath,
      });
      const parsed = JSON.parse(stdout);
      const blocked = (parsed.issues ?? parsed ?? []) as Array<{ id: string; title: string }>;
      if (blocked.length === 0) {
        return {
          name: "blocked seeds",
          status: "pass",
          message: "No blocked seeds",
        };
      }
      return {
        name: "blocked seeds",
        status: "warn",
        message: `${blocked.length} blocked: ${blocked.slice(0, 5).map((b) => b.id).join(", ")}${blocked.length > 5 ? "..." : ""}. Check deps with 'sd show <id>'.`,
      };
    } catch {
      return {
        name: "blocked seeds",
        status: "pass",
        message: "No blocked seeds (or sd blocked unavailable)",
      };
    }
  }

  async checkDataIntegrity(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult[]> {
    const results: CheckResult[] = [];

    const [worktreeResults, zombieResults, staleResult, failedStuckResults, consistencyResults, blockedResult] =
      await Promise.all([
        this.checkOrphanedWorktrees(opts),
        this.checkZombieRuns(opts),
        this.checkStalePendingRuns(opts),
        this.checkFailedStuckRuns(),
        this.checkRunStateConsistency(opts),
        this.checkBlockedSeeds(),
      ]);

    results.push(...worktreeResults, ...zombieResults, staleResult, ...failedStuckResults, ...consistencyResults, blockedResult);
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
