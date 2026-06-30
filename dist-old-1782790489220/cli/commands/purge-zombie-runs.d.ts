import { type Run } from "../../lib/store.js";
import type { ITaskClient } from "../../lib/task-client.js";
export interface PurgeZombieRunsOpts {
    dryRun?: boolean;
}
export interface PurgeZombieRunsResult {
    checked: number;
    purged: number;
    skipped: number;
    errors: number;
}
interface PurgeZombieStore {
    getProjectByPath(path: string): Promise<{
        id: string;
        path: string;
    } | null>;
    getRunsByStatus(status: Run["status"], projectId: string): Promise<Run[]>;
    deleteRun(runId: string): Promise<boolean>;
}
/**
 * Core purge logic extracted for testability.
 * Returns a summary result object.
 */
export declare function purgeZombieRunsAction(opts: PurgeZombieRunsOpts, beadsClient: Pick<ITaskClient, "show">, store: PurgeZombieStore, projectPath: string): Promise<PurgeZombieRunsResult>;
export declare function purgeZombieRunsCommandAction(opts: PurgeZombieRunsOpts): Promise<number>;
export {};
//# sourceMappingURL=purge-zombie-runs.d.ts.map