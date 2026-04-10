import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Run, RunProgress, Project, Metrics, Event } from "../../lib/store.js";
import { BeadsRustClient } from "../../lib/beads-rust.js";
import {
  renderEventLine,
  renderProjectHeader,
  renderDashboard,
  pollDashboard,
  renderBacklogPanel,
  renderProjectAgentPanel,
  sortBacklogBeads,
  readProjectRegistry,
  matchesRegisteredProject,
  readProjectSnapshot,
  aggregateSnapshots,
  approveBacklogBead,
  type DashboardBacklogBead,
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
    taskCounts: new Map([[project.id, { total: 4, ready: 1, backlog: 1, inProgress: 1, completed: 1, blocked: 1 }]]),
    backlogBeads: [],
    backlogLoadErrors: new Map(),
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

describe("readProjectRegistry", () => {
  it("uses the global registry for enumeration and local store only for project IDs", () => {
    const store = {
      getProjectByPath: vi.fn((path: string) => {
        if (path === "/projects/alpha") {
          return makeProject({ id: "proj-alpha", name: "alpha", path });
        }
        return null;
      }),
    };

    const registry = {
      list: () => [
        { name: "alpha", path: "/projects/alpha", addedAt: "2026-04-08T00:00:00.000Z" },
        { name: "beta", path: "/projects/beta", addedAt: "2026-04-08T00:00:00.000Z" },
      ],
    };

    const projects = readProjectRegistry(store, registry);
    expect(projects).toEqual([
      { id: "proj-alpha", name: "alpha", path: "/projects/alpha" },
      { id: "/projects/beta", name: "beta", path: "/projects/beta" },
    ]);
    expect(store.getProjectByPath).toHaveBeenCalledTimes(2);
  });
});


describe("matchesRegisteredProject", () => {
  const project: RegisteredProject = {
    id: "proj-alpha",
    name: "alpha",
    path: "/projects/alpha",
  };

  it("matches by registry name, path, or local id", () => {
    expect(matchesRegisteredProject(project, "alpha")).toBe(true);
    expect(matchesRegisteredProject(project, "/projects/alpha")).toBe(true);
    expect(matchesRegisteredProject(project, "proj-alpha")).toBe(true);
    expect(matchesRegisteredProject(project, "beta")).toBe(false);
  });
});


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
  it("shows backlog and blocked totals in footer", () => {
    const state = makeDashboardState();
    const output = renderDashboard(state);
    expect(output).toContain("backlog 1");
    expect(output).toContain("blocked 1");
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

// ── Backlog bead fixture helper ────────────────────────────────────────────

function makeBacklogBead(overrides?: Partial<DashboardBacklogBead>): DashboardBacklogBead {
  return {
    id: "bd-001",
    title: "Approve authentication refactor",
    priority: "P2",
    status: "open",
    created_at: new Date(Date.now() - 3_600_000).toISOString(),
    updated_at: new Date(Date.now() - 1_800_000).toISOString(),
    projectId: "proj-1",
    projectName: "my-project",
    projectPath: "/home/user/projects/my-project",
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
    taskCounts: { total: 0, ready: 0, backlog: 0, inProgress: 0, completed: 0, blocked: 0 },
    successRate: { rate: null, merged: 0, failed: 0 },
    backlogBeads: [],
    backlogLoadError: null,
    offline: false,
    ...overrides,
  };
}

// ── sortBacklogBeads() ─────────────────────────────────────────────────────

describe("sortBacklogBeads", () => {
  it("sorts by priority first", () => {
    const beads = [
      makeBacklogBead({ id: "b1", priority: "P3" }),
      makeBacklogBead({ id: "b2", priority: "P0" }),
      makeBacklogBead({ id: "b3", priority: "P1" }),
    ];
    const sorted = sortBacklogBeads(beads);
    expect(sorted.map((b) => b.priority)).toEqual(["P0", "P1", "P3"]);
  });

  it("accepts numeric-like backlog priorities without throwing", () => {
    const beads = [
      makeBacklogBead({ id: "b1", priority: "3" }),
      makeBacklogBead({ id: "b2", priority: "0" }),
      makeBacklogBead({ id: "b3", priority: "1" }),
    ];

    const sorted = sortBacklogBeads(beads);
    expect(sorted.map((b) => b.priority)).toEqual(["0", "1", "3"]);
  });


  it("sorts older backlog beads first within the same priority", () => {
    const old = new Date(Date.now() - 7_200_000).toISOString();
    const recent = new Date(Date.now() - 1_000).toISOString();
    const beads = [
      makeBacklogBead({ id: "b1", priority: "P1", updated_at: recent }),
      makeBacklogBead({ id: "b2", priority: "P1", updated_at: old }),
    ];
    const sorted = sortBacklogBeads(beads);
    expect(sorted.map((b) => b.id)).toEqual(["b2", "b1"]);
  });

  it("uses project name and bead id as a stable tiebreaker", () => {
    const timestamp = new Date(Date.now() - 1_000).toISOString();
    const beads = [
      makeBacklogBead({ id: "b2", projectName: "zeta", priority: "P1", updated_at: timestamp }),
      makeBacklogBead({ id: "b1", projectName: "alpha", priority: "P1", updated_at: timestamp }),
    ];
    const sorted = sortBacklogBeads(beads);
    expect(sorted.map((b) => `${b.projectName}:${b.id}`)).toEqual(["alpha:b1", "zeta:b2"]);
  });

  it("does not mutate the input array", () => {
    const beads = [makeBacklogBead({ id: "b1" }), makeBacklogBead({ id: "b2", priority: "P0" })];
    const original = [...beads];
    sortBacklogBeads(beads);
    expect(beads).toEqual(original);
  });
});

// ── renderBacklogPanel() ───────────────────────────────────────────────────

describe("renderBacklogPanel", () => {
  it("shows an empty-state message when no backlog beads are available", () => {
    const output = renderBacklogPanel([]);
    expect(output).toContain("APPROVAL BACKLOG");
    expect(output).toContain("No backlog beads await approval.");
  });

  it("shows bead title, id, project, priority, and keyboard hint", () => {
    const output = renderBacklogPanel([makeBacklogBead({ id: "bd-777", projectName: "api", priority: "P0" })]);
    expect(output).toContain("Approve authentication refactor");
    expect(output).toContain("bd-777");
    expect(output).toContain("api");
    expect(output).toContain("P0");
    expect(output).toContain("j/k move  a approve selected backlog bead");
  });

  it("shows overflow and backlog fetch errors together", () => {
    const beads = Array.from({ length: 12 }, (_, index) => makeBacklogBead({ id: `bd-${index}` }));
    const output = renderBacklogPanel(beads, {
      maxRows: 5,
      backlogLoadErrors: new Map([["proj-2", "br unavailable"]]),
      notice: "Approved bd-001 for dispatch",
    });
    expect(output).toContain("showing 1-5 of 12");
    expect(output).toContain("proj-2: br unavailable");
    expect(output).toContain("Approved bd-001 for dispatch");
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

  it("shows task queue summary when task counts are available", () => {
    const project = makeProject();
    const output = renderProjectAgentPanel(
      project,
      [],
      [],
      new Map(),
      makeMetrics(),
      [],
      false,
      { total: 5, ready: 1, backlog: 2, inProgress: 1, completed: 1, blocked: 1 },
    );
    expect(output).toContain("TASK QUEUE");
    expect(output).toContain("ready 1");
    expect(output).toContain("backlog 2");
    expect(output).toContain("blocked 1");
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

  it("aggregates backlog beads across projects and preserves project association", () => {
    const proj1 = makeProject({ id: "proj-1", name: "api" });
    const proj2 = makeProject({ id: "proj-2", name: "worker" });
    const snap1 = makeProjectSnapshot({
      project: proj1,
      backlogBeads: [makeBacklogBead({ id: "bd-1", projectId: proj1.id, projectName: proj1.name, projectPath: proj1.path, priority: "P1" })],
    });
    const snap2 = makeProjectSnapshot({
      project: proj2,
      backlogBeads: [makeBacklogBead({ id: "bd-2", projectId: proj2.id, projectName: proj2.name, projectPath: proj2.path, priority: "P0" })],
      backlogLoadError: "br unavailable",
    });

    const state = aggregateSnapshots([snap1, snap2]);
    expect(state.backlogBeads?.map((bead) => `${bead.projectName}:${bead.id}`)).toEqual(["worker:bd-2", "api:bd-1"]);
    expect(state.backlogLoadErrors?.get("proj-2")).toBe("br unavailable");
  });

  it("preserves per-project task counts in aggregated state", () => {
    const proj1 = makeProject({ id: "proj-1", name: "p1" });
    const snap1 = makeProjectSnapshot({
      project: proj1,
      taskCounts: { total: 3, ready: 1, backlog: 1, inProgress: 0, completed: 1, blocked: 0 },
    });
    const state = aggregateSnapshots([snap1]);
    expect(state.taskCounts?.get("proj-1")).toEqual({
      total: 3, ready: 1, backlog: 1, inProgress: 0, completed: 1, blocked: 0,
    });
  });

  it("sets lastUpdated to a recent timestamp", () => {
    const before = Date.now();
    const state = aggregateSnapshots([]);
    expect(state.lastUpdated.getTime()).toBeGreaterThanOrEqual(before);
  });

  it("returns empty projects and backlog for empty snapshots", () => {
    const state = aggregateSnapshots([]);
    expect(state.projects).toHaveLength(0);
    expect(state.backlogBeads).toHaveLength(0);
    expect(state.backlogLoadErrors?.size).toBe(0);
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

// ── renderDashboard() with backlog beads ────────────────────────────────────

describe("renderDashboard with backlog beads", () => {
  it("shows approval backlog when backlog beads are present", () => {
    const state = makeDashboardState({
      backlogBeads: [makeBacklogBead({ id: "bd-9", title: "Approve auth migration", projectName: "api" })],
    });
    const output = renderDashboard(state);
    expect(output).toContain("APPROVAL BACKLOG");
    expect(output).toContain("Approve auth migration");
    expect(output).toContain("api");
  });

  it("shows backlog fetch failures without crashing the dashboard", () => {
    const state = makeDashboardState({
      backlogLoadErrors: new Map([["proj-1", "br unavailable"]]),
    });
    const output = renderDashboard(state);
    expect(output).toContain("Backlog unavailable for");
    expect(output).toContain("proj-1: br unavailable");
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

// ── approveBacklogBead() ───────────────────────────────────────────────────

describe("approveBacklogBead", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("calls BeadsRustClient.approve with recursive approval by default", async () => {
    const approveSpy = vi.spyOn(BeadsRustClient.prototype, "approve").mockResolvedValue({
      approved: ["bd-001"],
      skipped: [],
    });

    await expect(approveBacklogBead("bd-001", "/some/project")).resolves.toEqual({
      approved: ["bd-001"],
      skipped: [],
    });
    expect(approveSpy).toHaveBeenCalledWith("bd-001", { recursive: true });
  });

  it("passes through an explicit non-recursive approval request", async () => {
    const approveSpy = vi.spyOn(BeadsRustClient.prototype, "approve").mockResolvedValue({
      approved: ["bd-002"],
      skipped: [],
    });

    await approveBacklogBead("bd-002", "/some/project", { recursive: false });
    expect(approveSpy).toHaveBeenCalledWith("bd-002", { recursive: false });
  });

  it("propagates backend approval failures", async () => {
    vi.spyOn(BeadsRustClient.prototype, "approve").mockRejectedValue(new Error("br exploded"));
    await expect(approveBacklogBead("bd-404", "/some/project")).rejects.toThrow("br exploded");
  });
});
