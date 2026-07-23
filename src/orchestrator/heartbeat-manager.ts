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

// ── Constants ─────────────────────────────────────────────────────────────

/**
 * Phases that poll for external conditions and should NOT receive overwatch nudges.
 * These phases intentionally wait without activity, so nudging them is noisy and unhelpful.
 */
const POLLING_PHASES = new Set([
  "merge",      // Polls for PR merge completion
  "pr-wait",    // Polls for PR checks/review readiness
  "refinery",   // Processes merge queue (may poll)
]);

/**
 * Check if a phase is a polling phase that should not receive overwatch nudges.
 */
function isPollingPhase(phase: string): boolean {
  return POLLING_PHASES.has(phase);
}

// ── Types ─────────────────────────────────────────────────────────────────

/**
 * Heartbeat configuration.
 */
export interface HeartbeatConfig {
  /** Enable heartbeat events. Default: true. */
  enabled?: boolean;
  /** Interval between heartbeats in seconds. Default: 60. */
  intervalSeconds?: number;
  /** Enable phase overwatch nudges when heartbeat stats stop moving. Default: true. */
  overwatchEnabled?: boolean;
  /** Number of unchanged heartbeat intervals before a nudge. Default: 2. */
  overwatchStaleIntervals?: number;
  /** Maximum nudges per phase. Default: 3. */
  overwatchMaxNudges?: number;
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
  taskId: string;
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
  logEvent?: (eventType: "heartbeat" | "phase-nudge", data: Record<string, unknown>) => Promise<void> | void;
}

export interface OverwatchCallbacks {
  sendNudge?: (recipient: string, subject: string, body: string) => Promise<void> | void;
  log?: (message: string) => void;
}

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
  private config: Required<HeartbeatConfig>;
  private store: ProgressEventStore;
  private eventWriter?: HeartbeatEventWriter;
  private overwatch?: OverwatchCallbacks;
  private projectId: string;
  private runId: string;
  private vcs: VcsBackend;
  private worktreePath: string;

  private interval: ReturnType<typeof setInterval> | null = null;
  private currentPhase: string | null = null;
  private lastStats: SessionStats | null = null;

  /** Files changed at the start of the phase (for delta computation). */
  private phaseStartFiles: string[] = [];
  /** HEAD commit at the start of the phase. */
  private phaseStartHead: string = "";
  /** Task ID attached to heartbeat events for task attribution. */
  private taskId = "";
  /** Whether the heartbeat has fired at least once this phase. */
  private hasFired = false;
  private overwatchSnapshot: string | null = null;
  private overwatchStaleCount = 0;
  private overwatchNudgeCount = 0;

  constructor(
    config: HeartbeatConfig,
    store: ProgressEventStore,
    projectId: string,
    runId: string,
    vcs: VcsBackend,
    worktreePath: string,
    eventWriter?: HeartbeatEventWriter,
    overwatch?: OverwatchCallbacks,
  ) {
    this.config = {
      enabled: config.enabled ?? true,
      intervalSeconds: config.intervalSeconds ?? 60,
      overwatchEnabled: config.overwatchEnabled ?? true,
      overwatchStaleIntervals: Math.max(1, config.overwatchStaleIntervals ?? 2),
      overwatchMaxNudges: Math.max(0, config.overwatchMaxNudges ?? 3),
    };
    this.store = store;
    this.projectId = projectId;
    this.runId = runId;
    this.vcs = vcs;
    this.worktreePath = worktreePath;
    this.eventWriter = eventWriter;
    this.overwatch = overwatch;
  }

  /**
   * Start the heartbeat interval for a new phase.
   * Captures the initial state (HEAD, files) for delta computation.
   *
   * @param phaseName - Name of the current phase (e.g., "developer", "qa")
   */
  async start(phaseName: string): Promise<void> {
    if (!this.config.enabled) return;

    this.currentPhase = phaseName;
    this.hasFired = false;
    this.overwatchSnapshot = null;
    this.overwatchStaleCount = 0;
    this.overwatchNudgeCount = 0;

    // Capture initial state
    try {
      this.phaseStartHead = await this.vcs.getHeadId(this.worktreePath);
      this.phaseStartFiles = await this.vcs.getChangedFiles(
        this.worktreePath,
        this.phaseStartHead,
        this.phaseStartHead,
      );
    } catch {
      // Best effort — proceed with empty state
      this.phaseStartHead = "";
      this.phaseStartFiles = [];
    }

    // Calculate interval in milliseconds
    const intervalMs = this.config.intervalSeconds * 1000;

    this.interval = setInterval(() => {
      this.fireHeartbeat().catch((err) => {
        // Fail-safe: log the error but don't crash the session
        console.error(
          `[HeartbeatManager] Heartbeat write failed (non-fatal): ${err instanceof Error ? err.message : String(err)}`,
        );
      });
    }, intervalMs);
  }

  /**
   * Update the session statistics for the next heartbeat.
   * Call this after each tool call or turn to keep stats current.
   *
   * @param stats - Current session statistics
   */
  update(stats: SessionStats): void {
    this.lastStats = { ...stats };
  }

  /**
   * Stop the heartbeat interval.
   * Call this when the phase completes to clean up the timer.
   */
  stop(): void {
    if (this.interval) {
      clearInterval(this.interval);
      this.interval = null;
    }
    this.currentPhase = null;
    this.lastStats = null;
    this.hasFired = false;
    this.overwatchSnapshot = null;
    this.overwatchStaleCount = 0;
    this.overwatchNudgeCount = 0;
  }

  /**
   * Check if the heartbeat interval is currently active.
   */
  isActive(): boolean {
    return this.interval !== null;
  }

  /**
   * Fire a heartbeat event immediately.
   * Useful for testing or when you need to emit a heartbeat before the interval.
   */
  async fireHeartbeat(): Promise<void> {
    if (!this.config.enabled || !this.currentPhase) return;

    // Don't fire if we haven't started
    if (!this.interval && !this.hasFired) return;

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
    let filesChanged: string[] = [];
    if (this.phaseStartHead) {
      try {
        const currentHead = await this.vcs.getHeadId(this.worktreePath);
        filesChanged = await this.vcs.getChangedFiles(
          this.worktreePath,
          this.phaseStartHead,
          currentHead,
        );
      } catch {
        // Best effort — use empty list
      }
    }

    const heartbeatData: HeartbeatData = {
      taskId: this.taskId,
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
        await Promise.resolve(this.eventWriter.logEvent("heartbeat", heartbeatData as unknown as Record<string, unknown>));
      } else {
        this.store.logEvent(this.projectId, "heartbeat", heartbeatData as unknown as Record<string, unknown>, this.runId);
      }
      this.hasFired = true;
      await this.maybeNudge(heartbeatData);
    } catch (err) {
      // Fail-safe: log and continue
      console.error(
        `[HeartbeatManager] heartbeat event write failed (non-fatal): ${err instanceof Error ? err.message : String(err)}`,
      );
    }
  }

  private async maybeNudge(data: HeartbeatData): Promise<void> {
    if (!this.config.overwatchEnabled || this.config.overwatchMaxNudges <= 0 || !this.currentPhase) return;

    // Skip nudging for polling phases — they intentionally wait without activity
    if (isPollingPhase(this.currentPhase)) return;

    const snapshot = JSON.stringify({
      turns: data.turns,
      toolCalls: data.toolCalls,
      costUsd: Number(data.costUsd.toFixed(6)),
      tokensIn: data.tokensIn,
      tokensOut: data.tokensOut,
      filesChanged: [...data.filesChanged].sort(),
      lastFileEdited: data.lastFileEdited,
    });

    if (this.overwatchSnapshot === null || snapshot !== this.overwatchSnapshot) {
      this.overwatchSnapshot = snapshot;
      this.overwatchStaleCount = 0;
      return;
    }

    this.overwatchStaleCount += 1;
    if (this.overwatchStaleCount < this.config.overwatchStaleIntervals) return;
    if (this.overwatchNudgeCount >= this.config.overwatchMaxNudges) return;

    this.overwatchNudgeCount += 1;
    this.overwatchStaleCount = 0;

    const recipient = this.taskId ? `${this.currentPhase}-${this.taskId}` : this.currentPhase;
    const subject = `Overwatch nudge: ${this.currentPhase}`;
    const body = [
      `Overwatch noticed no new phase activity for ${this.config.overwatchStaleIntervals} heartbeat intervals.`,
      "Refocus on the current phase objective.",
      "Summarize current state, pick the next concrete action, and proceed.",
      "If blocked, send a concise agent-error / blocker note instead of spinning.",
      `Run: ${this.runId}`,
      this.taskId ? `Task: ${this.taskId}` : undefined,
      `Phase: ${this.currentPhase}`,
    ].filter(Boolean).join("\n");

    try {
      await Promise.resolve(this.overwatch?.sendNudge?.(recipient, subject, body));
      const eventData = {
        ...data,
        recipient,
        subject,
        nudgeCount: this.overwatchNudgeCount,
        staleIntervals: this.config.overwatchStaleIntervals,
        message: "No new phase activity; overwatch sent a steering nudge.",
      };
      if (this.eventWriter?.logEvent) {
        await Promise.resolve(this.eventWriter.logEvent("phase-nudge", eventData));
      } else {
        this.store.logEvent(this.projectId, "phase-nudge", eventData, this.runId);
      }
      this.overwatch?.log?.(`[OVERWATCH] Nudged ${recipient} after stale ${this.currentPhase} heartbeat`);
    } catch (err) {
      this.overwatch?.log?.(`[OVERWATCH] nudge failed (non-fatal): ${err instanceof Error ? err.message : String(err)}`);
    }
  }

  /**
   * Check if the heartbeat should fire now (for testing).
   * Returns true if the configured interval has elapsed since the last fire.
   */
  shouldFire(): boolean {
    return this.config.enabled && this.currentPhase !== null;
  }

  /**
   * Get the current heartbeat configuration.
   */
  getConfig(): Readonly<HeartbeatConfig> {
    return { ...this.config };
  }

  /**
   * Set the task ID for heartbeat events.
   * Called by the pipeline executor after dispatch.
   */
  setTaskId(taskId: string): void {
    this.taskId = taskId;
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
export function createHeartbeatManager(
  config: HeartbeatConfig | undefined,
  store: ProgressEventStore,
  projectId: string,
  runId: string,
  vcs: VcsBackend,
  worktreePath: string,
  eventWriter?: HeartbeatEventWriter,
  overwatch?: OverwatchCallbacks,
): HeartbeatManager | null {
  // If config is explicitly disabled, return null
  if (config?.enabled === false) {
    return null;
  }

  return new HeartbeatManager(
    config ?? {},
    store,
    projectId,
    runId,
    vcs,
    worktreePath,
    eventWriter,
    overwatch,
  );
}
