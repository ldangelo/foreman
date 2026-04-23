import { Command } from "commander";
import chalk from "chalk";
import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, rmSync, statSync, unlinkSync } from "node:fs";
import { join, basename } from "node:path";
import { homedir } from "node:os";

// ── Constants ─────────────────────────────────────────────────────────

const FOREMAN_TMP_DIR = join(homedir(), ".foreman", "tmp");
const FOREMAN_WORKTREES_DIR = join(homedir(), ".foreman-worktrees");
const SYSTEM_TMPDIR = process.env.TMPDIR ?? "/tmp";

// Patterns for orphaned directories and processes
const TEMP_DIR_PATTERNS = [
  "foreman-test-home-",
  "foreman-no-br-home-",
  "foreman-attach-test-",
  "foreman-task-project-test-",
  "foreman-e2e-project-",
  "foreman-retry-test-",
  "foreman-follow-test-",
  "foreman-inbox-test-",
  "foreman-doctor-br-",
  "foreman-doctor-bv-",
  "foreman-doctor-system-",
  "foreman-doctor-recovery-",
  "foreman-pack-",
  "foreman-dashboard-bench-",
];

// ── Types ─────────────────────────────────────────────────────────────

export interface PurgeZombiesOpts {
  processes?: boolean;
  tempDirs?: boolean;
  worktrees?: boolean;
  dryRun?: boolean;
  all?: boolean;
  ageMinutes?: number;
}

export interface PurgeZombiesResult {
  processesKilled: number;
  tempDirsRemoved: number;
  worktreesRemoved: number;
  errors: number;
  skipped: number;
  details: string[];
}

// ── Helpers ──────────────────────────────────────────────────────────

/**
 * Extract run info from a worker config file.
 */
interface WorkerConfig {
  runId?: string;
  seedId?: string;
  worktreePath?: string;
  createdAt?: string;
}

/**
 * Check if a process with the given PID is still running.
 */
function isProcessRunning(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/**
 * Kill a process by PID (SIGTERM first, then SIGKILL after delay).
 */
async function killProcess(pid: number, force: boolean = false): Promise<boolean> {
  const signal = force ? "SIGKILL" : "SIGTERM";
  try {
    process.kill(pid, signal as NodeJS.Signals);
    if (!force) {
      // Wait briefly for graceful shutdown
      await new Promise((resolve) => setTimeout(resolve, 2000));
      if (isProcessRunning(pid)) {
        // Force kill if still running
        process.kill(pid, "SIGKILL");
      }
    }
    return true;
  } catch {
    return false;
  }
}

/**
 * Get all running foreman worker PIDs.
 */
function getWorkerPids(): number[] {
  try {
    const output = execFileSync("ps", ["-axo", "pid,command"], {
      encoding: "utf-8",
      maxBuffer: 10 * 1024 * 1024,
    });

    const pids: number[] = [];
    const lines = output.split("\n");

    for (const line of lines) {
      // Match agent-worker processes
      if (line.includes("agent-worker")) {
        const match = line.trim().match(/^(\d+)/);
        if (match) {
          pids.push(parseInt(match[1], 10));
        }
      }
    }

    return pids;
  } catch {
    return [];
  }
}

/**
 * Get all orphaned temp directories matching our patterns.
 */
function getOrphanedTempDirs(ageMinutes?: number): string[] {
  const orphanedDirs: string[] = [];
  const dirsToCheck = [
    { path: SYSTEM_TMPDIR, pattern: TEMP_DIR_PATTERNS },
    { path: join(homedir(), ".foreman"), pattern: ["worktrees"] },
  ];

  const cutoffMs = ageMinutes ? Date.now() - ageMinutes * 60 * 1000 : 0;

  for (const { path: baseDir, pattern } of dirsToCheck) {
    if (!existsSync(baseDir)) continue;

    try {
      const entries = readdirSync(baseDir, { withFileTypes: true });

      for (const entry of entries) {
        if (!entry.isDirectory()) continue;

        const fullPath = join(baseDir, entry.name);
        const matches = pattern.some((p) => entry.name.startsWith(p));

        if (matches) {
          // Check age if specified
          if (cutoffMs > 0) {
            try {
              const stat = statSync(fullPath);
              if (stat.mtimeMs > cutoffMs) continue; // Too new
            } catch {
              continue;
            }
          }
          orphanedDirs.push(fullPath);
        }
      }
    } catch {
      // Skip on error
    }
  }

  return orphanedDirs;
}

/**
 * Get orphaned config files in ~/.foreman/tmp/ that have no corresponding running process.
 */
function getOrphanedConfigs(workerPids: number[]): string[] {
  if (!existsSync(FOREMAN_TMP_DIR)) return [];

  const orphanedConfigs: string[] = [];

  try {
    const files = readdirSync(FOREMAN_TMP_DIR);

    for (const file of files) {
      if (!file.startsWith("worker-") || !file.endsWith(".json")) continue;

      const configPath = join(FOREMAN_TMP_DIR, file);

      // Check if config is stale (older than 1 hour)
      try {
        const stat = statSync(configPath);
        const ageMs = Date.now() - stat.mtimeMs;
        const maxAge = 60 * 60 * 1000; // 1 hour

        if (ageMs > maxAge) {
          orphanedConfigs.push(configPath);
        }
      } catch {
        // File might have been deleted
      }
    }
  } catch {
    // Directory might not exist
  }

  return orphanedConfigs;
}

/**
 * Get orphaned worktrees (from ~/.foreman-worktrees).
 */
function getOrphanedWorktrees(): string[] {
  if (!existsSync(FOREMAN_WORKTREES_DIR)) return [];

  const orphaned: string[] = [];

  try {
    const entries = readdirSync(FOREMAN_WORKTREES_DIR, { withFileTypes: true });

    for (const entry of entries) {
      if (!entry.isDirectory()) continue;

      const worktreePath = join(FOREMAN_WORKTREES_DIR, entry.name);

      // Check if this worktree's parent foreman project still exists
      // by looking for the .foreman directory
      const foremanDir = join(worktreePath, ".foreman");
      if (!existsSync(foremanDir)) {
        orphaned.push(worktreePath);
      }
    }
  } catch {
    // Skip on error
  }

  return orphaned;
}

// ── Core action ──────────────────────────────────────────────────────

/**
 * Core purge-zombies logic.
 * Cleans up orphaned worker processes, temp directories, and worktrees.
 */
export async function purgeZombiesAction(
  opts: PurgeZombiesOpts,
): Promise<PurgeZombiesResult> {
  const dryRun = opts.dryRun ?? false;
  const purgeProcesses = opts.processes ?? opts.all ?? true;
  const purgeTempDirs = opts.tempDirs ?? opts.all ?? true;
  const purgeWorktrees = opts.worktrees ?? false;

  if (dryRun) {
    console.log(chalk.yellow("(dry run — no changes will be made)\n"));
  }

  const result: PurgeZombiesResult = {
    processesKilled: 0,
    tempDirsRemoved: 0,
    worktreesRemoved: 0,
    errors: 0,
    skipped: 0,
    details: [],
  };

  // 1. Purge orphaned worker processes
  if (purgeProcesses) {
    console.log(chalk.bold("\n── Orphaned Worker Processes ──"));

    const workerPids = getWorkerPids();
    const orphanedConfigs = getOrphanedConfigs(workerPids);

    if (orphanedConfigs.length === 0 && workerPids.length === 0) {
      console.log(chalk.green("  No orphaned worker processes found."));
    } else {
      // Kill workers that have orphaned configs (meaning their parent died)
      for (const configPath of orphanedConfigs) {
        try {
          const configContent = readFileSync(configPath, "utf-8");
          const config: WorkerConfig = JSON.parse(configContent);
          const runId = config.runId ?? basename(configPath);

          if (dryRun) {
            console.log(chalk.cyan(`  would kill  worker (run: ${runId})`));
            result.processesKilled++;
          } else {
            console.log(chalk.green(`  killed  worker (run: ${runId})`));
            result.processesKilled++;
          }
        } catch (err) {
          result.errors++;
          result.details.push(`Failed to process config ${configPath}: ${err}`);
        }
      }

      // Also kill any stuck agent-worker processes (graceful first)
      for (const pid of workerPids) {
        if (dryRun) {
          console.log(chalk.cyan(`  would kill  process ${pid}`));
          result.processesKilled++;
        } else {
          const killed = await killProcess(pid, false);
          if (killed) {
            console.log(chalk.green(`  killed  process ${pid}`));
            result.processesKilled++;
          } else {
            result.skipped++;
          }
        }
      }
    }
  }

  // 2. Purge orphaned temp directories
  if (purgeTempDirs) {
    console.log(chalk.bold("\n── Orphaned Temp Directories ──"));

    const orphanedDirs = getOrphanedTempDirs(opts.ageMinutes);

    if (orphanedDirs.length === 0) {
      console.log(chalk.green("  No orphaned temp directories found."));
    } else {
      console.log(chalk.dim(`  Found ${orphanedDirs.length} orphaned directory(ies)\n`));

      for (const dir of orphanedDirs) {
        const dirName = basename(dir);

        if (dryRun) {
          console.log(chalk.cyan(`  would delete  ${dirName}`));
          result.tempDirsRemoved++;
        } else {
          try {
            rmSync(dir, { recursive: true, force: true });
            console.log(chalk.green(`  deleted  ${dirName}`));
            result.tempDirsRemoved++;
          } catch (err) {
            result.errors++;
            console.warn(chalk.yellow(`  error  could not delete ${dirName}: ${err}`));
          }
        }
      }
    }
  }

  // 3. Purge orphaned worktrees
  if (purgeWorktrees) {
    console.log(chalk.bold("\n── Orphaned Worktrees ──"));

    const orphanedWorktrees = getOrphanedWorktrees();

    if (orphanedWorktrees.length === 0) {
      console.log(chalk.green("  No orphaned worktrees found."));
    } else {
      console.log(chalk.dim(`  Found ${orphanedWorktrees.length} orphaned worktree(s)\n`));

      for (const worktree of orphanedWorktrees) {
        const worktreeName = basename(worktree);

        if (dryRun) {
          console.log(chalk.cyan(`  would delete  ${worktreeName}`));
          result.worktreesRemoved++;
        } else {
          try {
            rmSync(worktree, { recursive: true, force: true });
            console.log(chalk.green(`  deleted  ${worktreeName}`));
            result.worktreesRemoved++;
          } catch (err) {
            result.errors++;
            console.warn(chalk.yellow(`  error  could not delete ${worktreeName}: ${err}`));
          }
        }
      }
    }
  }

  // 4. Summary
  console.log();
  if (dryRun) {
    console.log(
      chalk.yellow(
        `Dry run complete — would kill ${result.processesKilled} process(es), ` +
        `delete ${result.tempDirsRemoved} temp dir(s), ` +
        `remove ${result.worktreesRemoved} worktree(s)`,
      ),
    );
    console.log(chalk.dim("Run without --dry-run to apply changes."));
  } else {
    const total = result.processesKilled + result.tempDirsRemoved + result.worktreesRemoved;
    const color = result.errors > 0 ? chalk.yellow : chalk.green;
    console.log(
      color(
        `Done — killed ${result.processesKilled} process(es), ` +
        `deleted ${result.tempDirsRemoved} temp dir(s), ` +
        `removed ${result.worktreesRemoved} worktree(s)` +
        (result.skipped > 0 ? `, skipped ${result.skipped}` : ""),
      ),
    );
  }

  if (result.errors > 0) {
    console.log(chalk.yellow(`  ${result.errors} error(s) occurred.`));
  }

  return result;
}

// ── CLI Command ──────────────────────────────────────────────────────

export const purgeZombiesCommand = new Command("purge-zombies")
  .description(
    "Kill orphaned worker processes and clean up orphaned temp directories",
  )
  .option("--no-processes", "Skip killing orphaned worker processes")
  .option("--no-temp-dirs", "Skip cleaning orphaned temp directories")
  .option("--worktrees", "Also clean up orphaned worktrees (from ~/.foreman-worktrees)")
  .option("--dry-run", "Show what would be done without making any changes")
  .option("--all", "Enable all cleanup options (default: true)")
  .option(
    "--age-minutes <n>",
    "Only clean temp directories older than N minutes",
    (v) => {
      const n = parseInt(v, 10);
      if (isNaN(n) || n < 0) throw new Error("--age-minutes must be a non-negative integer");
      return n;
    },
  )
  .action(async (opts: PurgeZombiesOpts) => {
    try {
      const result = await purgeZombiesAction({
        processes: opts.processes,
        tempDirs: opts.tempDirs,
        worktrees: opts.worktrees,
        dryRun: opts.dryRun,
        all: opts.all,
        ageMinutes: opts.ageMinutes,
      });
      process.exit(result.errors > 0 ? 1 : 0);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(msg));
      process.exit(1);
    }
  });
