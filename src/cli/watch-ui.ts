import React from "react";
import { render, Box, Text } from "ink";
import Spinner from "ink-spinner";

import type { ForemanStore, Run, RunProgress } from "../lib/store.js";

const { createElement: h } = React;

// ── Helpers ──────────────────────────────────────────────────────────────

function elapsed(since: string | null): string {
  if (!since) return "—";
  const ms = Date.now() - new Date(since).getTime();
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${s % 60}s`;
  return `${Math.floor(m / 60)}h ${m % 60}m`;
}

function shortModel(model: string): string {
  return model
    .replace("claude-", "")
    .replace("-20251001", "");
}

function shortPath(path: string): string {
  // Show just the filename, not the full path
  const parts = path.split("/");
  return parts[parts.length - 1] ?? path;
}

const STATUS_COLORS: Record<string, string> = {
  pending: "gray",
  running: "blue",
  completed: "green",
  failed: "red",
  stuck: "yellow",
  merged: "green",
  conflict: "red",
  "test-failed": "red",
};

const STATUS_ICONS: Record<string, string> = {
  pending: "○",
  completed: "✓",
  failed: "✗",
  stuck: "⚠",
  merged: "⊕",
  conflict: "⊘",
  "test-failed": "⊘",
};

// ── Components ───────────────────────────────────────────────────────────

/** Renders "━━━━━━━━" style horizontal rule */
function Rule({ width = 60 }: { width?: number }): React.ReactElement {
  return h(Text, { dimColor: true }, "━".repeat(width));
}

/** Single labeled value: "  Label  value" */
function Field({ label, value, valueColor }: {
  label: string;
  value: string;
  valueColor?: string;
}): React.ReactElement {
  return h(Box, { gap: 1 },
    h(Text, { dimColor: true }, `  ${label.padEnd(10)}`),
    h(Text, { color: valueColor }, value),
  );
}

/** Tool breakdown: shows top tools as mini bar chart */
function ToolBreakdown({ progress }: { progress: RunProgress }): React.ReactElement {
  const sorted = Object.entries(progress.toolBreakdown)
    .sort(([, a], [, b]) => b - a)
    .slice(0, 5);

  if (sorted.length === 0) return h(Text, { dimColor: true }, "  none yet");

  const max = sorted[0][1];

  return h(Box, { flexDirection: "column" },
    ...sorted.map(([name, count]) => {
      const barLen = Math.max(1, Math.round((count / max) * 15));
      const bar = "█".repeat(barLen);
      return h(Box, { key: name, gap: 1 },
        h(Text, { dimColor: true }, `  ${name.padEnd(8)}`),
        h(Text, { color: "cyan" }, bar),
        h(Text, { dimColor: true }, ` ${count}`),
      );
    }),
  );
}

/** Files changed list (compact) */
function FilesChanged({ files }: { files: string[] }): React.ReactElement {
  if (files.length === 0) {
    return h(Text, { dimColor: true }, "  none");
  }

  // Show up to 5 files, then "+N more"
  const shown = files.slice(0, 5);
  const remaining = files.length - shown.length;

  return h(Box, { flexDirection: "column" },
    ...shown.map((f) =>
      h(Text, { key: f, color: "yellow" }, `  ${shortPath(f)}`),
    ),
    remaining > 0
      ? h(Text, { dimColor: true }, `  +${remaining} more`)
      : null,
  );
}

/** Full agent card with all details */
function AgentCard({ run, progress }: {
  run: Run;
  progress: RunProgress | null;
}): React.ReactElement {
  const color = STATUS_COLORS[run.status] ?? "gray";
  const isRunning = run.status === "running";
  const isPending = run.status === "pending";
  const time = isRunning || isPending
    ? elapsed(run.started_at ?? run.created_at)
    : elapsed(run.started_at);

  // Header: icon + bead ID + status
  const header = h(Box, { gap: 1 },
    isRunning
      ? h(Text, { color }, h(Spinner, { type: "dots" }))
      : h(Text, { color }, STATUS_ICONS[run.status] ?? "?"),
    h(Text, { bold: true, color: "cyan" }, run.bead_id),
    h(Text, { color, bold: true }, run.status.toUpperCase()),
    h(Text, { dimColor: true }, time),
  );

  // If pending or no progress yet, show minimal card
  if (isPending || !progress || progress.toolCalls === 0) {
    return h(Box, { flexDirection: "column", marginBottom: 1 },
      header,
      h(Field, { label: "Model", value: shortModel(run.agent_type), valueColor: "magenta" }),
      isRunning
        ? h(Box, { marginLeft: 2, gap: 1 },
            h(Text, { dimColor: true }, "Initializing"),
            h(Text, { dimColor: true }, h(Spinner, { type: "simpleDots" })),
          )
        : null,
    );
  }

  // Full card with progress
  return h(Box, { flexDirection: "column", marginBottom: 1 },
    header,
    h(Field, { label: "Model", value: shortModel(run.agent_type), valueColor: "magenta" }),
    h(Field, { label: "Cost", value: `$${progress.costUsd.toFixed(4)}`, valueColor: "green" }),
    h(Field, { label: "Turns", value: String(progress.turns) }),
    h(Box, { gap: 1 },
      h(Text, { dimColor: true }, `  ${"Tools".padEnd(10)}`),
      h(Text, null, String(progress.toolCalls)),
      progress.lastToolCall
        ? h(Text, { dimColor: true }, `(last: ${progress.lastToolCall})`)
        : null,
    ),
    h(ToolBreakdown, { progress }),
    h(Box, { gap: 1 },
      h(Text, { dimColor: true }, `  ${"Files".padEnd(10)}`),
      h(Text, { color: "yellow" }, String(progress.filesChanged.length)),
    ),
    progress.filesChanged.length > 0
      ? h(FilesChanged, { files: progress.filesChanged })
      : null,
    // Failed run: show log hint
    run.status === "failed"
      ? h(Text, { dimColor: true }, `  Logs      ~/.foreman/logs/${run.id}.log`)
      : null,
  );
}

/** Summary footer bar */
function SummaryBar({ totalCost, totalTools, totalFiles, runCount }: {
  totalCost: number;
  totalTools: number;
  totalFiles: number;
  runCount: number;
}): React.ReactElement {
  return h(Box, { gap: 2 },
    h(Text, { dimColor: true }, `${runCount} agents`),
    h(Text, null, `${totalTools} tool calls`),
    h(Text, { color: "yellow" }, `${totalFiles} files`),
    h(Text, { color: "green" }, `$${totalCost.toFixed(4)}`),
  );
}

/** Completion banner */
function DoneBanner({ completedCount, failedCount, stuckCount, totalTools, totalCost }: {
  completedCount: number;
  failedCount: number;
  stuckCount: number;
  totalTools: number;
  totalCost: number;
}): React.ReactElement {
  return h(Box, { flexDirection: "column", marginTop: 1 },
    h(Rule, null),
    h(Box, { gap: 1, marginTop: 0 },
      h(Text, { bold: true }, "Done:"),
      h(Text, { color: "green" }, `${completedCount} completed`),
      failedCount > 0 ? h(Text, { color: "red" }, `${failedCount} failed`) : null,
      stuckCount > 0 ? h(Text, { color: "yellow" }, `${stuckCount} rate-limited`) : null,
    ),
    h(Text, { dimColor: true },
      `  ${totalTools} tool calls, $${totalCost.toFixed(4)} total cost`,
    ),
    stuckCount > 0
      ? h(Text, { color: "yellow" },
          "  Run 'foreman run --resume' after rate limit resets to continue.",
        )
      : null,
  );
}

// ── Main App ─────────────────────────────────────────────────────────────

interface WatchAppProps {
  store: ForemanStore;
  runIds: string[];
}

interface WatchAppState {
  runs: Array<{ run: Run; progress: RunProgress | null }>;
  allDone: boolean;
  totalCost: number;
  totalTools: number;
  totalFiles: number;
  completedCount: number;
  failedCount: number;
  stuckCount: number;
}

function useWatchState(store: ForemanStore, runIds: string[]): WatchAppState {
  const [state, setState] = React.useState<WatchAppState>(() => poll(store, runIds));

  React.useEffect(() => {
    const interval = setInterval(() => {
      setState(poll(store, runIds));
    }, 3_000);
    return () => clearInterval(interval);
  }, [store, runIds]);

  return state;
}

function poll(store: ForemanStore, runIds: string[]): WatchAppState {
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

function WatchApp({ store, runIds }: WatchAppProps): React.ReactElement {
  const state = useWatchState(store, runIds);
  const { runs, allDone, totalCost, totalTools, totalFiles, completedCount, failedCount, stuckCount } = state;

  if (runs.length === 0) {
    return h(Text, { dimColor: true }, "No runs found.");
  }

  return h(Box, { flexDirection: "column" },
    // Header
    h(Box, { gap: 1 },
      h(Text, { bold: true }, "Foreman"),
      h(Text, { dimColor: true }, "— agent monitor"),
      !allDone
        ? h(Text, { dimColor: true }, "(Ctrl+C to detach)")
        : null,
    ),
    h(Rule, null),

    // Agent cards
    ...runs.map(({ run, progress }) =>
      h(AgentCard, { key: run.id, run, progress }),
    ),

    // Summary bar
    h(Rule, null),
    h(SummaryBar, { totalCost, totalTools, totalFiles, runCount: runs.length }),

    // Completion banner
    allDone
      ? h(DoneBanner, { completedCount, failedCount, stuckCount, totalTools, totalCost })
      : null,
  );
}

// ── Public API ────────────────────────────────────────────────────────────

export async function watchRunsInk(store: ForemanStore, runIds: string[]): Promise<void> {
  const { unmount } = render(
    h(WatchApp, { store, runIds }),
    { exitOnCtrlC: false },
  );

  let detached = false;
  const onSigint = () => {
    if (detached) return; // Prevent double-fire
    detached = true;
    unmount();
    console.log("\n  Detached — agents continue in background (detached workers).");
    console.log("  Check status:  foreman monitor");
    console.log("  Attach to run: foreman attach <run-id>\n");
  };
  process.on("SIGINT", onSigint);

  // Poll until done or user detaches with Ctrl+C
  const POLL_MS = 3_000;
  while (!detached) {
    const state = poll(store, runIds);
    if (state.runs.length === 0 || state.allDone) {
      // Give Ink one last render cycle
      await new Promise((resolve) => setTimeout(resolve, 500));
      unmount();
      break;
    }
    await new Promise((resolve) => setTimeout(resolve, POLL_MS));
  }

  process.removeListener("SIGINT", onSigint);
}
