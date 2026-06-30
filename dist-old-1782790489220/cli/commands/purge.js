/**
 * `foreman purge` — grouped cleanup commands.
 *
 *   foreman purge logs   Remove old agent log files (formerly `foreman purge-logs`)
 *   foreman purge runs   Remove zombie run records   (formerly `foreman purge-zombie-runs`)
 *
 * The old top-level spellings remain registered as hidden, deprecated
 * commands that print a one-line notice and delegate to the same handlers,
 * with all of their original flags intact.
 */
import { Command } from "commander";
import { purgeLogsCommandAction } from "./purge-logs.js";
import { purgeZombieRunsCommandAction } from "./purge-zombie-runs.js";
import { parseNonNegativeIntOption, printDeprecationNotice } from "./cli-output.js";
// ── Shared option builders (one definition per flag set) ────────────────
function withPurgeLogsOptions(command) {
    return command
        .option("--days <n>", "Delete logs from runs older than N days (default: 7)", parseNonNegativeIntOption("--days"))
        .option("--dry-run", "Show what would be deleted without making any changes")
        .option("--all", "Delete all terminal-status logs regardless of age (use with caution)");
}
function withPurgeRunsOptions(command) {
    return command.option("--dry-run", "Show what would be purged without making any changes");
}
// ── Canonical group: foreman purge logs|runs ─────────────────────────────
const purgeLogsSubcommand = withPurgeLogsOptions(new Command("logs").description("Remove old agent log files from ~/.foreman/logs/ based on a retention policy")).action(async (opts) => {
    await purgeLogsCommandAction(opts);
});
const purgeRunsSubcommand = withPurgeRunsOptions(new Command("runs").description("Remove failed run records whose beads are already closed or no longer exist")).action(async (opts) => {
    process.exit(await purgeZombieRunsCommandAction(opts));
});
export const purgeCommand = new Command("purge")
    .description("Purge old agent logs and stale run records")
    .addCommand(purgeLogsSubcommand)
    .addCommand(purgeRunsSubcommand);
// ── Deprecated top-level spellings (registered hidden) ───────────────────
export const purgeLogsCommand = withPurgeLogsOptions(new Command("purge-logs").description("Remove old agent log files (deprecated: use 'foreman purge logs')")).action(async (opts) => {
    printDeprecationNotice("foreman purge-logs", "foreman purge logs");
    await purgeLogsCommandAction(opts);
});
export const purgeZombieRunsCommand = withPurgeRunsOptions(new Command("purge-zombie-runs").description("Remove zombie run records (deprecated: use 'foreman purge runs')")).action(async (opts) => {
    printDeprecationNotice("foreman purge-zombie-runs", "foreman purge runs");
    process.exit(await purgeZombieRunsCommandAction(opts));
});
//# sourceMappingURL=purge.js.map