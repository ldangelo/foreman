import chalk from "chalk";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import type { ForemanStore, Run, RunProgress } from "../lib/store.js";
import type { NotificationBus } from "../orchestrator/notification-bus.js";
import { PIPELINE_TIMEOUTS } from "../lib/config.js";

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

// ── Success rate display ─────────────────────────────────────────────────

/**
 * Format a success rate value as a colored percentage string.
 *
 * @param rate - Value between 0 and 1, or null/undefined when there is insufficient data.
 * @returns A chalk-colored string like "87%" or "--" when rate is null/undefined.
 */
export function formatSuccessRate(rate: number | null | undefined): string {
  if (rate == null) return chalk.dim("--");
  const pct = Math.round(rate * 100);
  const label = `${pct}%`;
  if (pct >= 90) return chalk.green(label);
  if (pct >= 70) return chalk.yellow(label);
  return chalk.red(label);
}

// ── Error log helper ─────────────────────────────────────────────────────

/**
 * Read the last N lines from an agent's .err log file.
 * Returns an empty array if the file doesn't exist or can't be read.
 */
export function readLastErrorLines(runId: string, n = 5): string[] {
  try {
    const logPath = join(process.env.HOME ?? "/tmp", ".foreman", "logs", `${runId}.err`);
    const content = readFileSync(logPath, "utf-8");
    return content
      .split("\n")
      .filter((line) => line.trim().length > 0)
      .slice(-n);
  } catch {
    return [];
  }
}

// ── Display functions ─────────────────────────────────────────────────────

/**
 * Render a single-line summary card for a collapsed agent.
 * Shows: indicator, status icon, seed ID, status, elapsed, model, and key
 * progress metrics on one line.
 */
export function renderAgentCardSummary(run: Run, progress: RunProgress | null, index?: number, attemptNumber?: number, previousStatus?: string): string {
  const icon = STATUS_ICONS[run.status] ?? "?";
  const isRunning = run.status === "running";
  const isPending = run.status === "pending";
  const time = isRunning || isPending
    ? elapsed(run.started_at ?? run.created_at)
    : elapsed(run.started_at);

  const expandIndicator = chalk.dim("▶");
  const indexPrefix = index !== undefined ? chalk.dim(`${index + 1}.`) + " " : "";

  const attemptInfo = attemptNumber && attemptNumber > 1
    ? chalk.dim(` (attempt ${attemptNumber}${previousStatus ? ", prev: " + previousStatus : ""})`)
    : "";

  let line = `${indexPrefix}${expandIndicator} ${statusColor(run.status, icon)} ${chalk.cyan.bold(run.seed_id)} ${statusColor(run.status, run.status.toUpperCase())} ${chalk.dim(time)}${attemptInfo}  ${chalk.magenta(shortModel(run.agent_type))}`;

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
 * @param attemptNumber - If > 1, indicates this is a retry (e.g. attempt 2 of 3).
 * @param previousStatus - Status of the previous run (e.g. "failed", "stuck").
 */
export function renderAgentCard(run: Run, progress: RunProgress | null, isExpanded = true, index?: number, attemptNumber?: number, previousStatus?: string, showErrorLogs = false): string {
  if (!isExpanded) {
    return renderAgentCardSummary(run, progress, index, attemptNumber, previousStatus);
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
  const attemptInfo = attemptNumber && attemptNumber > 1
    ? chalk.dim(` (attempt ${attemptNumber}${previousStatus ? ", prev: " + previousStatus : ""})`)
    : "";
  lines.push(
    `${indexPrefix}${collapseIndicator} ${statusColor(run.status, icon)} ${chalk.cyan.bold(run.seed_id)} ${statusColor(run.status, run.status.toUpperCase())} ${chalk.dim(time)}${attemptInfo}`,
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

  // Per-phase cost breakdown (pipeline mode only)
  if (progress.costByPhase && Object.keys(progress.costByPhase).length > 0) {
    const phaseOrder = ["explorer", "developer", "qa", "reviewer"];
    const phases = Object.entries(progress.costByPhase)
      .sort(([a], [b]) => {
        const ai = phaseOrder.indexOf(a);
        const bi = phaseOrder.indexOf(b);
        if (ai === -1 && bi === -1) return a.localeCompare(b);
        if (ai === -1) return 1;
        if (bi === -1) return -1;
        return ai - bi;
      });
    for (const [phase, cost] of phases) {
      const agent = progress.agentByPhase?.[phase];
      const agentHint = agent ? chalk.dim(` (${shortModel(agent)})`) : "";
      lines.push(`  ${chalk.dim("  " + phase.padEnd(10))} ${chalk.dim("$" + cost.toFixed(4))}${agentHint}`);
    }
  }

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

  // Error log section (toggled with 'e' key)
  if (showErrorLogs) {
    const errorLines = readLastErrorLines(run.id);
    if (errorLines.length > 0) {
      lines.push(`  ${chalk.dim("──── Last error log lines ────")}`);
      for (const errLine of errorLines) {
        lines.push(`  ${chalk.red(errLine)}`);
      }
    } else {
      lines.push(`  ${chalk.dim("──── No error log entries ────")}`);
    }
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
  /** 24-hour success rate (0–1), or null when fewer than 3 terminal runs exist. */
  successRate?: number | null;
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
export function renderWatchDisplay(state: WatchState, showDetachHint = true, expandedRunIds?: Set<string>, notification?: string, showErrorLogs = false): string {
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
      hintParts.push(chalk.dim("'e' toggle errors"));
      // Only show numeric-index hint when there are multiple agents to index.
      if (state.runs.length > 1) {
        hintParts.push(chalk.dim("1-9 toggle agent"));
      }
    }
    detachHint = `  (${hintParts.join(" | ")})`;
  }
  lines.push(`${chalk.bold("Foreman")} ${chalk.dim("— agent monitor")}${detachHint}`);
  lines.push(RULE);

  // Show auto-dispatch notification if present
  if (notification) {
    lines.push(chalk.green.bold(`  ✦ ${notification}`));
    lines.push("");
  }

  // Agent cards
  for (let i = 0; i < state.runs.length; i++) {
    const { run, progress } = state.runs[i];
    // When expandedRunIds is provided: use the set to determine expansion.
    // When undefined (non-interactive / legacy): always expand.
    const isExpanded = expandedRunIds ? expandedRunIds.has(run.id) : true;
    // Show numeric index prefix only when there are multiple agents.
    const index = state.runs.length > 1 ? i : undefined;
    lines.push(renderAgentCard(run, progress, isExpanded, index, undefined, undefined, showErrorLogs));
    lines.push("");
  }

  // Summary bar
  lines.push(RULE);
  const successRatePart = state.successRate !== undefined
    ? `  ${chalk.dim("success (24h)")} ${formatSuccessRate(state.successRate)}`
    : "";
  lines.push(
    `${chalk.dim(String(state.runs.length) + " agents")}  ` +
    `${state.totalTools} tool calls  ` +
    `${chalk.yellow(String(state.totalFiles) + " files")}  ` +
    `${chalk.green("$" + state.totalCost.toFixed(4))}` +
    successRatePart,
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
    /** Optional callback invoked when an agent completes and capacity may be
     *  available.  Returns IDs of newly-dispatched runs to add to the watch
     *  list.  Errors from this callback are swallowed (non-fatal). */
    autoDispatch?: () => Promise<string[]>;
  },
): Promise<WatchResult> {
  const POLL_MS = PIPELINE_TIMEOUTS.monitorPollMs;
  let detached = false;
  // All runs start collapsed; users press 'a' or a digit to expand.
  const expandedRunIds = new Set<string>();
  let showErrorLogs = false; // Toggle with 'e' key
  let lastState: WatchState | null = null;
  // Resolved to interrupt the poll sleep early (e.g. on key press or detach).
  let sleepResolve: (() => void) | null = null;

  /** Re-render the current state immediately without waiting for next poll. */
  const renderNow = () => {
    if (lastState) {
      const display = renderWatchDisplay(lastState, true, expandedRunIds, undefined, showErrorLogs);
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

  // Local mutable list of run IDs to watch; new IDs may be appended by
  // auto-dispatch while the loop is running.
  const watchList = [...runIds];
  // Track active count across poll cycles to detect completions.
  let prevActiveCount: number | null = null;
  let autoDispatchNotification: string | null = null;

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
    } else if (key === "e" || key === "E") {
      // Toggle error log display
      showErrorLogs = !showErrorLogs;
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
      let state = poll(store, watchList);

      // Auto-dispatch: if a run completed, try to dispatch new tasks
      const currentActiveCount = state.runs.filter(
        (e) => e.run.status === "pending" || e.run.status === "running",
      ).length;

      if (opts?.autoDispatch && prevActiveCount !== null && currentActiveCount < prevActiveCount) {
        let addedNew = false;
        let newDispatchedCount = 0;
        try {
          const newRunIds = await opts.autoDispatch();
          newDispatchedCount = newRunIds.length;
          for (const id of newRunIds) {
            if (!watchedRunIds.has(id)) {
              watchList.push(id);
              watchedRunIds.add(id);
              if (opts?.notificationBus) {
                opts.notificationBus.onRunNotification(id, onNotification);
              }
              addedNew = true;
            }
          }
        } catch {
          // Non-fatal — auto-dispatch errors should not kill the watch loop
        }
        // Re-poll to include new runs in state
        if (addedNew) {
          autoDispatchNotification = `[auto-dispatch] ${newDispatchedCount} new task(s)`;
          state = poll(store, watchList);
        }
      }
      prevActiveCount = currentActiveCount;

      // Enrich state with 24-hour success rate
      {
        const projectId = state.runs[0]?.run.project_id;
        try {
          const sr = store.getSuccessRate(projectId);
          state = { ...state, successRate: sr.rate };
        } catch {
          // Non-fatal — success rate is supplemental
        }
      }

      lastState = state;

      // Clear screen and render current state (single write to avoid flicker)
      const display = renderWatchDisplay(state, true, expandedRunIds, autoDispatchNotification ?? undefined, showErrorLogs);
      process.stdout.write("\x1B[2J\x1B[H" + display + "\n");
      autoDispatchNotification = null;

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
