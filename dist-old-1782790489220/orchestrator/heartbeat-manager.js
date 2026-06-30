/**
 * Heartbeat manager — Periodic observability events during active pipeline phases.
 *
 * Writes structured heartbeat events to the Postgres events table every N seconds
 * (default: 60s), capturing turn count, tool call breakdown, files changed,
 * cost estimates, and last activity for operator visibility.
 *
 * Fail-safe: If `store.logEvent()` throws, the error is logged and the session
 * continues — heartbeat failures must never kill the agent session.
 *
 * @module src/orchestrator/heartbeat-manager
 */
// ── HeartbeatManager ─────────────────────────────────────────────────────
/**
 * Manages periodic heartbeat events during an active pipeline phase.
 *
 * Tracks session statistics and writes heartbeat events to the Postgres store
 * at configured intervals. The manager is non-blocking and handles store
 * write failures gracefully.
 *
 * Usage:
 * ```typescript
 * const manager = new HeartbeatManager(
 *   { enabled: true, intervalSeconds: 60 },
 *   store,
 *   projectId,
 *   runId,
 *   vcsBackend,
 *   worktreePath,
 * );
 * manager.start("developer");
 * // ... during phase ...
 * manager.update({ turns: 10, toolCalls: 25, ... });
 * // ... at phase end ...
 * manager.stop();
 * ```
 */
export class HeartbeatManager {
    config;
    store;
    eventWriter;
    projectId;
    runId;
    vcs;
    worktreePath;
    interval = null;
    currentPhase = null;
    lastStats = null;
    /** Files changed at the start of the phase (for delta computation). */
    phaseStartFiles = [];
    /** HEAD commit at the start of the phase. */
    phaseStartHead = "";
    /** Seed ID attached to heartbeat events for task attribution. */
    seedId = "";
    /** Whether the heartbeat has fired at least once this phase. */
    hasFired = false;
    constructor(config, store, projectId, runId, vcs, worktreePath, eventWriter) {
        this.config = {
            enabled: config.enabled ?? true,
            intervalSeconds: config.intervalSeconds ?? 60,
        };
        this.store = store;
        this.projectId = projectId;
        this.runId = runId;
        this.vcs = vcs;
        this.worktreePath = worktreePath;
        this.eventWriter = eventWriter;
    }
    /**
     * Start the heartbeat interval for a new phase.
     * Captures the initial state (HEAD, files) for delta computation.
     *
     * @param phaseName - Name of the current phase (e.g., "developer", "qa")
     */
    async start(phaseName) {
        if (!this.config.enabled)
            return;
        this.currentPhase = phaseName;
        this.hasFired = false;
        // Capture initial state
        try {
            this.phaseStartHead = await this.vcs.getHeadId(this.worktreePath);
            this.phaseStartFiles = await this.vcs.getChangedFiles(this.worktreePath, this.phaseStartHead, this.phaseStartHead);
        }
        catch {
            // Best effort — proceed with empty state
            this.phaseStartHead = "";
            this.phaseStartFiles = [];
        }
        // Calculate interval in milliseconds
        const intervalMs = this.config.intervalSeconds * 1000;
        this.interval = setInterval(() => {
            this.fireHeartbeat().catch((err) => {
                // Fail-safe: log the error but don't crash the session
                console.error(`[HeartbeatManager] Heartbeat write failed (non-fatal): ${err instanceof Error ? err.message : String(err)}`);
            });
        }, intervalMs);
    }
    /**
     * Update the session statistics for the next heartbeat.
     * Call this after each tool call or turn to keep stats current.
     *
     * @param stats - Current session statistics
     */
    update(stats) {
        this.lastStats = { ...stats };
    }
    /**
     * Stop the heartbeat interval.
     * Call this when the phase completes to clean up the timer.
     */
    stop() {
        if (this.interval) {
            clearInterval(this.interval);
            this.interval = null;
        }
        this.currentPhase = null;
        this.lastStats = null;
        this.hasFired = false;
    }
    /**
     * Check if the heartbeat interval is currently active.
     */
    isActive() {
        return this.interval !== null;
    }
    /**
     * Fire a heartbeat event immediately.
     * Useful for testing or when you need to emit a heartbeat before the interval.
     */
    async fireHeartbeat() {
        if (!this.config.enabled || !this.currentPhase)
            return;
        // Don't fire if we haven't started
        if (!this.interval && !this.hasFired)
            return;
        // Get current stats (or use last known)
        const stats = this.lastStats ?? {
            turns: 0,
            toolCalls: 0,
            toolBreakdown: {},
            costUsd: 0,
            tokensIn: 0,
            tokensOut: 0,
            lastFileEdited: null,
            lastActivity: new Date().toISOString(),
        };
        // Compute files changed since phase start
        let filesChanged = [];
        if (this.phaseStartHead) {
            try {
                const currentHead = await this.vcs.getHeadId(this.worktreePath);
                filesChanged = await this.vcs.getChangedFiles(this.worktreePath, this.phaseStartHead, currentHead);
            }
            catch {
                // Best effort — use empty list
            }
        }
        const heartbeatData = {
            seedId: this.seedId,
            phase: this.currentPhase,
            turns: stats.turns,
            toolCalls: stats.toolCalls,
            toolBreakdown: stats.toolBreakdown,
            filesChanged,
            costUsd: stats.costUsd,
            tokensIn: stats.tokensIn,
            tokensOut: stats.tokensOut,
            lastFileEdited: stats.lastFileEdited ?? null,
            lastActivity: stats.lastActivity ?? new Date().toISOString(),
            runId: this.runId,
            projectId: this.projectId,
        };
        try {
            if (this.eventWriter?.logEvent) {
                await Promise.resolve(this.eventWriter.logEvent("heartbeat", heartbeatData));
            }
            else {
                this.store.logEvent(this.projectId, "heartbeat", heartbeatData, this.runId);
            }
            this.hasFired = true;
        }
        catch (err) {
            // Fail-safe: log and continue
            console.error(`[HeartbeatManager] heartbeat event write failed (non-fatal): ${err instanceof Error ? err.message : String(err)}`);
        }
    }
    /**
     * Check if the heartbeat should fire now (for testing).
     * Returns true if the configured interval has elapsed since the last fire.
     */
    shouldFire() {
        return this.config.enabled && this.currentPhase !== null;
    }
    /**
     * Get the current heartbeat configuration.
     */
    getConfig() {
        return { ...this.config };
    }
    /**
     * Set the seed ID for heartbeat events.
     * Called by the pipeline executor after dispatch.
     */
    setSeedId(seedId) {
        this.seedId = seedId;
    }
}
// ── Factory function ──────────────────────────────────────────────────────
/**
 * Create a HeartbeatManager from project configuration.
 *
 * Reads `observability.heartbeat` from ProjectConfig and creates a manager
 * with sensible defaults. Returns null if heartbeat is disabled.
 *
 * @param config - Heartbeat config from ProjectConfig.observability.heartbeat
 * @param store - ForemanStore for event logging
 * @param projectId - Project ID for event scoping
 * @param runId - Run ID for event scoping
 * @param vcs - VcsBackend for file change tracking
 * @param worktreePath - Worktree path for diff operations
 */
export function createHeartbeatManager(config, store, projectId, runId, vcs, worktreePath, eventWriter) {
    // If config is explicitly disabled, return null
    if (config?.enabled === false) {
        return null;
    }
    return new HeartbeatManager(config ?? {}, store, projectId, runId, vcs, worktreePath, eventWriter);
}
//# sourceMappingURL=heartbeat-manager.js.map