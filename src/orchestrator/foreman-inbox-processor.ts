/**
 * ForemanInboxProcessor — polls the "foreman" Agent Mail inbox for
 * "phase-complete" messages and translates them into "branch-ready" messages
 * sent to the MergeAgent's "refinery" mailbox.
 *
 * This bridges the gap between PiRpcSpawnStrategy (which sends phase-complete
 * to "foreman" when a Pi agent finishes) and MergeAgent (which listens on
 * "refinery" for branch-ready messages).
 *
 * Message flow:
 *   Pi agent → "foreman" inbox: { subject: "phase-complete", body: { seedId, phase, runId, status } }
 *   ForemanInboxProcessor → "refinery" inbox: { subject: "branch-ready", body: { seedId, runId, branch, worktreePath } }
 *   MergeAgent → triggers Refinery merge
 */

import type { AgentMailClient } from "./agent-mail-client.js";
import type { AgentMailMessage } from "./agent-mail-client.js";
import type { ForemanStore } from "../lib/store.js";
import { MERGE_AGENT_MAILBOX } from "./merge-agent.js";

// ── Constants ─────────────────────────────────────────────────────────────

/** Default poll interval in ms (30 seconds, matching MergeAgent). */
export const DEFAULT_INBOX_POLL_INTERVAL_MS = 30_000;

/** Agent Mail inbox name that the Foreman orchestrator reads. */
export const FOREMAN_MAILBOX = "foreman";

// ── Types ─────────────────────────────────────────────────────────────────

/** Payload carried in a "phase-complete" message body. */
export interface PhaseCompletePayload {
  seedId: string;
  phase: string;
  runId: string;
  status: "complete" | "error" | string;
}

// ── ForemanInboxProcessor ─────────────────────────────────────────────────

/**
 * Continuously-running daemon that reads the "foreman" Agent Mail inbox and
 * translates "phase-complete" messages into "branch-ready" messages for the
 * MergeAgent.
 *
 * Usage:
 *   const processor = new ForemanInboxProcessor(agentMailClient, store, projectPath);
 *   processor.start();
 *   // later...
 *   processor.stop();
 */
export class ForemanInboxProcessor {
  private agentMailClient: AgentMailClient;
  private store: ForemanStore;
  private projectPath: string;
  private running = false;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private pollIntervalMs: number;

  constructor(
    agentMailClient: AgentMailClient,
    store: ForemanStore,
    projectPath: string,
    pollIntervalMs: number = DEFAULT_INBOX_POLL_INTERVAL_MS,
  ) {
    this.agentMailClient = agentMailClient;
    this.store = store;
    this.projectPath = projectPath;
    this.pollIntervalMs = pollIntervalMs;
  }

  /**
   * Start the inbox processor daemon loop.
   * Polls the "foreman" Agent Mail inbox on each interval.
   */
  start(intervalMs?: number): void {
    if (this.running) {
      throw new Error("ForemanInboxProcessor is already running");
    }
    if (intervalMs !== undefined) {
      this.pollIntervalMs = intervalMs;
    }
    this.running = true;

    let activePoll = false;

    const loop = async (): Promise<void> => {
      if (!this.running) return;

      if (activePoll) {
        // Previous poll cycle still in progress — skip this tick
        this.timer = setTimeout(() => void loop(), this.pollIntervalMs);
        return;
      }

      activePoll = true;
      try {
        await this.pollOnce();
      } catch (err) {
        console.error("[foreman-inbox] Unexpected error in poll loop:", err);
      } finally {
        activePoll = false;
      }

      if (this.running) {
        this.timer = setTimeout(() => void loop(), this.pollIntervalMs);
      }
    };

    void loop();
  }

  /** Stop the inbox processor daemon (in-flight poll cycle completes normally). */
  stop(): void {
    this.running = false;
    if (this.timer !== null) {
      clearTimeout(this.timer);
      this.timer = null;
    }
  }

  isRunning(): boolean {
    return this.running;
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  /**
   * Execute a single poll cycle:
   * 1. Health-check Agent Mail — skip if unavailable.
   * 2. Fetch unacknowledged messages from the "foreman" inbox.
   * 3. Process each "phase-complete" message.
   */
  private async pollOnce(): Promise<void> {
    // Graceful degradation: skip cycle if Agent Mail is not reachable
    let healthy = false;
    try {
      healthy = await this.agentMailClient.healthCheck();
    } catch {
      // Silent failure
    }

    if (!healthy) {
      console.warn(
        "[foreman-inbox] Agent Mail server is not running — skipping poll cycle",
      );
      return;
    }

    let messages: AgentMailMessage[] = [];
    try {
      messages = await this.agentMailClient.fetchInbox(FOREMAN_MAILBOX, {
        limit: 50,
      });
    } catch {
      // Silent failure — fetchInbox already swallows errors, but guard defensively
      return;
    }

    const pending = messages.filter(
      (m) => !m.acknowledged && m.subject === "phase-complete",
    );

    for (const msg of pending) {
      // Each message is processed in isolation — one failure must not stop others
      try {
        await this.processPhaseComplete(msg);
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        console.error(
          `[foreman-inbox] Failed to process message ${msg.id}: ${message}`,
        );
      }
    }
  }

  /**
   * Process a single "phase-complete" message:
   * 1. Parse the payload.
   * 2. Look up the run in SQLite to get worktreePath.
   * 3. If status=complete: send "branch-ready" to the "refinery" mailbox.
   * 4. Acknowledge the message (always, to prevent reprocessing).
   */
  private async processPhaseComplete(msg: AgentMailMessage): Promise<void> {
    const msgId = parseInt(msg.id, 10);

    // Parse the payload
    let payload: PhaseCompletePayload;
    try {
      payload = JSON.parse(msg.body) as PhaseCompletePayload;
    } catch {
      console.warn(
        `[foreman-inbox] Ignoring message ${msg.id}: invalid JSON body`,
      );
      await this.acknowledgeQuietly(msgId);
      return;
    }

    const { seedId, phase, runId, status } = payload;

    if (!seedId || !runId) {
      console.warn(
        `[foreman-inbox] Ignoring message ${msg.id}: missing seedId or runId`,
      );
      await this.acknowledgeQuietly(msgId);
      return;
    }

    if (status === "error") {
      console.warn(
        `[foreman-inbox] Phase ${phase ?? "unknown"} for ${seedId} reported error — skipping branch-ready`,
      );
      await this.acknowledgeQuietly(msgId);
      return;
    }

    if (status !== "complete") {
      console.warn(
        `[foreman-inbox] Unknown status "${status}" for ${seedId} — acknowledging without action`,
      );
      await this.acknowledgeQuietly(msgId);
      return;
    }

    // Look up the run to get worktreePath
    let worktreePath: string | undefined;
    try {
      const run = this.store.getRun(runId);
      if (!run) {
        console.warn(
          `[foreman-inbox] Run ${runId} not found for seed ${seedId} — acknowledging without action`,
        );
        await this.acknowledgeQuietly(msgId);
        return;
      }
      // Only forward runs that actually completed successfully in SQLite.
      // Runs that were reset (failed/conflict) should not trigger a merge.
      if (run.status !== "completed") {
        console.warn(
          `[foreman-inbox] Run ${runId} has status "${run.status}" (not completed) — acknowledging without merge`,
        );
        await this.acknowledgeQuietly(msgId);
        return;
      }
      worktreePath = run.worktree_path ?? undefined;
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      console.warn(
        `[foreman-inbox] Failed to look up run ${runId}: ${message} — acknowledging without action`,
      );
      await this.acknowledgeQuietly(msgId);
      return;
    }

    // Derive the branch name using the same convention as the rest of the codebase
    const branch = `foreman/${seedId}`;

    console.log(
      `[foreman-inbox] Phase-complete for ${phase}/${seedId} → sending branch-ready: ${branch}`,
    );

    // Send branch-ready to the refinery mailbox
    try {
      await this.agentMailClient.sendMessage(
        MERGE_AGENT_MAILBOX,
        "branch-ready",
        JSON.stringify({ seedId, runId, branch, worktreePath }),
      );
    } catch {
      // Silent failure — Agent Mail errors must never surface
      console.warn(
        `[foreman-inbox] Failed to send branch-ready for ${seedId} (non-fatal)`,
      );
    }

    // Acknowledge the phase-complete message (do this even on send failure)
    await this.acknowledgeQuietly(msgId);
  }

  /** Acknowledge a message, swallowing any errors. */
  private async acknowledgeQuietly(msgId: number): Promise<void> {
    try {
      await this.agentMailClient.acknowledgeMessage(FOREMAN_MAILBOX, msgId);
    } catch {
      // Silent failure
    }
  }
}
