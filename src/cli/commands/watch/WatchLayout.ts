/**
 * WatchLayout — Responsive panel layout computation for the unified watch display.
 *
 * Layout modes:
 * - 3-panel side-by-side at 120+ columns
 * - 3-panel side-by-side at 90-119 columns (narrower panels)
 * - 3-panel stacked at 80-89 columns
 * - Warning at < 80 columns
 *
 * Panel widths are computed proportionally based on terminal width.
 * Each panel has a header line and a body.
 */

import chalk from "chalk";
import type { BoardStatus } from "../board.js";
import { type PanelId, type WatchState } from "./WatchState.js";
import { renderAgentCard } from "../../watch-ui.js";
import { elapsed } from "../../watch-ui.js";

// ── Layout constants ──────────────────────────────────────────────────────

const MIN_WIDTH = 80;
const NARROW_WIDTH = 90;
const RECOMMENDED_WIDTH = 120;

const PANEL_LABELS: Record<PanelId, string> = {
  agents: "AGENTS",
  board: "BOARD",
  inbox: "INBOX",
};

const PANEL_ICONS: Record<PanelId, string> = {
  agents: "●",
  board: "■",
  inbox: "✉",
};

// ── Layout mode ────────────────────────────────────────────────────────────

export type LayoutMode = "wide" | "medium" | "narrow" | "too-narrow";

export function detectLayoutMode(width: number): LayoutMode {
  if (width < MIN_WIDTH) return "too-narrow";
  if (width < NARROW_WIDTH) return "narrow";
  if (width < RECOMMENDED_WIDTH) return "medium";
  return "wide";
}

export function getPanelWidths(mode: LayoutMode, totalWidth: number): Record<PanelId, number> {
  // Reserve 2 for outer padding + 2 for borders = 4 total
  const available = totalWidth - 4;

  if (mode === "narrow") {
    // Stacked: each panel gets full width
    return { agents: available, board: available, inbox: available };
  }

  // Proportional split for side-by-side:
  // Agents: 40%, Board: 30%, Inbox: 30%
  const agentsW = Math.floor(available * 0.4);
  const boardW = Math.floor(available * 0.3);
  const inboxW = available - agentsW - boardW;
  return { agents: agentsW, board: boardW, inbox: inboxW };
}

// ── Truncation helpers ────────────────────────────────────────────────────

function truncate(text: string, maxLen: number): string {
  if (text.length <= maxLen) return text;
  return text.slice(0, Math.max(0, maxLen - 1)) + "…";
}

function truncateMiddle(text: string, maxLen: number): string {
  if (text.length <= maxLen) return text;
  if (maxLen <= 3) return "…".repeat(maxLen);
  const keep = Math.floor((maxLen - 1) / 2);
  return text.slice(0, keep) + "…" + text.slice(-keep);
}

// ── Panel header ─────────────────────────────────────────────────────────

function panelHeader(panel: PanelId, state: WatchState, width: number): string {
  const mode = detectLayoutMode(width);
  const label = PANEL_LABELS[panel];
  const isFocused = state.focusedPanel === panel;

  const bg = isFocused ? chalk.cyan : chalk.dim;
  const fg = isFocused ? (t: string) => chalk.cyan.bold(t) : (t: string) => t;

  const offline = getOfflineIndicator(panel, state);
  const status = offline ?? chalk.dim("ok");

  // Build header line within panel width
  const innerWidth = width - 2; // subtract border chars
  const labelStr = truncate(` ${label} `, innerWidth - 2);
  const statusStr = chalk.dim(` ${status}`);

  // Assemble with borders
  let line = fg(bg("┌")) + labelStr.padEnd(innerWidth - statusStr.length, "─") + fg(bg("┐"));
  line += "\n";
  line += fg(bg("│")) + chalk.dim("".padEnd(innerWidth)) + fg(bg("│"));
  line += "\n";
  line += fg(bg("│")) + ` ${fg(labelStr.trim())}${statusStr}`.padEnd(innerWidth) + fg(bg("│"));
  line += "\n";
  line += fg(bg("│")) + chalk.dim("".padEnd(innerWidth)) + fg(bg("│"));
  line += "\n";
  line += fg(bg("├")) + chalk.dim("".padEnd(innerWidth, "─")) + fg(bg("┤"));

  return line;
}

function panelFooter(width: number): string {
  const innerWidth = width - 2;
  return chalk.dim("└" + "".padEnd(innerWidth, "─") + "┘");
}

function getOfflineIndicator(panel: PanelId, state: WatchState): string | null {
  switch (panel) {
    case "agents": return state.agentsOffline ? chalk.red("offline") : null;
    case "board":  return state.boardOffline  ? chalk.red("offline") : null;
    case "inbox":  return state.inboxOffline   ? chalk.red("offline") : null;
  }
}

// ── Agent panel rendering ─────────────────────────────────────────────────

function renderAgentsPanel(state: WatchState, width: number): string {
  const lines: string[] = [];

  if (state.agentsOffline) {
    lines.push(chalk.dim("  (agents unavailable)"));
    return lines.join("\n");
  }

  if (state.agents.length === 0) {
    lines.push(chalk.dim("  (no agents running)"));
    return lines.join("\n");
  }

  const innerWidth = width - 2;

  for (let i = 0; i < state.agents.length; i++) {
    const { run, progress } = state.agents[i];
    const isExpanded = state.expandedAgentIndices.has(i);

    // Collapsed: summary line only
    const icon = run.status === "running" ? chalk.blue("●") :
                run.status === "pending" ? chalk.gray("○") :
                run.status === "completed" ? chalk.green("✓") :
                run.status === "failed" ? chalk.red("✗") :
                chalk.yellow("⚠");

    const time = run.started_at || run.created_at;
    const elapsedStr = time ? ` ${elapsed(time)}` : "";

    const indexPrefix = state.agents.length > 1 ? chalk.dim(`${i + 1}.`) + " " : "";

    const expandIndicator = isExpanded ? chalk.dim("▼") : chalk.dim("▶");
    const statusColor = run.status === "failed" ? chalk.red :
                        run.status === "completed" ? chalk.green :
                        run.status === "pending" ? chalk.gray : chalk.blue;

    let line = `${indexPrefix}${expandIndicator} ${icon} ${chalk.cyan(run.seed_id)} ${statusColor(run.status.toUpperCase())}${elapsedStr}`;
    line = truncate(line, innerWidth);

    lines.push(`  ${line}`);

    if (isExpanded) {
      // Expanded card
      const cardLines = renderAgentCard(run, progress, true, undefined, undefined, undefined, false)
        .split("\n")
        .slice(1); // Skip header since we already rendered one
      for (const cardLine of cardLines) {
        lines.push(`  ${truncate(cardLine, innerWidth)}`);
      }
    }

    lines.push(""); // blank line between agents
  }

  // Total cost footer
  let totalCost = 0;
  for (const { progress } of state.agents) {
    if (progress) totalCost += progress.costUsd;
  }
  if (totalCost > 0) {
    lines.push(chalk.dim(`  Total: ${chalk.yellow("$" + totalCost.toFixed(4))}`));
  } else {
    lines.push(chalk.dim(`  Total: $0.00`));
  }

  return lines.join("\n");
}

// ── Board panel rendering ────────────────────────────────────────────────

const BOARD_STATUS_ABBREV: Record<string, string> = {
  backlog:     "backlog",
  ready:        "ready",
  in_progress:  "in_prog",
  review:       "review",
  blocked:      "blocked",
  closed:       "closed",
};

type ChalkFn = (text: string) => string;

const BOARD_STATUS_COLOR: Record<string, ChalkFn> = {
  backlog:     chalk.dim,
  ready:       chalk.green,
  in_progress: chalk.yellow,
  review:      chalk.magenta,
  blocked:     chalk.red,
  closed:      chalk.gray,
};

function renderBoardPanel(state: WatchState, width: number): string {
  const lines: string[] = [];

  if (state.boardOffline) {
    lines.push(chalk.dim("  (board unavailable)"));
    return lines.join("\n");
  }

  if (!state.board) {
    lines.push(chalk.dim("  (no data)"));
    return lines.join("\n");
  }

  const innerWidth = width - 2;

  // Compact status summary: backlog(8) ready(3) in_prog(2) ...
  const parts: string[] = [];
  const statusOrder: Array<keyof typeof BOARD_STATUS_ABBREV> = [
    "backlog", "ready", "in_progress", "review", "blocked", "closed",
  ];

  for (const status of statusOrder) {
    const count = state.board.counts[status as BoardStatus];
    if (count === 0) continue;
    const colorFn = BOARD_STATUS_COLOR[status] ?? ((t: string) => chalk.white(t) as string);
    const abbrev = BOARD_STATUS_ABBREV[status];
    parts.push(String(colorFn(`${abbrev}(${count})`)));
  }

  const summary = parts.join(chalk.dim(" "));
  const line1 = truncate(summary, innerWidth);
  lines.push(`  ${line1}`);

  // Highlight tasks needing attention
  if (state.board.needsAttention.length > 0) {
    lines.push("");
    lines.push(chalk.red("  ⚠ Needs attention:"));
    for (const task of state.board.needsAttention.slice(0, 3)) {
      const isSelected = state.selectedTaskIndex >= 0 &&
        state.board!.needsAttention[state.selectedTaskIndex]?.id === task.id;
      const marker = isSelected ? chalk.cyan("▶") : chalk.dim(" ");
      const title = truncate(task.title, innerWidth - 10);
      const statusTag = chalk.red(`[${task.status}]`);
      lines.push(`  ${marker} ${statusTag} ${title}`);
    }
    if (state.board.needsAttention.length > 3) {
      lines.push(chalk.dim(`  +${state.board.needsAttention.length - 3} more`));
    }
  }

  // Totals
  lines.push("");
  lines.push(chalk.dim(`  Total: ${state.board.total}  Ready: ${state.board.ready}`));

  return lines.join("\n");
}

// ── Inbox panel rendering ────────────────────────────────────────────────

function renderInboxPanel(state: WatchState, width: number): string {
  const lines: string[] = [];

  if (state.inboxOffline) {
    lines.push(chalk.dim("  (inbox unavailable)"));
    return lines.join("\n");
  }

  if (!state.inbox || state.inbox.messages.length === 0) {
    lines.push(chalk.dim("  (no messages)"));
    return lines.join("\n");
  }

  const innerWidth = width - 2;

  // Live indicator
  if (state.inbox.newestTimestamp) {
    const age = elapsed(state.inbox.newestTimestamp);
    lines.push(chalk.dim(`  Live · last ${age} ago`));
  }

  for (const entry of state.inbox.messages) {
    const { message, isNew } = entry;
    const ts = formatInboxTime(message.created_at);
    const sender = truncateMiddle(message.sender_agent_type, 10);
    const recipient = truncateMiddle(message.recipient_agent_type, 10);
    const subject = truncate(message.subject, 20);

    const newMarker = isNew ? chalk.green("✦ ") : chalk.dim("  ");
    const line = `${newMarker}[${ts}] ${sender} → ${recipient}  ${subject}`;
    lines.push(`  ${truncate(line, innerWidth)}`);
  }

  // Footer
  lines.push("");
  lines.push(chalk.dim(`  ${state.inbox.totalCount} message(s)`));

  return lines.join("\n");
}

function formatInboxTime(isoStr: string): string {
  try {
    const d = new Date(isoStr);
    const pad = (n: number) => String(n).padStart(2, "0");
    return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  } catch {
    return isoStr;
  }
}

// ── Full layout rendering ─────────────────────────────────────────────────

export interface LayoutSection {
  panel: PanelId;
  lines: string[];
}

export function computeLayoutSections(state: WatchState, totalWidth: number): LayoutSection[] {
  const mode = detectLayoutMode(totalWidth);
  const widths = getPanelWidths(mode, totalWidth);

  if (mode === "too-narrow") {
    return [{
      panel: "agents",
      lines: [
        chalk.red("  ⚠ Terminal too narrow for unified view."),
        chalk.dim("  Minimum: 80 columns. Use `foreman dashboard` instead."),
      ],
    }];
  }

  const sections: LayoutSection[] = [];

  if (mode === "narrow") {
    // Stacked: agents | board | inbox
    for (const panel of ["agents", "board", "inbox"] as PanelId[]) {
      sections.push({
        panel,
        lines: renderPanelBody(panel, state, widths[panel]),
      });
    }
  } else {
    // Side-by-side: render all three panels horizontally
    sections.push({
      panel: "agents",
      lines: renderPanelBody("agents", state, widths.agents),
    });
    sections.push({
      panel: "board",
      lines: renderPanelBody("board", state, widths.board),
    });
    sections.push({
      panel: "inbox",
      lines: renderPanelBody("inbox", state, widths.inbox),
    });
  }

  return sections;
}

function renderPanelBody(panel: PanelId, state: WatchState, width: number): string[] {
  switch (panel) {
    case "agents": return renderAgentsPanel(state, width).split("\n");
    case "board":  return renderBoardPanel(state, width).split("\n");
    case "inbox":  return renderInboxPanel(state, width).split("\n");
  }
}

/**
 * Render the full unified watch display as a string.
 */
export function renderWatchLayout(state: WatchState, totalWidth: number): string {
  const mode = detectLayoutMode(totalWidth);

  if (mode === "too-narrow") {
    return [
      chalk.bold.red("⚠ Terminal too narrow for unified view."),
      chalk.dim("Minimum: 80 columns. Use `foreman dashboard` instead."),
    ].join("\n");
  }

  const widths = getPanelWidths(mode, totalWidth);
  const sections = computeLayoutSections(state, totalWidth);

  const lines: string[] = [];

  // Header
  const refreshStr = chalk.dim("[refresh: 5s]");
  const quitStr = chalk.dim("[Ctrl+C quit]");
  const headerText = `FOREMAN WATCH${refreshStr} ${quitStr}`;
  lines.push(chalk.bold.cyan(headerText));
  lines.push(chalk.dim("─".repeat(Math.min(totalWidth, 80))));
  lines.push("");

  if (mode === "narrow") {
    // Stacked: render each section as a bordered block
    for (const section of sections) {
      const w = widths[section.panel];
      const panelLines = section.lines;
      lines.push(...renderBorderedSection(section.panel, panelLines, w, state));
      lines.push("");
    }
  } else {
    // Side-by-side: horizontal border + content per panel + divider
    const innerWidths = {
      agents: widths.agents - 2,
      board:  widths.board  - 2,
      inbox:  widths.inbox   - 2,
    };

    // Top border row
    const topBorder = [
      chalk.dim("┌"),
      "".padEnd(innerWidths.agents, "─"),
      chalk.dim("┬"),
      "".padEnd(innerWidths.board, "─"),
      chalk.dim("┬"),
      "".padEnd(innerWidths.inbox, "─"),
      chalk.dim("┐"),
    ].join("");
    lines.push(topBorder);

    // Panel headers row
    const headerRow = [
      chalk.dim("│"),
      renderPanelHeaderText("agents", state, innerWidths.agents),
      chalk.dim("│"),
      renderPanelHeaderText("board", state, innerWidths.board),
      chalk.dim("│"),
      renderPanelHeaderText("inbox", state, innerWidths.inbox),
      chalk.dim("│"),
    ].join("");
    lines.push(headerRow);

    // Separator row
    const sepRow = [
      chalk.dim("├"),
      "".padEnd(innerWidths.agents, "─"),
      chalk.dim("┼"),
      "".padEnd(innerWidths.board, "─"),
      chalk.dim("┼"),
      "".padEnd(innerWidths.inbox, "─"),
      chalk.dim("┤"),
    ].join("");
    lines.push(sepRow);

    // Content rows (zip through panels row by row)
    const maxRows = Math.max(
      sections.find(s => s.panel === "agents")?.lines.length ?? 0,
      sections.find(s => s.panel === "board")?.lines.length ?? 0,
      sections.find(s => s.panel === "inbox")?.lines.length ?? 0,
    );

    for (let r = 0; r < maxRows; r++) {
      const agentsLine = (sections.find(s => s.panel === "agents")?.lines[r]) ?? "";
      const boardLine  = (sections.find(s => s.panel === "board")?.lines[r])  ?? "";
      const inboxLine  = (sections.find(s => s.panel === "inbox")?.lines[r])  ?? "";

      const trim = (s: string, w: number) => s.slice(0, w).padEnd(w);
      lines.push([
        chalk.dim("│"),
        trim(agentsLine, innerWidths.agents),
        chalk.dim("│"),
        trim(boardLine, innerWidths.board),
        chalk.dim("│"),
        trim(inboxLine, innerWidths.inbox),
        chalk.dim("│"),
      ].join(""));
    }

    // Bottom border
    const bottomBorder = [
      chalk.dim("└"),
      "".padEnd(innerWidths.agents, "─"),
      chalk.dim("┴"),
      "".padEnd(innerWidths.board, "─"),
      chalk.dim("┴"),
      "".padEnd(innerWidths.inbox, "─"),
      chalk.dim("┘"),
    ].join("");
    lines.push(bottomBorder);
  }

  // Error message
  if (state.errorMessage) {
    lines.push("");
    lines.push(chalk.red(`  Error: ${state.errorMessage}`));
  }

  // Last updated
  lines.push("");
  const timeStr = state.lastPollMs > 0
    ? new Date(state.lastPollMs).toLocaleTimeString()
    : "—";
  lines.push(chalk.dim(`  Last updated: ${timeStr}`));

  return lines.join("\n");
}

function renderPanelHeaderText(panel: PanelId, state: WatchState, width: number): string {
  const isFocused = state.focusedPanel === panel;
  const label = PANEL_LABELS[panel];
  const fg = isFocused ? chalk.cyan.bold : chalk.white;
  const offline = getOfflineIndicator(panel, state);
  const status = offline ?? chalk.dim("ok");
  const text = ` ${label} ${status}`;
  return fg(text.padEnd(width));
}

function renderBorderedSection(
  panel: PanelId,
  contentLines: string[],
  width: number,
  state: WatchState,
): string[] {
  const lines: string[] = [];
  const isFocused = state.focusedPanel === panel;
  const label = PANEL_LABELS[panel];
  const fg = isFocused ? chalk.cyan.bold : chalk.white;
  const innerWidth = width - 2;

  // Header
  lines.push(fg("┌" + "".padEnd(innerWidth, "─") + "┐"));
  lines.push(fg("│" + ` ${label}`.padEnd(innerWidth) + "│"));
  lines.push(fg("├" + "".padEnd(innerWidth, "─") + "┤"));

  // Content
  for (const line of contentLines) {
    lines.push(fg("│") + line.padEnd(innerWidth) + fg("│"));
  }

  // Footer
  lines.push(fg("└" + "".padEnd(innerWidth, "─") + "┘"));

  return lines;
}
