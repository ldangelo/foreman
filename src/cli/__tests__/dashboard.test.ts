import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Event, Project, Run, RunProgress } from "../../lib/store.js";
import {
  renderDashboard,
  renderEventLog,
  renderAgentsList,
  pollDashboard,
  type DashboardState,
} from "../dashboard-ui.js";

// ── Fixtures ──────────────────────────────────────────────────────────────

function makeProject(overrides?: Partial<Project>): Project {
  return {
    id: "proj-1",
    name: "my-project",
    path: "/home/user/my-project",
    status: "active",
    created_at: new Date(Date.now() - 3_600_000).toISOString(),
    updated_at: new Date().toISOString(),
    ...overrides,
  };
}

function makeRun(overrides?: Partial<Run>): Run {
  return {
    id: "run-001",
    project_id: "proj-1",
    bead_id: "foreman-1a",
    agent_type: "claude-sonnet-4-6",
    session_key: null,
    worktree_path: null,
    status: "running",
    started_at: new Date(Date.now() - 90_000).toISOString(), // 90s ago
    completed_at: null,
    created_at: new Date(Date.now() - 100_000).toISOString(),
    progress: null,
    ...overrides,
  };
}

function makeProgress(overrides?: Partial<RunProgress>): RunProgress {
  return {
    toolCalls: 10,
    toolBreakdown: { Bash: 5, Read: 3, Edit: 2 },
    filesChanged: ["src/foo.ts", "src/bar.ts"],
    turns: 4,
    costUsd: 0.0123,
    tokensIn: 1000,
    tokensOut: 500,
    lastToolCall: "Bash",
    lastActivity: new Date().toISOString(),
    ...overrides,
  };
}

function makeEvent(overrides?: Partial<Event>): Event {
  return {
    id: "evt-001",
    project_id: "proj-1",
    run_id: "run-001",
    event_type: "dispatch",
    details: JSON.stringify({ beadId: "foreman-1a" }),
    created_at: new Date(Date.now() - 60_000).toISOString(), // 1m ago
    ...overrides,
  };
}

function makeDashboardState(overrides?: Partial<DashboardState>): DashboardState {
  const run = makeRun();
  return {
    project: makeProject(),
    runs: [{ run, progress: null }],
    summary: {
      totalCost: 0,
      totalTools: 0,
      totalFiles: 0,
      completedCount: 0,
      failedCount: 0,
      stuckCount: 0,
      runningCount: 1,
      pendingCount: 0,
    },
    recentEvents: [],
    updatedAt: new Date().toISOString(),
    ...overrides,
  };
}

// ── Mock Store ────────────────────────────────────────────────────────────

function makeMockStore(opts: {
  project?: Project | null;
  activeRuns?: Run[];
  completedRuns?: Run[];
  failedRuns?: Run[];
  progressMap?: Record<string, RunProgress | null>;
  events?: Event[];
}) {
  return {
    getProject: vi.fn((_id: string) => opts.project ?? null),
    getProjectByPath: vi.fn((_path: string) => opts.project ?? null),
    getActiveRuns: vi.fn((_projectId?: string) => opts.activeRuns ?? []),
    getRunsByStatus: vi.fn((status: string, _projectId?: string) => {
      if (status === "completed") return opts.completedRuns ?? [];
      if (status === "failed") return opts.failedRuns ?? [];
      return [];
    }),
    getRunProgress: vi.fn((runId: string) => opts.progressMap?.[runId] ?? null),
    getEvents: vi.fn((_projectId?: string, _limit?: number) => opts.events ?? []),
  };
}

// ── renderEventLog() ──────────────────────────────────────────────────────

describe("renderEventLog", () => {
  it("shows '(no events yet)' when events array is empty", () => {
    const output = renderEventLog([]);
    expect(output).toContain("no events yet");
  });

  it("renders event type for each event", () => {
    const events = [
      makeEvent({ event_type: "dispatch", details: JSON.stringify({ beadId: "foreman-1a" }) }),
      makeEvent({ id: "evt-2", event_type: "complete", details: JSON.stringify({ beadId: "foreman-1a" }) }),
    ];
    const output = renderEventLog(events);
    expect(output).toContain("dispatch");
    expect(output).toContain("complete");
  });

  it("shows bead ID from JSON details", () => {
    const events = [
      makeEvent({ details: JSON.stringify({ beadId: "foreman-abc" }) }),
    ];
    const output = renderEventLog(events);
    expect(output).toContain("foreman-abc");
  });

  it("respects the limit parameter", () => {
    const events = Array.from({ length: 20 }, (_, i) =>
      makeEvent({ id: `evt-${i}`, event_type: "dispatch" }),
    );
    const output = renderEventLog(events, 5);
    // Count occurrences of "dispatch" — should only have 5
    const matches = output.match(/dispatch/g) ?? [];
    expect(matches.length).toBe(5);
  });

  it("shows elapsed time for events", () => {
    const events = [makeEvent()];
    const output = renderEventLog(events);
    // Should contain some time indicator (like "1m" or "60s")
    expect(output).toMatch(/\d+(s|m)/);
  });
});

// ── renderAgentsList() ────────────────────────────────────────────────────

describe("renderAgentsList", () => {
  it("shows '(no agents running)' when runs array is empty", () => {
    const output = renderAgentsList([]);
    expect(output).toContain("no agents running");
  });

  it("renders bead IDs for each run", () => {
    const run1 = makeRun({ id: "r1", bead_id: "foreman-1a" });
    const run2 = makeRun({ id: "r2", bead_id: "foreman-2b" });
    const output = renderAgentsList([
      { run: run1, progress: null },
      { run: run2, progress: null },
    ]);
    expect(output).toContain("foreman-1a");
    expect(output).toContain("foreman-2b");
  });

  it("renders run status", () => {
    const run = makeRun({ status: "running" });
    const output = renderAgentsList([{ run, progress: null }]);
    expect(output).toContain("RUNNING");
  });

  it("renders cost from progress", () => {
    const run = makeRun({ status: "completed" });
    const progress = makeProgress({ costUsd: 0.0567 });
    const output = renderAgentsList([{ run, progress }]);
    expect(output).toContain("$0.0567");
  });
});

// ── renderDashboard() ─────────────────────────────────────────────────────

describe("renderDashboard", () => {
  it("shows project name in header", () => {
    const state = makeDashboardState({ project: makeProject({ name: "awesome-project" }) });
    const output = renderDashboard(state);
    expect(output).toContain("awesome-project");
  });

  it("shows 'Foreman Dashboard' title", () => {
    const state = makeDashboardState();
    const output = renderDashboard(state);
    expect(output).toContain("Foreman Dashboard");
  });

  it("shows 'Active Agents' section when running agents exist", () => {
    const run = makeRun({ status: "running" });
    const state = makeDashboardState({
      runs: [{ run, progress: null }],
      summary: { ...makeDashboardState().summary, runningCount: 1 },
    });
    const output = renderDashboard(state);
    expect(output).toContain("Active Agents");
  });

  it("shows 'Recent Agents' section for completed runs", () => {
    const run = makeRun({ status: "completed" });
    const state = makeDashboardState({
      runs: [{ run, progress: null }],
      summary: { ...makeDashboardState().summary, runningCount: 0, completedCount: 1 },
    });
    const output = renderDashboard(state);
    expect(output).toContain("Recent Agents");
  });

  it("shows 'no agents found' when no runs exist", () => {
    const state = makeDashboardState({
      runs: [],
      summary: { ...makeDashboardState().summary, runningCount: 0 },
    });
    const output = renderDashboard(state);
    expect(output).toContain("No agents found");
  });

  it("shows 'Recent Events' section when events exist", () => {
    const state = makeDashboardState({
      recentEvents: [makeEvent()],
    });
    const output = renderDashboard(state);
    expect(output).toContain("Recent Events");
  });

  it("does NOT show events section when events list is empty", () => {
    const state = makeDashboardState({ recentEvents: [] });
    const output = renderDashboard(state);
    expect(output).not.toContain("Recent Events");
  });

  it("shows summary bar with running count", () => {
    const state = makeDashboardState({
      summary: { ...makeDashboardState().summary, runningCount: 3 },
    });
    const output = renderDashboard(state);
    expect(output).toContain("3 running");
  });

  it("shows summary bar with completed count", () => {
    const run = makeRun({ status: "completed" });
    const state = makeDashboardState({
      runs: [{ run, progress: null }],
      summary: { ...makeDashboardState().summary, runningCount: 0, completedCount: 2 },
    });
    const output = renderDashboard(state);
    expect(output).toContain("2 completed");
  });

  it("shows total cost in summary bar", () => {
    const state = makeDashboardState({
      summary: { ...makeDashboardState().summary, totalCost: 1.2345 },
    });
    const output = renderDashboard(state);
    expect(output).toContain("$1.2345");
  });

  it("shows total tool calls in summary bar", () => {
    const state = makeDashboardState({
      summary: { ...makeDashboardState().summary, totalTools: 57 },
    });
    const output = renderDashboard(state);
    expect(output).toContain("57 tools");
  });

  it("shows Ctrl+C hint when there are active agents and showDetachHint=true", () => {
    const state = makeDashboardState({
      summary: { ...makeDashboardState().summary, runningCount: 1 },
    });
    const output = renderDashboard(state, true);
    expect(output).toContain("Ctrl+C");
  });

  it("hides Ctrl+C hint when showDetachHint=false", () => {
    const state = makeDashboardState({
      summary: { ...makeDashboardState().summary, runningCount: 1 },
    });
    const output = renderDashboard(state, false);
    expect(output).not.toContain("Ctrl+C");
  });

  it("hides Ctrl+C hint when no active agents", () => {
    const run = makeRun({ status: "completed" });
    const state = makeDashboardState({
      runs: [{ run, progress: null }],
      summary: { ...makeDashboardState().summary, runningCount: 0, pendingCount: 0 },
    });
    const output = renderDashboard(state, true);
    expect(output).not.toContain("Ctrl+C");
  });

  it("shows failed count in summary when > 0", () => {
    const run = makeRun({ status: "failed" });
    const state = makeDashboardState({
      runs: [{ run, progress: null }],
      summary: { ...makeDashboardState().summary, failedCount: 1, runningCount: 0 },
    });
    const output = renderDashboard(state);
    expect(output).toContain("1 failed");
  });

  it("shows stuck count in summary when > 0", () => {
    const run = makeRun({ status: "stuck" });
    const state = makeDashboardState({
      runs: [{ run, progress: null }],
      summary: { ...makeDashboardState().summary, stuckCount: 1, runningCount: 0 },
    });
    const output = renderDashboard(state);
    expect(output).toContain("1 stuck");
  });
});

// ── pollDashboard() ───────────────────────────────────────────────────────

describe("pollDashboard", () => {
  it("returns null project when projectId is null", () => {
    const store = makeMockStore({ project: null });
    const state = pollDashboard(store as any, null);
    expect(state.project).toBeNull();
  });

  it("fetches project by id when projectId is provided", () => {
    const project = makeProject({ id: "proj-42" });
    const store = makeMockStore({ project });
    const state = pollDashboard(store as any, "proj-42");
    expect(store.getProject).toHaveBeenCalledWith("proj-42");
    expect(state.project?.id).toBe("proj-42");
  });

  it("aggregates cost from progress across all runs", () => {
    const run1 = makeRun({ id: "r1", status: "running" });
    const run2 = makeRun({ id: "r2", status: "completed" });
    const prog1 = makeProgress({ costUsd: 0.01 });
    const prog2 = makeProgress({ costUsd: 0.02 });

    const store = makeMockStore({
      activeRuns: [run1],
      completedRuns: [run2],
      progressMap: { r1: prog1, r2: prog2 },
    });
    const state = pollDashboard(store as any, null);
    expect(state.summary.totalCost).toBeCloseTo(0.03, 5);
  });

  it("aggregates tool calls from progress across all runs", () => {
    const run1 = makeRun({ id: "r1", status: "running" });
    const prog1 = makeProgress({ toolCalls: 15 });

    const store = makeMockStore({
      activeRuns: [run1],
      progressMap: { r1: prog1 },
    });
    const state = pollDashboard(store as any, null);
    expect(state.summary.totalTools).toBe(15);
  });

  it("aggregates file counts from progress across all runs", () => {
    const run1 = makeRun({ id: "r1", status: "running" });
    const prog1 = makeProgress({ filesChanged: ["a.ts", "b.ts", "c.ts"] });

    const store = makeMockStore({
      activeRuns: [run1],
      progressMap: { r1: prog1 },
    });
    const state = pollDashboard(store as any, null);
    expect(state.summary.totalFiles).toBe(3);
  });

  it("correctly counts runningCount and pendingCount", () => {
    const running = makeRun({ id: "r1", status: "running" });
    const pending = makeRun({ id: "r2", status: "pending" });
    const store = makeMockStore({ activeRuns: [running, pending] });
    const state = pollDashboard(store as any, null);
    expect(state.summary.runningCount).toBe(1);
    expect(state.summary.pendingCount).toBe(1);
  });

  it("correctly counts completedCount", () => {
    const completed = makeRun({ id: "r1", status: "completed" });
    const store = makeMockStore({ completedRuns: [completed] });
    const state = pollDashboard(store as any, null);
    expect(state.summary.completedCount).toBe(1);
  });

  it("correctly counts failedCount including test-failed", () => {
    const failed = makeRun({ id: "r1", status: "failed" });
    const testFailed = makeRun({ id: "r2", status: "test-failed" });
    const store = makeMockStore({
      failedRuns: [failed, testFailed],
    });
    const state = pollDashboard(store as any, null);
    expect(state.summary.failedCount).toBe(2);
  });

  it("deduplicates runs that appear in multiple query results", () => {
    // Same run appears in activeRuns and completedRuns (edge case)
    const run = makeRun({ id: "r1", status: "completed" });
    const store = makeMockStore({
      activeRuns: [run],
      completedRuns: [run],
    });
    const state = pollDashboard(store as any, null);
    // Should only appear once
    expect(state.runs.filter((r) => r.run.id === "r1")).toHaveLength(1);
  });

  it("includes recent events in state", () => {
    const events = [makeEvent(), makeEvent({ id: "evt-2", event_type: "complete" })];
    const store = makeMockStore({ events });
    const state = pollDashboard(store as any, null);
    expect(state.recentEvents).toHaveLength(2);
  });

  it("sets updatedAt to a recent ISO timestamp", () => {
    const before = Date.now();
    const store = makeMockStore({});
    const state = pollDashboard(store as any, null);
    const after = Date.now();
    const updatedAt = new Date(state.updatedAt).getTime();
    expect(updatedAt).toBeGreaterThanOrEqual(before);
    expect(updatedAt).toBeLessThanOrEqual(after);
  });

  it("handles no runs gracefully (all counts are 0)", () => {
    const store = makeMockStore({});
    const state = pollDashboard(store as any, null);
    expect(state.runs).toHaveLength(0);
    expect(state.summary.totalCost).toBe(0);
    expect(state.summary.runningCount).toBe(0);
  });
});
