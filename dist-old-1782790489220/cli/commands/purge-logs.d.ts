import { ForemanStore } from "../../lib/store.js";
import type { RegisteredProjectSummary } from "./project-task-support.js";
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
    getRun(id: string): Promise<import("../../lib/store.js").Run | null>;
}
type RegisteredProject = RegisteredProjectSummary;
export interface PurgeLogsCommandContext {
    projectPath: string;
    localStore: ForemanStore;
    registered?: RegisteredProject;
    store: PurgeStore;
}
export declare function resolvePurgeLogsCommandContext(): Promise<PurgeLogsCommandContext>;
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
export declare function purgeLogsAction(opts: PurgeLogsOpts, store: PurgeStore, logsDir?: string): Promise<PurgeLogsResult>;
export declare function purgeLogsCommandAction(opts: PurgeLogsOpts): Promise<void>;
export {};
//# sourceMappingURL=purge-logs.d.ts.map