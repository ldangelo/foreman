/**
 * Write intent interfaces for the orchestrator.
 *
 * These interfaces define the mutation contracts that orchestrator modules
 * use to modify store data. Each interface represents a coherent set of
 * related write operations.
 */
import type { RunStatus, MergeStrategy, RunProgressSummary, RunSummary } from "./read-models.js";
/**
 * Commands for mutating run records.
 * Groups related write operations together for cleaner dependency injection.
 */
export interface RunCommands {
    /** Update the status of a run. */
    updateStatus(runId: string, status: RunStatus): Promise<void>;
    /** Update run progress (serialized JSON). */
    setProgress(runId: string, progress: string): Promise<void>;
    /** Log an event for a run. */
    logEvent(runId: string, projectId: string, eventType: string, payload: Record<string, unknown>): Promise<void>;
    /** Update run fields. */
    updateRun(runId: string, updates: {
        status?: RunStatus;
        sessionKey?: string | null;
        worktreePath?: string | null;
        startedAt?: string | null;
        completedAt?: string | null;
        baseBranch?: string | null;
        mergeStrategy?: MergeStrategy | null;
        commitSha?: string | null;
        prUrl?: string | null;
        prState?: string | null;
        prHeadSha?: string | null;
    }): Promise<void>;
}
/**
 * Factory for creating new run records.
 * Encapsulates the creation logic so callers don't need to know about
 * the concrete store schema.
 */
export interface RunFactory {
    /**
     * Create a new run record.
     * Returns the created run summary.
     */
    createRun(args: {
        runId: string;
        projectId: string;
        taskId: string;
        agentType: string;
        branchName: string;
        worktreePath: string | null;
        baseBranch?: string | null;
        mergeStrategy?: MergeStrategy;
    }): Promise<RunSummary>;
}
/**
 * Commands for updating run progress.
 */
export interface ProgressCommands {
    /** Update run progress from a RunProgress object. */
    updateRunProgress(runId: string, progress: RunProgressSummary): Promise<void>;
}
/**
 * Commands for sending messages between agents.
 */
export interface MessagingCommands {
    /** Send a message from one agent to another. */
    sendMessage(runId: string, senderAgentType: string, recipientAgentType: string, subject: string, body: string): Promise<void>;
}
/**
 * Combined write model aggregating all write operations.
 * Convenience type for modules that need both read and write access.
 */
export interface RunWriteModel extends RunCommands, ProgressCommands, MessagingCommands {
    /** Factory for creating new runs. */
    createRun(args: {
        runId: string;
        projectId: string;
        taskId: string;
        agentType: string;
        branchName: string;
        worktreePath: string | null;
        baseBranch?: string | null;
        mergeStrategy?: MergeStrategy;
    }): Promise<RunSummary>;
}
//# sourceMappingURL=write-models.d.ts.map