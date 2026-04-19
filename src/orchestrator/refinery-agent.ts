/**
 * Refinery Agent — Agentic Merge Queue Processing
 *
 * Replaces the legacy refinery script (~1500 lines, <5% success) with an agent
 * that reads PRs, fixes mechanical failures, builds, tests, and merges.
 *
 * Target: ~50 lines of agent code achieving 90%+ success rate.
 */

import { mkdirSync, appendFileSync, existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { promisify } from "node:util";
import { execFile as execFileSync } from "node:child_process";

import type { VcsBackend } from "../lib/vcs/index.js";
import { MergeQueue, type MergeQueueEntry } from "./merge-queue.js";
import { PIPELINE_BUFFERS } from "../lib/config.js";

const execFileAsync = promisify(execFileSync);

// ── Types ────────────────────────────────────────────────────────────────

export interface RefineryAgentConfig {
  pollIntervalMs: number;
  maxFixIterations: number;
  projectPath: string;
  logDir: string;
  systemPromptPath?: string;
}

export interface AgentResult {
  success: boolean;
  action: "merged" | "escalated" | "skipped" | "error";
  logPath: string;
  message?: string;
}

// ── Default Config ───────────────────────────────────────────────────────

const DEFAULT_CONFIG = {
  pollIntervalMs: 60_000, // 60 seconds
  maxFixIterations: 2,
  logDir: "docs/reports",
  systemPromptPath: "./src/orchestrator/prompts/refinery-agent.md",
} as const;

// ── RefineryAgent ────────────────────────────────────────────────────────

export class RefineryAgent {
  private config: RefineryAgentConfig;
  private running = false;
  private systemPrompt: string = "";

  constructor(
    private mergeQueue: MergeQueue,
    private vcsBackend: VcsBackend,
    private projectPath: string,
    config: Partial<RefineryAgentConfig> = {}
  ) {
    this.config = { ...DEFAULT_CONFIG, ...config, projectPath };
  }

  /**
   * Start the agent daemon loop.
   */
  async start(): Promise<void> {
    this.running = true;
    this.systemPrompt = await this.loadSystemPrompt();
    console.log(`[refinery-agent] Starting daemon (poll interval: ${this.config.pollIntervalMs}ms)`);

    while (this.running) {
      try {
        await this.processQueue();
      } catch (err) {
        console.error("[refinery-agent] Error in queue processing loop:", err);
      }

      // Wait before next poll
      await this.sleep(this.config.pollIntervalMs);
    }

    console.log("[refinery-agent] Daemon stopped");
  }

  /**
   * Stop the agent daemon.
   */
  stop(): void {
    this.running = false;
  }

  /**
   * Process the merge queue once (for --once mode).
   */
  async processOnce(): Promise<AgentResult[]> {
    this.systemPrompt = await this.loadSystemPrompt();
    return this.processQueue();
  }

  // ── Private Methods ────────────────────────────────────────────────────

  private async loadSystemPrompt(): Promise<string> {
    const promptPath = join(this.projectPath, this.config.systemPromptPath || "");
    if (existsSync(promptPath)) {
      return readFileSync(promptPath, "utf-8");
    }
    // Fallback to embedded prompt
    return DEFAULT_SYSTEM_PROMPT;
  }

  /**
   * Poll and process pending queue entries.
   */
  private async processQueue(): Promise<AgentResult[]> {
    const results: AgentResult[] = [];

    // Get pending entries in FIFO order using MergeQueue
    const entries = this.mergeQueue.list("pending");
    console.log(`[refinery-agent] Found ${entries.length} pending entries`);

    for (const entry of entries) {
      const result = await this.processEntry(entry);
      results.push(result);

      // Stop on first successful or escalated entry
      // (to avoid conflicts from parallel processing)
      if (result.action === "merged" || result.action === "escalated") {
        break;
      }
    }

    return results;
  }

  /**
   * Process a single queue entry.
   */
  private async processEntry(entry: MergeQueueEntry): Promise<AgentResult> {
    const logPath = this.ensureLogDir(entry.id);

    // Atomically claim the entry via MergeQueue
    // If another process has it, dequeue returns null
    const claimed = this.mergeQueue.dequeue();
    if (!claimed || claimed.id !== entry.id) {
      return {
        success: false,
        action: "skipped",
        logPath,
        message: "Entry locked by another process",
      };
    }

    this.logAction(entry.id, `Processing queue entry ${entry.id} for branch ${entry.branch_name}`);

    try {
      // Read PR state
      const prState = await this.readPrState(entry);
      if (!prState) {
        this.mergeQueue.updateStatus(entry.id, "failed", { error: "Could not read PR state" });
        return { success: false, action: "error", logPath, message: "Could not read PR state" };
      }

      // Check CI status
      const ciPassed = await this.checkCiStatus(entry);
      if (!ciPassed) {
        this.logAction(entry.id, "CI not yet passing, will retry on next poll");
        this.mergeQueue.resetForRetry(entry.seed_id);
        return { success: false, action: "skipped", logPath, message: "CI not passing" };
      }

      // Run agent to fix and merge
      const result = await this.runAgent(entry, prState);

      if (result.success) {
        this.mergeQueue.updateStatus(entry.id, "merged", { completedAt: new Date().toISOString() });
        this.logAction(entry.id, `Successfully merged ${entry.branch_name}`);
      } else {
        this.mergeQueue.updateStatus(entry.id, "conflict", { error: result.message });
        this.logAction(entry.id, `Escalated: ${result.message}`);
      }

      return result;
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      this.mergeQueue.updateStatus(entry.id, "failed", { error: message });
      this.logAction(entry.id, `Error: ${message}`);
      return { success: false, action: "error", logPath, message };
    }
  }

  /**
   * Read PR state using gh commands.
   */
  private async readPrState(entry: MergeQueueEntry): Promise<PrState | null> {
    try {
      const { stdout: viewOutput } = await execFileAsync("gh", [
        "pr", "view", entry.branch_name,
        "--json", "title,body,statusCheckRollup,headRefName,url",
        "--jq", ".",
      ], { cwd: this.projectPath, maxBuffer: PIPELINE_BUFFERS.maxBufferBytes });

      const { stdout: diffOutput } = await execFileAsync("gh", [
        "pr", "diff", entry.branch_name,
      ], { cwd: this.projectPath, maxBuffer: PIPELINE_BUFFERS.maxBufferBytes });

      return { view: viewOutput, diff: diffOutput };
    } catch {
      return null;
    }
  }

  /**
   * Check if CI status checks are passing.
   */
  private async checkCiStatus(entry: MergeQueueEntry): Promise<boolean> {
    try {
      const { stdout } = await execFileAsync("gh", [
        "pr", "view", entry.branch_name,
        "--json", "statusCheckRollup",
        "--jq", ".[0].conclusion // \"pending\"",
      ], { cwd: this.projectPath });

      return stdout.trim() === "SUCCESS";
    } catch {
      return false;
    }
  }

  /**
   * Run the agent to fix issues and merge.
   * This is a placeholder that delegates to the existing merge flow.
   * In a full implementation, this would spawn a Pi agent session.
   */
  private async runAgent(
    entry: MergeQueueEntry,
    _prState: PrState
  ): Promise<AgentResult> {
    const logPath = this.ensureLogDir(entry.id);
    this.logAction(entry.id, "Agent fix logic not yet implemented - using legacy merge path");

    // For now, delegate to the VCS backend merge
    // In the full implementation, this would:
    // 1. Run npm run build
    // 2. If fails, apply fixes
    // 3. Run npm run test
    // 4. If all pass, merge

    return {
      success: false,
      action: "skipped",
      logPath,
      message: "Agent logic not yet implemented",
    };
  }

  // ── Logging ────────────────────────────────────────────────────────────

  private ensureLogDir(queueEntryId: number): string {
    const logPath = join(this.config.logDir, `queue-entry-${queueEntryId}`);
    if (!existsSync(logPath)) {
      mkdirSync(logPath, { recursive: true });
    }
    return join(logPath, "AGENT_LOG.md");
  }

  private getLogPath(queueEntryId: number): string {
    return join(this.config.logDir, `queue-entry-${queueEntryId}`, "AGENT_LOG.md");
  }

  private logAction(queueEntryId: number, action: string): void {
    const logPath = this.ensureLogDir(queueEntryId);
    const timestamp = new Date().toISOString();
    const entry = `- ${timestamp} ${action}\n`;
    appendFileSync(logPath, entry, "utf-8");
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}

// ── PrState ──────────────────────────────────────────────────────────────

interface PrState {
  view: string;
  diff: string;
}

// ── Default System Prompt ────────────────────────────────────────────────

const DEFAULT_SYSTEM_PROMPT = `
# Refinery Agent — System Prompt

You are the Refinery Agent for Foreman. Your job is to process merge queue entries end-to-end.

## Your Tools
- bash: Run git, gh, npm commands
- read: Read files to understand code structure
- edit: Make targeted fixes to files
- write: Create or overwrite files

## Common Fix Patterns
| Pattern | Fix |
|---------|-----|
| Type errors | Fix types, not cast to any |
| Missing imports | Add missing import statements |
| Missing type union values | Add to EventType union |
| Wiring gaps | Read module, find call site, add usage |

## Decision Rules
- Wait if CI is still running
- Fix mechanical errors only (not logic bugs)
- Escalate after 2 fix attempts

## Safety Rules
- NEVER force-push to main
- ALWAYS verify build before merge
- Log every action to AGENT_LOG.md
`;
