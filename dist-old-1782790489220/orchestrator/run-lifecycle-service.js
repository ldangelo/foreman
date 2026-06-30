/**
 * Run lifecycle service.
 *
 * Encapsulates run create/update/log/mail operations for the dispatcher.
 * Uses narrow interfaces to reduce coupling to the full store.
 */
import { randomUUID } from "node:crypto";
// ── Run lifecycle service ─────────────────────────────────────────────────
/**
 * Service encapsulating run lifecycle operations.
 * Handles run create/update/log/mail with support for both local store
 * and external project overrides.
 *
 * Note: Read operations (getActiveRuns, getRunsByStatus, etc.) are delegated
 * directly to the store. The dispatcher is responsible for checking override
 * hooks (DispatcherOverrides) before calling read methods.
 */
export class RunLifecycleService {
    runStore;
    progressEventStore;
    mailStore;
    config;
    constructor(runStore, progressEventStore, mailStore, config) {
        this.runStore = runStore;
        this.progressEventStore = progressEventStore;
        this.mailStore = mailStore;
        this.config = config;
    }
    /**
     * Require a registered run op, throwing if not present in external mode.
     */
    requireRegisteredRunOp(method) {
        const op = this.config?.runOps?.[method];
        if (op) {
            return op;
        }
        const projectId = this.config?.externalProjectId;
        throw new Error(`Registered dispatcher write override missing runOps.${String(method)} for project ${projectId ?? "unknown"}`);
    }
    /**
     * Validate that required run ops are registered in external mode.
     */
    validateRegisteredRunOps(requiredMethods) {
        if (!this.config?.externalProjectId)
            return;
        for (const method of requiredMethods) {
            this.requireRegisteredRunOp(method);
        }
    }
    /**
     * Map internal run status to external project status.
     */
    mapRunStatusForExternal(status) {
        switch (status) {
            case "pending":
                return "pending";
            case "running":
                return "running";
            case "completed":
            case "merged":
            case "pr-created":
                return "success";
            case "failed":
            case "test-failed":
            case "stuck":
            case "conflict":
                return "failure";
            case "reset":
                return "cancelled";
            default:
                return null;
        }
    }
    /**
     * Check whether to preserve terminal success status.
     * Terminal success (merged, pr-created) should not be downgraded to failed/stuck.
     */
    shouldPreserveTerminalSuccess(currentStatus, nextStatus) {
        return (currentStatus !== undefined &&
            nextStatus !== undefined &&
            (currentStatus === "merged" || currentStatus === "pr-created") &&
            (nextStatus === "failed" || nextStatus === "stuck"));
    }
    // ── Run lifecycle operations ───────────────────────────────────────────
    /**
     * Create a new run record.
     */
    async createRunRecord(projectId, seedId, agentType, worktreePath, branchName, opts) {
        if (this.config?.externalProjectId) {
            const createRun = this.requireRegisteredRunOp("createRun");
            const runId = randomUUID();
            const createdAt = new Date().toISOString();
            const run = await createRun({
                runId,
                projectId,
                seedId,
                agentType,
                branchName,
                worktreePath,
                baseBranch: opts?.baseBranch ?? null,
                mergeStrategy: opts?.mergeStrategy ?? null,
            });
            if (run) {
                return run;
            }
            return {
                id: runId,
                project_id: projectId,
                seed_id: seedId,
                agent_type: agentType,
                session_key: null,
                worktree_path: worktreePath,
                status: "pending",
                started_at: null,
                completed_at: null,
                created_at: createdAt,
                progress: null,
                tmux_session: null,
                base_branch: opts?.baseBranch ?? null,
                merge_strategy: opts?.mergeStrategy ?? "auto",
            };
        }
        const run = this.runStore.createRun(projectId, seedId, agentType, worktreePath ?? undefined, opts ? {
            ...opts,
            mergeStrategy: opts.mergeStrategy ?? undefined,
        } : undefined);
        return run;
    }
    /**
     * Update a run record.
     */
    async updateRunRecord(runId, updates) {
        if (this.config?.externalProjectId) {
            const currentRun = this.config.getRun
                ? await this.config.getRun(runId)
                : null;
            if (this.shouldPreserveTerminalSuccess(currentRun?.status, updates.status)) {
                return;
            }
            const updateRun = this.requireRegisteredRunOp("updateRun");
            const normalized = { ...updates };
            if (updates.status) {
                const mapped = this.mapRunStatusForExternal(updates.status);
                if (!mapped)
                    return;
                normalized.status = mapped;
            }
            await updateRun(runId, normalized);
            return;
        }
        // Check if getRun is available (some store implementations may not have it)
        const currentRun = "getRun" in this.runStore
            ? await this.runStore.getRun(runId)
            : null;
        if (this.shouldPreserveTerminalSuccess(currentRun?.status, updates.status)) {
            return;
        }
        await this.runStore.updateRun(runId, updates);
    }
    /**
     * Send a mail message.
     */
    async sendMailRecord(runId, senderAgentType, recipientAgentType, subject, body) {
        if (this.config?.externalProjectId) {
            const sendMessage = this.requireRegisteredRunOp("sendMessage");
            await sendMessage(runId, senderAgentType, recipientAgentType, subject, body);
            return;
        }
        await this.mailStore.sendMessage(runId, senderAgentType, recipientAgentType, subject, body);
    }
    /**
     * Log an event.
     */
    async logEventRecord(projectId, eventType, payload, runId) {
        if (this.config?.externalProjectId) {
            const logEvent = this.requireRegisteredRunOp("logEvent");
            await logEvent(runId, projectId, eventType, payload);
            return;
        }
        await this.progressEventStore.logEvent(projectId, eventType, payload, runId);
    }
    // ── Run query operations ───────────────────────────────────────────────
    /**
     * Get active runs for a project.
     */
    async getActiveRunsRecord(projectId) {
        return this.runStore.getActiveRuns(projectId);
    }
    /**
     * Get runs by status for a project.
     */
    async getRunsByStatusRecord(status, projectId) {
        return this.runStore.getRunsByStatus(status, projectId);
    }
    /**
     * Get runs for a seed.
     */
    async getRunsForSeedRecord(seedId, projectId) {
        return this.runStore.getRunsForSeed(seedId, projectId);
    }
    /**
     * Get a run by ID.
     */
    async getRunRecord(runId) {
        return this.runStore.getRun(runId);
    }
}
//# sourceMappingURL=run-lifecycle-service.js.map