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
import type { ProgressEventStore } from "../lib/store.js";
import type { VcsBackend } from "../lib/vcs/index.js";
/**
 * Heartbeat configuration.
 */
export interface HeartbeatConfig {
    /** Enable heartbeat events. Default: true. */
    enabled?: boolean;
    /** Interval between heartbeats in seconds. Default: 60. */
    intervalSeconds?: number;
}
/**
 * Session statistics snapshot for heartbeat emission.
 */
export interface SessionStats {
    turns: number;
    toolCalls: number;
    toolBreakdown: Record<string, number>;
    costUsd: number;
    tokensIn: number;
    tokensOut: number;
    lastFileEdited?: string | null;
    lastActivity?: string;
}
/**
 * Heartbeat event data written to the store.
 */
export interface HeartbeatData {
    seedId: string;
    phase: string;
    turns: number;
    toolCalls: number;
    toolBreakdown: Record<string, number>;
    filesChanged: string[];
    costUsd: number;
    tokensIn: number;
    tokensOut: number;
    lastFileEdited: string | null;
    lastActivity: string;
    runId: string;
    projectId: string;
}
/**
 * Optional heartbeat event writer used by registered worker execution.
 */
export interface HeartbeatEventWriter {
    logEvent?: (eventType: "heartbeat", data: Record<string, unknown>) => Promise<void> | void;
}
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
export declare class HeartbeatManager {
    private config;
    private store;
    private eventWriter?;
    private projectId;
    private runId;
    private vcs;
    private worktreePath;
    private interval;
    private currentPhase;
    private lastStats;
    /** Files changed at the start of the phase (for delta computation). */
    private phaseStartFiles;
    /** HEAD commit at the start of the phase. */
    private phaseStartHead;
    /** Seed ID attached to heartbeat events for task attribution. */
    private seedId;
    /** Whether the heartbeat has fired at least once this phase. */
    private hasFired;
    constructor(config: HeartbeatConfig, store: ProgressEventStore, projectId: string, runId: string, vcs: VcsBackend, worktreePath: string, eventWriter?: HeartbeatEventWriter);
    /**
     * Start the heartbeat interval for a new phase.
     * Captures the initial state (HEAD, files) for delta computation.
     *
     * @param phaseName - Name of the current phase (e.g., "developer", "qa")
     */
    start(phaseName: string): Promise<void>;
    /**
     * Update the session statistics for the next heartbeat.
     * Call this after each tool call or turn to keep stats current.
     *
     * @param stats - Current session statistics
     */
    update(stats: SessionStats): void;
    /**
     * Stop the heartbeat interval.
     * Call this when the phase completes to clean up the timer.
     */
    stop(): void;
    /**
     * Check if the heartbeat interval is currently active.
     */
    isActive(): boolean;
    /**
     * Fire a heartbeat event immediately.
     * Useful for testing or when you need to emit a heartbeat before the interval.
     */
    fireHeartbeat(): Promise<void>;
    /**
     * Check if the heartbeat should fire now (for testing).
     * Returns true if the configured interval has elapsed since the last fire.
     */
    shouldFire(): boolean;
    /**
     * Get the current heartbeat configuration.
     */
    getConfig(): Readonly<HeartbeatConfig>;
    /**
     * Set the seed ID for heartbeat events.
     * Called by the pipeline executor after dispatch.
     */
    setSeedId(seedId: string): void;
}
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
export declare function createHeartbeatManager(config: HeartbeatConfig | undefined, store: ProgressEventStore, projectId: string, runId: string, vcs: VcsBackend, worktreePath: string, eventWriter?: HeartbeatEventWriter): HeartbeatManager | null;
//# sourceMappingURL=heartbeat-manager.d.ts.map