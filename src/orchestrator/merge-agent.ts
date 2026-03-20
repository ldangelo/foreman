/**
 * MergeAgent — daemon that polls Agent Mail for "branch-ready" messages and
 * triggers the Refinery merge logic automatically.
 *
 * Eliminates the need for manual `foreman merge` by reacting to messages that
 * agent-worker.ts sends when a pipeline run completes successfully.
 *
 * Message body format (from agent-worker.ts):
 *   { "seedId": "bd-xxx", "runId": "run-yyy", "branch": "foreman/bd-xxx", "worktreePath": "/path" }
 */

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { ForemanStore } from "../lib/store.js";
import type { IRefineryTaskClient } from "./refinery.js";
import { Refinery } from "./refinery.js";
import { MergeQueue } from "./merge-queue.js";
import { AgentMailClient } from "./agent-mail-client.js";
import type { AgentMailMessage } from "./agent-mail-client.js";
import { detectDefaultBranch } from "../lib/git.js";

const execFileAsync = promisify(execFile);

// ── Constants ─────────────────────────────────────────────────────────────

/** Mailbox name the merge agent listens on. */
export const MERGE_AGENT_MAILBOX = "refinery";

/** Default poll interval in ms (30 seconds, matching sentinel). */
export const DEFAULT_POLL_INTERVAL_MS = 30_000;

// ── Types ─────────────────────────────────────────────────────────────────

export interface BranchReadyPayload {
  seedId: string;
  runId: string;
  branch: string;
  worktreePath?: string;
}

export interface MergeAgentConfig {
  enabled: number; // 1 = enabled, 0 = disabled (SQLite boolean)
  poll_interval_ms: number;
}

// ── MergeAgent ────────────────────────────────────────────────────────────

/**
 * Continuously-running daemon that reacts to "branch-ready" messages from
 * Agent Mail and triggers the existing Refinery merge logic.
 *
 * Usage:
 *   const agent = new MergeAgent(projectPath, store, taskClient);
 *   agent.start();
 *   // later...
 *   agent.stop();
 */
export class MergeAgent {
  private agentMail: AgentMailClient | null = null;
  private store: ForemanStore;
  private taskClient: IRefineryTaskClient;
  private projectPath: string;
  private running = false;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private pollIntervalMs: number;

  constructor(
    projectPath: string,
    store: ForemanStore,
    taskClient: IRefineryTaskClient,
    pollIntervalMs: number = DEFAULT_POLL_INTERVAL_MS,
  ) {
    this.projectPath = projectPath;
    this.store = store;
    this.taskClient = taskClient;
    this.pollIntervalMs = pollIntervalMs;

    try {
      this.agentMail = new AgentMailClient();
    } catch {
      // Non-fatal — if Agent Mail client cannot be constructed, daemon will skip
      // poll cycles gracefully.
      this.agentMail = null;
    }
  }

  /**
   * Start the merge agent daemon loop.
   * Polls Agent Mail on each interval; processes any "branch-ready" messages.
   */
  start(): void {
    if (this.running) {
      throw new Error("MergeAgent is already running");
    }
    this.running = true;

    // Register our mailbox with Agent Mail on startup (non-fatal if unavailable).
    if (this.agentMail) {
      void this.agentMail.registerAgent(MERGE_AGENT_MAILBOX);
    }

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
        console.error("[merge-agent] Unexpected error in poll loop:", err);
      } finally {
        activePoll = false;
      }

      if (this.running) {
        this.timer = setTimeout(() => void loop(), this.pollIntervalMs);
      }
    };

    void loop();
  }

  /** Stop the merge agent daemon (in-flight poll cycle completes normally). */
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

  // ── Private helpers ─────────────────────────────────────────────────────

  /**
   * Execute a single poll cycle:
   * 1. Health-check Agent Mail — skip if unavailable.
   * 2. Fetch all unacknowledged messages in the "refinery" inbox.
   * 3. Process each "branch-ready" message.
   */
  private async pollOnce(): Promise<void> {
    if (!this.agentMail) return;

    // Graceful degradation: skip cycle if Agent Mail is not reachable
    const healthy = await this.agentMail.healthCheck();
    if (!healthy) {
      console.warn("[merge-agent] Agent Mail server is not running — skipping poll cycle");
      return;
    }

    const messages = await this.agentMail.fetchInbox(MERGE_AGENT_MAILBOX, { unreadOnly: false });
    const pending = messages.filter((m) => !m.acknowledged && m.subject === "branch-ready");

    for (const msg of pending) {
      // Each message is processed in isolation — one failure must not stop others
      try {
        await this.processBranchReady(msg);
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        console.error(`[merge-agent] Failed to process message ${msg.id}: ${message}`);
      }
    }
  }

  /**
   * Process a single "branch-ready" message:
   * 1. Parse the payload.
   * 2. Enqueue the branch in the merge queue.
   * 3. Call Refinery to merge.
   * 4. Acknowledge the message.
   * 5. Report outcome via Agent Mail.
   */
  private async processBranchReady(msg: AgentMailMessage): Promise<void> {
    // Parse the payload
    let payload: BranchReadyPayload;
    try {
      payload = JSON.parse(msg.body) as BranchReadyPayload;
    } catch {
      console.warn(`[merge-agent] Ignoring message ${msg.id}: invalid JSON body`);
      // Acknowledge malformed messages so they don't pile up
      await this.agentMail!.acknowledgeMessage(MERGE_AGENT_MAILBOX, parseInt(msg.id, 10));
      return;
    }

    const { seedId, runId, branch } = payload;
    if (!seedId || !runId || !branch) {
      console.warn(`[merge-agent] Ignoring message ${msg.id}: missing required fields (seedId, runId, branch)`);
      await this.agentMail!.acknowledgeMessage(MERGE_AGENT_MAILBOX, parseInt(msg.id, 10));
      return;
    }

    console.log(`[merge-agent] Processing branch-ready: ${branch} (seed: ${seedId}, run: ${runId})`);

    // Enqueue the branch in the merge queue so it's visible to other tooling
    const mq = new MergeQueue(this.store.getDb());
    let filesModified: string[] = [];
    try {
      const targetBranch = await detectDefaultBranch(this.projectPath);
      const { stdout } = await execFileAsync(
        "git",
        ["diff", "--name-only", `${targetBranch}...${branch}`],
        { cwd: this.projectPath },
      );
      filesModified = stdout.trim().split("\n").filter(Boolean);
    } catch {
      // Non-fatal — proceed with empty files list
    }

    mq.enqueue({ branchName: branch, seedId, runId, filesModified });

    // Call Refinery to merge
    const refinery = new Refinery(this.store, this.taskClient, this.projectPath);
    let mergeError: string | null = null;

    try {
      const targetBranch = await detectDefaultBranch(this.projectPath);
      const report = await refinery.mergeCompleted({
        targetBranch,
        runTests: true,
        testCommand: "npm test",
        seedId,
      });

      // Update the merge queue entry based on outcome
      const entry = mq.list().find((e) => e.run_id === runId);
      if (entry) {
        if (report.merged.length > 0) {
          mq.updateStatus(entry.id, "merged", { completedAt: new Date().toISOString() });
        } else if (report.conflicts.length > 0 || report.prsCreated.length > 0) {
          const conflictFiles = report.conflicts[0]?.conflictFiles ?? [];
          mergeError = `Merge conflict in files: ${conflictFiles.join(", ") || "unknown"}`;
          mq.updateStatus(entry.id, "conflict", { error: mergeError });
        } else if (report.testFailures.length > 0) {
          mergeError = `Tests failed after merge`;
          mq.updateStatus(entry.id, "failed", { error: mergeError });
        } else {
          mergeError = "No completed run found to merge";
          mq.updateStatus(entry.id, "failed", { error: mergeError });
        }
      }
    } catch (err) {
      mergeError = err instanceof Error ? err.message : String(err);
      // Update the merge queue entry to failed state
      const entry = mq.list().find((e) => e.run_id === runId);
      if (entry) {
        mq.updateStatus(entry.id, "failed", { error: mergeError });
      }
    }

    // Acknowledge the message (do this even on merge failure so we don't reprocess)
    await this.agentMail!.acknowledgeMessage(MERGE_AGENT_MAILBOX, parseInt(msg.id, 10));

    // Report outcome back to "foreman" via Agent Mail
    if (mergeError) {
      await this.agentMail!.sendMessage(
        "foreman",
        "merge-conflict",
        JSON.stringify({ seedId, branch, error: mergeError }),
      );
      console.warn(`[merge-agent] Merge conflict/failure for ${branch}: ${mergeError}`);
    } else {
      await this.agentMail!.sendMessage(
        "foreman",
        "merge-complete",
        JSON.stringify({ seedId, branch, result: "merged" }),
      );
      console.log(`[merge-agent] Successfully merged ${branch}`);
    }
  }
}
