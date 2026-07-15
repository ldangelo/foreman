import { describe, expect, it, vi } from "vitest";

import type { InboxTaskSummary } from "../commands/inbox.js";
import { actionNotice, buildSuperTuiPaletteActions } from "../super-tui/actions.js";
import { loadInitialSuperTuiSummaries } from "../super-tui/data.js";
import { buildCurrentPaletteActions, createSuperTuiState, filterSuperTuiSummaries, reduceSuperTuiState, selectedIndexForSelection, selectedVisibleIndexForState, type SuperTuiFilter } from "../super-tui/model.js";

function event(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: "evt-alpha",
    runId: "run-alpha",
    taskId: "task-alpha",
    eventType: "PhaseStarted",
    details: { phase_id: "developer" },
    createdAt: "2026-01-01T00:00:00.000Z",
    ...overrides,
  };
}

function message(overrides: Record<string, unknown> = {}): InboxTaskSummary["messages"][number] {
  return {
    id: "msg-alpha",
    run_id: "run-alpha",
    sender_agent_type: "developer",
    recipient_agent_type: "qa",
    subject: "Review requested",
    body: "Please review the latest changes.",
    read: 0,
    created_at: "2026-01-01T00:01:00.000Z",
    deleted_at: null,
    ...overrides,
  } as InboxTaskSummary["messages"][number];
}

function summary(overrides: Partial<InboxTaskSummary> = {}): InboxTaskSummary {
  const taskId = overrides.taskId ?? "task-alpha";
  const runId = overrides.runId ?? "run-alpha";
  const phase = overrides.phase ?? "developer";
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
    lastActivityAt: "2026-01-01T00:02:00.000Z",
    lastActivitySource: "event",
    statusText: `${phase} running`,
    attention: false,
    attentionReason: null,
    verdict: "unknown",
    projectId: "project-1",
    worktreePath: `/tmp/foreman/${taskId}`,
    messages: [],
    events: [event({ id: `evt-${runId}`, runId, taskId, details: { phase_id: phase } }) as never],
    run: mockRun,
    ...overrides,
  };
}

const alpha = summary({ taskId: "task-alpha", runId: "run-alpha", phase: "developer" });
const beta = summary({ taskId: "task-beta", runId: "run-beta", phase: "qa", attention: true, attentionReason: "qa failed", verdict: "fail" });
const gamma = summary({ taskId: "task-gamma", runId: "run-gamma", phase: "reviewer" });

const rows = [
  alpha,
  beta,
  gamma,
];

describe("super TUI model selection contracts", () => {
  it("switches between inbox, status, and board without losing the selected task and run", () => {
    const initial = createSuperTuiState({ summaries: rows, initialView: "inbox", initialRunId: "run-beta" });

    expect(initial.selectedIndex).toBe(1);
    expect(initial.selection).toMatchObject({ taskId: "task-beta", runId: "run-beta", projectId: "project-1", view: "inbox" });

    const status = reduceSuperTuiState(initial, { type: "set-view", view: "status" });
    expect(status.view).toBe("status");
    expect(status.selectedIndex).toBe(1);
    expect(status.selection).toMatchObject({ taskId: "task-beta", runId: "run-beta", projectId: "project-1", view: "status" });

    const board = reduceSuperTuiState(status, { type: "set-view", view: "board" });
    expect(board.view).toBe("board");
    expect(board.selectedIndex).toBe(1);
    expect(board.selection).toMatchObject({ taskId: "task-beta", runId: "run-beta", projectId: "project-1", view: "board" });
  });

  it("pins refreshed selection by run id even when rows reorder", () => {
    const state = createSuperTuiState({ summaries: rows, initialView: "status", initialRunId: "run-beta" });
    const reordered = [gamma, alpha, beta];

    expect(selectedIndexForSelection(reordered, state.selection, state.selectedIndex)).toBe(2);

    const refreshed = reduceSuperTuiState(state, { type: "refresh", summaries: reordered });
    expect(refreshed.selectedIndex).toBe(2);
    expect(refreshed.selection).toMatchObject({ taskId: "task-beta", runId: "run-beta", view: "status" });
  });

  it("falls back to the same task when the selected run disappears on refresh", () => {
    const state = createSuperTuiState({ summaries: rows, initialView: "inbox", initialRunId: "run-beta" });
    const refreshedRows = [
      summary({ taskId: "task-delta", runId: "run-delta", phase: "developer" }),
      summary({ taskId: "task-beta", runId: "run-beta-retry", phase: "repair", verdict: "retrying" }),
      summary({ taskId: "task-epsilon", runId: "run-epsilon", phase: "qa" }),
    ];

    expect(selectedIndexForSelection(refreshedRows, state.selection, state.selectedIndex)).toBe(1);

    const refreshed = reduceSuperTuiState(state, { type: "refresh", summaries: refreshedRows });
    expect(refreshed.selectedIndex).toBe(1);
    expect(refreshed.selection).toMatchObject({ taskId: "task-beta", runId: "run-beta-retry", view: "inbox" });
  });

  it("uses the nearest surviving row when both selected run and task disappear", () => {
    const state = createSuperTuiState({ summaries: rows, initialView: "board", initialRunId: "run-gamma" });
    const refreshedRows = [
      summary({ taskId: "task-delta", runId: "run-delta", phase: "developer" }),
      summary({ taskId: "task-epsilon", runId: "run-epsilon", phase: "qa" }),
    ];

    expect(state.selectedIndex).toBe(2);
    expect(selectedIndexForSelection(refreshedRows, state.selection, state.selectedIndex)).toBe(1);

    const refreshed = reduceSuperTuiState(state, { type: "refresh", summaries: refreshedRows });
    expect(refreshed.selectedIndex).toBe(1);
    expect(refreshed.selection).toMatchObject({ taskId: "task-epsilon", runId: "run-epsilon", view: "board" });
  });
});

describe("super TUI search and filter contracts", () => {
  it.each([
    { name: "task id", query: "task-searchable" },
    { name: "run id", query: "run-special-123" },
    { name: "phase", query: "deploy" },
    { name: "status text", query: "integration status" },
    { name: "message subject", query: "credential rotation" },
    { name: "message body", query: "spline-token" },
    { name: "event label", query: "qa report label" },
    { name: "event details", query: "flaky checkout" },
    { name: "report filename", query: "regression-summary.md" },
  ])("matches $name in the task summary search index", ({ query }) => {
    const searchable = summary({
      taskId: "task-searchable",
      runId: "run-special-123",
      phase: "deploy",
      statusText: "waiting on integration status",
      messages: [
        message({
          id: "msg-searchable",
          run_id: "run-special-123",
          subject: "Credential rotation required",
          body: "The handoff body contains spline-token for the operator.",
        }),
      ],
      events: [
        event({
          id: "evt-searchable",
          runId: "run-special-123",
          taskId: "task-searchable",
          eventType: "PhaseReportProduced",
          details: {
            label: "QA Report Label",
            detail: "event detail mentions flaky checkout reproduction",
            reportPath: "/tmp/foreman/reports/regression-summary.md",
          },
        }) as never,
      ],
    });
    const control = summary({
      taskId: "task-control",
      runId: "run-control",
      phase: "developer",
      statusText: "quiet",
      messages: [message({ id: "msg-control", run_id: "run-control", subject: "Unrelated", body: "No matching terms." })],
      events: [event({ id: "evt-control", runId: "run-control", taskId: "task-control", details: { label: "Unrelated" } }) as never],
    });

    expect(filterSuperTuiSummaries([control, searchable], { query }).map((item) => item.taskId)).toEqual(["task-searchable"]);
  });

  it("applies individual filters over active, attention, failed, stale, PR, dirty worktree, current project, and global rows", () => {
    const now = Date.parse("2026-01-01T01:00:00.000Z");
    const recent = "2026-01-01T00:55:00.000Z";
    const filterRows = [
      summary({ taskId: "task-active", runId: "run-active", runStatus: "running", verdict: "unknown", projectId: "project-1", lastActivityAt: recent }),
      summary({ taskId: "task-attention-failed", runId: "run-attention-failed", runStatus: "failed", verdict: "fail", attention: true, attentionReason: "qa failed", projectId: "project-1", lastActivityAt: recent }),
      summary({ taskId: "task-stale", runId: "run-stale", runStatus: "completed", verdict: "pass", projectId: "project-1", lastActivityAt: "2026-01-01T00:10:00.000Z" }),
      summary({
        taskId: "task-pr",
        runId: "run-pr",
        runStatus: "pr-created",
        verdict: "pass",
        projectId: "project-1",
        lastActivityAt: recent,
        events: [event({ id: "evt-pr", runId: "run-pr", taskId: "task-pr", details: { prUrl: "https://github.com/Fortium/foreman/pull/42" } }) as never],
      }),
      summary({ taskId: "task-dirty", runId: "run-dirty", runStatus: "completed", verdict: "unknown", projectId: "project-1", lastActivityAt: recent, statusText: "worktree has modified changed files" }),
      summary({ taskId: "task-global-active", runId: "run-global-active", runStatus: "running", verdict: "unknown", projectId: "project-2", lastActivityAt: recent }),
    ];

    const idsFor = (filters: SuperTuiFilter[]): string[] =>
      filterSuperTuiSummaries(filterRows, { filters, currentProjectId: "project-1", now }).map((item) => item.taskId);

    expect(idsFor(["active"])).toEqual(["task-active", "task-global-active"]);
    expect(idsFor(["attention"])).toEqual(["task-attention-failed"]);
    expect(idsFor(["failed"])).toEqual(["task-attention-failed"]);
    expect(idsFor(["stale"])).toEqual(["task-stale"]);
    expect(idsFor(["has-pr"])).toEqual(["task-pr"]);
    expect(idsFor(["dirty-worktree"])).toEqual(["task-dirty"]);
    expect(idsFor(["current-project"])).toEqual(["task-active", "task-attention-failed", "task-stale", "task-pr", "task-dirty"]);
    expect(idsFor(["global"])).toEqual(["task-global-active"]);
  });

  it("ANDs filter combinations so narrowed operator scopes do not include unrelated rows", () => {
    const now = Date.parse("2026-01-01T01:00:00.000Z");
    const recent = "2026-01-01T00:55:00.000Z";
    const filterRows = [
      summary({ taskId: "task-active-current", runId: "run-active-current", runStatus: "running", projectId: "project-1", lastActivityAt: recent }),
      summary({ taskId: "task-active-global", runId: "run-active-global", runStatus: "running", projectId: "project-2", lastActivityAt: recent }),
      summary({ taskId: "task-attention-failed", runId: "run-attention-failed", runStatus: "failed", verdict: "fail", attention: true, projectId: "project-1", lastActivityAt: recent }),
      summary({ taskId: "task-attention-pass", runId: "run-attention-pass", runStatus: "completed", verdict: "pass", attention: true, projectId: "project-1", lastActivityAt: recent }),
    ];

    expect(filterSuperTuiSummaries(filterRows, { filters: ["active", "current-project"], currentProjectId: "project-1", now }).map((item) => item.taskId)).toEqual(["task-active-current"]);
    expect(filterSuperTuiSummaries(filterRows, { filters: ["attention", "failed"], currentProjectId: "project-1", now }).map((item) => item.taskId)).toEqual(["task-attention-failed"]);
  });

  it("keeps a valid visible selection when search or filters hide the selected run", () => {
    const visibleAlpha = summary({ taskId: "task-visible-alpha", runId: "run-visible-alpha", statusText: "visible-match alpha" });
    const hiddenBeta = summary({ taskId: "task-hidden-beta", runId: "run-hidden-beta", statusText: "hidden beta" });
    const visibleGamma = summary({ taskId: "task-visible-gamma", runId: "run-visible-gamma", statusText: "visible-match gamma" });
    const state = createSuperTuiState({ summaries: [visibleAlpha, hiddenBeta, visibleGamma], initialRunId: "run-hidden-beta" });
    const visible = filterSuperTuiSummaries(state.summaries, { query: "visible-match" });

    expect(visible.map((item) => item.taskId)).toEqual(["task-visible-alpha", "task-visible-gamma"]);
    expect(selectedVisibleIndexForState(state, visible)).toBe(1);
    expect(selectedIndexForSelection(visible, state.selection, state.selectedIndex)).toBe(1);
    expect(visible[selectedVisibleIndexForState(state, visible)]?.taskId).toBe("task-visible-gamma");

    const activeAlpha = summary({ taskId: "task-active-alpha", runId: "run-active-alpha", runStatus: "running", statusText: "active alpha" });
    const completedBeta = summary({ taskId: "task-completed-beta", runId: "run-completed-beta", runStatus: "completed", statusText: "completed hidden" });
    const activeGamma = summary({ taskId: "task-active-gamma", runId: "run-active-gamma", runStatus: "running", statusText: "active gamma" });
    const filteredState = createSuperTuiState({ summaries: [activeAlpha, completedBeta, activeGamma], initialRunId: "run-completed-beta" });
    const filteredVisible = filterSuperTuiSummaries(filteredState.summaries, { filters: ["active"] });

    expect(filteredVisible.map((item) => item.taskId)).toEqual(["task-active-alpha", "task-active-gamma"]);
    expect(selectedVisibleIndexForState(filteredState, filteredVisible)).toBe(1);
    expect(filteredVisible[selectedVisibleIndexForState(filteredState, filteredVisible)]?.taskId).toBe("task-active-gamma");
  });

  it("appends, backspaces, and closes search without discarding the current query", () => {
    const initial = createSuperTuiState({ summaries: rows });
    const withQa = reduceSuperTuiState(reduceSuperTuiState(initial, { type: "append-search", input: "q" }), { type: "append-search", input: "a" });

    expect(withQa.searchQuery).toBe("qa");
    expect(withQa.focus).toBe("search");

    const afterBackspace = reduceSuperTuiState(withQa, { type: "backspace-search" });
    expect(afterBackspace.searchQuery).toBe("q");
    expect(afterBackspace.focus).toBe("search");

    const closed = reduceSuperTuiState(afterBackspace, { type: "close-search" });
    expect(closed.searchQuery).toBe("q");
    expect(closed.focus).toBe("tasks");
  });
});

describe("super TUI palette safety contracts", () => {
  it("builds only copy, manual, or confirmed command text for the current selection", () => {
    const state = createSuperTuiState({ summaries: rows, initialView: "inbox", initialRunId: "run-beta" });
    const actions = buildCurrentPaletteActions(state, "Fortium Foreman");

    expect(actions.length).toBeGreaterThan(0);
    expect(actions.every((action) => action.safety === "copy" || action.safety === "manual-command" || action.safety === "confirmed-execution")).toBe(true);
    expect(actions.every((action) => typeof action.command === "string" && action.command.length > 0)).toBe(true);
    expect(actions.map((action) => action.command).join("\n")).toContain("task-beta");
    expect(actions.map((action) => action.command).join("\n")).toContain("run-beta");
    expect(actions.map((action) => action.command).join("\n")).not.toContain("task-alpha");

    for (const action of actions) {
      expect(Object.values(action as unknown as Record<string, unknown>).some((value) => typeof value === "function")).toBe(false);
    }
  });

  it("labels retry as manual and reset as confirmed destructive execution without function callbacks", () => {
    const actions = buildSuperTuiPaletteActions(summary({ taskId: "task-danger", runId: "run-danger" }), "Fortium Foreman");
    const retry = actions.find((action) => action.id === "retry-task");
    const reset = actions.find((action) => action.id === "reset-task");

    expect(retry).toMatchObject({
      label: expect.stringMatching(/manual/i),
      command: "foreman retry task-danger --project 'Fortium Foreman'",
      safety: "manual-command",
      destructive: true,
    });
    expect(reset).toMatchObject({
      label: "Reset task",
      command: "foreman reset task-danger --project 'Fortium Foreman'",
      safety: "confirmed-execution",
      destructive: true,
      execution: "reset-task",
    });

    if (!retry || !reset) throw new Error("expected retry and reset actions");

    expect(Object.values(retry as unknown as Record<string, unknown>).some((value) => typeof value === "function")).toBe(false);
    expect(actionNotice(retry)).toContain("manual command; destructive if executed externally");
    expect(Object.values(reset as unknown as Record<string, unknown>).some((value) => typeof value === "function")).toBe(false);
    expect(actionNotice(reset)).toBe("confirm to execute: foreman reset task-danger --project 'Fortium Foreman'");
  });

  it("reports copy actions as copy text instead of manual or destructive commands", () => {
    const actions = buildSuperTuiPaletteActions(summary({ taskId: "task-copy", runId: "run-copy" }), "project-1");
    const copyRun = actions.find((action) => action.id === "copy-run-id");

    expect(copyRun).toMatchObject({ command: "run-copy", safety: "copy", destructive: false });
    expect(actionNotice(copyRun)).toBe("copy text: run-copy");
  });

  it("keeps non-reset actions text-only and marks reset as the only confirmed executable action", () => {
    const actions = buildSuperTuiPaletteActions(summary({
      taskId: "task with space",
      runId: "run-with-space",
      worktreePath: "/tmp/Fortium Worktree",
      events: [
        event({
          id: "evt-pr-action",
          runId: "run-with-space",
          taskId: "task with space",
          details: { pr_url: "https://github.com/Fortium/foreman/pull/42" },
        }) as never,
      ],
    }), "Fortium Foreman");

    for (const action of actions) {
      expect(Object.values(action as unknown as Record<string, unknown>).some((value) => typeof value === "function")).toBe(false);
    }

    for (const id of ["logs", "open-pr", "open-worktree"] as const) {
      const action = actions.find((item) => item.id === id);
      if (!action) throw new Error(`expected ${id} action`);
      expect(action.label).toMatch(/^Manual:/);
      expect(action.safety).toBe("manual-command");
      expect(action.destructive).toBe(false);
      expect(actionNotice(action)).toMatch(/^manual command: /);
    }

    const retry = actions.find((item) => item.id === "retry-task");
    if (!retry) throw new Error("expected retry-task action");
    expect(retry.label).toMatch(/^Manual:/);
    expect(retry.safety).toBe("manual-command");
    expect(retry.destructive).toBe(true);
    expect(actionNotice(retry)).toMatch(/^manual command; destructive if executed externally: /);

    const reset = actions.find((item) => item.id === "reset-task");
    if (!reset) throw new Error("expected reset-task action");
    expect(reset.label).toBe("Reset task");
    expect(reset.safety).toBe("confirmed-execution");
    expect(reset.destructive).toBe(true);
    expect(reset.execution).toBe("reset-task");
    expect(actionNotice(reset)).toMatch(/^confirm to execute: /);

    for (const action of actions.filter((item) => /send|message/i.test(`${item.id} ${item.label}`))) {
      expect(action.label).toMatch(/^Manual:/);
      expect(action.safety).toBe("manual-command");
      expect(actionNotice(action)).toMatch(/^manual command: /);
    }
  });
});

describe("super TUI data loading contracts", () => {
  it("uses adapter initial summaries without triggering a refresh load", async () => {
    const loadSummaries = vi.fn(async () => [summary({ taskId: "task-loaded", runId: "run-loaded" })]);
    const initialSummaries = [summary({ taskId: "task-initial", runId: "run-initial" })];

    const loaded = await loadInitialSuperTuiSummaries({ projectLabel: "project-1", initialSummaries, loadSummaries });

    expect(loaded).toBe(initialSummaries);
    expect(loadSummaries).not.toHaveBeenCalled();
  });

  it("delegates to the adapter loader when no initial summaries are supplied", async () => {
    const loadedRows = [summary({ taskId: "task-loaded", runId: "run-loaded" })];
    const loadSummaries = vi.fn(async () => loadedRows);
    const adapter = { projectLabel: "project-1", loadSummaries };

    await expect(loadInitialSuperTuiSummaries(adapter)).resolves.toBe(loadedRows);
    expect(loadSummaries).toHaveBeenCalledTimes(1);
  });
});
