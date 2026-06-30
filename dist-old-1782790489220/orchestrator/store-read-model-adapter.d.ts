/**
 * Store read model adapter.
 *
 * Wraps ForemanStore and exposes the RunStoreReadModel interface,
 * enabling orchestrator modules to depend on the interface rather
 * than the concrete store implementation.
 */
import type { ForemanStore } from "../lib/store.js";
import type { RunSummary, RunProgressSummary, RunStoreReadModel, RunStatus } from "./read-models.js";
/**
 * Adapter that wraps ForemanStore and exposes RunStoreReadModel.
 *
 * This allows orchestrator modules to depend on the read model interface
 * while the concrete store implementation remains unchanged.
 */
export declare class ForemanStoreReadModelAdapter implements RunStoreReadModel {
    private store;
    constructor(store: ForemanStore);
    getRun(runId: string): Promise<RunSummary | null>;
    getRunsForSeed(taskId: string, projectId?: string): Promise<RunSummary[]>;
    getActiveRuns(projectId?: string): Promise<RunSummary[]>;
    getRunsByStatus(status: RunStatus, projectId?: string): Promise<RunSummary[]>;
    getRunsByStatuses(statuses: RunStatus[], projectId?: string): Promise<RunSummary[]>;
    getRunsByStatusesSince(statuses: RunStatus[], since: string, projectId?: string): Promise<RunSummary[]>;
    hasActiveOrPendingRun(taskId: string, projectId?: string): Promise<boolean>;
    getRunProgress(runId: string): Promise<RunProgressSummary | null>;
}
//# sourceMappingURL=store-read-model-adapter.d.ts.map