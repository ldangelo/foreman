import chalk from "chalk";

import type { ForemanStore, Run, RunProgress } from "../lib/store.js";

// ── Helpers ──────────────────────────────────────────────────────────────

export function elapsed(since: string | null): string {
  if (!since) return "—";
  const ms = Date.now() - new Date(since).getTime();
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${s % 60}s`;
  return `${Math.floor(m / 60)}h ${m % 60}m`;
}

export function shortModel(model: string): string {
  return model
    .replace("claude-", "")
    .replace("-20251001", "");
}

export function shortPath(path: string): string {
  const parts = path.split("/");
  return parts[parts.length - 1] ?? path;
}

const STATUS_ICONS: Record<string, string> = {
  pending: "○",
  running: "●",
  completed: "✓",
  failed: "✗",
  stuck: "⚠",
  merged: "⊕",
  conflict: "⊘",
  "test-failed": "⊘",
};

function statusColor(status: string, text: string): string {
  switch (status) {
    case "pending":    return chalk.gray(text);
    case "running":    return chalk.blue(text);
    case "completed":  return chalk.green(text);
    case "failed":     return chalk.red(text);
    case "stuck":      return chalk.yellow(text);
    case "merged":     return chalk.green(text);
    case "conflict":   return chalk.red(text);
    case "test-failed": return chalk.red(text);
    default:           return chalk.gray(text);
  }
}

const RULE = chalk.dim("━".repeat(60));

// ── Display functions ─────────────────────────────────────────────────────

export function renderAgentCard(run: Run, progress: RunProgress | null): string {
  const icon = STATUS_ICONS[run.status] ?? "?";
  const isRunning = run.status === "running";
  const isPending = run.status === "pending";
  const time = isRunning || isPending
    ? elapsed(run.started_at ?? run.created_at)
    : elapsed(run.started_at);

  const lines: string[] = [];

  // Header: icon + bead ID + status + elapsed time
  lines.push(
    `${statusColor(run.status, icon)} ${chalk.cyan.bold(run.bead_id)} ${statusColor(run.status, run.status.toUpperCase())} ${chalk.dim(time)}`,
  );
  lines.push(`  ${chalk.dim("Model     ")} ${chalk.magenta(shortModel(run.agent_type))}`);

  if (isPending || !progress || progress.toolCalls === 0) {
    if (isRunning) {
      lines.push(`  ${chalk.dim("Initializing...")}`);
    }
    return lines.join("\n");
  }

  // Full card with progress
  lines.push(`  ${chalk.dim("Cost      ")} ${chalk.green("$" + progress.costUsd.toFixed(4))}`);

  // Phase cost breakdown
  if (progress.phaseCosts && Object.keys(progress.phaseCosts).length > 0) {
    const phaseNames: Array<[string, string]> = [
      ["explorer", "expl"],
      ["developer", "dev"],
      ["qa", "qa"],
      ["reviewer", "rev"],
    ];
    const parts = phaseNames
      .filter(([phase]) => (progress.phaseCosts![phase] ?? 0) > 0)
      .map(([phase, abbr]) => `${chalk.dim(abbr + ":")}${chalk.green("$" + progress.phaseCosts![phase].toFixed(3))}`);
    if (parts.length > 0) {
      lines.push(`  ${chalk.dim("By Phase  ")} ${parts.join(chalk.dim("  "))}`);
    }
  }

  lines.push(`  ${chalk.dim("Turns     ")} ${progress.turns}`);

  const lastTool = progress.lastToolCall
    ? chalk.dim(` (last: ${progress.lastToolCall})`)
    : "";
  lines.push(`  ${chalk.dim("Tools     ")} ${progress.toolCalls}${lastTool}`);

  // Tool breakdown (top 5 as mini bar chart)
  const sorted = Object.entries(progress.toolBreakdown)
    .sort(([, a], [, b]) => b - a)
    .slice(0, 5);

  if (sorted.length > 0) {
    const max = sorted[0][1];
    for (const [name, count] of sorted) {
      const barLen = Math.max(1, Math.round((count / max) * 15));
      const bar = chalk.cyan("█".repeat(barLen));
      lines.push(`  ${chalk.dim(name.padEnd(8))} ${bar} ${chalk.dim(String(count))}`);
    }
  }

  // Files changed
  lines.push(`  ${chalk.dim("Files     ")} ${chalk.yellow(String(progress.filesChanged.length))}`);
  const shown = progress.filesChanged.slice(0, 5);
  const remaining = progress.filesChanged.length - shown.length;
  for (const f of shown) {
    lines.push(`  ${chalk.yellow(shortPath(f))}`);
  }
  if (remaining > 0) {
    lines.push(`  ${chalk.dim(`+${remaining} more`)}`);
  }

  // Failed run: show log hint
  if (run.status === "failed") {
    lines.push(`  ${chalk.dim(`Logs      ~/.foreman/logs/${run.id}.log`)}`);
  }

  return lines.join("\n");
}

// ── State polling ────────────────────────────────────────────────────────

export interface WatchState {
  runs: Array<{ run: Run; progress: RunProgress | null }>;
  allDone: boolean;
  totalCost: number;
  totalTools: number;
  totalFiles: number;
  completedCount: number;
  failedCount: number;
  stuckCount: number;
}

export function poll(store: ForemanStore, runIds: string[]): WatchState {
  const entries: Array<{ run: Run; progress: RunProgress | null }> = [];
  let totalCost = 0;
  let totalTools = 0;
  let totalFiles = 0;
  let allDone = true;

  for (const id of runIds) {
    const run = store.getRun(id);
    if (!run) continue;
    const progress = store.getRunProgress(run.id);

    if (progress) {
      totalCost += progress.costUsd;
      totalTools += progress.toolCalls;
      totalFiles += progress.filesChanged.length;
    }

    if (run.status === "pending" || run.status === "running") {
      allDone = false;
    }

    entries.push({ run, progress });
  }

  const completedCount = entries.filter((e) => e.run.status === "completed").length;
  const failedCount = entries.filter(
    (e) => e.run.status === "failed" || e.run.status === "test-failed",
  ).length;
  const stuckCount = entries.filter((e) => e.run.status === "stuck").length;

  return { runs: entries, allDone, totalCost, totalTools, totalFiles, completedCount, failedCount, stuckCount };
}

export function renderWatchDisplay(state: WatchState, showDetachHint = true): string {
  if (state.runs.length === 0) {
    return chalk.dim("No runs found.");
  }

  const lines: string[] = [];

  // Header
  const detachHint = showDetachHint && !state.allDone
    ? `  ${chalk.dim("(Ctrl+C to detach)")}`
    : "";
  lines.push(`${chalk.bold("Foreman")} ${chalk.dim("— agent monitor")}${detachHint}`);
  lines.push(RULE);

  // Agent cards
  for (const { run, progress } of state.runs) {
    lines.push(renderAgentCard(run, progress));
    lines.push("");
  }

  // Summary bar
  lines.push(RULE);
  lines.push(
    `${chalk.dim(String(state.runs.length) + " agents")}  ` +
    `${state.totalTools} tool calls  ` +
    `${chalk.yellow(String(state.totalFiles) + " files")}  ` +
    `${chalk.green("$" + state.totalCost.toFixed(4))}`,
  );

  // Completion banner
  if (state.allDone) {
    lines.push(RULE);
    const parts = [
      chalk.bold("Done:"),
      chalk.green(`${state.completedCount} completed`),
    ];
    if (state.failedCount > 0) parts.push(chalk.red(`${state.failedCount} failed`));
    if (state.stuckCount > 0) parts.push(chalk.yellow(`${state.stuckCount} rate-limited`));
    lines.push(parts.join("  "));
    lines.push(chalk.dim(`  ${state.totalTools} tool calls, $${state.totalCost.toFixed(4)} total cost`));
    if (state.stuckCount > 0) {
      lines.push(chalk.yellow("  Run 'foreman run --resume' after rate limit resets to continue."));
    }
  }

  return lines.join("\n");
}

// ── Public API ────────────────────────────────────────────────────────────

export async function watchRunsInk(store: ForemanStore, runIds: string[]): Promise<void> {
  const POLL_MS = 3_000;
  let detached = false;

  const onSigint = () => {
    if (detached) return; // Prevent double-fire
    detached = true;
    process.stdout.write("\n");
    console.log("  Detached — agents continue in background (detached workers).");
    console.log("  Check status:  foreman monitor");
    console.log("  Attach to run: foreman attach <run-id>\n");
  };
  process.on("SIGINT", onSigint);

  try {
    while (!detached) {
      const state = poll(store, runIds);

      // Clear screen and render current state (single write to avoid flicker)
      const display = renderWatchDisplay(state, true);
      process.stdout.write("\x1B[2J\x1B[H" + display + "\n");

      if (state.runs.length === 0 || state.allDone) {
        break;
      }

      await new Promise<void>((resolve) => setTimeout(resolve, POLL_MS));
    }
  } finally {
    process.removeListener("SIGINT", onSigint);
  }
}
