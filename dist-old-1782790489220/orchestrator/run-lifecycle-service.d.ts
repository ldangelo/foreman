/**
 * Run lifecycle service.
 *
 * Encapsulates run create/update/log/mail operations for the dispatcher.
 * Uses narrow interfaces to reduce coupling to the full store.
 */
import type { Run, EventType } from "../lib/store.js";
import type { RunStore, ProgressEventStore } from "../lib/store.js";
/**
 * Narrow interface for mail sending (only method used by lifecycle service).
 */
export interface MailSendStore {
    sendMessage(runId: string, senderAgentType: string, recipientAgentType: string, subject: string, body: string): Promise<void>;
}
/**
 * Override-backed run operations for external project mode.
 */
export interface RunOpsOverrides {
    createRun(args: {
        runId: string;
        projectId: string;
        seedId: string;
        agentType: string;
        branchName: string;
        worktreePath: string | null;
        baseBranch?: string | null;
        mergeStrategy?: string | null;
    }): Promise<Run | void>;
    updateRun(runId: string, updates: Partial<Pick<Run, "status" | "session_key" | "worktree_path" | "started_at" | "completed_at">>): Promise<void>;
    sendMessage(runId: string, senderAgentType: string, recipientAgentType: string, subject: string, body: string): Promise<void>;
    logEvent(runId: string, projectId: string, eventType: string, payload: Record<string, unknown>): Promise<void>;
}
/**
 * Configuration for run lifecycle service.
 */
export interface RunLifecycleConfig {
    /** External project ID when operating in external mode. */
    externalProjectId?: string;
    /** Override run operations for external project mode. */
    runOps?: RunOpsOverrides;
    /** Override for fetching a run by ID (used in external mode to check terminal success). */
    getRun?: (runId: string) => Promise<Run | null>;
}
/**
 * Service encapsulating run lifecycle operations.
 * Handles run create/update/log/mail with support for both local store
 * and external project overrides.
 *
 * Note: Read operations (getActiveRuns, getRunsByStatus, etc.) are delegated
 * directly to the store. The dispatcher is responsible for checking override
 * hooks (DispatcherOverrides) before calling read methods.
 */
export declare class RunLifecycleService {
    private runStore;
    private progressEventStore;
    private mailStore;
    private config?;
    constructor(runStore: RunStore, progressEventStore: ProgressEventStore, mailStore: MailSendStore, config?: RunLifecycleConfig | undefined);
    /**
     * Require a registered run op, throwing if not present in external mode.
     */
    private requireRegisteredRunOp;
    /**
     * Validate that required run ops are registered in external mode.
     */
    validateRegisteredRunOps(requiredMethods: Array<keyof RunOpsOverrides>): void;
    /**
     * Map internal run status to external project status.
     */
    private mapRunStatusForExternal;
    /**
     * Check whether to preserve terminal success status.
     * Terminal success (merged, pr-created) should not be downgraded to failed/stuck.
     */
    private shouldPreserveTerminalSuccess;
    /**
     * Create a new run record.
     */
    createRunRecord(projectId: string, seedId: string, agentType: string, worktreePath: string | null, branchName: string, opts?: {
        baseBranch?: string | null;
        mergeStrategy?: Run["merge_strategy"];
        sessionKey?: string | null;
    }): Promise<Run>;
    /**
     * Update a run record.
     */
    updateRunRecord(runId: string, updates: Partial<Pick<Run, "status" | "session_key" | "worktree_path" | "started_at" | "completed_at">>): Promise<void>;
    /**
     * Send a mail message.
     */
    sendMailRecord(runId: string, senderAgentType: string, recipientAgentType: string, subject: string, body: string): Promise<void>;
    /**
     * Log an event.
     */
    logEventRecord(projectId: string, eventType: EventType, payload: Record<string, unknown>, runId: string): Promise<void>;
    /**
     * Get active runs for a project.
     */
    getActiveRunsRecord(projectId: string): Promise<Run[]>;
    /**
     * Get runs by status for a project.
     */
    getRunsByStatusRecord(status: Run["status"], projectId: string): Promise<Run[]>;
    /**
     * Get runs for a seed.
     */
    getRunsForSeedRecord(seedId: string, projectId: string): Promise<Run[]>;
    /**
     * Get a run by ID.
     */
    getRunRecord(runId: string): Promise<Run | null>;
}
//# sourceMappingURL=run-lifecycle-service.d.ts.map