import { Command } from "commander";
import chalk from "chalk";
import { ForemanStore } from "../../lib/store.js";
import type { Metrics, Run, RunProgress } from "../../lib/store.js";
import { getRepoRoot } from "../../lib/git.js";
import { renderAgentCard } from "../watch-ui.js";
import { BeadsRustClient } from "../../lib/beads-rust.js";
import type { BrIssue } from "../../lib/beads-rust.js";
import type { TaskBackend } from "../../lib/feature-flags.js";
import type { Issue } from "../../lib/task-client.js";
import { AgentMailClient } from "../../orchestrator/agent-mail-client.js";

// ── Exported helpers (used by tests) ─────────────────────────────────────

/**
 * Returns the active task backend. Exported for testing.
 * TRD-024: Always returns 'br'; sd backend removed.
 */
export function getStatusBackend(): TaskBackend {
  return 'br';
}

/**
 * Status counts returned by fetchStatusCounts.
 */
export interface StatusCounts {
  total: number;
  ready: number;
  inProgress: number;
  completed: number;
  blocked: number;
}

/**
 * Fetch task status counts using the br backend.
 *
 * TRD-024: sd backend removed. Always uses BeadsRustClient (br CLI).
 */
export async function fetchStatusCounts(projectPath: string): Promise<StatusCounts> {
  const brClient = new BeadsRustClient(projectPath);

  // Fetch open issues (all non-closed)
  let openIssues: BrIssue[] = [];
  try {
    openIssues = await brClient.list();
  } catch { /* br not initialized or binary missing — return zeros */ }

  // Fetch closed issues separately (br list excludes closed by default)
  let closedIssues: BrIssue[] = [];
  try {
    closedIssues = await brClient.list({ status: "closed" });
  } catch { /* no closed issues */ }

  // Fetch ready issues (open + unblocked)
  let readyIssues: Issue[] = [];
  try {
    readyIssues = await brClient.ready();
  } catch { /* br ready may fail */ }

  const inProgress = openIssues.filter((i) => i.status === "in_progress").length;
  const completed = closedIssues.length;
  const ready = readyIssues.length;
  // blocked = open issues that are not ready and not in_progress
  const readyIds = new Set(readyIssues.map((i) => i.id));
  const blocked = openIssues.filter(
    (i) => i.status !== "in_progress" && !readyIds.has(i.id),
  ).length;
  const total = openIssues.length + completed;

  return { total, ready, inProgress, completed, blocked };
}

// ── Agent Mail integration ────────────────────────────────────────────────

/** The 5 canonical agent mailboxes checked by foreman status. */
export const AGENT_MAILBOXES = [
  "explorer-agent",
  "developer-agent",
  "qa-agent",
  "reviewer-agent",
  "merge-agent",
] as const;

export type AgentMailbox = (typeof AGENT_MAILBOXES)[number];

/** Result returned by fetchAgentMailStatus. */
export interface AgentMailStatus {
  online: boolean;
  /** Present only when online === true. Keys are agent names; values are pending message counts. */
  inboxCounts?: Record<string, number>;
}

/**
 * Check Agent Mail health and fetch inbox counts for all 5 agent mailboxes.
 * Never throws — returns { online: false } on any failure.
 */
export async function fetchAgentMailStatus(): Promise<AgentMailStatus> {
  const client = new AgentMailClient();
  let healthy = false;
  try {
    healthy = await client.healthCheck();
  } catch {
    return { online: false };
  }
  if (!healthy) {
    return { online: false };
  }

  const inboxCounts: Record<string, number> = {};
  await Promise.all(
    AGENT_MAILBOXES.map(async (agent) => {
      const messages = await client.fetchInbox(agent);
      inboxCounts[agent] = messages.length;
    }),
  );

  return { online: true, inboxCounts };
}

/**
 * Render the "Agent Mail" section to the provided output function (defaults to console.log).
 * Exported for testing.
 */
export function renderAgentMailSection(
  status: AgentMailStatus,
  output: (line: string) => void = console.log,
): void {
  if (status.online) {
    output(chalk.bold("Agent Mail") + ": " + chalk.green("● Online"));
    if (status.inboxCounts !== undefined) {
      const agentsWithMessages = AGENT_MAILBOXES.filter(
        (a) => (status.inboxCounts![a] ?? 0) > 0,
      );
      if (agentsWithMessages.length > 0) {
        for (const agent of agentsWithMessages) {
          const count = status.inboxCounts![agent] ?? 0;
          output(
            `  ${agent.padEnd(18)} ${chalk.yellow(count)} pending ${count === 1 ? "message" : "messages"}`,
          );
        }
      } else {
        output(chalk.dim("  (all inboxes empty)"));
      }
    }
  } else {
    output(
      chalk.bold("Agent Mail") +
        ": " +
        chalk.dim("○ Offline") +
        chalk.dim("  (run: python -m mcp_agent_mail)"),
    );
  }
}

// ── Pi RPC Stats integration ──────────────────────────────────────────────

/**
 * Determine whether a run has Pi RPC progress data worth displaying.
 *
 * A run is considered a Pi RPC run when any of the following is true:
 * - `runs.session_key` starts with `foreman:pi-rpc:`
 * - `RunProgress.lastToolCall` is set (Pi-specific real-time field)
 * - `RunProgress.currentPhase` is set (written by PiRpcSpawnStrategy)
 */
export function hasPiRpcProgress(run: Run, progress: RunProgress | null): boolean {
  if (run.session_key?.startsWith("foreman:pi-rpc:")) return true;
  if (progress?.lastToolCall !== null && progress?.lastToolCall !== undefined) return true;
  if (progress?.currentPhase !== undefined) return true;
  return false;
}

/**
 * Format a number with comma thousands separator.
 * e.g. 45230 → "45,230"
 */
export function formatNumber(n: number): string {
  return n.toLocaleString("en-US");
}

/**
 * Format an ISO timestamp as a relative "X ago" string.
 * Returns undefined when lastToolCall is null/undefined.
 */
export function formatRelativeTime(isoTimestamp: string | null | undefined): string | undefined {
  if (!isoTimestamp) return undefined;
  const diffMs = Date.now() - new Date(isoTimestamp).getTime();
  if (diffMs < 0) return "just now";
  const diffSec = Math.floor(diffMs / 1000);
  if (diffSec < 60) return `${diffSec}s ago`;
  const diffMin = Math.floor(diffSec / 60);
  if (diffMin < 60) return `${diffMin}m ago`;
  const diffHr = Math.floor(diffMin / 60);
  return `${diffHr}h ago`;
}

/**
 * Render Pi RPC Stats section for a single run.
 * Only renders when the run has Pi progress data.
 * Exported for testing.
 */
export function renderPiRpcStatsSection(
  run: Run,
  progress: RunProgress | null,
  output: (line: string) => void = console.log,
): void {
  if (!hasPiRpcProgress(run, progress)) return;
  if (!progress) return;

  const divider = chalk.dim("  " + "─".repeat(43));
  output(divider);
  output(chalk.bold("  Pi RPC Stats"));
  output(divider);

  // Model — use progress.model (actual Pi model) or fall back to run agent_type
  const model = progress.model ?? chalk.dim("(unknown)");
  output(`  Model:       ${chalk.cyan(model)}`);

  // Phase
  const phase = progress.currentPhase ?? chalk.dim("(unknown)");
  output(`  Phase:       ${chalk.yellow(phase)}`);

  // Turns: current / max
  const turnsStr = progress.maxTurns !== undefined
    ? `${progress.turns} / ${progress.maxTurns}`
    : `${progress.turns}`;
  output(`  Turns:       ${turnsStr}`);

  // Tokens: combined in+out / max
  const totalTokens = progress.tokensIn + progress.tokensOut;
  const tokensStr = progress.maxTokens !== undefined
    ? `${formatNumber(totalTokens)} / ${formatNumber(progress.maxTokens)}`
    : formatNumber(totalTokens);
  output(`  Tokens:      ${tokensStr}`);

  // Last tool call with relative time
  if (progress.lastToolCall) {
    const relTime = formatRelativeTime(progress.lastActivity);
    const toolStr = relTime
      ? `${progress.lastToolCall} ${chalk.dim(`(${relTime})`)}`
      : progress.lastToolCall;
    output(`  Last tool:   ${toolStr}`);
  }

  output(divider);
}

// ── Internal render helper ────────────────────────────────────────────────

async function renderStatus(): Promise<void> {
  const projectPath = await getRepoRoot(process.cwd());
  let counts: StatusCounts = { total: 0, ready: 0, inProgress: 0, completed: 0, blocked: 0 };
  try {
    counts = await fetchStatusCounts(projectPath);
  } catch (err) {
    console.error(chalk.red(err instanceof Error ? err.message : String(err)));
    process.exit(1);
  }

  const { total, ready, inProgress, completed, blocked } = counts;

  console.log(chalk.bold("Tasks"));
  console.log(`  Total:       ${chalk.white(total)}`);
  console.log(`  Ready:       ${chalk.green(ready)}`);
  console.log(`  In Progress: ${chalk.yellow(inProgress)}`);
  console.log(`  Completed:   ${chalk.cyan(completed)}`);
  console.log(`  Blocked:     ${chalk.red(blocked)}`);

  // Show active agents from sqlite
  const store = ForemanStore.forProject(projectPath);
  const project = store.getProjectByPath(projectPath);

  // Show failed/stuck run counts from SQLite (only recent — last 24h)
  if (project) {
    const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
    const failedCount = store.getRunsByStatusSince("failed", since, project.id).length;
    const stuckCount = store.getRunsByStatusSince("stuck", since, project.id).length;
    if (failedCount > 0) console.log(`  Failed:      ${chalk.red(failedCount)} ${chalk.dim("(last 24h)")}`);
    if (stuckCount > 0) console.log(`  Stuck:       ${chalk.red(stuckCount)} ${chalk.dim("(last 24h)")}`);
  }

  console.log();
  console.log(chalk.bold("Active Agents"));

  if (project) {
    const activeRuns = store.getActiveRuns(project.id);
    if (activeRuns.length === 0) {
      console.log(chalk.dim("  (no agents running)"));
    } else {
      for (let i = 0; i < activeRuns.length; i++) {
        const run = activeRuns[i];
        const progress = store.getRunProgress(run.id);
        console.log(renderAgentCard(run, progress));
        renderPiRpcStatsSection(run, progress);
        // Separate cards with a blank line, but don't add a trailing blank
        // after the last card (avoids a dangling empty line in single-agent output).
        if (i < activeRuns.length - 1) console.log();
      }
    }

    // Cost summary
    const metrics = store.getMetrics(project.id);
    if (metrics.totalCost > 0) {
      console.log();
      console.log(chalk.bold("Costs"));
      console.log(`  Total: ${chalk.yellow(`$${metrics.totalCost.toFixed(2)}`)}`);
      console.log(`  Tokens: ${chalk.dim(`${(metrics.totalTokens / 1000).toFixed(1)}k`)}`);

      // Per-phase cost breakdown
      if (metrics.costByPhase && Object.keys(metrics.costByPhase).length > 0) {
        console.log(`  ${chalk.dim("By phase:")}`);
        const phaseOrder = ["explorer", "developer", "qa", "reviewer"];
        const phases = Object.entries(metrics.costByPhase)
          .sort(([a], [b]) => {
            const ai = phaseOrder.indexOf(a);
            const bi = phaseOrder.indexOf(b);
            if (ai === -1 && bi === -1) return a.localeCompare(b);
            if (ai === -1) return 1;
            if (bi === -1) return -1;
            return ai - bi;
          });
        for (const [phase, cost] of phases) {
          console.log(`    ${phase.padEnd(12)} ${chalk.yellow(`$${cost.toFixed(4)}`)}`);
        }
      }

      // Per-agent/model cost breakdown
      if (metrics.agentCostBreakdown && Object.keys(metrics.agentCostBreakdown).length > 0) {
        console.log(`  ${chalk.dim("By model:")}`);
        const sorted = Object.entries(metrics.agentCostBreakdown).sort(([, a], [, b]) => b - a);
        for (const [model, cost] of sorted) {
          console.log(`    ${model.padEnd(32)} ${chalk.yellow(`$${cost.toFixed(4)}`)}`);
        }
      }
    }
  } else {
    console.log(chalk.dim("  (project not registered — run 'foreman init')"));
  }

  store.close();

  // Agent Mail section (always shown, at the bottom)
  console.log();
  const agentMailStatus = await fetchAgentMailStatus();
  renderAgentMailSection(agentMailStatus);
}

export const statusCommand = new Command("status")
  .description("Show project status from beads_rust (br) + sqlite")
  .option("-w, --watch [seconds]", "Refresh every N seconds (default: 10)")
  .option("--json", "Output status as JSON")
  .action(async (opts: { watch?: boolean | string; json?: boolean }) => {
    if (opts.json) {
      // JSON output path — gather data and serialize
      try {
        const projectPath = await getRepoRoot(process.cwd());
        let counts: StatusCounts = { total: 0, ready: 0, inProgress: 0, completed: 0, blocked: 0 };
        try {
          counts = await fetchStatusCounts(projectPath);
        } catch { /* return zeros on error */ }

        const store = ForemanStore.forProject(projectPath);
        const project = store.getProjectByPath(projectPath);

        let failed = 0;
        let stuck = 0;
        let activeRuns: Array<{ run: Run; progress: RunProgress | null }> = [];
        let metrics: Metrics = { totalCost: 0, totalTokens: 0, tasksByStatus: {}, costByRuntime: [] };

        if (project) {
          const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
          failed = store.getRunsByStatusSince("failed", since, project.id).length;
          stuck = store.getRunsByStatusSince("stuck", since, project.id).length;
          const runs = store.getActiveRuns(project.id);
          activeRuns = runs.map((run) => ({ run, progress: store.getRunProgress(run.id) }));
          metrics = store.getMetrics(project.id);
        }

        store.close();

        const output = {
          tasks: {
            total: counts.total,
            ready: counts.ready,
            inProgress: counts.inProgress,
            completed: counts.completed,
            blocked: counts.blocked,
            failed,
            stuck,
          },
          agents: {
            active: activeRuns.map(({ run, progress }) => ({ ...run, progress })),
          },
          costs: {
            totalCost: metrics.totalCost,
            totalTokens: metrics.totalTokens,
            byPhase: metrics.costByPhase ?? {},
            byModel: metrics.agentCostBreakdown ?? {},
          },
        };

        console.log(JSON.stringify(output, null, 2));
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        console.error(JSON.stringify({ error: message }));
        process.exit(1);
      }
      return;
    }

    if (opts.watch !== undefined) {
      const interval = typeof opts.watch === "string" ? parseInt(opts.watch, 10) : 10;
      const seconds = Number.isFinite(interval) && interval > 0 ? interval : 10;

      // Keep process alive and handle Ctrl+C gracefully
      process.on("SIGINT", () => {
        process.stdout.write("\x1b[?25h"); // restore cursor
        process.exit(0);
      });

      process.stdout.write("\x1b[?25l"); // hide cursor
      while (true) {
        // Clear screen and move cursor to top
        process.stdout.write("\x1b[2J\x1b[H");
        console.log(chalk.bold("Project Status") + chalk.dim(`  (watching every ${seconds}s — Ctrl+C to stop)\n`));
        await renderStatus();
        console.log(chalk.dim(`\nLast updated: ${new Date().toLocaleTimeString()}`));
        await new Promise((r) => setTimeout(r, seconds * 1000));
      }
    } else {
      console.log(chalk.bold("Project Status\n"));
      await renderStatus();
    }
  });
