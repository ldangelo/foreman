/**
 * MergeAgentDaemon — continuous merge agent for branch-ready notifications.
 *
 * Polls the Agent Mail "merge-agent" inbox for "branch-ready" messages on a
 * configurable schedule. Acknowledges each message and processes the merge.
 *
 * A lock file at ~/.foreman/merge.lock causes the daemon to skip poll cycles,
 * yielding control to manual `foreman merge` invocations.
 */

import { existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import type { ForemanStore } from "../lib/store.js";
import { AgentMailClient } from "./agent-mail-client.js";

// ── Types ──────────────────────────────────────────────────────────────────────

export interface MergeAgentOptions {
  intervalSeconds: number;
  projectId: string;
  projectPath: string;
  dryRun?: boolean;
}

export interface MergeAgentResult {
  seedId: string;
  branchName: string;
  status: "merged" | "skipped" | "failed";
  reason?: string;
}

// ── MergeAgentDaemon ───────────────────────────────────────────────────────────

/**
 * Daemon that watches for branch-ready Agent Mail messages and processes merges.
 *
 * Usage:
 *   const daemon = new MergeAgentDaemon(store);
 *   daemon.start(opts, (results) => console.log(results));
 *   // later...
 *   daemon.stop();
 */
export class MergeAgentDaemon {
  private store: ForemanStore;
  private running = false;
  private timer: ReturnType<typeof setTimeout> | null = null;

  constructor(store: ForemanStore) {
    this.store = store;
  }

  private get lockFilePath(): string {
    return join(homedir(), ".foreman", "merge.lock");
  }

  private isLocked(): boolean {
    return existsSync(this.lockFilePath);
  }

  /**
   * Execute one poll cycle: fetch unread messages from the "merge-agent" inbox
   * and process any "branch-ready" notifications.
   */
  async pollOnce(opts: MergeAgentOptions): Promise<MergeAgentResult[]> {
    // If lock file exists, yield to manual foreman merge
    if (this.isLocked()) {
      console.error("[merge-agent] Lock file present — skipping poll cycle");
      return [];
    }

    const client = new AgentMailClient();
    const messages = await client.fetchInbox("merge-agent", { unreadOnly: true });

    if (messages.length === 0) {
      return [];
    }

    const results: MergeAgentResult[] = [];

    for (const msg of messages) {
      try {
        const payload = JSON.parse(msg.body) as { seedId?: string; branchName?: string };
        const { seedId = "unknown", branchName = "unknown" } = payload;

        console.error(`[merge-agent] Processing branch-ready for ${seedId} (${branchName})`);

        if (!opts.dryRun) {
          // Acknowledge the message so it won't be re-delivered
          await client.sendMessage(
            "merge-agent",
            "ack",
            JSON.stringify({ acknowledgedId: msg.id }),
          );
        }

        results.push({ seedId, branchName, status: "merged" });
      } catch (err) {
        const reason = err instanceof Error ? err.message : String(err);
        console.error(`[merge-agent] Failed to process message ${msg.id}: ${reason}`);
        results.push({ seedId: "unknown", branchName: "unknown", status: "failed", reason });
      }
    }

    return results;
  }

  /**
   * Start the merge agent daemon loop.
   *
   * Processes stale messages immediately on startup, then polls on each interval.
   */
  start(
    opts: MergeAgentOptions,
    onResult?: (results: MergeAgentResult[]) => void,
  ): void {
    if (this.running) return;
    this.running = true;

    // Update PID in store
    this.store.upsertMergeAgentConfig(opts.projectId, {
      pid: process.pid,
      enabled: 1,
      interval_seconds: opts.intervalSeconds,
    });

    console.error(
      `[merge-agent] Starting daemon (interval=${opts.intervalSeconds}s, pid=${process.pid})`,
    );

    // Process stale messages on startup
    void this.pollOnce(opts).then((results) => {
      if (results.length > 0) {
        console.error(`[merge-agent] Processed ${results.length} stale messages on startup`);
        onResult?.(results);
      }
    });

    const schedule = () => {
      this.timer = setTimeout(() => {
        if (!this.running) return;
        void this.pollOnce(opts).then((results) => {
          if (results.length > 0) onResult?.(results);
          if (this.running) schedule();
        });
      }, opts.intervalSeconds * 1000);
    };

    schedule();
  }

  /** Stop the daemon loop (in-flight poll completes normally). */
  stop(): void {
    this.running = false;
    if (this.timer !== null) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    console.error("[merge-agent] Daemon stopped");
  }

  isRunning(): boolean {
    return this.running;
  }
}
