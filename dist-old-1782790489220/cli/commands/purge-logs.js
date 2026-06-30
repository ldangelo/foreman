import chalk from "chalk";
import { promises as fs } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { ForemanStore } from "../../lib/store.js";
import { PostgresStore } from "../../lib/postgres-store.js";
import { resolveProjectContext } from "./project-context.js";
import { closeStoreIfPossible, wrapLocalRunStore } from "./local-store-adapter.js";
import { printDryRunNotice, printPurgeSummary } from "./cli-output.js";
export async function resolvePurgeLogsCommandContext() {
    const { projectPath, registered } = await resolveProjectContext();
    const localStore = ForemanStore.forProject(projectPath);
    const store = registered
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
]);
// ── Helpers ──────────────────────────────────────────────────────────
/**
 * Extract a UUID run-id from a log filename like `<uuid>.log`.
 * Returns null if the filename doesn't match.
 */
function extractRunId(filename) {
    const uuidPattern = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.[a-z]+$/i;
    const match = uuidPattern.exec(filename);
    return match ? match[1] : null;
}
function humanBytes(bytes) {
    if (bytes < 1024)
        return `${bytes} B`;
    if (bytes < 1024 * 1024)
        return `${(bytes / 1024).toFixed(1)} KB`;
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
export async function purgeLogsAction(opts, store, logsDir) {
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
    let entries;
    try {
        const dirents = await fs.readdir(dir, { withFileTypes: true });
        const statResults = await Promise.allSettled(dirents
            .filter((d) => d.isFile())
            .map(async (d) => {
            const stat = await fs.stat(join(dir, d.name));
            return { name: d.name, size: stat.size, mtimeMs: stat.mtimeMs };
        }));
        entries = statResults
            .filter((r) => r.status === "fulfilled")
            .map((r) => r.value);
    }
    catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        if (err.code === "ENOENT") {
            console.log(chalk.green("No logs directory found — nothing to purge."));
            return { checked: 0, deleted: 0, skipped: 0, errors: 0, freedBytes: 0 };
        }
        throw new Error(`Cannot read logs directory: ${msg}`);
    }
    // 2. Group files by runId
    const runGroups = new Map();
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
        runGroups.get(runId).push(entry);
    }
    if (runGroups.size === 0) {
        console.log(chalk.green("No run log files found — nothing to purge."));
        return { checked: 0, deleted: 0, skipped: 0, errors: 0, freedBytes: 0 };
    }
    console.log(chalk.dim(`  Found ${runGroups.size} run log group(s) across ${entries.length - nonMatchingFiles} file(s)\n`));
    const result = {
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
            console.log(chalk.dim(`  skip  ${runId}  (recent — ${Math.floor((Date.now() - newestMtime) / 86400000)}d old)`));
            result.skipped++;
            continue;
        }
        // Check the run status in the DB
        const run = await store.getRun(runId);
        if (run && !TERMINAL_STATUSES.has(run.status)) {
            // Active run — never delete
            console.log(chalk.dim(`  skip  ${runId}  (run status: ${run.status} — active, will not delete)`));
            result.skipped++;
            continue;
        }
        // Safe to delete: either terminal status or not in DB (orphaned)
        const ageStr = cutoffDate
            ? `${Math.floor((Date.now() - newestMtime) / 86400000)}d old`
            : "all ages";
        const statusStr = run ? run.status : "orphaned";
        if (dryRun) {
            console.log(chalk.cyan(`  would delete  ${runId}  [${statusStr}, ${ageStr}, ${humanBytes(groupBytes)}]`));
            result.deleted++;
            result.freedBytes += groupBytes;
        }
        else {
            let groupErrors = 0;
            for (const file of files) {
                try {
                    await fs.unlink(join(dir, file.name));
                }
                catch (err) {
                    const msg = err instanceof Error ? err.message : String(err);
                    console.warn(chalk.yellow(`  warn  could not delete ${file.name}: ${msg}`));
                    groupErrors++;
                }
            }
            if (groupErrors > 0) {
                result.errors++;
            }
            else {
                console.log(chalk.green(`  deleted  ${runId}  [${statusStr}, ${ageStr}, ${humanBytes(groupBytes)}]`));
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
export async function purgeLogsCommandAction(opts) {
    let context;
    try {
        context = await resolvePurgeLogsCommandContext();
    }
    catch {
        console.error(chalk.red("Not in a git repository. Run from within a foreman project."));
        process.exit(1);
    }
    try {
        const result = await purgeLogsAction({
            days: opts.days ?? 7,
            dryRun: opts.dryRun,
            all: opts.all,
        }, context.store);
        context.localStore.close();
        closeStoreIfPossible(context.store);
        process.exit(result.errors > 0 ? 1 : 0);
    }
    catch (err) {
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
//# sourceMappingURL=purge-logs.js.map