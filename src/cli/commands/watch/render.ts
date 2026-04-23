/**
 * render.ts — Top-level render compositing for the unified watch display.
 *
 * Provides:
 * - renderWatch(): assembles the full display from WatchState
 * - renderWatchHeader(): header bar with project name, refresh, quit hint
 * - renderWatchFooter(): footer with last updated time
 */

import chalk from "chalk";
import { type WatchState } from "./WatchState.js";
import { renderWatchLayout, computeLayoutSections } from "./WatchLayout.js";
import { renderHelpOverlay } from "./WatchState.js";

// ── Terminal dimensions ───────────────────────────────────────────────────

function getTerminalWidth(): number {
  return process.stdout.columns || 120;
}

// ── Main render entry ──────────────────────────────────────────────────────

/**
 * Render the complete unified watch display.
 * Returns the full terminal-ready string.
 */
export function renderWatch(state: WatchState): string {
  const width = getTerminalWidth();

  // Show help overlay on top of everything
  if (state.showHelp) {
    return [
      renderWatchHeader(state),
      "",
      renderHelpOverlay(width),
    ].join("\n");
  }

  // Normal display
  const display = renderWatchLayout(state, width);
  return [renderWatchHeader(state), "", display].join("\n");
}

// ── Header ────────────────────────────────────────────────────────────────

/**
 * Render the display header bar.
 */
export function renderWatchHeader(state: WatchState): string {
  const mode = chalk.dim("[watch]");
  const refresh = chalk.dim("[refresh: 5s]");
  const quit = chalk.dim("[Ctrl+C quit]");

  const projectName = state.dashboard?.projects[0]?.name ?? "—";
  const title = `${chalk.bold.cyan("FOREMAN WATCH")} — ${chalk.bold(projectName)}`;

  return [title, chalk.dim("─".repeat(Math.min(getTerminalWidth(), 80)))].join("\n");
}

// ── Footer ────────────────────────────────────────────────────────────────

/**
 * Render the display footer.
 */
export function renderWatchFooter(state: WatchState): string {
  const timeStr = state.lastPollMs > 0
    ? new Date(state.lastPollMs).toLocaleTimeString()
    : "—";
  const footer = chalk.dim(`Last updated: ${timeStr}  |  Ctrl+C to quit`);
  return footer;
}

// ── Error toast ───────────────────────────────────────────────────────────

/**
 * Render a temporary error toast (shown for 3 seconds after a failed action).
 */
export function renderErrorToast(message: string, width: number): string {
  const innerWidth = width - 4;
  const text = `⚠ ${message}`;
  const line = chalk.red(text.padEnd(innerWidth));
  return ["┌" + "".padEnd(innerWidth, "─") + "┐",
          "│" + line + "│",
          "└" + "".padEnd(innerWidth, "─") + "┘",
  ].join("\n");
}
