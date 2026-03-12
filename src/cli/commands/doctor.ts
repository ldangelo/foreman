import { Command } from "commander";
import chalk from "chalk";
import { access, stat } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { execFile, execFileSync } from "node:child_process";
import { promisify } from "node:util";

import { ForemanStore } from "../../lib/store.js";
import { getRepoRoot, listWorktrees, removeWorktree } from "../../lib/git.js";

const execFileAsync = promisify(execFile);

// ── Types ────────────────────────────────────────────────────────────────

type CheckStatus = "pass" | "warn" | "fail" | "fixed";

interface CheckResult {
  name: string;
  status: CheckStatus;
  message: string;
  fixApplied?: string;
}

// ── Helpers ──────────────────────────────────────────────────────────────

function icon(status: CheckStatus): string {
  switch (status) {
    case "pass":  return chalk.green("✓");
    case "warn":  return chalk.yellow("⚠");
    case "fail":  return chalk.red("✗");
    case "fixed": return chalk.cyan("⚙");
  }
}

function label(status: CheckStatus): string {
  switch (status) {
    case "pass":  return chalk.green("pass");
    case "warn":  return chalk.yellow("warn");
    case "fail":  return chalk.red("fail");
    case "fixed": return chalk.cyan("fixed");
  }
}

function printCheck(result: CheckResult): void {
  const pad = 40;
  const nameCol = result.name.padEnd(pad);
  console.log(`  ${icon(result.status)} ${nameCol} ${label(result.status)}`);
  if (result.status !== "pass") {
    console.log(`      ${chalk.dim(result.message)}`);
  }
  if (result.fixApplied) {
    console.log(`      ${chalk.cyan("→ " + result.fixApplied)}`);
  }
}

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

// ── Individual checks ────────────────────────────────────────────────────

async function checkSdBinary(): Promise<CheckResult> {
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

async function checkGitBinary(): Promise<CheckResult> {
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

async function checkGitRepo(cwd: string): Promise<{ result: CheckResult; projectPath: string | null }> {
  try {
    const projectPath = await getRepoRoot(cwd);
    return {
      result: {
        name: "git repository",
        status: "pass",
        message: `Root: ${projectPath}`,
      },
      projectPath,
    };
  } catch {
    return {
      result: {
        name: "git repository",
        status: "fail",
        message: "Not inside a git repository. Run from your project directory.",
      },
      projectPath: null,
    };
  }
}

async function checkProjectRegistered(projectPath: string, store: ForemanStore): Promise<CheckResult> {
  const project = store.getProjectByPath(projectPath);
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
    message: `No project registered for ${projectPath}. Run 'foreman init' first.`,
  };
}

async function checkSeedsInitialized(projectPath: string): Promise<CheckResult> {
  const seedsDir = join(projectPath, ".seeds");
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

async function checkDatabaseFile(): Promise<CheckResult> {
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

async function checkOrphanedWorktrees(
  projectPath: string,
  store: ForemanStore,
  fix: boolean,
): Promise<CheckResult[]> {
  const results: CheckResult[] = [];

  let worktrees;
  try {
    worktrees = await listWorktrees(projectPath);
  } catch {
    results.push({
      name: "orphaned worktrees",
      status: "warn",
      message: "Could not list worktrees (skipping check)",
    });
    return results;
  }

  // Filter to foreman-managed worktrees (foreman/* branches)
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
    // Extract bead ID from branch name: foreman/<beadId>
    const beadId = wt.branch.replace("foreman/", "");

    // Check run status for this worktree
    const runs = store.getRunsForBead(beadId);
    const activeRun = runs.find((r) =>
      ["pending", "running"].includes(r.status) && r.worktree_path === wt.path,
    );
    const completedRun = runs.find((r) => r.status === "completed");
    const mergedRun = runs.find((r) => r.status === "merged");

    if (activeRun) {
      // Worktree has an active run — healthy
      results.push({
        name: `worktree: ${beadId}`,
        status: "pass",
        message: `Active run (${activeRun.status}) for bead ${beadId}`,
      });
    } else if (mergedRun) {
      // Already merged — safe to clean up
      if (fix) {
        try {
          await removeWorktree(projectPath, wt.path);
          try { await execFileAsync("git", ["worktree", "prune"], { cwd: projectPath }); } catch { /* */ }
          results.push({
            name: `worktree: ${beadId}`,
            status: "fixed",
            message: `Already merged — stale worktree`,
            fixApplied: `Removed worktree at ${wt.path}`,
          });
        } catch (err: unknown) {
          const msg = err instanceof Error ? err.message : String(err);
          results.push({
            name: `worktree: ${beadId}`,
            status: "warn",
            message: `Already merged but could not auto-remove: ${msg}`,
          });
        }
      } else {
        results.push({
          name: `worktree: ${beadId}`,
          status: "warn",
          message: `Already merged — stale worktree. Use --fix to remove.`,
        });
      }
    } else if (completedRun) {
      // Completed but not merged — needs merge, do NOT delete
      results.push({
        name: `worktree: ${beadId}`,
        status: "warn",
        message: `Needs merge. Run: foreman merge --bead ${beadId}`,
      });
    } else {
      // No active, completed, or merged run — truly orphaned
      if (fix) {
        try {
          await removeWorktree(projectPath, wt.path);
          try { await execFileAsync("git", ["worktree", "prune"], { cwd: projectPath }); } catch { /* */ }
          results.push({
            name: `worktree: ${beadId}`,
            status: "fixed",
            message: `Orphaned worktree (no runs)`,
            fixApplied: `Removed worktree at ${wt.path}`,
          });
        } catch (err: unknown) {
          const msg = err instanceof Error ? err.message : String(err);
          results.push({
            name: `worktree: ${beadId}`,
            status: "warn",
            message: `Orphaned worktree — could not auto-remove: ${msg}`,
          });
        }
      } else {
        results.push({
          name: `worktree: ${beadId}`,
          status: "warn",
          message: `Orphaned worktree at ${wt.path} (no runs). Use --fix to remove.`,
        });
      }
    }
  }

  return results;
}

async function checkZombieRuns(
  projectPath: string,
  store: ForemanStore,
  fix: boolean,
): Promise<CheckResult[]> {
  const project = store.getProjectByPath(projectPath);
  if (!project) return [];

  const runningRuns = store.getRunsByStatus("running", project.id);
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
        name: `run: ${run.bead_id} [${run.agent_type}]`,
        status: "pass",
        message: `Process pid ${pid} is alive`,
      });
    } else {
      if (fix) {
        store.updateRun(run.id, {
          status: "failed",
          completed_at: new Date().toISOString(),
        });
        results.push({
          name: `run: ${run.bead_id} [${run.agent_type}]`,
          status: "fixed",
          message: `Zombie run (status=running, no live process${pid ? ` for pid ${pid}` : ""})`,
          fixApplied: "Marked as failed",
        });
      } else {
        results.push({
          name: `run: ${run.bead_id} [${run.agent_type}]`,
          status: "warn",
          message: `Zombie run: status=running but no live process${pid ? ` (pid ${pid})` : ""}. Use --fix to mark failed.`,
        });
      }
    }
  }

  return results;
}

async function checkStalePendingRuns(
  projectPath: string,
  store: ForemanStore,
  fix: boolean,
): Promise<CheckResult> {
  const project = store.getProjectByPath(projectPath);
  if (!project) {
    return {
      name: "stale pending runs",
      status: "pass",
      message: "No project registered (skipping)",
    };
  }

  const pendingRuns = store.getRunsByStatus("pending", project.id);
  const staleThresholdMs = 24 * 60 * 60 * 1000; // 24 hours
  const now = Date.now();

  const staleRuns = pendingRuns.filter((r) => {
    const age = now - new Date(r.created_at).getTime();
    return age > staleThresholdMs;
  });

  if (staleRuns.length === 0) {
    return {
      name: "stale pending runs (>24h)",
      status: "pass",
      message: `${pendingRuns.length} pending run(s), none older than 24h`,
    };
  }

  if (fix) {
    for (const run of staleRuns) {
      store.updateRun(run.id, {
        status: "failed",
        completed_at: new Date().toISOString(),
      });
    }
    return {
      name: "stale pending runs (>24h)",
      status: "fixed",
      message: `${staleRuns.length} stale pending run(s)`,
      fixApplied: `Marked ${staleRuns.length} run(s) as failed`,
    };
  }

  return {
    name: "stale pending runs (>24h)",
    status: "warn",
    message: `${staleRuns.length} pending run(s) older than 24h. Use --fix to mark failed.`,
  };
}

async function checkFailedStuckRuns(
  projectPath: string,
  store: ForemanStore,
): Promise<CheckResult[]> {
  const project = store.getProjectByPath(projectPath);
  if (!project) return [];

  const results: CheckResult[] = [];

  const failedRuns = store.getRunsByStatus("failed", project.id);
  if (failedRuns.length > 0) {
    results.push({
      name: `failed runs`,
      status: "warn",
      message: `${failedRuns.length} failed run(s): ${failedRuns.slice(0, 5).map((r) => r.bead_id).join(", ")}${failedRuns.length > 5 ? "..." : ""}. Use 'foreman reset' to retry.`,
    });
  }

  const stuckRuns = store.getRunsByStatus("stuck", project.id);
  if (stuckRuns.length > 0) {
    results.push({
      name: `stuck runs`,
      status: "warn",
      message: `${stuckRuns.length} stuck run(s): ${stuckRuns.slice(0, 5).map((r) => r.bead_id).join(", ")}${stuckRuns.length > 5 ? "..." : ""}. Use 'foreman reset' to retry or 'foreman run --resume' to continue.`,
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

async function checkBlockedSeeds(
  projectPath: string,
): Promise<CheckResult> {
  const sdPath = join(homedir(), ".bun", "bin", "sd");
  try {
    const output = execFileSync(sdPath, ["blocked", "--json"], {
      cwd: projectPath,
      stdio: ["pipe", "pipe", "pipe"],
      encoding: "utf-8",
    });
    const parsed = JSON.parse(output);
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

// ── Command ──────────────────────────────────────────────────────────────

export const doctorCommand = new Command("doctor")
  .description("Check foreman installation and project health, with optional auto-fix")
  .option("--fix", "Auto-fix issues where possible")
  .option("--json", "Output results as JSON")
  .action(async (opts) => {
    const fix = opts.fix as boolean | undefined;
    const jsonOutput = opts.json as boolean | undefined;

    const allResults: CheckResult[] = [];

    if (!jsonOutput) {
      console.log(chalk.bold("\nforeman doctor\n"));
    }

    // ── System checks ───────────────────────────────────────────────────
    if (!jsonOutput) {
      console.log(chalk.bold("System:"));
    }

    const [sdResult, gitResult] = await Promise.all([
      checkSdBinary(),
      checkGitBinary(),
    ]);
    allResults.push(sdResult, gitResult);

    if (!jsonOutput) {
      printCheck(sdResult);
      printCheck(gitResult);
      console.log();
    }

    // ── Repository checks ────────────────────────────────────────────────
    if (!jsonOutput) {
      console.log(chalk.bold("Repository:"));
    }

    const { result: repoResult, projectPath } = await checkGitRepo(process.cwd());
    allResults.push(repoResult);
    if (!jsonOutput) printCheck(repoResult);

    const dbFileResult = await checkDatabaseFile();
    allResults.push(dbFileResult);
    if (!jsonOutput) printCheck(dbFileResult);

    let store: ForemanStore | null = null;
    try {
      store = new ForemanStore();

      if (projectPath) {
        const registeredResult = await checkProjectRegistered(projectPath, store);
        allResults.push(registeredResult);
        if (!jsonOutput) printCheck(registeredResult);

        const seedsResult = await checkSeedsInitialized(projectPath);
        allResults.push(seedsResult);
        if (!jsonOutput) printCheck(seedsResult);
      }
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      allResults.push({
        name: "foreman store",
        status: "fail",
        message: `Could not open database: ${msg}`,
      });
      if (!jsonOutput) printCheck(allResults[allResults.length - 1]);
    }

    if (!jsonOutput) console.log();

    // ── Data integrity checks ────────────────────────────────────────────
    if (store && projectPath) {
      if (!jsonOutput) {
        console.log(chalk.bold("Data integrity:"));
      }

      const worktreeResults = await checkOrphanedWorktrees(projectPath, store, fix ?? false);
      const zombieResults = await checkZombieRuns(projectPath, store, fix ?? false);
      const staleResult = await checkStalePendingRuns(projectPath, store, fix ?? false);
      const failedStuckResults = await checkFailedStuckRuns(projectPath, store);
      const blockedResult = await checkBlockedSeeds(projectPath);

      for (const r of [...worktreeResults, ...zombieResults, staleResult, ...failedStuckResults, blockedResult]) {
        allResults.push(r);
        if (!jsonOutput) printCheck(r);
      }

      if (!jsonOutput) console.log();
    }

    // ── Summary ──────────────────────────────────────────────────────────
    const counts = {
      pass: allResults.filter((r) => r.status === "pass").length,
      warn: allResults.filter((r) => r.status === "warn").length,
      fail: allResults.filter((r) => r.status === "fail").length,
      fixed: allResults.filter((r) => r.status === "fixed").length,
    };

    if (jsonOutput) {
      console.log(JSON.stringify({ checks: allResults, summary: counts }, null, 2));
    } else {
      const parts: string[] = [];
      if (counts.pass > 0)  parts.push(chalk.green(`${counts.pass} passed`));
      if (counts.fixed > 0) parts.push(chalk.cyan(`${counts.fixed} fixed`));
      if (counts.warn > 0)  parts.push(chalk.yellow(`${counts.warn} warning(s)`));
      if (counts.fail > 0)  parts.push(chalk.red(`${counts.fail} failed`));

      console.log(chalk.bold("Summary: ") + parts.join(chalk.dim(", ")));

      if (counts.warn > 0 || counts.fail > 0) {
        if (!fix) {
          console.log(chalk.dim("\nRe-run with --fix to auto-resolve fixable issues."));
        }
      }

      if (counts.fail > 0) {
        console.log();
      }
    }

    if (store) store.close();

    // Exit with non-zero if there are failures
    if (counts.fail > 0) {
      process.exit(1);
    }
  });
