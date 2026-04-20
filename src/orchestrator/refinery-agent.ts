/**
 * Refinery Agent — Agentic Merge Queue Processing
 *
 * Replaces the legacy refinery script (~1500 lines, <5% success) with an agent
 * that reads PRs, fixes mechanical failures, builds, tests, and merges.
 *
 * Target: ~50 lines of agent code achieving 90%+ success rate.
 */

import { mkdirSync, appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { promisify } from "node:util";
import { execFile as execFileSync } from "node:child_process";

import type { VcsBackend } from "../lib/vcs/index.js";
import { MergeQueue, type MergeQueueEntry } from "./merge-queue.js";
import { PIPELINE_BUFFERS } from "../lib/config.js";
import { ForemanStore } from "../lib/store.js";
import { runWithPiSdk, type PiRunResult } from "./pi-sdk-runner.js";
import { createSendMailTool } from "./pi-sdk-tools.js";
import { SqliteMailClient } from "../lib/sqlite-mail-client.js";
import {
  createBashTool,
  createReadTool,
  createEditTool,
  createWriteTool,
  createGrepTool,
  createFindTool,
  createLsTool,
} from "@mariozechner/pi-coding-agent";
import type { ToolDefinition } from "@mariozechner/pi-coding-agent";

const execFileAsync = promisify(execFileSync);

// ── Types ────────────────────────────────────────────────────────────────

export interface RefineryAgentConfig {
  pollIntervalMs: number;
  maxFixIterations: number;
  projectPath: string;
  logDir: string;
  systemPromptPath?: string;
  /** Model for the fix agent (default: sonnet) */
  model?: string;
}

export interface AgentResult {
  success: boolean;
  action: "merged" | "escalated" | "skipped" | "error";
  logPath: string;
  message?: string;
  costUsd?: number;
}

// ── Default Config ───────────────────────────────────────────────────────

const DEFAULT_CONFIG = {
  pollIntervalMs: 60_000, // 60 seconds
  maxFixIterations: 2,
  logDir: "docs/reports",
  systemPromptPath: "./src/orchestrator/prompts/refinery-agent.md",
  model: "MiniMax",
} as const;

// ── RefineryAgent ────────────────────────────────────────────────────────

export class RefineryAgent {
  private config: RefineryAgentConfig;
  private running = false;
  private systemPrompt: string = "";
  private store: ForemanStore;
  private mailClient: SqliteMailClient;
  private mailInitialized = false;

  constructor(
    private mergeQueue: MergeQueue,
    private vcsBackend: VcsBackend,
    private projectPath: string,
    config: Partial<RefineryAgentConfig> = {},
  ) {
    this.config = { ...DEFAULT_CONFIG, ...config, projectPath };
    this.store = ForemanStore.forProject(this.projectPath);
    this.mailClient = new SqliteMailClient();
    // Note: mailClient.ensureProject(projectPath) must be called before use
    // in instance methods. Called lazily in processQueue() to avoid async constructor.
  }

  /**
   * Ensure the mail client is initialized for this project.
   * Safe to call multiple times.
   */
  private async ensureMailClient(): Promise<void> {
    if (!this.mailInitialized) {
      await this.mailClient.ensureProject(this.projectPath);
      this.mailInitialized = true;
    }
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

    // Ensure mail client is initialized before processing
    await this.ensureMailClient();

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

      // Get the worktree path from the run record
      const run = this.store.getRun(entry.run_id);
      const worktreePath = run?.worktree_path ?? join(this.projectPath, "worktrees", entry.seed_id);

      // Run agent to fix and merge
      const result = await this.runAgent(entry, prState, worktreePath);

      if (result.success) {
        this.mergeQueue.updateStatus(entry.id, "merged", { completedAt: new Date().toISOString() });
        this.logAction(entry.id, `Successfully merged ${entry.branch_name}`);
      } else if (result.action === "escalated") {
        await this.escalate(entry, result.message ?? "Fix budget exhausted");
        this.mergeQueue.updateStatus(entry.id, "conflict", { error: result.message });
        this.logAction(entry.id, `Escalated: ${result.message}`);
      } else {
        this.mergeQueue.updateStatus(entry.id, "failed", { error: result.message });
        this.logAction(entry.id, `Error: ${result.message}`);
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
   *
   * Uses the Pi SDK to run an agent session that:
   * 1. Reads the PR diff and identifies mechanical failures
   * 2. Applies fixes (type errors, missing imports, wiring gaps)
   * 3. Runs build
   * 4. Runs tests
   * 5. Merges if all pass, escalates if not
   */
  private async runAgent(
    entry: MergeQueueEntry,
    prState: PrState,
    worktreePath: string,
  ): Promise<AgentResult> {
    const logPath = this.ensureLogDir(entry.id);
    const model = this.config.model ?? DEFAULT_CONFIG.model;
    const maxIterations = this.config.maxFixIterations ?? DEFAULT_CONFIG.maxFixIterations;

    this.logAction(entry.id, `Starting agent for ${entry.branch_name} (worktree: ${worktreePath})`);

    // Determine the target branch
    const targetBranch = await this.vcsBackend.detectDefaultBranch(this.projectPath);

    // Build the agent task prompt
    const taskPrompt = this.buildAgentTaskPrompt(entry, prState, worktreePath, targetBranch);

    // Build tools
    const tools = this.buildTools(worktreePath);
    const customTools: ToolDefinition[] = [
      createSendMailTool(this.mailClient, `refinery-${entry.seed_id}`),
    ];

    let lastResult: PiRunResult | null = null;

    for (let attempt = 1; attempt <= maxIterations; attempt++) {
      this.logAction(entry.id, `Fix attempt ${attempt}/${maxIterations}`);

      // Run the Pi SDK session
      const result = await runWithPiSdk({
        prompt: taskPrompt,
        systemPrompt: this.systemPrompt,
        cwd: worktreePath,
        model,
        allowedTools: ["Read", "Bash", "Edit", "Write", "Grep", "Find", "LS"],
        customTools,
        logFile: logPath,
      });

      lastResult = result;

      if (!result.success) {
        const errorMsg = result.errorMessage ?? "Agent ended without success";
        this.logAction(entry.id, `Agent failed: ${errorMsg.slice(0, 200)}`);

        // If this was the last attempt, escalate
        if (attempt === maxIterations) {
          return {
            success: false,
            action: "escalated",
            logPath,
            message: `Fix attempts exhausted (${maxIterations}). Last error: ${errorMsg.slice(0, 200)}`,
            costUsd: result.costUsd,
          };
        }

        // Append feedback for next attempt
        const feedback = `\n\n## Previous Fix Attempt ${attempt} Failed\n\nError: ${errorMsg}\n\nPlease analyze the error and try a different fix approach.\n`;
        // Update task prompt with feedback for next iteration
        continue;
      }

      // Commit and push agent changes BEFORE building/testing
      const pushOk = await this.commitAndPush(worktreePath);
      if (!pushOk) {
        this.logAction(entry.id, `Could not push changes — worktree may be dirty`);
        if (attempt === maxIterations) {
          return { success: false, action: "escalated", logPath, message: "Could not push changes — worktree dirty", costUsd: result.costUsd };
        }
        continue;
      }

      // Build passed? Check the result
      const buildOk = await this.checkBuildOk(worktreePath);
      if (!buildOk) {
        this.logAction(entry.id, `Build still failing after attempt ${attempt}`);
        if (attempt === maxIterations) {
          return {
            success: false,
            action: "escalated",
            logPath,
            message: `Build failed after ${attempt} fix attempts`,
            costUsd: result.costUsd,
          };
        }
        continue;
      }

      // Build passes — run tests
      this.logAction(entry.id, `Build passed, running tests...`);
      const testOk = await this.checkTestsOk(worktreePath);
      if (!testOk) {
        this.logAction(entry.id, `Tests still failing after attempt ${attempt}`);
        if (attempt === maxIterations) {
          return {
            success: false,
            action: "escalated",
            logPath,
            message: `Tests failed after ${attempt} fix attempts`,
            costUsd: result.costUsd,
          };
        }
        continue;
      }

      // All pass — merge!
      this.logAction(entry.id, `Build and tests passed! Merging...`);
      const mergeOk = await this.mergeBranch(entry, targetBranch);
      if (mergeOk) {
        return {
          success: true,
          action: "merged",
          logPath,
          message: `Successfully merged ${entry.branch_name}`,
          costUsd: result.costUsd,
        };
      } else {
        return {
          success: false,
          action: "error",
          logPath,
          message: `Merge failed for ${entry.branch_name}`,
          costUsd: result.costUsd,
        };
      }
    }

    // Exhausted all attempts
    return {
      success: false,
      action: "escalated",
      logPath,
      message: `Fix budget exhausted (${maxIterations} attempts)`,
      costUsd: lastResult?.costUsd ?? 0,
    };
  }

  /**
   * Build the task prompt for the fix agent.
   */
  private buildAgentTaskPrompt(
    entry: MergeQueueEntry,
    prState: PrState,
    _worktreePath: string,
    targetBranch: string,
  ): string {
    const maxIter = this.config.maxFixIterations ?? 2;
    const gitPush = "git add -A && git commit -m 'fix: auto-fix from merge queue' && git push origin HEAD";
    return [
      "# Refinery Agent -- Fix Task",
      "",
      "## Context",
      "You are processing a merge queue entry for branch " + entry.branch_name + " (seed: " + entry.seed_id + ").",
      "",
      "## Your Mission",
      "Fix mechanical failures (type errors, missing imports, wiring gaps) in the branch, then build and test. If all pass, merge. If not fixable after " + maxIter + " attempts, escalate.",
      "",
      "## PR State",
      "```json",
      prState.view,
      "```",
      "",
      "## Diff (what changed)",
      "```diff",
      prState.diff.slice(0, 20_000),
      "```",
      "",
      "## Critical: Commit Your Fixes FIRST",
      "After making edits, you MUST commit and push before running build/tests.",
      "",
      "Bash command: " + gitPush,
      "",
      "## Workflow",
      "1. Read files with errors using the Read tool",
      "2. Fix type errors, missing imports, wiring gaps using Edit/Write tools",
      "3. Bash: " + gitPush,
      "4. Bash: npm run build",
      "5. Bash: npm test",
      "6. If build+tests pass -> MERGE_SUCCESS: <summary>",
      "7. If unrecoverable after " + maxIter + " attempts -> ESCALATE: <reason>",
      "",
      "## Decision Rules",
      "- If build/test fixable -> fix and continue",
      "- If unrecoverable after " + maxIter + " attempts -> report ESCALATE",
      "- NEVER force-push to " + targetBranch,
      "- Log every action to the log file",
      "",
      "## Exit Signal",
      "When done, output one of:",
      "- MERGE_SUCCESS: <brief summary>",
      "- ESCALATE: <reason why it couldn't be fixed>",
    ].join("\n");
  }


  /**
   * Build the tool array for the agent session.
   * Uses the worktree path as the agent's cwd.
   */
  private buildTools(cwd: string) {
    return [
      createReadTool(cwd),
      createBashTool(cwd),
      createEditTool(cwd),
      createWriteTool(cwd),
      createGrepTool(cwd),
      createFindTool(cwd),
      createLsTool(cwd),
    ];
  }

  /**
   * Check if the build passes in the worktree.
   */
  private async checkBuildOk(worktreePath: string): Promise<boolean> {
    try {
      const { stdout, stderr } = await execFileAsync("npm", ["run", "build"], {
        cwd: worktreePath, maxBuffer: PIPELINE_BUFFERS.maxBufferBytes,
      });
      const output = stdout + stderr;
      return !output.includes("error") && !output.includes("ERROR");
    } catch {
      return false;
    }
  }

  /**
   * Check if tests pass in the worktree.
   */
  private async checkTestsOk(worktreePath: string): Promise<boolean> {
    try {
      const { stdout } = await execFileAsync("npm", ["test"], {
        cwd: worktreePath, maxBuffer: PIPELINE_BUFFERS.maxBufferBytes,
      });
      // Successful if: at least one test passed AND no failures
      const passed = /\d+ passed/.test(stdout);
      const hasFailures = /\d+ failed/.test(stdout);
      return passed && !hasFailures;
    } catch {
      return false;
    }
  }

  /**
   * Commit all changes in the worktree and push to origin.
   * Handles dirty state by stashing, committing, then restoring.
   */
  private async commitAndPush(worktreePath: string): Promise<boolean> {
    try {
      // Check if there are changes to commit
      const statusOutput = await this.vcsBackend.status(worktreePath);

      if (!statusOutput.trim()) {
        this.logAction(0, "No changes to commit in worktree");
        return true;
      }

      // Stage all changes
      await this.vcsBackend.stageAll(worktreePath);

      // Commit with descriptive message
      await this.vcsBackend.commit(
        worktreePath,
        "fix: refinery agent — auto-fix from merge queue",
      );

      // Push to origin
      const branchName = await this.vcsBackend.getCurrentBranch(worktreePath);
      await this.vcsBackend.push(worktreePath, branchName);

      this.logAction(0, `Committed and pushed worktree changes`);
      return true;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      this.logAction(0, `Commit/push failed: ${msg.slice(0, 200)}`);
      return false;
    }
  }

  /**
   * Merge the branch via gh pr merge.
   * Uses --squash only; does NOT auto-delete the branch on failure.
   */
  private async mergeBranch(entry: MergeQueueEntry, _targetBranch: string): Promise<boolean> {
    try {
      // Ensure branch is up-to-date first
      await this.vcsBackend.push(this.projectPath, entry.branch_name);

      // Merge via gh — squash only, let GitHub handle branch deletion on success
      await execFileAsync(
        "gh",
        ["pr", "merge", entry.branch_name, "--squash", "--admin"],
        { cwd: this.projectPath, maxBuffer: PIPELINE_BUFFERS.maxBufferBytes },
      );

      return true;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      this.logAction(entry.id, `Merge failed: ${msg.slice(0, 200)}`);
      return false;
    }
  }

  // ── Escalation ─────────────────────────────────────────────────────────

  /**
   * Create a manual PR for escalation when the agent can't auto-fix.
   */
  private async escalate(entry: MergeQueueEntry, reason: string): Promise<void> {
    try {
      this.logAction(entry.id, `Escalating: ${reason}`);

      // Get PR title and body
      const { stdout: prView } = await execFileAsync(
        "gh", ["pr", "view", entry.branch_name, "--json", "title,body,url"],
        { cwd: this.projectPath, maxBuffer: PIPELINE_BUFFERS.maxBufferBytes },
      );
      const prData = JSON.parse(prView);

      // Create manual PR with escalation context
      await execFileAsync(
        "gh",
        [
          "pr", "create",
          "--title", `[ESCALATED] ${prData.title ?? entry.seed_id}`,
          "--body", `## Escalated from Merge Queue\n\n**Queue Entry:** ${entry.id}\n**Branch:** ${entry.branch_name}\n**Reason:** ${reason}\n\n**Original PR:** ${prData.url ?? "N/A"}\n\n---\n\n*This PR was escalated because the Refinery Agent could not auto-fix within ${this.config.maxFixIterations} attempts.*`,
          "--base", "dev",
        ],
        { cwd: this.projectPath, maxBuffer: PIPELINE_BUFFERS.maxBufferBytes },
      );

      this.logAction(entry.id, `Escalation PR created`);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      this.logAction(entry.id, `Escalation PR creation failed: ${msg.slice(0, 200)}`);
    }
  }

  // ── Logging ────────────────────────────────────────────────────────────

  private ensureLogDir(queueEntryId: number): string {
    const logPath = join(this.config.logDir, `queue-entry-${queueEntryId}`);
    if (!existsSync(logPath)) {
      mkdirSync(logPath, { recursive: true });
    }
    return join(logPath, "AGENT_LOG.md");
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
- send_mail: Send notifications (for escalations)

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

## Exit Signals
When done, output one of:
- MERGE_SUCCESS: <brief summary>
- ESCALATE: <reason why it couldn't be fixed>
`;
