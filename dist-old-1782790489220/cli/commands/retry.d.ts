import { Command } from "commander";
import { type TaskClientBackend } from "../../lib/task-client-factory.js";
import type { ITaskClient } from "../../lib/task-client.js";
import { Dispatcher } from "../../orchestrator/dispatcher.js";
import type { ModelSelection } from "../../orchestrator/types.js";
export interface RetryOpts {
    dispatch?: boolean;
    model?: ModelSelection;
    dryRun?: boolean;
}
interface RetryStore {
    getProjectByPath(path: string): Promise<{
        id: string;
        path: string;
    } | null>;
    getRunsForSeed(seedId: string, projectId: string): Promise<import("../../lib/store.js").Run[]>;
    updateRun(runId: string, updates: Partial<Pick<import("../../lib/store.js").Run, "status" | "completed_at">>): Promise<void>;
    logEvent(projectId: string, eventType: "restart", data: Record<string, unknown>, runId?: string): Promise<void>;
}
/**
 * Core retry logic extracted for testability.
 * Returns the exit code (0 = success, 1 = error).
 */
export declare function retryAction(beadId: string, opts: RetryOpts, beadsClient: ITaskClient, store: RetryStore, projectPath: string, dispatcher?: Dispatcher, backendType?: TaskClientBackend): Promise<number>;
export declare const retryCommand: Command;
export {};
//# sourceMappingURL=retry.d.ts.map