import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Run, RunProgress, Project, Metrics, Event } from "../../lib/store.js";
import {
  renderEventLine,
  renderProjectHeader,
  renderDashboard,
  pollDashboard,
  type DashboardState,
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
    progress: null,
    tmux_session: null,
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
