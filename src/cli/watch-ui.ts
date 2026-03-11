import React from "react";
import { render, Box, Text, Newline } from "ink";
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
  if (m < 60) return `${m}m${s % 60}s`;
  return `${Math.floor(m / 60)}h${m % 60}m`;
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
  running: "",  // use spinner
  completed: "✓",
  failed: "✗",
  stuck: "⚠",
  merged: "⊕",
  conflict: "⊘",
  "test-failed": "⊘",
};

// ── Components ───────────────────────────────────────────────────────────

interface ProgressBarProps {
  progress: RunProgress | null;
}

function ProgressBar({ progress }: ProgressBarProps): React.ReactElement {
  if (!progress || progress.toolCalls === 0) {
    return h(Text, { dimColor: true }, "starting...");
  }

  const topTools = Object.entries(progress.toolBreakdown)
    .sort(([, a], [, b]) => b - a)
    .slice(0, 3)
    .map(([name, count]) => `${name}:${count}`)
    .join(" ");

  return h(Box, { gap: 1 },
    h(Text, null, `${progress.toolCalls} tools`),
    topTools ? h(Text, { dimColor: true }, `(${topTools})`) : null,
    progress.filesChanged.length > 0
      ? h(Text, { color: "yellow" }, `${progress.filesChanged.length} files`)
      : null,
    progress.costUsd > 0
      ? h(Text, { color: "green" }, `$${progress.costUsd.toFixed(3)}`)
      : null,
    progress.lastToolCall
      ? h(Text, { dimColor: true }, `→ ${progress.lastToolCall}`)
      : null,
  );
}

interface AgentRowProps {
  run: Run;
  progress: RunProgress | null;
}

function AgentRow({ run, progress }: AgentRowProps): React.ReactElement {
  const color = STATUS_COLORS[run.status] ?? "gray";
  const icon = STATUS_ICONS[run.status];
  const isRunning = run.status === "running";
  const time = isRunning || run.status === "pending"
    ? elapsed(run.started_at ?? run.created_at)
    : elapsed(run.started_at);

  const logHint = run.status === "failed"
    ? ` logs:~/.foreman/logs/${run.id}.log`
    : "";

  return h(Box, { flexDirection: "column", marginLeft: 1 },
    // Status line
    h(Box, { gap: 1 },
      isRunning
        ? h(Text, { color }, h(Spinner, { type: "dots" }))
        : h(Text, { color }, icon),
      h(Text, { color: "cyan" }, run.bead_id),
      h(Text, { dimColor: true }, `[${run.agent_type}]`),
      h(Text, { dimColor: true }, time),
      logHint ? h(Text, { dimColor: true }, logHint) : null,
    ),
    // Progress line (indented)
    (isRunning || run.status === "completed")
      ? h(Box, { marginLeft: 2 }, h(ProgressBar, { progress }))
      : null,
  );
}

interface WatchAppProps {
  store: ForemanStore;
  runIds: string[];
}

interface WatchAppState {
  runs: Array<{ run: Run; progress: RunProgress | null }>;
  allDone: boolean;
  totalCost: number;
  totalTools: number;
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
  let allDone = true;

  for (const id of runIds) {
    const run = store.getRun(id);
    if (!run) continue;
    const progress = store.getRunProgress(run.id);

    if (progress) {
      totalCost += progress.costUsd;
      totalTools += progress.toolCalls;
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

  return { runs: entries, allDone, totalCost, totalTools, completedCount, failedCount, stuckCount };
}

function WatchApp({ store, runIds }: WatchAppProps): React.ReactElement {
  const { runs, allDone, totalCost, totalTools, completedCount, failedCount, stuckCount } =
    useWatchState(store, runIds);

  if (runs.length === 0) {
    return h(Text, { dimColor: true }, "No runs found.");
  }

  return h(Box, { flexDirection: "column" },
    // Header
    h(Text, { bold: true }, "Agent status:"),
    h(Newline, null),

    // Agent rows
    ...runs.map(({ run, progress }) =>
      h(AgentRow, { key: run.id, run, progress }),
    ),

    // Summary
    h(Newline, null),
    h(Text, { dimColor: true },
      `  Total: ${totalTools} tool calls, $${totalCost.toFixed(3)}`,
    ),

    // Completion summary
    allDone
      ? h(Box, { flexDirection: "column", marginTop: 1 },
          h(Box, { gap: 1 },
            h(Text, { bold: true }, "Done:"),
            h(Text, { color: "green" }, `${completedCount} completed`),
            failedCount > 0 ? h(Text, { color: "red" }, `${failedCount} failed`) : null,
            stuckCount > 0 ? h(Text, { color: "yellow" }, `${stuckCount} rate-limited`) : null,
          ),
          h(Text, { dimColor: true },
            `  ${totalTools} tool calls, $${totalCost.toFixed(3)} total cost`,
          ),
          stuckCount > 0
            ? h(Text, { color: "yellow" },
                "\n  Run 'foreman run --resume' after rate limit resets to continue.",
              )
            : null,
        )
      : null,
  );
}

// ── Public API ────────────────────────────────────────────────────────────

export async function watchRunsInk(store: ForemanStore, runIds: string[]): Promise<void> {
  const { waitUntilExit, unmount } = render(
    h(WatchApp, { store, runIds }),
    { exitOnCtrlC: false },
  );

  const onSigint = () => {
    unmount();
    console.log("\n  Detached — agents continue in background.");
    console.log("  Check status: foreman monitor\n");
    process.exit(0);
  };
  process.on("SIGINT", onSigint);

  // Poll until done — Ink re-renders via React state, but we need to
  // know when all runs have completed to exit the process
  const POLL_MS = 3_000;
  while (true) {
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
