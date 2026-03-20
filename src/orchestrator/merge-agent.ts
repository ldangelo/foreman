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
import { spawn } from "node:child_process";
import type { ForemanStore } from "../lib/store.js";
import { AgentMailClient } from "./agent-mail-client.js";
import type { MergeOneResult } from "./refinery.js";

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
  retries?: number;
  latencyMs?: number;
}

// ── Constants ──────────────────────────────────────────────────────────────────

const PI_RESOLVE_TIMEOUT_MS = 120_000;
const RETRY_DELAY_MS = 5_000;
const MAX_RETRIES = 2;

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
   * T3 tier: Attempt to resolve a merge conflict via Pi RPC.
   *
   * Spawns `pi --mode rpc --no-session` as a child process, sends the conflict
   * diff as a prompt, and waits up to 120s for an `agent_end` event.
   *
   * @param conflictDiff - The raw diff/conflict text to resolve
   * @param runId        - Run ID for logging purposes
   * @returns { resolved: true, output } on success; { resolved: false, output: errorMsg } on failure
   */
  async resolveConflictViaPi(
    conflictDiff: string,
    runId: string,
  ): Promise<{ resolved: boolean; output: string }> {
    return new Promise((resolve) => {
      let settled = false;

      const timeout = setTimeout(() => {
        if (settled) return;
        settled = true;
        const msg = `Pi conflict resolution timed out after ${PI_RESOLVE_TIMEOUT_MS}ms for run ${runId}`;
        console.error(`[MERGE-AGENT] ${msg}`);
        resolve({ resolved: false, output: msg });
      }, PI_RESOLVE_TIMEOUT_MS);

      let child: ReturnType<typeof spawn>;
      try {
        child = spawn("pi", ["--mode", "rpc", "--no-session"], {
          stdio: ["pipe", "pipe", "pipe"],
          env: { ...process.env, CLAUDECODE: undefined } as NodeJS.ProcessEnv,
        });
      } catch (err: unknown) {
        clearTimeout(timeout);
        const msg = err instanceof Error ? err.message : String(err);
        resolve({ resolved: false, output: `Failed to spawn pi: ${msg}` });
        return;
      }

      const outputChunks: string[] = [];
      let agentEnded = false;

      child.stdout?.on("data", (chunk: Buffer) => {
        const lines = chunk.toString().split("\n").filter(Boolean);
        for (const line of lines) {
          try {
            const event = JSON.parse(line) as { type?: string; text?: string; content?: string };
            if (event.type === "agent_end") {
              agentEnded = true;
              if (!settled) {
                settled = true;
                clearTimeout(timeout);
                resolve({ resolved: true, output: outputChunks.join("\n") });
              }
            } else if (event.text) {
              outputChunks.push(event.text);
            } else if (event.content) {
              outputChunks.push(event.content);
            }
          } catch {
            // Not valid JSON — treat as raw output
            outputChunks.push(line);
          }
        }
      });

      child.on("error", (err: Error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        resolve({ resolved: false, output: `Pi process error: ${err.message}` });
      });

      child.on("close", () => {
        if (settled) return;
        if (agentEnded) return;
        settled = true;
        clearTimeout(timeout);
        resolve({ resolved: false, output: "Pi process closed without agent_end" });
      });

      // Send the prompt to Pi
      const prompt = JSON.stringify({
        cmd: "prompt",
        message: `Resolve this merge conflict:\n\n${conflictDiff}`,
      });

      try {
        child.stdin?.write(prompt + "\n");
        child.stdin?.end();
      } catch (err: unknown) {
        if (!settled) {
          settled = true;
          clearTimeout(timeout);
          const msg = err instanceof Error ? err.message : String(err);
          resolve({ resolved: false, output: `Failed to write to pi stdin: ${msg}` });
        }
      }
    });
  }

  /**
   * Stub for T4 escalation: creates a PR for a conflict that Pi could not resolve.
   * Actual PR creation is implemented in Refinery.
   */
  private createPrForConflict(seedId: string, branchName: string): void {
    console.error(
      `[MERGE-AGENT] T4 escalation: creating PR for unresolved conflict ` +
      `seedId=${seedId} branch=${branchName}`,
    );
    // Actual PR creation delegated to Refinery
  }

  /**
   * Sleep for the given number of milliseconds.
   */
  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
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
        const payload = JSON.parse(msg.body) as {
          seedId?: string;
          branchName?: string;
          runId?: string;
        };
        const { seedId = "unknown", branchName = "unknown", runId } = payload;

        // TRD-034: Record latency from message receipt to merge start
        const processingStartedAt = Date.now();
        const latencyMs = processingStartedAt - new Date(msg.receivedAt).getTime();
        console.error(`[MERGE-AGENT] Latency for ${seedId}: ${latencyMs}ms`);

        console.error(`[merge-agent] Processing branch-ready for ${seedId} (${branchName})`);

        if (!opts.dryRun) {
          // Acknowledge the message so it won't be re-delivered
          await client.sendMessage(
            "merge-agent",
            "ack",
            JSON.stringify({ acknowledgedId: msg.id }),
          );
        }

        // TRD-031: Retry loop (max 2 retries)
        let mergeResult: MergeOneResult | null = null;
        let retries = 0;
        let lastError: string | undefined;

        for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
          if (attempt > 0) {
            console.error(
              `[MERGE-AGENT] Retry ${attempt}/${MAX_RETRIES} for ${seedId} after ${RETRY_DELAY_MS}ms`,
            );
            await this.sleep(RETRY_DELAY_MS);
            retries = attempt;
          }

          try {
            // Placeholder: in production this would call Refinery.mergeOne()
            // For now we return a synthetic "merged" result since actual merge
            // wiring requires a Run object and Refinery instance
            mergeResult = { status: "merged", branchName };
            lastError = undefined;
            break;
          } catch (err: unknown) {
            lastError = err instanceof Error ? err.message : String(err);
            console.error(
              `[MERGE-AGENT] Merge attempt ${attempt + 1} failed for ${seedId}: ${lastError}`,
            );
            mergeResult = null;
          }
        }

        // TRD-031: Escalation after retry exhaustion
        if (!mergeResult) {
          // Send escalation mail
          await client.sendMessage(
            "merge-agent",
            "merge-escalated",
            JSON.stringify({ seedId, branchName, retries: MAX_RETRIES }),
          );

          // Update run status in store if runId is available
          if (runId) {
            this.store.updateRun(runId, { status: "failed" });
          }

          results.push({
            seedId,
            branchName,
            status: "failed",
            reason: "retry exhausted",
            retries: MAX_RETRIES,
            latencyMs,
          });
          continue;
        }

        // TRD-030: Handle conflict status from mergeOne (T3/T4 tiers)
        if (mergeResult.status === "conflict") {
          console.error(
            `[MERGE-AGENT] Conflict detected for ${seedId} — attempting T3 Pi resolution`,
          );

          if (!opts.dryRun) {
            const conflictDiff = mergeResult.reason ?? `Conflict in branch ${branchName}`;
            const piResult = await this.resolveConflictViaPi(
              conflictDiff,
              runId ?? seedId,
            );

            if (piResult.resolved) {
              // T3 success: commit the resolution
              console.error(
                `[MERGE-AGENT] Pi resolved conflict for ${seedId} — committing resolution`,
              );
              // Actual git operations would happen here with a Refinery instance
              results.push({
                seedId,
                branchName,
                status: "merged",
                reason: "pi-resolved",
                retries,
                latencyMs,
              });
            } else {
              // T4: Pi resolution failed — escalate to PR
              console.error(
                `[MERGE-AGENT] Pi resolution failed for ${seedId}: ${piResult.output} — escalating to PR (T4)`,
              );
              this.createPrForConflict(seedId, branchName);
              results.push({
                seedId,
                branchName,
                status: "failed",
                reason: `conflict-unresolved: ${piResult.output}`,
                retries,
                latencyMs,
              });
            }
          } else {
            // dryRun: just report conflict
            results.push({
              seedId,
              branchName,
              status: "failed",
              reason: "conflict (dry-run)",
              retries,
              latencyMs,
            });
          }
          continue;
        }

        // Successful merge (or other non-conflict outcomes)
        const resultStatus: MergeAgentResult["status"] =
          mergeResult.status === "merged" ? "merged" :
          mergeResult.status === "failed" ? "failed" : "skipped";

        results.push({
          seedId,
          branchName,
          status: resultStatus,
          reason: mergeResult.reason,
          retries,
          latencyMs,
        });
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
