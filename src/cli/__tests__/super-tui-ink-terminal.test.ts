import { createElement } from "react";
import { describe, expect, it, vi } from "vitest";

import type { InboxTaskSummary } from "../commands/inbox.js";
import { SuperTuiApp, type SuperTuiAppProps, type SuperTuiResetTaskExecutor } from "../super-tui/App.js";
import { renderInkTerminal, type InkTerminalHarness } from "./helpers/ink-terminal.js";

function summary(overrides: Partial<InboxTaskSummary> = {}): InboxTaskSummary {
  const taskId = overrides.taskId ?? "task-retry";
  const runId = overrides.runId ?? "run-retry";
  const phase = overrides.phase ?? "repair";
  const runStatus = overrides.runStatus ?? "running";

  // Create a mock run object for tasks with runs (unless explicitly set to undefined for backlog)
  const hasExplicitRun = "run" in overrides;
  const mockRun = hasExplicitRun ? overrides.run : {
    id: runId,
    task_id: taskId,
    project_id: "project-1",
    status: runStatus as never,
    agent_type: phase,
    session_key: null,
    worktree_path: null,
    created_at: "2026-01-01T00:00:00.000Z",
    started_at: null,
    completed_at: null,
    progress: null,
  };

  return {
    taskId,
    runId,
    runStatus,
    phase,
    lastActivityAt: "2026-01-01T00:05:00.000Z",
    lastActivitySource: "event",
    statusText: `${phase} running`,
    attention: true,
    attentionReason: "operator action requested",
    verdict: "retrying",
    projectId: "project-1",
    worktreePath: null,
    messages: [],
    events: [],
    run: mockRun,
    ...overrides,
  };
}

type TestAppProps = Partial<Pick<SuperTuiAppProps, "resetTask" | "loadSummaries">>;
type TerminalOptions = { columns?: number; rows?: number };

async function renderSuperTuiTerminal(props: TestAppProps = {}, terminal: TerminalOptions = {}): Promise<InkTerminalHarness> {
  return renderInkTerminal(createElement(SuperTuiApp, {
    summaries: [summary()],
    projectLabel: "Fortium Foreman",
    limit: 10,
    eventsLimit: 10,
    initialView: "inbox",
    initialRunId: "run-retry",
    refreshIntervalMs: 60_000,
    ...props,
  }), { columns: terminal.columns ?? 160, rows: terminal.rows ?? 40 });
}

function renderedTerminalLines(output: string): string[] {
  const withoutFinalNewline = output.endsWith("\n") ? output.slice(0, -1) : output;
  return withoutFinalNewline.length === 0 ? [] : withoutFinalNewline.split("\n");
}

async function cueResetConfirmation(harness: InkTerminalHarness): Promise<string> {
  await harness.send("a");
  await harness.waitForOutput("Command palette");

  for (let index = 0; index < 7; index += 1) {
    await harness.send("j");
  }
  await harness.waitForOutput("› x Reset task");

  await harness.sendKey("enter");
  return harness.waitForOutput("Confirm Reset task: press y to run, Esc/n to cancel.");
}

describe("super TUI Ink terminal input", () => {
  it("reserves the full Ink stdout height on tall terminals", async () => {
    const rows = 32;
    const harness = await renderSuperTuiTerminal({}, { columns: 160, rows });

    try {
      const lines = renderedTerminalLines(harness.plainOutput());

      expect(lines).toHaveLength(rows);
      expect(lines.join("\n")).toContain("FOREMAN WATCH");
      expect(lines.join("\n")).toContain("q/Esc quit");
    } finally {
      await harness.cleanup();
    }
  });

  it.each(["a", ":"] as const)("opens the action palette from real Ink input %s", async (opener) => {
    const harness = await renderSuperTuiTerminal();

    try {
      await harness.send(opener);
      const output = await harness.waitForOutput("Command palette");

      expect(output).toContain("Enter shows copy/manual commands. Reset runs only after explicit y confirmation.");
      expect(output).toContain("Reset task");
    } finally {
      await harness.cleanup();
    }
  });

  it("cues reset confirmation on Enter and executes only after y, then reloads summaries", async () => {
    const refreshed = [summary({
      taskId: "task-after-reset",
      runId: "run-after-reset",
      runStatus: "ready",
      phase: "triage",
      statusText: "ready after reset",
      attention: false,
      attentionReason: null,
      verdict: "unknown",
    })];
    const resetTask = vi.fn(async (_args: Parameters<SuperTuiResetTaskExecutor>[0]) => ({ code: 0, output: "reset ok" }));
    const loadSummaries = vi.fn(async () => refreshed);
    const harness = await renderSuperTuiTerminal({ resetTask, loadSummaries });

    try {
      const confirmationOutput = await cueResetConfirmation(harness);

      expect(confirmationOutput).toContain("Confirm Reset task: press y to run, Esc/n to cancel.");
      expect(resetTask).not.toHaveBeenCalled();
      expect(loadSummaries).not.toHaveBeenCalled();

      await harness.send("y");
      const output = await harness.waitForOutput("reset complete: task-retry");

      expect(resetTask).toHaveBeenCalledOnce();
      expect(resetTask).toHaveBeenCalledWith({
        taskId: "task-retry",
        projectId: "project-1",
        projectLabel: "Fortium Foreman",
        reason: "reset from Foreman TUI",
      });
      expect(loadSummaries).toHaveBeenCalledOnce();
      expect(output).toContain("task-after-reset");
      expect(output).toContain("ready after reset");
    } finally {
      await harness.cleanup();
    }
  });

  it.each([
    { name: "Esc", cancel: async (harness: InkTerminalHarness) => harness.sendKey("escape") },
    { name: "n", cancel: async (harness: InkTerminalHarness) => harness.send("n") },
  ])("cancels reset confirmation with $name without executing or reloading", async ({ cancel }) => {
    const resetTask = vi.fn(async (_args: Parameters<SuperTuiResetTaskExecutor>[0]) => ({ code: 0, output: "should not run" }));
    const loadSummaries = vi.fn(async () => [summary({ taskId: "unexpected-refresh", runId: "unexpected-run" })]);
    const harness = await renderSuperTuiTerminal({ resetTask, loadSummaries });

    try {
      await cueResetConfirmation(harness);
      harness.clearOutput();

      await cancel(harness);
      const output = await harness.waitForOutput("cancelled: Reset task");

      expect(output).toContain("cancelled: Reset task");
      expect(resetTask).not.toHaveBeenCalled();
      expect(loadSummaries).not.toHaveBeenCalled();
    } finally {
      await harness.cleanup();
    }
  });
});
