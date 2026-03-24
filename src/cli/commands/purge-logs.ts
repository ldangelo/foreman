import { Command } from "commander";
import chalk from "chalk";
import { promises as fs } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

import { ForemanStore } from "../../lib/store.js";
import { getRepoRoot } from "../../lib/git.js";

// ── Types ─────────────────────────────────────────────────────────────

export interface PurgeLogsOpts {
  days?: number;
  dryRun?: boolean;
  all?: boolean;
}

export interface PurgeLogsResult {
  checked: number;
  deleted: number;
  skipped: number;
  errors: number;
  freedBytes: number;
}

// ── Constants ─────────────────────────────────────────────────────────

const LOGS_DIR = join(homedir(), ".foreman", "logs");
const LOG_EXTENSIONS = [".log", ".err", ".out"];

/**
 * Terminal run statuses — logs for these runs are safe to delete
 * once they fall outside the retention window.
 */
const TERMINAL_STATUSES = new Set([
  "completed",
  "failed",
  "stuck",
  "merged",
  "conflict",
  "test-failed",
  "pr-created",
  "reset",
]);

// ── Helpers ──────────────────────────────────────────────────────────

/**
 * Extract a UUID run-id from a log filename like `<uuid>.log`.
 * Returns null if the filename doesn't match.
 */
function extractRunId(filename: string): string | null {
  const uuidPattern =
    /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.[a-z]+$/i;
  const match = uuidPattern.exec(filename);
  return match ? match[1] : null;
}

function humanBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

// ── Core action (exported for testing) ───────────────────────────────

/**
 * Core purge-logs logic extracted for testability.
 *
 * Scans ~/.foreman/logs/ for .log / .err / .out files and deletes
 * those whose corresponding runs are:
 *   1. Older than `days` days (or all, if `all` is true), AND
 *   2. In a terminal state (completed / failed / merged / etc.), OR
 *      not present in the database at all (orphaned).
 *
 * Runs in "running" or "pending" status are always skipped for safety.
 */
export async function purgeLogsAction(
  opts: PurgeLogsOpts,
  store: ForemanStore,
  logsDir?: string,
): Promise<PurgeLogsResult> {
  const dryRun = opts.dryRun ?? false;
  const deleteAll = opts.all ?? false;
  const days = opts.days ?? 7;
  const dir = logsDir ?? LOGS_DIR;

  if (dryRun) {
    console.log(chalk.yellow("(dry run — no changes will be made)\n"));
  }

  // Cutoff: files/runs older than this timestamp are candidates
  const cutoffMs = deleteAll ? Infinity : Date.now() - days * 24 * 60 * 60 * 1000;
  const cutoffDate = deleteAll ? null : new Date(cutoffMs);

  const label = deleteAll
    ? "all ages"
    : `older than ${days} day${days === 1 ? "" : "s"}`;

  console.log(chalk.bold(`Scanning ${dir} for log files (${label})…\n`));

  // 1. Read the logs directory
  let entries: { name: string; size: number; mtimeMs: number }[];
  try {
    const dirents = await fs.readdir(dir, { withFileTypes: true });
    const statResults = await Promise.allSettled(
      dirents
        .filter((d) => d.isFile())
        .map(async (d) => {
          const stat = await fs.stat(join(dir, d.name));
          return { name: d.name, size: stat.size, mtimeMs: stat.mtimeMs };
        }),
    );
    entries = statResults
      .filter((r): r is PromiseFulfilledResult<{ name: string; size: number; mtimeMs: number }> =>
        r.status === "fulfilled",
      )
      .map((r) => r.value);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    if ((err as NodeJS.ErrnoException).code === "ENOENT") {
      console.log(chalk.green("No logs directory found — nothing to purge."));
      return { checked: 0, deleted: 0, skipped: 0, errors: 0, freedBytes: 0 };
    }
    throw new Error(`Cannot read logs directory: ${msg}`);
  }

  // 2. Group files by runId
  const runGroups = new Map<string, { name: string; size: number; mtimeMs: number }[]>();
  let nonMatchingFiles = 0;

  for (const entry of entries) {
    const runId = extractRunId(entry.name);
    if (!runId) {
      nonMatchingFiles++;
      continue; // not a run log file
    }
    const ext = entry.name.slice(entry.name.lastIndexOf("."));
    if (!LOG_EXTENSIONS.includes(ext)) {
      nonMatchingFiles++;
      continue;
    }
    if (!runGroups.has(runId)) {
      runGroups.set(runId, []);
    }
    runGroups.get(runId)!.push(entry);
  }

  if (runGroups.size === 0) {
    console.log(chalk.green("No run log files found — nothing to purge."));
    return { checked: 0, deleted: 0, skipped: 0, errors: 0, freedBytes: 0 };
  }

  console.log(
    chalk.dim(`  Found ${runGroups.size} run log group(s) across ${entries.length - nonMatchingFiles} file(s)\n`),
  );

  const result: PurgeLogsResult = {
    checked: runGroups.size,
    deleted: 0,
    skipped: 0,
    errors: 0,
    freedBytes: 0,
  };

  // 3. For each run group, decide whether to delete
  for (const [runId, files] of runGroups) {
    // Check age using the newest file in the group as proxy
    const newestMtime = Math.max(...files.map((f) => f.mtimeMs));
    const groupBytes = files.reduce((acc, f) => acc + f.size, 0);

    const isOldEnough = deleteAll || newestMtime < cutoffMs;
    if (!isOldEnough) {
      console.log(
        chalk.dim(
          `  skip  ${runId}  (recent — ${Math.floor((Date.now() - newestMtime) / 86400000)}d old)`,
        ),
      );
      result.skipped++;
      continue;
    }

    // Check the run status in the DB
    const run = store.getRun(runId);

    if (run && !TERMINAL_STATUSES.has(run.status)) {
      // Active run — never delete
      console.log(
        chalk.dim(`  skip  ${runId}  (run status: ${run.status} — active, will not delete)`),
      );
      result.skipped++;
      continue;
    }

    // Safe to delete: either terminal status or not in DB (orphaned)
    const ageStr = cutoffDate
      ? `${Math.floor((Date.now() - newestMtime) / 86400000)}d old`
      : "all ages";
    const statusStr = run ? run.status : "orphaned";

    if (dryRun) {
      console.log(
        chalk.cyan(
          `  would delete  ${runId}  [${statusStr}, ${ageStr}, ${humanBytes(groupBytes)}]`,
        ),
      );
      result.deleted++;
      result.freedBytes += groupBytes;
    } else {
      let groupErrors = 0;
      for (const file of files) {
        try {
          await fs.unlink(join(dir, file.name));
        } catch (err: unknown) {
          const msg = err instanceof Error ? err.message : String(err);
          console.warn(
            chalk.yellow(`  warn  could not delete ${file.name}: ${msg}`),
          );
          groupErrors++;
        }
      }
      if (groupErrors > 0) {
        result.errors++;
      } else {
        console.log(
          chalk.green(
            `  deleted  ${runId}  [${statusStr}, ${ageStr}, ${humanBytes(groupBytes)}]`,
          ),
        );
        result.deleted++;
        result.freedBytes += groupBytes;
      }
    }
  }

  // 4. Summary
  console.log();
  const freedStr = humanBytes(result.freedBytes);

  if (dryRun) {
    console.log(
      chalk.yellow(
        `Dry run complete — ${result.deleted} log group(s) would be deleted (${freedStr}), ${result.skipped} skipped, ${result.errors} error(s).`,
      ),
    );
    console.log(chalk.dim("Run without --dry-run to apply changes."));
  } else {
    const color = result.errors > 0 ? chalk.yellow : chalk.green;
    console.log(
      color(
        `Done — ${result.deleted} log group(s) deleted (${freedStr}), ${result.skipped} skipped, ${result.errors} error(s).`,
      ),
    );
  }

  return result;
}

// ── CLI Command ──────────────────────────────────────────────────────

export const purgeLogsCommand = new Command("purge-logs")
  .description(
    "Remove old agent log files from ~/.foreman/logs/ based on a retention policy",
  )
  .option(
    "--days <n>",
    "Delete logs from runs older than N days (default: 7)",
    (v) => {
      const n = parseInt(v, 10);
      if (isNaN(n) || n < 0) throw new Error("--days must be a non-negative integer");
      return n;
    },
  )
  .option("--dry-run", "Show what would be deleted without making any changes")
  .option("--all", "Delete all terminal-status logs regardless of age (use with caution)")
  .action(async (opts: { days?: number; dryRun?: boolean; all?: boolean }) => {
    let projectPath: string;
    try {
      projectPath = await getRepoRoot(process.cwd());
    } catch {
      console.error(
        chalk.red("Not in a git repository. Run from within a foreman project."),
      );
      process.exit(1);
    }

    const store = ForemanStore.forProject(projectPath);

    try {
      const result = await purgeLogsAction(
        {
          days: opts.days ?? 7,
          dryRun: opts.dryRun,
          all: opts.all,
        },
        store,
      );
      store.close();
      process.exit(result.errors > 0 ? 1 : 0);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(msg));
      store.close();
      process.exit(1);
    }
  });
