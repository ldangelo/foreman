import chalk from "chalk";
import { promises as fs } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

import { foremanBackendMode } from "../../lib/backend-mode.js";
import { ElixirServerClient, type ElixirRun } from "../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
import { ForemanStore, type Run } from "../../lib/store.js";
import { PostgresStore } from "../../lib/postgres-store.js";
import type { RegisteredProjectSummary } from "./project-task-support.js";
import { resolveProjectContext } from "./project-context.js";
import { closeStoreIfPossible, wrapLocalRunStore } from "./local-store-adapter.js";
import { printDryRunNotice, printPurgeSummary } from "./cli-output.js";

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

interface PurgeStore {
  getRun(id: string): Promise<Run | null>;
}

type RegisteredProject = RegisteredProjectSummary;

export interface PurgeLogsCommandContext {
  projectPath: string;
  localStore: ForemanStore;
  registered?: RegisteredProject;
  store: PurgeStore;
}

export async function resolvePurgeLogsCommandContext(): Promise<PurgeLogsCommandContext> {
  const { projectPath, registered } = await resolveProjectContext();
  const localStore = ForemanStore.forProject(projectPath);

  const store: PurgeStore = registered
    ? PostgresStore.forProject(registered.id)
    : wrapLocalRunStore(localStore);

  return { projectPath, localStore, registered, store };
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
  "blocked",
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
  store: PurgeStore,
  logsDir?: string,
): Promise<PurgeLogsResult> {
  const dryRun = opts.dryRun ?? false;
  const deleteAll = opts.all ?? false;
  const days = opts.days ?? 7;
  const dir = logsDir ?? LOGS_DIR;

  printDryRunNotice(dryRun);

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
    const run = await store.getRun(runId);

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
  printPurgeSummary({
    dryRun,
    subject: "log group(s)",
    verb: "deleted",
    count: result.deleted,
    skipped: result.skipped,
    errors: result.errors,
    detail: humanBytes(result.freedBytes),
    dryRunHint: "Run without --dry-run to apply changes.",
    warnOnErrors: true,
  });

  return result;
}

function elixirRunToPurgeRun(run: ElixirRun): Run | null {
  const id = run.run_id ?? run.id;
  if (!id) return null;
  const now = new Date().toISOString();
  return {
    id,
    project_id: run.project_id ?? "elixir",
    seed_id: run.task_id ?? id,
    agent_type: typeof run.agent_type === "string" ? run.agent_type : "elixir",
    session_key: null,
    worktree_path: typeof run.worktree_path === "string" ? run.worktree_path : null,
    status: (run.status as Run["status"] | undefined) ?? "running",
    started_at: typeof run.started_at === "string" ? run.started_at : now,
    completed_at: typeof run.completed_at === "string" ? run.completed_at : null,
    created_at: typeof run.created_at === "string" ? run.created_at : now,
    progress: null,
  };
}

export async function purgeLogsElixirDryRun(opts: PurgeLogsOpts): Promise<number> {
  const manager = new ElixirServerManager();
  const status = manager.status();
  if (!status.running || !(await manager.health()).ok) {
    console.error(chalk.red("Elixir server is not running. Start it with 'foreman server start' before purge preview."));
    return 1;
  }
  const client = new ElixirServerClient(status.url, manager.authToken);
  const runMap = new Map<string, Run>();
  for (const run of await client.listRuns()) {
    const mapped = elixirRunToPurgeRun(run);
    if (mapped) runMap.set(mapped.id, mapped);
  }
  try {
    const result = await purgeLogsAction({ days: opts.days ?? 7, dryRun: true, all: opts.all }, { getRun: async (id) => runMap.get(id) ?? null });
    return result.errors > 0 ? 1 : 0;
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(chalk.red(msg));
    return 1;
  }
}

export async function purgeLogsCommandAction(opts: PurgeLogsOpts): Promise<void> {
  if (foremanBackendMode() === "elixir") {
    if (!opts.dryRun) {
      console.error(chalk.red("foreman purge logs deletes local log files using legacy run-store safety decisions. Use --dry-run for an Elixir projection-backed preview, or set FOREMAN_BACKEND=node for legacy log cleanup."));
      process.exit(1);
    }

    process.exit(await purgeLogsElixirDryRun(opts));
  }

  let context: PurgeLogsCommandContext;
  try {
    context = await resolvePurgeLogsCommandContext();
  } catch {
    console.error(chalk.red("Not in a git repository. Run from within a foreman project."));
    process.exit(1);
  }

  try {
    const result = await purgeLogsAction(
      {
        days: opts.days ?? 7,
        dryRun: opts.dryRun,
        all: opts.all,
      },
      context.store,
    );
    context.localStore.close();
    closeStoreIfPossible(context.store);
    process.exit(result.errors > 0 ? 1 : 0);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(chalk.red(msg));
    context.localStore.close();
    closeStoreIfPossible(context.store);
    process.exit(1);
  }
}

// The CLI command surface lives in purge.ts:
//   foreman purge logs        (canonical)
//   foreman purge-logs        (hidden, deprecated alias)
