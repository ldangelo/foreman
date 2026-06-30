import { Command } from "commander";
import { type Run } from "../../lib/store.js";
export interface StopOpts {
    list?: boolean;
    force?: boolean;
    dryRun?: boolean;
}
export interface StopResult {
    stopped: number;
    errors: string[];
    skipped: number;
}
interface StopStore {
    getProjectByPath(path: string): Promise<{
        id: string;
        path: string;
    } | null>;
    getActiveRuns(projectId: string): Promise<Run[]>;
    getRun(id: string): Promise<Run | null>;
    getRunsForSeed(seedId: string, projectId: string): Promise<Run[]>;
    updateRun(runId: string, updates: Partial<Pick<Run, "status" | "completed_at">>): Promise<void>;
    logEvent(projectId: string, eventType: "stuck", data: Record<string, unknown>, runId?: string): Promise<void>;
}
/**
 * Core stop logic extracted for testability.
 * Returns the exit code (0 = success, 1 = error).
 */
export declare function stopAction(id: string | undefined, opts: StopOpts, store: StopStore, projectPath: string): Promise<number>;
/**
 * List active runs with full details.
 */
export declare function listActiveRuns(store: StopStore, projectPath: string): Promise<void>;
export declare function stopCommandAction(id: string | undefined, opts: StopOpts): Promise<number>;
export declare const stopCommand: Command;
export {};
//# sourceMappingURL=stop.d.ts.map