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

import { purgeLogsCommandAction, type PurgeLogsOpts } from "./purge-logs.js";
import { purgeZombieRunsCommandAction, type PurgeZombieRunsOpts } from "./purge-zombie-runs.js";
import { printDeprecationNotice } from "./cli-output.js";

// ── Shared option builders (one definition per flag set) ────────────────

function parseDaysOption(value: string): number {
  const n = parseInt(value, 10);
  if (isNaN(n) || n < 0) throw new Error("--days must be a non-negative integer");
  return n;
}

function withPurgeLogsOptions(command: Command): Command {
  return command
    .option(
      "--days <n>",
      "Delete logs from runs older than N days (default: 7)",
      parseDaysOption,
    )
    .option("--dry-run", "Show what would be deleted without making any changes")
    .option("--all", "Delete all terminal-status logs regardless of age (use with caution)");
}

function withPurgeRunsOptions(command: Command): Command {
  return command.option("--dry-run", "Show what would be purged without making any changes");
}

// ── Canonical group: foreman purge logs|runs ─────────────────────────────

const purgeLogsSubcommand = withPurgeLogsOptions(
  new Command("logs").description(
    "Remove old agent log files from ~/.foreman/logs/ based on a retention policy",
  ),
).action(async (opts: PurgeLogsOpts) => {
  await purgeLogsCommandAction(opts);
});

const purgeRunsSubcommand = withPurgeRunsOptions(
  new Command("runs").description(
    "Remove failed run records whose beads are already closed or no longer exist",
  ),
).action(async (opts: PurgeZombieRunsOpts) => {
  process.exit(await purgeZombieRunsCommandAction(opts));
});

export const purgeCommand = new Command("purge")
  .description("Purge old agent logs and stale run records")
  .addCommand(purgeLogsSubcommand)
  .addCommand(purgeRunsSubcommand);

// ── Deprecated top-level spellings (registered hidden) ───────────────────

export const purgeLogsCommand = withPurgeLogsOptions(
  new Command("purge-logs").description(
    "Remove old agent log files (deprecated: use 'foreman purge logs')",
  ),
).action(async (opts: PurgeLogsOpts) => {
  printDeprecationNotice("foreman purge-logs", "foreman purge logs");
  await purgeLogsCommandAction(opts);
});

export const purgeZombieRunsCommand = withPurgeRunsOptions(
  new Command("purge-zombie-runs").description(
    "Remove zombie run records (deprecated: use 'foreman purge runs')",
  ),
).action(async (opts: PurgeZombieRunsOpts) => {
  printDeprecationNotice("foreman purge-zombie-runs", "foreman purge runs");
  process.exit(await purgeZombieRunsCommandAction(opts));
});
