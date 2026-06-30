import type { VcsBackend } from "../lib/vcs/interface.js";
import type { MergeQueueEntry, MissingFromQueueEntry, ReconcileResult } from "./merge-queue.js";
import type { MergeQueueOperation, MergeQueueStatus } from "../lib/db/postgres-adapter.js";
import { PostgresAdapter } from "../lib/db/postgres-adapter.js";
interface EnqueueInput {
    branchName: string;
    seedId: string;
    runId: string;
    operation?: MergeQueueOperation;
    agentName?: string;
    filesModified?: string[];
}
export declare class PostgresMergeQueue {
    private readonly projectId;
    private readonly adapter;
    constructor(projectId: string, adapter?: PostgresAdapter);
    enqueue(input: EnqueueInput): Promise<MergeQueueEntry>;
    list(status?: MergeQueueStatus): Promise<MergeQueueEntry[]>;
    dequeue(): Promise<MergeQueueEntry | null>;
    getOrderedPending(): Promise<MergeQueueEntry[]>;
    updateStatus(id: number, status: MergeQueueStatus, extra?: {
        resolvedTier?: number;
        error?: string;
        completedAt?: string;
        lastAttemptedAt?: string;
        retryCount?: number;
    }): Promise<void>;
    remove(id: number): Promise<void>;
    resetForRetry(seedId: string): Promise<boolean>;
    getRetryableEntries(): Promise<MergeQueueEntry[]>;
    reEnqueue(id: number): Promise<boolean>;
    missingFromQueue(): Promise<MissingFromQueueEntry[]>;
    reconcile(repoPath: string, backend?: VcsBackend): Promise<ReconcileResult>;
}
export {};
//# sourceMappingURL=postgres-merge-queue.d.ts.map