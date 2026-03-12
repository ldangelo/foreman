import chalk from "chalk";

import type { ForemanStore, Run, RunProgress } from "../lib/store.js";
import type { NotificationBus } from "../orchestrator/notification-bus.js";

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

/**
 * Render a single-line summary card for a collapsed agent.
 * Shows: indicator, status icon, seed ID, status, elapsed, model, and key
 * progress metrics on one line.
 */
export function renderAgentCardSummary(run: Run, progress: RunProgress | null, index?: number): string {
  const icon = STATUS_ICONS[run.status] ?? "?";
  const isRunning = run.status === "running";
  const isPending = run.status === "pending";
  const time = isRunning || isPending
    ? elapsed(run.started_at ?? run.created_at)
    : elapsed(run.started_at);

  const expandIndicator = chalk.dim("▶");
  const indexPrefix = index !== undefined ? chalk.dim(`${index + 1}.`) + " " : "";

  let line = `${indexPrefix}${expandIndicator} ${statusColor(run.status, icon)} ${chalk.cyan.bold(run.seed_id)} ${statusColor(run.status, run.status.toUpperCase())} ${chalk.dim(time)}  ${chalk.magenta(shortModel(run.agent_type))}`;

  if (progress && progress.toolCalls > 0) {
    const activity = progress.currentPhase
      ? chalk.dim(`[${progress.currentPhase}]`)
      : progress.lastToolCall
      ? chalk.dim(`last: ${progress.lastToolCall}`)
      : "";

    if (activity) line += `  ${activity}`;
    line += `  ${chalk.green("$" + progress.costUsd.toFixed(4))}`;
    line += `  ${chalk.dim(progress.turns + "t " + progress.toolCalls + " tools")}`;
  } else if (isRunning) {
    line += `  ${chalk.dim("Initializing...")}`;
  }

  return line;
}

/**
 * Render an agent card.
 * @param isExpanded - When false, delegates to the compact summary view.
 * @param index - Zero-based position in the run list; shown as a 1-based
 *   numeric prefix so users can press the matching key to toggle.
 */
export function renderAgentCard(run: Run, progress: RunProgress | null, isExpanded = true, index?: number): string {
  if (!isExpanded) {
    return renderAgentCardSummary(run, progress, index);
  }

  const icon = STATUS_ICONS[run.status] ?? "?";
  const isRunning = run.status === "running";
  const isPending = run.status === "pending";
  const time = isRunning || isPending
    ? elapsed(run.started_at ?? run.created_at)
    : elapsed(run.started_at);

  const lines: string[] = [];

  // Header: collapse indicator + index prefix + icon + seed ID + status + elapsed
  const collapseIndicator = chalk.dim("▼");
  const indexPrefix = index !== undefined ? chalk.dim(`${index + 1}.`) + " " : "";
  lines.push(
    `${indexPrefix}${collapseIndicator} ${statusColor(run.status, icon)} ${chalk.cyan.bold(run.seed_id)} ${statusColor(run.status, run.status.toUpperCase())} ${chalk.dim(time)}`,
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
  lines.push(`  ${chalk.dim("Turns     ")} ${progress.turns}`);

  // Show pipeline phase if available (colour-coded by role)
  if (progress.currentPhase) {
    const phaseColors: Record<string, (s: string) => string> = {
      explorer:  chalk.cyan,
      developer: chalk.green,
      qa:        chalk.yellow,
      reviewer:  chalk.magenta,
      finalize:  chalk.blue,
    };
    const colorFn = phaseColors[progress.currentPhase] ?? chalk.white;
    lines.push(`  ${chalk.dim("Phase     ")} ${colorFn(progress.currentPhase)}`);
  }

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

/**
 * Render the full watch display.
 *
 * @param showDetachHint - Show the "Ctrl+C to detach" hint (true in interactive
 *   watch mode, false in non-interactive contexts like `foreman status`).
 * @param expandedRunIds - When provided (i.e. not undefined), the function is
 *   running in interactive mode: each run is rendered collapsed or expanded
 *   based on whether its ID is in the set, and toggle key-binding hints are
 *   shown.  When omitted (undefined), all runs are rendered expanded and no
 *   key-binding hints are shown — safe for non-interactive output.
 */
export function renderWatchDisplay(state: WatchState, showDetachHint = true, expandedRunIds?: Set<string>): string {
  if (state.runs.length === 0) {
    return chalk.dim("No runs found.");
  }

  const lines: string[] = [];

  // Header — build hint string incrementally
  let detachHint = "";
  if (showDetachHint && !state.allDone) {
    const hintParts: string[] = [chalk.dim("Ctrl+C to detach")];
    // Toggle hints are only meaningful when we're in interactive mode
    // (i.e. expandedRunIds is provided).
    if (expandedRunIds !== undefined) {
      hintParts.push(chalk.dim("'a' toggle all"));
      // Only show numeric-index hint when there are multiple agents to index.
      if (state.runs.length > 1) {
        hintParts.push(chalk.dim("1-9 toggle agent"));
      }
    }
    detachHint = `  (${hintParts.join(" | ")})`;
  }
  lines.push(`${chalk.bold("Foreman")} ${chalk.dim("— agent monitor")}${detachHint}`);
  lines.push(RULE);

  // Agent cards
  for (let i = 0; i < state.runs.length; i++) {
    const { run, progress } = state.runs[i];
    // When expandedRunIds is provided: use the set to determine expansion.
    // When undefined (non-interactive / legacy): always expand.
    const isExpanded = expandedRunIds ? expandedRunIds.has(run.id) : true;
    // Show numeric index prefix only when there are multiple agents.
    const index = state.runs.length > 1 ? i : undefined;
    lines.push(renderAgentCard(run, progress, isExpanded, index));
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

export interface WatchResult {
  detached: boolean;
}

export async function watchRunsInk(
  store: ForemanStore,
  runIds: string[],
  opts?: {
    /** Optional notification bus — when provided, status/progress events wake
     *  the poll immediately instead of waiting for the next 3-second cycle. */
    notificationBus?: NotificationBus;
  },
): Promise<WatchResult> {
  const POLL_MS = 3_000;
  let detached = false;
  // All runs start collapsed; users press 'a' or a digit to expand.
  const expandedRunIds = new Set<string>();
  let lastState: WatchState | null = null;
  // Resolved to interrupt the poll sleep early (e.g. on key press or detach).
  let sleepResolve: (() => void) | null = null;

  /** Re-render the current state immediately without waiting for next poll. */
  const renderNow = () => {
    if (lastState) {
      const display = renderWatchDisplay(lastState, true, expandedRunIds);
      process.stdout.write("\x1B[2J\x1B[H" + display + "\n");
    }
  };

  const onSigint = () => {
    if (detached) return; // Prevent double-fire
    detached = true;
    process.stdout.write("\n");
    console.log("  Detached — agents continue in background (detached workers).");
    console.log("  Check status:  foreman monitor");
    console.log("  Attach to run: foreman attach <run-id>\n");
    // Wake up the sleep immediately so the loop exits
    if (sleepResolve) sleepResolve();
  };
  process.on("SIGINT", onSigint);

  // Subscribe to worker notifications to wake the poll early.
  // When a worker reports a status or progress change for one of our watched
  // runs, we interrupt the 3-second sleep so the UI refreshes immediately.
  const watchedRunIds = new Set(runIds);
  const onNotification = () => {
    if (sleepResolve) sleepResolve();
  };
  if (opts?.notificationBus) {
    for (const runId of watchedRunIds) {
      opts.notificationBus.onRunNotification(runId, onNotification);
    }
  }

  // Set up keyboard input for expand/collapse toggle
  let stdinRawMode = false;

  const handleKeyInput = (key: string) => {
    if (key === "\u0003") {
      // Ctrl+C in raw mode — signal the process so onSigint fires.
      // process.kill() is more semantically correct than process.emit("SIGINT")
      // and avoids a TypeScript type cast.
      process.kill(process.pid, "SIGINT");
      return;
    }

    let stateChanged = false;

    if (key === "a" || key === "A") {
      // Toggle all: if any expanded, collapse all; otherwise expand all.
      if (expandedRunIds.size > 0) {
        expandedRunIds.clear();
      } else if (lastState) {
        for (const { run } of lastState.runs) {
          expandedRunIds.add(run.id);
        }
      }
      stateChanged = true;
    } else if (/^[1-9]$/.test(key) && lastState) {
      const idx = parseInt(key, 10) - 1;
      const entry = lastState.runs[idx];
      if (entry) {
        if (expandedRunIds.has(entry.run.id)) {
          expandedRunIds.delete(entry.run.id);
        } else {
          expandedRunIds.add(entry.run.id);
        }
        stateChanged = true;
      }
    }

    if (stateChanged) {
      // Provide immediate visual feedback — do not wait for the next poll cycle.
      renderNow();
      // Also wake the poll sleep so the next full poll+render fires promptly.
      if (sleepResolve) sleepResolve();
    }
  };

  if (process.stdin.isTTY) {
    try {
      process.stdin.setRawMode(true);
      process.stdin.resume();
      process.stdin.setEncoding("utf8");
      process.stdin.on("data", handleKeyInput);
      stdinRawMode = true;
    } catch {
      // stdin may not support raw mode in some environments; continue without it
    }
  }

  try {
    while (!detached) {
      const state = poll(store, runIds);
      lastState = state;

      // Clear screen and render current state (single write to avoid flicker)
      const display = renderWatchDisplay(state, true, expandedRunIds);
      process.stdout.write("\x1B[2J\x1B[H" + display + "\n");

      if (state.runs.length === 0 || state.allDone) {
        break;
      }

      await new Promise<void>((resolve) => {
        sleepResolve = resolve;
        setTimeout(resolve, POLL_MS);
      });
      sleepResolve = null;
    }
  } finally {
    process.removeListener("SIGINT", onSigint);
    // Unsubscribe from notification bus to avoid listener leaks
    if (opts?.notificationBus) {
      for (const runId of watchedRunIds) {
        opts.notificationBus.offRunNotification(runId, onNotification);
      }
    }
    if (stdinRawMode && process.stdin.isTTY) {
      try {
        process.stdin.removeListener("data", handleKeyInput);
        process.stdin.setRawMode(false);
        process.stdin.pause();
      } catch {
        // ignore cleanup errors
      }
    }
  }
  return { detached };
}
