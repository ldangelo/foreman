import { createElement } from "react";
import { renderToString } from "ink";
import { describe, expect, it, vi } from "vitest";

import type { Message } from "../../lib/store.js";
import type { InboxTaskSummary } from "../commands/inbox.js";
import { handleSuperTuiResetConfirmation, SuperTuiApp, type SuperTuiResetTaskExecutor } from "../super-tui/App.js";
import { buildCurrentPaletteActions, createSuperTuiState, reduceSuperTuiState } from "../super-tui/model.js";

function message(overrides: Partial<Message> = {}): Message {
  return {
    id: "msg-alpha",
    run_id: "run-alpha",
    sender_agent_type: "developer",
    recipient_agent_type: "foreman",
    subject: "implementation note",
    body: JSON.stringify({ message: "implementation ready", phase: "developer" }),
    read: 0,
    created_at: "2026-01-01T00:01:00.000Z",
    deleted_at: null,
    ...overrides,
  };
}

type SummaryEvent = InboxTaskSummary["events"][number];

function event(overrides: Partial<SummaryEvent> & { details?: Record<string, unknown> } = {}): SummaryEvent {
  return {
    id: "evt-alpha",
    runId: "run-alpha",
    taskId: "task-alpha",
    eventType: "PhaseStarted",
    details: { phase_id: "developer" },
    createdAt: "2026-01-01T00:00:00.000Z",
    ...overrides,
  } as SummaryEvent;
}

function summary(overrides: Partial<InboxTaskSummary> = {}): InboxTaskSummary {
  const taskId = overrides.taskId ?? "task-alpha";
  const runId = overrides.runId ?? "run-alpha";
  const phase = overrides.phase ?? "developer";
  const runStatus = overrides.runStatus ?? "running";

  // Create a mock run object for tasks with runs (unless explicitly set to undefined for backlog)
  // Check if 'run' is explicitly in overrides to preserve undefined for backlog tasks
  const hasExplicitRun = "run" in overrides;
  const mockRun = hasExplicitRun ? overrides.run : {
    id: runId,
    task_id: taskId,
    project_id: "project-1",
    status: runStatus as never,
    agent_type: phase,
    session_key: null,
    worktree_path: `/tmp/foreman/${taskId}`,
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
    attention: false,
    attentionReason: null,
    verdict: "unknown",
    projectId: "project-1",
    worktreePath: `/tmp/foreman/${taskId}`,
    messages: [],
    events: [],
    run: mockRun,
    ...overrides,
  };
}

function retriedWorkflowSummary(): InboxTaskSummary {
  return summary({
    taskId: "task-retry",
    runId: "run-retry",
    runStatus: "running",
    phase: "repair",
    statusText: "repair running after QA failure",
    attention: true,
    attentionReason: "QA rejected the fix",
    verdict: "retrying",
    lastActivityAt: "2026-01-01T00:04:00.000Z",
    messages: [
      message({
        id: "msg-retry",
        run_id: "run-retry",
        sender_agent_type: "qa",
        recipient_agent_type: "foreman",
        subject: "operator review needed",
        body: JSON.stringify({ message: "QA asked for repair", phase: "qa", verdict: "fail" }),
        created_at: "2026-01-01T00:05:00.000Z",
      }),
    ],
    events: [
      event({
        id: "evt-developer-completed",
        runId: "run-retry",
        taskId: "task-retry",
        eventType: "PhaseCompleted",
        details: { phase: "developer", verdict: "pass", task_id: "task-retry" },
        createdAt: "2026-01-01T00:01:00.000Z",
      }),
      event({
        id: "evt-qa-failed",
        runId: "run-retry",
        taskId: "task-retry",
        eventType: "PhaseFailed",
        details: {
          phase: "qa",
          error: "QA rejected the fix",
          artifactPath: "reports/qa-failure.md",
          verdict: "fail",
          task_id: "task-retry",
        },
        createdAt: "2026-01-01T00:02:00.000Z",
      }),
      event({
        id: "evt-qa-retried",
        runId: "run-retry",
        taskId: "task-retry",
        eventType: "PhaseRetried",
        details: {
          phase: "qa",
          retryTarget: "repair",
          attempt: 2,
          maxRetries: 3,
          reason: "Send back to repair",
          task_id: "task-retry",
        },
        createdAt: "2026-01-01T00:03:00.000Z",
      }),
      event({
        id: "evt-repair-started",
        runId: "run-retry",
        taskId: "task-retry",
        eventType: "PhaseStarted",
        details: { phase: "repair", attempt: 2, maxRetries: 3, task_id: "task-retry" },
        createdAt: "2026-01-01T00:04:00.000Z",
      }),
    ],
  });
}

function cockpitRows(): InboxTaskSummary[] {
  return [
    summary({
      taskId: "task-active",
      runId: "run-active",
      runStatus: "developer",
      phase: "developer",
      statusText: "developer is implementing",
      messages: [message({ id: "msg-active", run_id: "run-active" })],
    }),
    retriedWorkflowSummary(),
    summary({
      taskId: "task-ready",
      runId: "run-ready",
      runStatus: "ready",
      phase: "triage",
      statusText: "ready for dispatch",
      lastActivityAt: "2026-01-01T00:06:00.000Z",
      messages: [
        message({
          id: "msg-ready",
          run_id: "run-ready",
          sender_agent_type: "foreman",
          recipient_agent_type: "developer",
          subject: "ready card",
          body: JSON.stringify({ message: "Ready task selected for board context", phase: "triage" }),
          created_at: "2026-01-01T00:06:00.000Z",
        }),
      ],
      events: [
        event({
          id: "evt-ready-pr",
          runId: "run-ready",
          taskId: "task-ready",
          eventType: "TaskUpdated",
          details: { task_id: "task-ready", status: "ready", pr_url: "https://example.test/pr/42" },
          createdAt: "2026-01-01T00:06:00.000Z",
        }),
      ],
    }),
    summary({
      taskId: "task-closed",
      runId: "run-closed",
      runStatus: "completed",
      phase: "finalize",
      verdict: "pass",
      statusText: "completed successfully",
      lastActivityAt: "2026-01-01T00:03:00.000Z",
    }),
  ];
}

function renderCockpit(initialView: "inbox" | "status" | "board", initialRunId: string): string {
  return renderToString(createElement(SuperTuiApp, {
    summaries: cockpitRows(),
    projectLabel: "Fortium Foreman",
    limit: 10,
    eventsLimit: 10,
    initialView,
    initialRunId,
  }), { columns: 160 });
}

describe("super TUI render contracts", () => {
  it("renders the watch cockpit chrome, task selector, inbox timeline, detail pane, and footer shortcuts", () => {
    const output = renderCockpit("inbox", "run-retry");

    expect(output).toContain("FOREMAN WATCH");
    expect(output).toContain("cockpit project=Fortium Foreman");
    expect(output).toContain("selected=task-retry / run-retry");
    expect(output).toContain("view=Inbox");
    expect(output).toContain("Tasks");
    expect(output).toContain("Inbox timeline");
    expect(output).toContain("Details · task-retry");
    expect(output).toContain("Run: run-retry");
    expect(output).toContain("QA asked for repair");
    expect(output).toContain("Failed qa");
    expect(output).toContain("j/k select");
    expect(output).toContain("i inbox");
    expect(output).toContain("s status");
    expect(output).toContain("b board");
    expect(output).toContain("a/: actions");
    expect(output).toContain("q/Esc quit");
  });

  it("renders a failed-and-retried status workflow with retry path, failure, artifacts, and active phase", () => {
    const output = renderCockpit("status", "run-retry");

    expect(output).toContain("view=Status");
    expect(output).toContain("Status workflow");
    expect(output).toContain("task-retry run=run-retry status=running current=repair verdict=retrying");
    expect(output).toContain("✓ developer completed verdict=pass");
    expect(output).toContain("↻ qa retried attempt=2/3 verdict=retrying");
    expect(output).toContain("▶ repair running attempt=2/3");
    expect(output).toContain("Retry path");
    expect(output).toContain("↻ qa → repair attempt=2/3");
    expect(output).toContain("Failure: QA rejected the fix");
    expect(output).toContain("Active: repair");
    expect(output).toContain("Artifacts: reports/qa-failure.md");
    expect(output).toContain("Details · task-retry");
  });

  it("renders the board view and selected task board context without leaving the cockpit shell", () => {
    const output = renderCockpit("board", "run-ready");

    expect(output).toContain("FOREMAN WATCH");
    expect(output).toContain("selected=task-ready / run-ready");
    expect(output).toContain("view=Board");
    expect(output).toContain("Board");
    expect(output).toContain("Ready (1)");
    expect(output).toContain("task-ready triage");
    expect(output).toContain("Selected board context: task-ready is in ready.");
    expect(output).toContain("Details · task-ready");
    expect(output).toContain("Run: run-ready");
  });

  it("places backlog tasks (without runs) in the Backlog column and cooldown runs in In Progress", () => {
    // Create summaries with various run statuses
    const backlogTask = summary({
      taskId: "task-backlog",
      runId: "run-backlog",
      runStatus: "unknown", // No run = backlog
      phase: "triage",
      run: undefined, // Explicitly no run
    });
    const cooldownTask = summary({
      taskId: "task-cooldown",
      runId: "run-cooldown",
      runStatus: "cooldown",
      phase: "finalize",
      run: { id: "run-cooldown", task_id: "task-cooldown", project_id: "project-1", status: "cooldown", agent_type: "developer", session_key: null, worktree_path: null, created_at: "2026-01-01T00:00:00.000Z", started_at: null, completed_at: null, progress: null } as never,
    });
    const readyTask = summary({
      taskId: "task-pending",
      runId: "run-pending",
      runStatus: "pending",
      phase: "triage",
      run: { id: "run-pending", task_id: "task-pending", project_id: "project-1", status: "pending", agent_type: "developer", session_key: null, worktree_path: null, created_at: "2026-01-01T00:00:00.000Z", started_at: null, completed_at: null, progress: null } as never,
    });

    const output = renderToString(createElement(SuperTuiApp, {
      summaries: [backlogTask, cooldownTask, readyTask],
      projectLabel: "Fortium Foreman",
      limit: 10,
      eventsLimit: 10,
      initialView: "board",
      initialRunId: "run-backlog",
    }), { columns: 160 });

    // Backlog task should appear in Backlog column
    expect(output).toContain("Backlog (1)");
    expect(output).toContain("task-backlog");
    expect(output).toContain("Selected board context: task-backlog is in backlog.");

    // Cooldown task should appear in In Progress column
    expect(output).toContain("In Progress (1)");
    expect(output).toContain("task-cooldown");

    // Pending task should appear in Ready column
    expect(output).toContain("Ready (1)");
    expect(output).toContain("task-pending");
  });

  it("marks reset as a confirmed destructive executable and Enter cues confirmation before execution", () => {
    const state = createSuperTuiState({ summaries: cockpitRows(), initialView: "inbox", initialRunId: "run-retry" });
    const actions = buildCurrentPaletteActions(state, "Fortium Foreman");
    const retryAction = actions.find((action) => action.id === "retry-task");
    const resetAction = actions.find((action) => action.id === "reset-task");

    expect(actions.length).toBeGreaterThan(0);
    expect(actions.every((action) => typeof action.command === "string" && action.command.length > 0)).toBe(true);
    expect(actions.every((action) => Object.values(action).every((value) => typeof value !== "function"))).toBe(true);
    expect(retryAction).toMatchObject({
      label: expect.stringMatching(/manual/i),
      command: "foreman retry task-retry --project 'Fortium Foreman'",
      safety: "manual-command",
      destructive: true,
    });
    expect(resetAction).toMatchObject({
      label: "Reset task",
      command: "foreman reset task-retry --project 'Fortium Foreman'",
      safety: "confirmed-execution",
      destructive: true,
      execution: "reset-task",
    });
    for (const action of actions.filter((item) => item.id !== "reset-task")) {
      expect(action.safety === "copy" || action.safety === "manual-command").toBe(true);
      expect(action.execution).toBeUndefined();
    }

    const paletteOpen = reduceSuperTuiState(state, { type: "open-palette" });
    const afterEnter = reduceSuperTuiState(paletteOpen, { type: "show-palette-action", action: resetAction });

    expect(afterEnter.paletteOpen).toBe(true);
    expect(afterEnter.focus).toBe("palette");
    expect(afterEnter.confirmationAction).toBe(resetAction);
    expect(afterEnter.actionNotice).toBe("Confirm Reset task: press y to execute, or Esc/n to cancel. foreman reset task-retry --project 'Fortium Foreman'");
  });

  it("confirmed reset invokes the injected executor with selected task and project, reports success, and refreshes summaries", async () => {
    const selected = retriedWorkflowSummary();
    const refreshed = [summary({ taskId: "task-after-reset", runId: "run-after-reset", runStatus: "ready", phase: "triage" })];
    const resetTask = vi.fn(async (_args: Parameters<SuperTuiResetTaskExecutor>[0]) => ({ code: 0, output: "reset ok" }));
    const loadSummaries = vi.fn(async () => refreshed);

    const result = await handleSuperTuiResetConfirmation({
      decision: "confirm",
      selected,
      projectLabel: "Fortium Foreman",
      resetTask,
      loadSummaries,
    });

    expect(resetTask).toHaveBeenCalledOnce();
    expect(resetTask).toHaveBeenCalledWith({
      taskId: "task-retry",
      projectId: "project-1",
      projectLabel: "Fortium Foreman",
      reason: "reset from Foreman TUI",
    });
    expect(loadSummaries).toHaveBeenCalledOnce();
    expect(result).toEqual({
      status: "executed",
      notice: "reset complete: task-retry",
      summaries: refreshed,
    });
  });

  it("cancelling reset confirmation leaves the executor and summary loader untouched", async () => {
    const selected = retriedWorkflowSummary();
    const resetTask = vi.fn(async (_args: Parameters<SuperTuiResetTaskExecutor>[0]) => ({ code: 0, output: "should not run" }));
    const loadSummaries = vi.fn(async () => cockpitRows());

    const result = await handleSuperTuiResetConfirmation({
      decision: "cancel",
      selected,
      projectLabel: "Fortium Foreman",
      resetTask,
      loadSummaries,
    });

    expect(result).toEqual({ status: "cancelled", notice: "reset cancelled" });
    expect(resetTask).not.toHaveBeenCalled();
    expect(loadSummaries).not.toHaveBeenCalled();
  });
});
