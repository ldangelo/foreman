/**
 * Tests for the unified live monitoring features:
 *   - foreman status --live  (full dashboard TUI with br task counts)
 *   - foreman dashboard --simple  (compact single-project view with task counts)
 *   - renderLiveStatusHeader()  (task counts header for live mode)
 *   - renderSimpleDashboard()   (compact dashboard renderer)
 *   - fetchDashboardTaskCounts()  (br task counts for dashboard --simple)
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// ── Hoisted mocks ───────────────────────────────────────────────────────────
const {
  mockGetRepoRoot,
  mockCreateVcsBackend,
  mockBrList,
  mockBrReady,
  mockBrListBacklog,
  MockBeadsRustClient,
  mockGetProjectByPath,
  mockGetActiveRuns,
  mockGetRunsByStatus,
  mockGetMetrics,
  mockGetRunsByStatusSince,
  mockGetRunProgress,
  mockGetEvents,
  mockListProjects,
  MockForemanStore,
  mockPollDashboard,
  mockRenderDashboard,
} = vi.hoisted(() => {
  const mockGetRepoRoot = vi.fn().mockResolvedValue("/mock/project");
  const mockCreateVcsBackend = vi.fn().mockResolvedValue({
    name: "git",
    getRepoRoot: mockGetRepoRoot,
  });

  // BeadsRustClient mocks
  const mockBrList = vi.fn().mockResolvedValue([]);
  const mockBrReady = vi.fn().mockResolvedValue([]);
  const mockBrListBacklog = vi.fn().mockResolvedValue([]);
  const MockBeadsRustClient = vi.fn(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
    this.list = mockBrList;
    this.ready = mockBrReady;
    this.listBacklog = mockBrListBacklog;
    this.ensureBrInstalled = vi.fn().mockResolvedValue(undefined);
  });

  // ForemanStore mocks
  const mockGetProjectByPath = vi.fn().mockReturnValue(null);
  const mockGetActiveRuns = vi.fn().mockReturnValue([]);
  const mockGetRunsByStatus = vi.fn().mockReturnValue([]);
  const mockGetMetrics = vi.fn().mockReturnValue({ totalCost: 0, totalTokens: 0, tasksByStatus: {}, costByRuntime: [] });
  const mockGetRunsByStatusSince = vi.fn().mockReturnValue([]);
  const mockGetRunProgress = vi.fn().mockReturnValue(null);
  const mockGetEvents = vi.fn().mockReturnValue([]);
  const mockListProjects = vi.fn().mockReturnValue([]);
  const MockForemanStore = vi.fn(function MockForemanStoreImpl(this: Record<string, unknown>) {
    this.getProjectByPath = mockGetProjectByPath;
    this.getActiveRuns = mockGetActiveRuns;
    this.getRunsByStatus = mockGetRunsByStatus;
    this.getMetrics = mockGetMetrics;
    this.getRunsByStatusSince = mockGetRunsByStatusSince;
    this.getRunProgress = mockGetRunProgress;
    this.getEvents = mockGetEvents;
    this.listProjects = mockListProjects;
    this.getProject = vi.fn().mockReturnValue(null);
    this.close = vi.fn();
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (MockForemanStore as any).forProject = vi.fn((...args: unknown[]) => new (MockForemanStore as any)(...args));

  // Dashboard function mocks (used by status --live tests)
  const mockPollDashboard = vi.fn().mockReturnValue({
    projects: [],
    activeRuns: new Map(),
    completedRuns: new Map(),
    progresses: new Map(),
    metrics: new Map(),
    events: new Map(),
    lastUpdated: new Date("2026-01-01T12:00:00Z"),
  });
  const mockRenderDashboard = vi.fn().mockReturnValue("Foreman Dashboard\n━━━\n\nNo projects.\n━━━\nLast updated: 12:00:00 PM");

  return {
    mockGetRepoRoot,
    mockCreateVcsBackend,
    mockBrList,
    mockBrReady,
    mockBrListBacklog,
    MockBeadsRustClient,
    mockGetProjectByPath,
    mockGetActiveRuns,
    mockGetRunsByStatus,
    mockGetMetrics,
    mockGetRunsByStatusSince,
    mockGetRunProgress,
    mockGetEvents,
    mockListProjects,
    MockForemanStore,
    mockPollDashboard,
    mockRenderDashboard,
  };
});

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: mockCreateVcsBackend,
  },
}));

vi.mock("../../lib/beads-rust.js", () => ({
  BeadsRustClient: MockBeadsRustClient,
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: MockForemanStore,
}));

vi.mock("../watch-ui.js", () => ({
  renderAgentCard: vi.fn().mockReturnValue("  ● seed-1 RUNNING"),
  elapsed: vi.fn().mockReturnValue("5m 30s"),
}));

vi.mock("../../lib/feature-flags.js", () => ({
  getTaskBackend: vi.fn().mockReturnValue("br"),
}));

// ── process.exit mock ────────────────────────────────────────────────────────
let exitSpy: ReturnType<typeof vi.spyOn>;
beforeEach(() => {
  exitSpy = vi.spyOn(process, "exit").mockImplementation((code?: number | string | null | undefined) => {
    throw new Error(`process.exit(${code ?? ""}) called`);
  });
});
afterEach(() => {
  exitSpy.mockRestore();
});

// ── Imports ─────────────────────────────────────────────────────────────────
import { renderLiveStatusHeader } from "../commands/status.js";
import {
  renderSimpleDashboard,
  fetchDashboardTaskCounts,
  renderProjectHeader,
  renderEventLine,
  type DashboardState,
  type DashboardTaskCounts,
} from "../commands/dashboard.js";

// ── Helpers ─────────────────────────────────────────────────────────────────

const MOCK_PROJECT = {
  id: "proj-1",
  path: "/mock/project",
  name: "test-project",
  status: "active" as const,
  created_at: "2026-01-01T00:00:00Z",
  updated_at: "2026-01-01T00:00:00Z",
};

function makeDashboardState(overrides?: Partial<DashboardState>): DashboardState {
  return {
    projects: [],
    activeRuns: new Map(),
    completedRuns: new Map(),
    progresses: new Map(),
    metrics: new Map(),
    events: new Map(),
    lastUpdated: new Date("2026-01-01T12:00:00Z"),
    ...overrides,
  };
}

const ZERO_COUNTS: DashboardTaskCounts = {
  total: 0, ready: 0, backlog: 0, inProgress: 0, completed: 0, blocked: 0,
};

// ── Tests: renderLiveStatusHeader() ─────────────────────────────────────────

describe("renderLiveStatusHeader()", () => {
  it("includes 'Tasks:' label", () => {
    const result = renderLiveStatusHeader(ZERO_COUNTS);
    expect(result).toContain("Tasks:");
  });

  it("shows total, ready, in-progress, completed counts", () => {
    const counts = { total: 10, ready: 3, backlog: 0, inProgress: 2, completed: 5, blocked: 0 };
    const result = renderLiveStatusHeader(counts);
    const plain = result.replace(/\x1b\[[0-9;]*m/g, "");
    expect(plain).toContain("total 10");
    expect(plain).toContain("ready 3");
    expect(plain).toContain("in-progress 2");
    expect(plain).toContain("completed 5");
  });

  it("shows blocked count only when > 0", () => {
    const withBlocked = { total: 5, ready: 2, backlog: 0, inProgress: 1, completed: 1, blocked: 1 };
    const withoutBlocked = { total: 5, ready: 2, backlog: 0, inProgress: 1, completed: 2, blocked: 0 };

    const resultWith = renderLiveStatusHeader(withBlocked).replace(/\x1b\[[0-9;]*m/g, "");
    const resultWithout = renderLiveStatusHeader(withoutBlocked).replace(/\x1b\[[0-9;]*m/g, "");

    expect(resultWith).toContain("blocked 1");
    expect(resultWithout).not.toContain("blocked");
  });

  it("renders as a single line (no newlines)", () => {
    const result = renderLiveStatusHeader(ZERO_COUNTS);
    expect(result).not.toContain("\n");
  });
});

// ── Tests: fetchDashboardTaskCounts() ───────────────────────────────────────

describe("fetchDashboardTaskCounts()", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    MockBeadsRustClient.mockImplementation(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
      this.list = mockBrList;
      this.ready = mockBrReady;
      this.listBacklog = vi.fn().mockResolvedValue([]);
      this.ensureBrInstalled = vi.fn().mockResolvedValue(undefined);
    });
    mockBrList.mockResolvedValue([]);
    mockBrReady.mockResolvedValue([]);
  });

  it("returns zero counts when br returns empty lists", async () => {
    const counts = await fetchDashboardTaskCounts("/mock/project");
    expect(counts).toEqual({ total: 0, ready: 0, backlog: 0, inProgress: 0, completed: 0, blocked: 0 });
  });

  it("correctly counts in-progress, ready, completed, and blocked issues", async () => {
    mockBrList.mockImplementation(async (opts?: { status?: string }) => {
      if (opts?.status === "closed") {
        return [
          { id: "c1", status: "closed", title: "Done 1" },
          { id: "c2", status: "closed", title: "Done 2" },
        ];
      }
      return [
        { id: "1", status: "in_progress", title: "Active task" },
        { id: "2", status: "open", title: "Ready task" },
        { id: "3", status: "open", title: "Blocked task" },
      ];
    });
    mockBrReady.mockResolvedValue([{ id: "2", status: "open", title: "Ready task" }]);

    const counts = await fetchDashboardTaskCounts("/mock/project");
    expect(counts.total).toBe(5);
    expect(counts.inProgress).toBe(1);
    expect(counts.backlog).toBe(0);
    expect(counts.ready).toBe(1);
    expect(counts.completed).toBe(2);
    expect(counts.blocked).toBe(1);

  });
  it("returns zeros when br.list() throws", async () => {
    mockBrList.mockRejectedValue(new Error("br not found"));
    const counts = await fetchDashboardTaskCounts("/mock/project");
    expect(counts).toEqual({ total: 0, ready: 0, backlog: 0, inProgress: 0, completed: 0, blocked: 0 });
  });

  it("handles br.ready() throwing gracefully", async () => {
    // Return 1 open issue, 0 closed
    mockBrList.mockImplementation(async (opts?: { status?: string }) => {
      if (opts?.status === "closed") return [];
      return [{ id: "1", status: "open", title: "Task" }];
    });
    mockBrReady.mockRejectedValue(new Error("ready failed"));
    const counts = await fetchDashboardTaskCounts("/mock/project");
    // Should still return counts (ready = 0 due to failure)
    expect(counts.total).toBe(1);
    expect(counts.ready).toBe(0);
  });
  it("reports backlog separately from blocked", async () => {
    const mockBacklog = vi.fn().mockResolvedValue([{ id: "1", status: "open", title: "Draft task" }]);
    MockBeadsRustClient.mockImplementation(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
      this.list = mockBrList;
      this.ready = mockBrReady;
      this.listBacklog = mockBacklog;
      this.ensureBrInstalled = vi.fn().mockResolvedValue(undefined);
    });
    mockBrList.mockImplementation(async (opts?: { status?: string }) => {
      if (opts?.status === "closed") return [];
      return [
        { id: "1", status: "open", title: "Draft task" },
        { id: "2", status: "open", title: "Blocked task" },
      ];
    });
    mockBrReady.mockResolvedValue([]);

    const counts = await fetchDashboardTaskCounts("/mock/project");
    expect(counts.backlog).toBe(1);
    expect(counts.blocked).toBe(1);
  });


});

// ── Tests: renderSimpleDashboard() ───────────────────────────────────────────

describe("renderSimpleDashboard()", () => {
  it("shows 'Foreman Status' header (not 'Foreman Dashboard')", () => {
    const state = makeDashboardState();
    const result = renderSimpleDashboard(state, ZERO_COUNTS);
    const plain = result.replace(/\x1b\[[0-9;]*m/g, "");
    expect(plain).toContain("Foreman Status");
    expect(plain).not.toContain("Foreman Dashboard");
  });

  it("shows task count section with all fields", () => {
    const counts: DashboardTaskCounts = { total: 8, ready: 3, backlog: 2, inProgress: 2, completed: 3, blocked: 0 };
    const state = makeDashboardState();
    const result = renderSimpleDashboard(state, counts);
    const plain = result.replace(/\x1b\[[0-9;]*m/g, "");
    expect(plain).toContain("Tasks");
    expect(plain).toContain("Total:");
    expect(plain).toContain("8");
    expect(plain).toContain("Ready:");
    expect(plain).toContain("3");
    expect(plain).toContain("Backlog:");
    expect(plain).toContain("2");
    expect(plain).toContain("In Progress:");
    expect(plain).toContain("2");
    expect(plain).toContain("Completed:");
  });

  it("shows blocked line only when blocked > 0", () => {
    const withBlocked: DashboardTaskCounts = { total: 5, ready: 1, backlog: 0, inProgress: 1, completed: 2, blocked: 1 };
    const noBlocked: DashboardTaskCounts = { total: 5, ready: 2, backlog: 0, inProgress: 1, completed: 2, blocked: 0 };

    const withResult = renderSimpleDashboard(makeDashboardState(), withBlocked)
      .replace(/\x1b\[[0-9;]*m/g, "");
    const noResult = renderSimpleDashboard(makeDashboardState(), noBlocked)
      .replace(/\x1b\[[0-9;]*m/g, "");

    expect(withResult).toContain("Blocked:");
    expect(noResult).not.toContain("Blocked:");
  });

  it("shows 'no projects registered' when project list is empty", () => {
    const state = makeDashboardState({ projects: [] });
    const result = renderSimpleDashboard(state, ZERO_COUNTS);
    const plain = result.replace(/\x1b\[[0-9;]*m/g, "");
    expect(plain).toContain("No projects registered");
  });

  it("shows '(no agents running)' when project has no active runs", () => {
    const state = makeDashboardState({
      projects: [MOCK_PROJECT],
      activeRuns: new Map([["proj-1", []]]),
      metrics: new Map([["proj-1", { totalCost: 0, totalTokens: 0, tasksByStatus: {}, costByRuntime: [] }]]),
    });
    const result = renderSimpleDashboard(state, ZERO_COUNTS, "proj-1");
    const plain = result.replace(/\x1b\[[0-9;]*m/g, "");
    expect(plain).toContain("no agents running");
  });

  it("does NOT show event timeline (unlike full dashboard)", () => {
    const state = makeDashboardState({
      projects: [MOCK_PROJECT],
      events: new Map([["proj-1", [
        { id: "e1", project_id: "proj-1", run_id: null, event_type: "complete" as const, details: null, created_at: "2026-01-01T10:00:00Z" },
      ]]]),
    });
    const result = renderSimpleDashboard(state, ZERO_COUNTS, "proj-1");
    const plain = result.replace(/\x1b\[[0-9;]*m/g, "");
    // Simple view should not show RECENT EVENTS section
    expect(plain).not.toContain("RECENT EVENTS");
  });

  it("shows cost section when totalCost > 0", () => {
    const state = makeDashboardState({
      projects: [MOCK_PROJECT],
      activeRuns: new Map([["proj-1", []]]),
      metrics: new Map([["proj-1", {
        totalCost: 2.50,
        totalTokens: 25000,
        tasksByStatus: {},
        costByRuntime: [],
      }]]),
    });
    const result = renderSimpleDashboard(state, ZERO_COUNTS, "proj-1");
    const plain = result.replace(/\x1b\[[0-9;]*m/g, "");
    expect(plain).toContain("Costs");
    expect(plain).toContain("$2.50");
    expect(plain).toContain("25.0k");
  });

  it("omits cost section when totalCost is 0", () => {
    const state = makeDashboardState({
      projects: [MOCK_PROJECT],
      activeRuns: new Map([["proj-1", []]]),
      metrics: new Map([["proj-1", { totalCost: 0, totalTokens: 0, tasksByStatus: {}, costByRuntime: [] }]]),
    });
    const result = renderSimpleDashboard(state, ZERO_COUNTS, "proj-1");
    const plain = result.replace(/\x1b\[[0-9;]*m/g, "");
    expect(plain).not.toContain("Costs");
  });

  it("shows tip suggesting 'foreman status --live'", () => {
    const state = makeDashboardState({ projects: [MOCK_PROJECT] });
    const result = renderSimpleDashboard(state, ZERO_COUNTS, "proj-1");
    const plain = result.replace(/\x1b\[[0-9;]*m/g, "");
    expect(plain).toContain("foreman status --live");
  });

  it("includes last-updated timestamp", () => {
    const state = makeDashboardState();
    const result = renderSimpleDashboard(state, ZERO_COUNTS);
    const plain = result.replace(/\x1b\[[0-9;]*m/g, "");
    expect(plain).toContain("Last updated:");
  });

  it("uses first project when no projectId is specified", () => {
    const projects = [
      { ...MOCK_PROJECT, id: "proj-1", name: "project-one" },
      { ...MOCK_PROJECT, id: "proj-2", name: "project-two" },
    ];
    const state = makeDashboardState({
      projects,
      activeRuns: new Map([["proj-1", []], ["proj-2", []]]),
      metrics: new Map([
        ["proj-1", { totalCost: 0, totalTokens: 0, tasksByStatus: {}, costByRuntime: [] }],
        ["proj-2", { totalCost: 0, totalTokens: 0, tasksByStatus: {}, costByRuntime: [] }],
      ]),
    });
    const result = renderSimpleDashboard(state, ZERO_COUNTS);
    // Should not throw and should show active agents for first project
    const plain = result.replace(/\x1b\[[0-9;]*m/g, "");
    expect(plain).toContain("Active Agents");
  });
});

// ── Tests: renderProjectHeader() (existing, regression) ─────────────────────

describe("renderProjectHeader() regression", () => {
  it("shows project name and path", () => {
    const metrics = { totalCost: 0, totalTokens: 0, tasksByStatus: {}, costByRuntime: [] };
    const result = renderProjectHeader(MOCK_PROJECT, 0, metrics);
    const plain = result.replace(/\x1b\[[0-9;]*m/g, "");
    expect(plain).toContain("test-project");
    expect(plain).toContain("/mock/project");
  });

  it("shows active agent count", () => {
    const metrics = { totalCost: 0, totalTokens: 0, tasksByStatus: {}, costByRuntime: [] };
    const result = renderProjectHeader(MOCK_PROJECT, 3, metrics);
    const plain = result.replace(/\x1b\[[0-9;]*m/g, "");
    expect(plain).toContain("3 active agents");
  });

  it("shows cost when non-zero", () => {
    const metrics = { totalCost: 1.25, totalTokens: 10000, tasksByStatus: {}, costByRuntime: [] };
    const result = renderProjectHeader(MOCK_PROJECT, 0, metrics);
    const plain = result.replace(/\x1b\[[0-9;]*m/g, "");
    expect(plain).toContain("$1.25");
  });
});

// ── Tests: renderEventLine() (existing, regression) ─────────────────────────

describe("renderEventLine() regression", () => {
  it("renders event type and age", () => {
    const event = {
      id: "e1",
      project_id: "proj-1",
      run_id: null,
      event_type: "complete" as const,
      details: null,
      created_at: new Date(Date.now() - 5 * 60 * 1000).toISOString(),
    };
    const result = renderEventLine(event);
    const plain = result.replace(/\x1b\[[0-9;]*m/g, "");
    expect(plain).toContain("complete");
    expect(plain).toContain("ago");
  });
});
