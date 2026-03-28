import { Command } from "commander";
import { ForemanStore } from "../../lib/store.js";
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
export declare function purgeLogsAction(opts: PurgeLogsOpts, store: ForemanStore, logsDir?: string): Promise<PurgeLogsResult>;
export declare const purgeLogsCommand: Command;
//# sourceMappingURL=purge-logs.d.ts.map