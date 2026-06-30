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
export declare const purgeCommand: Command;
export declare const purgeLogsCommand: Command;
export declare const purgeZombieRunsCommand: Command;
//# sourceMappingURL=purge.d.ts.map