import { describe, it, expect, vi, beforeEach } from "vitest";
import { ForemanStore } from "../../lib/store.js";
import type { Run, RunProgress, Project, Metrics, Event, NativeTask } from "../../lib/store.js";
import {
  renderEventLine,
  renderProjectHeader,
  renderDashboard,
  pollDashboard,
  renderNeedsHumanPanel,
  renderProjectAgentPanel,
  sortNeedsHumanTasks,
  readProjectSnapshot,
  aggregateSnapshots,
  approveTask,
  retryTask,
  NEEDS_HUMAN_STATUSES,
  type NeedsHumanStatus,
  type DashboardState,
  type ProjectSnapshot,
  type RegisteredProject,
} from "../commands/dashboard.js";

// ── Fixtures ──────────────────────────────────────────────────────────────

function makeProject(overrides?: Partial<Project>): Project {
  return {
    id: "proj-1",
    name: "my-project",
    path: "/home/user/projects/my-project",
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
    seed_id: "foreman-1a",
    agent_type: "claude-sonnet-4-6",
    session_key: null,
    worktree_path: null,
    status: "running",
    started_at: new Date(Date.now() - 90_000).toISOString(),
    completed_at: null,
    created_at: new Date(Date.now() - 100_000).toISOString(),
    progress: null,    ...overrides,
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

function makeMetrics(overrides?: Partial<Metrics>): Metrics {
  return {
    totalCost: 12.40,
    totalTokens: 45_000,
    tasksByStatus: { running: 2, completed: 3 },
    costByRuntime: [],
    ...overrides,
  };
}

function makeEvent(overrides?: Partial<Event>): Event {
  return {
    id: "event-001",
    project_id: "proj-1",
    run_id: "run-001",
    event_type: "dispatch",
    details: JSON.stringify({ seedId: "foreman-1a", title: "Fix auth bug" }),
    created_at: new Date(Date.now() - 5 * 60_000).toISOString(),
    ...overrides,
  };
}

function makeDashboardState(overrides?: Partial<DashboardState>): DashboardState {
  const project = makeProject();
  const run = makeRun();
  const progress = makeProgress();
  const metrics = makeMetrics();

  const activeRuns = new Map<string, Run[]>([[project.id, [run]]]);
  const completedRuns = new Map<string, Run[]>([[project.id, []]]);
  const progresses = new Map<string, RunProgress | null>([[run.id, progress]]);
  const metricsMap = new Map<string, Metrics>([[project.id, metrics]]);
  const eventsMap = new Map<string, Event[]>([[project.id, [makeEvent()]]]);

  return {
    projects: [project],
    activeRuns,
    completedRuns,
    progresses,
    metrics: metricsMap,
    events: eventsMap,
    lastUpdated: new Date(),
    ...overrides,
  };
}

function makeMockStore(opts: {
  projects?: Project[];
  activeRuns?: Record<string, Run[]>;
  runsByStatus?: Record<string, Record<string, Run[]>>;
  progresses?: Record<string, RunProgress | null>;
  metrics?: Record<string, Metrics>;
  events?: Record<string, Event[]>;
}) {
  const projectsById = Object.fromEntries((opts.projects ?? []).map((p) => [p.id, p]));
  return {
    listProjects: vi.fn(() => opts.projects ?? []),
    getProject: vi.fn((id: string) => projectsById[id] ?? null),
    getProjectByPath: vi.fn(() => opts.projects?.[0] ?? null),
    getActiveRuns: vi.fn((projectId: string) => opts.activeRuns?.[projectId] ?? []),
    getRunsByStatus: vi.fn((status: string, projectId: string) =>
      opts.runsByStatus?.[status]?.[projectId] ?? [],
    ),
    getRunProgress: vi.fn((runId: string) => opts.progresses?.[runId] ?? null),
    getMetrics: vi.fn((projectId: string) =>
      opts.metrics?.[projectId] ?? {
        totalCost: 0,
        totalTokens: 0,
        tasksByStatus: {},
        costByRuntime: [],
      },
    ),
    getEvents: vi.fn((projectId: string) => opts.events?.[projectId] ?? []),
    getSuccessRate: vi.fn(() => ({ rate: null, merged: 0, failed: 0 })),
  };
}

// ── renderEventLine() ─────────────────────────────────────────────────────

describe("renderEventLine", () => {
  it("renders a dispatch event with seedId", () => {
    const event = makeEvent({ event_type: "dispatch", details: JSON.stringify({ seedId: "foreman-1a" }) });
    const output = renderEventLine(event);
    expect(output).toContain("dispatch");
    expect(output).toContain("foreman-1a");
  });

  it("renders a complete event", () => {
    const event = makeEvent({ event_type: "complete", details: JSON.stringify({ seedId: "foreman-1a", phase: "developer" }) });
    const output = renderEventLine(event);
    expect(output).toContain("complete");
    expect(output).toContain("foreman-1a");
    expect(output).toContain("phase:developer");
  });

  it("renders a fail event", () => {
    const event = makeEvent({ event_type: "fail", details: JSON.stringify({ seedId: "foreman-2b", reason: "Build failed" }) });
    const output = renderEventLine(event);
    expect(output).toContain("fail");
    expect(output).toContain("Build failed");
  });

  it("renders events with no details", () => {
    const event = makeEvent({ event_type: "restart", details: null });
    const output = renderEventLine(event);
    expect(output).toContain("restart");
  });

  it("includes elapsed time suffix '(X ago)'", () => {
    const event = makeEvent();
    const output = renderEventLine(event);
    expect(output).toMatch(/ago\)/);
  });

  it("handles non-JSON details gracefully", () => {
    const event = makeEvent({ details: "plain text detail" });
    const output = renderEventLine(event);
    expect(output).toContain("plain text detail");
  });
});

// ── renderProjectHeader() ─────────────────────────────────────────────────

describe("renderProjectHeader", () => {
  it("shows project name", () => {
    const project = makeProject({ name: "my-project" });
    const output = renderProjectHeader(project, 2, makeMetrics());
    expect(output).toContain("my-project");
  });

  it("shows total cost", () => {
    const project = makeProject();
    const output = renderProjectHeader(project, 1, makeMetrics({ totalCost: 12.40 }));
    expect(output).toContain("12.40");
  });

  it("shows token count in k format", () => {
    const project = makeProject();
    const output = renderProjectHeader(project, 1, makeMetrics({ totalTokens: 45_000 }));
    expect(output).toContain("45.0k");
  });

  it("shows active agent count", () => {
    const project = makeProject();
    const output = renderProjectHeader(project, 3, makeMetrics());
    expect(output).toContain("3 active agents");
  });

  it("uses singular 'agent' when count is 1", () => {
    const project = makeProject();
    const output = renderProjectHeader(project, 1, makeMetrics());
    expect(output).toContain("1 active agent");
    expect(output).not.toContain("1 active agents");
  });

  it("shows '$0.00 spent' when no cost", () => {
    const project = makeProject();
    const output = renderProjectHeader(project, 0, makeMetrics({ totalCost: 0, totalTokens: 0 }));
    expect(output).toContain("$0.00");
  });
});

// ── renderDashboard() ─────────────────────────────────────────────────────

describe("renderDashboard", () => {
  it("shows 'Foreman Dashboard' header", () => {
    const state = makeDashboardState();
    const output = renderDashboard(state);
    expect(output).toContain("Foreman Dashboard");
  });

  it("shows 'Ctrl+C to detach' hint", () => {
    const state = makeDashboardState();
    const output = renderDashboard(state);
    expect(output).toContain("Ctrl+C to detach");
  });

  it("shows project name in output", () => {
    const state = makeDashboardState();
    const output = renderDashboard(state);
    expect(output).toContain("my-project");
  });

  it("shows active seed_id in output", () => {
    const state = makeDashboardState();
    const output = renderDashboard(state);
    expect(output).toContain("foreman-1a");
  });

  it("shows events section when events exist", () => {
    const state = makeDashboardState();
    const output = renderDashboard(state);
    expect(output).toContain("RECENT EVENTS");
  });

  it("shows 'no agents running' when active list is empty", () => {
    const project = makeProject();
    const state = makeDashboardState({
      activeRuns: new Map([[project.id, []]]),
    });
    const output = renderDashboard(state);
    expect(output).toContain("no agents running");
  });

  it("shows 'No projects registered' when projects array is empty", () => {
    const state = makeDashboardState({
      projects: [],
      activeRuns: new Map(),
      completedRuns: new Map(),
      progresses: new Map(),
      metrics: new Map(),
      events: new Map(),
    });
    const output = renderDashboard(state);
    expect(output).toContain("No projects registered");
  });

  it("shows TOTALS footer", () => {
    const state = makeDashboardState();
    const output = renderDashboard(state);
    expect(output).toContain("TOTALS");
  });

  it("shows last updated timestamp", () => {
    const state = makeDashboardState();
    const output = renderDashboard(state);
    expect(output).toContain("Last updated:");
  });

  it("shows recently completed section when runs exist", () => {
    const project = makeProject();
    const completedRun = makeRun({
      id: "run-completed",
      status: "completed",
      completed_at: new Date(Date.now() - 300_000).toISOString(),
      seed_id: "foreman-done",
    });
    const state = makeDashboardState({
      activeRuns: new Map([[project.id, []]]),
      completedRuns: new Map([[project.id, [completedRun]]]),
    });
    const output = renderDashboard(state);
    expect(output).toContain("RECENTLY COMPLETED");
    expect(output).toContain("foreman-done");
  });

  it("aggregates total cost from all projects", () => {
    const proj1 = makeProject({ id: "proj-1", name: "p1" });
    const proj2 = makeProject({ id: "proj-2", name: "p2" });
    const state: DashboardState = {
      projects: [proj1, proj2],
      activeRuns: new Map([["proj-1", []], ["proj-2", []]]),
      completedRuns: new Map([["proj-1", []], ["proj-2", []]]),
      progresses: new Map(),
      metrics: new Map([
        ["proj-1", makeMetrics({ totalCost: 5.00, totalTokens: 10_000 })],
        ["proj-2", makeMetrics({ totalCost: 7.50, totalTokens: 20_000 })],
      ]),
      events: new Map([["proj-1", []], ["proj-2", []]]),
      lastUpdated: new Date(),
    };
    const output = renderDashboard(state);
    expect(output).toContain("12.50"); // 5 + 7.5
  });
});

// ── pollDashboard() ────────────────────────────────────────────────────────

describe("pollDashboard", () => {
  it("returns projects from store", () => {
    const project = makeProject();
    const store = makeMockStore({ projects: [project] });
    const state = pollDashboard(store as any);
    expect(state.projects).toHaveLength(1);
    expect(state.projects[0].id).toBe("proj-1");
  });

  it("returns empty state when no projects", () => {
    const store = makeMockStore({ projects: [] });
    const state = pollDashboard(store as any);
    expect(state.projects).toHaveLength(0);
    expect(state.activeRuns.size).toBe(0);
  });

  it("collects active runs per project", () => {
    const project = makeProject();
    const run = makeRun();
    const store = makeMockStore({
      projects: [project],
      activeRuns: { "proj-1": [run] },
    });
    const state = pollDashboard(store as any);
    expect(state.activeRuns.get("proj-1")).toHaveLength(1);
  });

  it("collects run progress for active runs", () => {
    const project = makeProject();
    const run = makeRun();
    const progress = makeProgress();
    const store = makeMockStore({
      projects: [project],
      activeRuns: { "proj-1": [run] },
      progresses: { "run-001": progress },
    });
    const state = pollDashboard(store as any);
    expect(state.progresses.get("run-001")).toEqual(progress);
  });

  it("collects metrics per project", () => {
    const project = makeProject();
    const metrics = makeMetrics({ totalCost: 5.00 });
    const store = makeMockStore({
      projects: [project],
      metrics: { "proj-1": metrics },
    });
    const state = pollDashboard(store as any);
    expect(state.metrics.get("proj-1")?.totalCost).toBe(5.00);
  });

  it("collects recent events per project", () => {
    const project = makeProject();
    const event = makeEvent();
    const store = makeMockStore({
      projects: [project],
      events: { "proj-1": [event] },
    });
    const state = pollDashboard(store as any);
    expect(state.events.get("proj-1")).toHaveLength(1);
  });

  it("filters to the specified projectId using store.getProject", () => {
    const proj1 = makeProject({ id: "proj-1", name: "first" });
    const proj2 = makeProject({ id: "proj-2", name: "second" });
    const store = makeMockStore({ projects: [proj1, proj2] });

    const state = pollDashboard(store as any, "proj-2");
    expect(state.projects).toHaveLength(1);
    expect(state.projects[0].id).toBe("proj-2");
    // Should call getProject, not listProjects
    expect(store.getProject).toHaveBeenCalledWith("proj-2");
    expect(store.listProjects).not.toHaveBeenCalled();
  });

  it("returns empty projects array when projectId does not exist", () => {
    const project = makeProject({ id: "proj-1" });
    const store = makeMockStore({ projects: [project] });

    const state = pollDashboard(store as any, "nonexistent-id");
    expect(state.projects).toHaveLength(0);
  });

  it("sets lastUpdated to a recent timestamp", () => {
    const store = makeMockStore({ projects: [] });
    const before = Date.now();
    const state = pollDashboard(store as any);
    const after = Date.now();
    expect(state.lastUpdated.getTime()).toBeGreaterThanOrEqual(before);
    expect(state.lastUpdated.getTime()).toBeLessThanOrEqual(after);
  });
});

// ── NativeTask fixture helper ─────────────────────────────────────────────

function makeNativeTask(overrides?: Partial<NativeTask>): NativeTask {
  return {
    id: "task-001",
    title: "Fix authentication bug",
    description: null,
    type: "task",
    priority: 2,
    status: "backlog",
    run_id: null,
    branch: null,
    external_id: null,
    created_at: new Date(Date.now() - 3_600_000).toISOString(),
    updated_at: new Date(Date.now() - 1_800_000).toISOString(),
    approved_at: null,
    closed_at: null,
    ...overrides,
  };
}

function makeProjectSnapshot(overrides?: Partial<ProjectSnapshot>): ProjectSnapshot {
  const project = makeProject();
  return {
    project,
    activeRuns: [],
    completedRuns: [],
    progresses: new Map(),
    metrics: makeMetrics(),
    events: [],
    successRate: { rate: null, merged: 0, failed: 0 },
    needsHumanTasks: [],
    offline: false,
    ...overrides,
  };
}

// ── sortNeedsHumanTasks() ─────────────────────────────────────────────────

describe("sortNeedsHumanTasks", () => {
  it("sorts conflict before failed before stuck before backlog", () => {
    const tasks = [
      makeNativeTask({ id: "t1", status: "backlog", priority: 0 }),
      makeNativeTask({ id: "t2", status: "stuck", priority: 0 }),
      makeNativeTask({ id: "t3", status: "conflict", priority: 0 }),
      makeNativeTask({ id: "t4", status: "failed", priority: 0 }),
    ];
    const sorted = sortNeedsHumanTasks(tasks);
    expect(sorted.map((t) => t.status)).toEqual(["conflict", "failed", "stuck", "backlog"]);
  });

  it("sorts by priority (P0 first) within same status", () => {
    const tasks = [
      makeNativeTask({ id: "t1", status: "failed", priority: 3 }),
      makeNativeTask({ id: "t2", status: "failed", priority: 0 }),
      makeNativeTask({ id: "t3", status: "failed", priority: 1 }),
    ];
    const sorted = sortNeedsHumanTasks(tasks);
    expect(sorted.map((t) => t.priority)).toEqual([0, 1, 3]);
  });

  it("sorts by age (oldest updated_at first) within same status and priority", () => {
    const old = new Date(Date.now() - 7_200_000).toISOString();
    const recent = new Date(Date.now() - 1_000).toISOString();
    const tasks = [
      makeNativeTask({ id: "t1", status: "stuck", priority: 1, updated_at: recent }),
      makeNativeTask({ id: "t2", status: "stuck", priority: 1, updated_at: old }),
    ];
    const sorted = sortNeedsHumanTasks(tasks);
    expect(sorted[0].id).toBe("t2"); // older first
    expect(sorted[1].id).toBe("t1");
  });

  it("returns empty array for empty input", () => {
    expect(sortNeedsHumanTasks([])).toEqual([]);
  });

  it("does not mutate the input array", () => {
    const tasks = [
      makeNativeTask({ id: "t1", status: "backlog", priority: 2 }),
      makeNativeTask({ id: "t2", status: "conflict", priority: 2 }),
    ];
    const original = [...tasks];
    sortNeedsHumanTasks(tasks);
    expect(tasks).toEqual(original);
  });

  it("maintains sort stability when status, priority, and age are equal", () => {
    const timestamp = new Date(Date.now() - 1_000).toISOString();
    const tasks = [
      makeNativeTask({ id: "t1", status: "conflict", priority: 0, updated_at: timestamp }),
      makeNativeTask({ id: "t2", status: "conflict", priority: 0, updated_at: timestamp }),
      makeNativeTask({ id: "t3", status: "conflict", priority: 0, updated_at: timestamp }),
    ];
    const sorted = sortNeedsHumanTasks(tasks);
    // With equal status, priority, and age, original order should be preserved
    expect(sorted.map((t) => t.id)).toEqual(["t1", "t2", "t3"]);
  });
});

// ── NEEDS_HUMAN_STATUSES constant ────────────────────────────────────────

describe("NEEDS_HUMAN_STATUSES", () => {
  it("contains exactly conflict, failed, stuck, backlog", () => {
    expect(NEEDS_HUMAN_STATUSES).toEqual(["conflict", "failed", "stuck", "backlog"]);
  });

  it("is a readonly tuple of exactly 4 elements", () => {
    expect(NEEDS_HUMAN_STATUSES.length).toBe(4);
    // as const makes it readonly
    expect(NEEDS_HUMAN_STATUSES).toEqual(["conflict", "failed", "stuck", "backlog"]);
  });

  it("each status is a string", () => {
    NEEDS_HUMAN_STATUSES.forEach((status) => {
      expect(typeof status).toBe("string");
    });
  });
});

// ── NeedsHumanStatus type ─────────────────────────────────────────────────

describe("NeedsHumanStatus", () => {
  it("accepts valid needs-human status values", () => {
    const validStatuses: NeedsHumanStatus[] = ["conflict", "failed", "stuck", "backlog"];
    validStatuses.forEach((status) => {
      expect(NEEDS_HUMAN_STATUSES).toContain(status);
    });
  });
});

// ── renderNeedsHumanPanel() ───────────────────────────────────────────────

describe("renderNeedsHumanPanel", () => {
  it("returns empty string when no tasks", () => {
    expect(renderNeedsHumanPanel([])).toBe("");
  });

  it("shows NEEDS HUMAN ATTENTION header when tasks exist", () => {
    const output = renderNeedsHumanPanel([makeNativeTask()]);
    expect(output).toContain("NEEDS HUMAN ATTENTION");
  });

  it("shows task title in output", () => {
    const output = renderNeedsHumanPanel([makeNativeTask({ title: "My broken task" })]);
    expect(output).toContain("My broken task");
  });

  it("shows task status in output", () => {
    const output = renderNeedsHumanPanel([makeNativeTask({ status: "conflict" })]);
    expect(output.toUpperCase()).toContain("CONFLICT");
  });

  it("shows priority label", () => {
    const output = renderNeedsHumanPanel([makeNativeTask({ priority: 0 })]);
    expect(output).toContain("P0");
  });

  it("shows project name when available", () => {
    const output = renderNeedsHumanPanel([makeNativeTask({ projectName: "my-api" })]);
    expect(output).toContain("my-api");
  });

  it("truncates display to maxRows and shows overflow count", () => {
    const tasks = Array.from({ length: 15 }, (_, i) =>
      makeNativeTask({ id: `t${i}`, title: `Task ${i}` })
    );
    const output = renderNeedsHumanPanel(tasks, 5);
    expect(output).toContain("10 more");
  });

  it("shows all tasks when count <= maxRows", () => {
    const tasks = [
      makeNativeTask({ id: "t1", title: "First task" }),
      makeNativeTask({ id: "t2", title: "Second task" }),
    ];
    const output = renderNeedsHumanPanel(tasks, 10);
    expect(output).toContain("First task");
    expect(output).toContain("Second task");
    expect(output).not.toContain("more");
  });
});

// ── renderProjectAgentPanel() ─────────────────────────────────────────────

describe("renderProjectAgentPanel", () => {
  it("shows [offline] indicator when project is offline", () => {
    const project = makeProject({ name: "remote-project" });
    const output = renderProjectAgentPanel(project, [], [], new Map(), makeMetrics(), [], true);
    expect(output).toContain("[offline]");
  });

  it("shows project name", () => {
    const project = makeProject({ name: "my-project" });
    const output = renderProjectAgentPanel(project, [], [], new Map(), makeMetrics(), [], false);
    expect(output).toContain("my-project");
  });

  it("shows 'no agents running' when active runs are empty", () => {
    const project = makeProject();
    const output = renderProjectAgentPanel(project, [], [], new Map(), makeMetrics(), [], false);
    expect(output).toContain("no agents running");
  });

  it("shows RECENT EVENTS when events exist", () => {
    const project = makeProject();
    const event = makeEvent({ project_id: project.id });
    const output = renderProjectAgentPanel(project, [], [], new Map(), makeMetrics(), [event], false);
    expect(output).toContain("RECENT EVENTS");
  });
});

// ── aggregateSnapshots() ─────────────────────────────────────────────────

describe("aggregateSnapshots", () => {
  it("merges multiple project snapshots into a single DashboardState", () => {
    const proj1 = makeProject({ id: "proj-1", name: "p1" });
    const proj2 = makeProject({ id: "proj-2", name: "p2" });
    const snap1 = makeProjectSnapshot({ project: proj1 });
    const snap2 = makeProjectSnapshot({ project: proj2 });
    const state = aggregateSnapshots([snap1, snap2]);
    expect(state.projects).toHaveLength(2);
    expect(state.projects.map((p) => p.id)).toContain("proj-1");
    expect(state.projects.map((p) => p.id)).toContain("proj-2");
  });

  it("marks offline projects in offlineProjects set", () => {
    const proj = makeProject({ id: "proj-offline" });
    const snap = makeProjectSnapshot({ project: proj, offline: true });
    const state = aggregateSnapshots([snap]);
    expect(state.offlineProjects?.has("proj-offline")).toBe(true);
  });

  it("aggregates needsHumanTasks from all projects and sorts them", () => {
    const proj1 = makeProject({ id: "proj-1" });
    const proj2 = makeProject({ id: "proj-2" });
    const snap1 = makeProjectSnapshot({
      project: proj1,
      needsHumanTasks: [makeNativeTask({ id: "t1", status: "backlog", priority: 1 })],
    });
    const snap2 = makeProjectSnapshot({
      project: proj2,
      needsHumanTasks: [makeNativeTask({ id: "t2", status: "conflict", priority: 2 })],
    });
    const state = aggregateSnapshots([snap1, snap2]);
    expect(state.needsHumanTasks).toHaveLength(2);
    // conflict should come first
    expect(state.needsHumanTasks![0].status).toBe("conflict");
  });

  it("sets lastUpdated to a recent timestamp", () => {
    const before = Date.now();
    const state = aggregateSnapshots([]);
    expect(state.lastUpdated.getTime()).toBeGreaterThanOrEqual(before);
  });

  it("returns empty projects when snapshots is empty", () => {
    const state = aggregateSnapshots([]);
    expect(state.projects).toHaveLength(0);
    expect(state.needsHumanTasks).toHaveLength(0);
  });
});

// ── readProjectSnapshot() ─────────────────────────────────────────────────

describe("readProjectSnapshot", () => {
  it("returns an offline snapshot for a project with no DB file", async () => {
    const project: RegisteredProject = {
      id: "proj-missing",
      name: "missing-project",
      path: "/nonexistent/path",
    };
    const snapshots = await readProjectSnapshot([project]);
    expect(snapshots).toHaveLength(1);
    expect(snapshots[0].offline).toBe(true);
  });

  it("returns an array of snapshots for each project", async () => {
    const projects: RegisteredProject[] = [
      { id: "p1", name: "first", path: "/nonexistent/p1" },
      { id: "p2", name: "second", path: "/nonexistent/p2" },
    ];
    const snapshots = await readProjectSnapshot(projects);
    expect(snapshots).toHaveLength(2);
    expect(snapshots.every((s) => s.offline)).toBe(true);
  });

  it("returns empty array for empty input", async () => {
    const snapshots = await readProjectSnapshot([]);
    expect(snapshots).toHaveLength(0);
  });

  it("handles a mix of accessible and inaccessible projects", async () => {
    const projects: RegisteredProject[] = [
      { id: "p-missing", name: "missing", path: "/nonexistent" },
    ];
    const snapshots = await readProjectSnapshot(projects);
    expect(snapshots[0].offline).toBe(true);
    expect(snapshots[0].project.name).toBe("missing");
  });
});

// ── renderDashboard() with needsHumanTasks ────────────────────────────────

describe("renderDashboard with needsHumanTasks", () => {
  it("shows NEEDS HUMAN ATTENTION when needsHumanTasks is non-empty", () => {
    const state = makeDashboardState({
      needsHumanTasks: [makeNativeTask({ status: "conflict", title: "Merge conflict in auth" })],
    });
    const output = renderDashboard(state);
    expect(output).toContain("NEEDS HUMAN ATTENTION");
    expect(output).toContain("Merge conflict in auth");
  });

  it("does not show NEEDS HUMAN ATTENTION when there are no such tasks", () => {
    const state = makeDashboardState({ needsHumanTasks: [] });
    const output = renderDashboard(state);
    expect(output).not.toContain("NEEDS HUMAN ATTENTION");
  });

  it("shows offline indicator for offline projects", () => {
    const proj = makeProject({ id: "proj-x" });
    const state = makeDashboardState({
      projects: [proj],
      offlineProjects: new Set(["proj-x"]),
      activeRuns: new Map([["proj-x", []]]),
      completedRuns: new Map([["proj-x", []]]),
      metrics: new Map([["proj-x", makeMetrics()]]),
      events: new Map([["proj-x", []]]),
    });
    const output = renderDashboard(state);
    expect(output).toContain("[offline]");
  });
});

// ── approveTask() / retryTask() ───────────────────────────────────────────

describe("approveTask and retryTask", () => {
  it("approveTask calls updateTaskStatus with 'ready'", () => {
    const mockUpdateTaskStatus = vi.fn();
    const mockClose = vi.fn();
    vi.spyOn(ForemanStore, "forProject").mockReturnValueOnce({
      updateTaskStatus: mockUpdateTaskStatus,
      close: mockClose,
    } as unknown as ForemanStore);

    approveTask("task-001", "/some/project");
    expect(mockUpdateTaskStatus).toHaveBeenCalledWith("task-001", "ready");
    expect(mockClose).toHaveBeenCalled();
  });

  it("retryTask calls updateTaskStatus with 'backlog'", () => {
    const mockUpdateTaskStatus = vi.fn();
    const mockClose = vi.fn();
    vi.spyOn(ForemanStore, "forProject").mockReturnValueOnce({
      updateTaskStatus: mockUpdateTaskStatus,
      close: mockClose,
    } as unknown as ForemanStore);

    retryTask("task-001", "/some/project");
    expect(mockUpdateTaskStatus).toHaveBeenCalledWith("task-001", "backlog");
    expect(mockClose).toHaveBeenCalled();
  });

  it("approveTask closes the store even if updateTaskStatus throws", () => {
    const mockClose = vi.fn();
    vi.spyOn(ForemanStore, "forProject").mockReturnValueOnce({
      updateTaskStatus: vi.fn().mockImplementation(() => { throw new Error("DB error"); }),
      close: mockClose,
    } as unknown as ForemanStore);

    expect(() => approveTask("task-001", "/some/project")).toThrow("DB error");
    expect(mockClose).toHaveBeenCalled();
  });

  it("approveTask propagates error from updateTaskStatus for invalid taskId", () => {
    const mockClose = vi.fn();
    vi.spyOn(ForemanStore, "forProject").mockReturnValueOnce({
      updateTaskStatus: vi.fn().mockImplementation(() => { throw new Error("no such task: nonexistent-id"); }),
      close: mockClose,
    } as unknown as ForemanStore);

    expect(() => approveTask("nonexistent-id", "/some/project")).toThrow("no such task: nonexistent-id");
    expect(mockClose).toHaveBeenCalled();
  });

  it("retryTask propagates error from updateTaskStatus for invalid taskId", () => {
    const mockClose = vi.fn();
    vi.spyOn(ForemanStore, "forProject").mockReturnValueOnce({
      updateTaskStatus: vi.fn().mockImplementation(() => { throw new Error("no such task: nonexistent-id"); }),
      close: mockClose,
    } as unknown as ForemanStore);

    expect(() => retryTask("nonexistent-id", "/some/project")).toThrow("no such task: nonexistent-id");
    expect(mockClose).toHaveBeenCalled();
  });
});
