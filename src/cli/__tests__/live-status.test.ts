/**
 * Tests for the unified live monitoring features:
 *   - foreman status --live  (full dashboard TUI with br task counts)
 *   - renderLiveStatusHeader()  (task counts header for live mode)
 *   - dashboard-state render helpers shared with status --live / watch
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import * as dashboardModule from "../dashboard-state.js";
import type { ForemanStore } from "../../lib/store.js";

// ── Hoisted mocks ───────────────────────────────────────────────────────────
const {
  mockGetRepoRoot,
  mockCreateVcsBackend,
  mockBrList,
  mockBrReady,
  MockBeadsRustClient,
  mockGetProjectByPath,
  mockGetActiveRuns,
  mockGetRunsByStatus,
  mockGetMetrics,
  mockGetRunsByStatusSince,
  mockGetRunProgress,
  mockGetEvents,
  mockListProjects,
  mockHasNativeTasks,
  mockListTasksByStatus,
  MockForemanStore,
  mockPollDashboard,
  mockRenderDashboard,
  mockListRegisteredProjects,
  mockCreateTrpcClient,
  mockProjectsStats,
  mockProjectsListNeedsHuman,
  mockRunsListActive,
  mockElixirEnsureRunning,
} = vi.hoisted(() => {
  const mockGetRepoRoot = vi.fn().mockResolvedValue("/mock/project");
  const mockCreateVcsBackend = vi.fn().mockResolvedValue({
    name: "git",
    getRepoRoot: mockGetRepoRoot,
  });

  // BeadsRustClient mocks
  const mockBrList = vi.fn().mockResolvedValue([]);
  const mockBrReady = vi.fn().mockResolvedValue([]);
  const MockBeadsRustClient = vi.fn(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
    this.list = mockBrList;
    this.ready = mockBrReady;
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
  const mockHasNativeTasks = vi.fn().mockReturnValue(false);
  const mockListTasksByStatus = vi.fn().mockReturnValue([]);
  const MockForemanStore = vi.fn(function MockForemanStoreImpl(this: Record<string, unknown>) {
    this.getProjectByPath = mockGetProjectByPath;
    this.getActiveRuns = mockGetActiveRuns;
    this.getRunsByStatus = mockGetRunsByStatus;
    this.getMetrics = mockGetMetrics;
    this.getRunsByStatusSince = mockGetRunsByStatusSince;
    this.getRunProgress = mockGetRunProgress;
    this.getEvents = mockGetEvents;
    this.listProjects = mockListProjects;
    this.hasNativeTasks = mockHasNativeTasks;
    this.listTasksByStatus = mockListTasksByStatus;
    this.getProject = vi.fn().mockReturnValue(null);
    this.close = vi.fn();
  }) as ReturnType<typeof vi.fn>& { forProject: ReturnType<typeof vi.fn>; forDashboard: ReturnType<typeof vi.fn> };
  MockForemanStore.forProject = vi.fn((...args: unknown[]) => new MockForemanStore(...args));
  MockForemanStore.forDashboard = vi.fn((...args: unknown[]) => new MockForemanStore(...args));

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

  const mockListRegisteredProjects = vi.fn().mockResolvedValue([]);
  const mockProjectsStats = vi.fn();
  const mockProjectsListNeedsHuman = vi.fn();
  const mockRunsListActive = vi.fn();
  const mockElixirEnsureRunning = vi.fn().mockRejectedValue(new Error("Elixir unavailable"));
  const mockCreateTrpcClient = vi.fn(() => ({
    projects: {
      stats: mockProjectsStats,
      listNeedsHuman: mockProjectsListNeedsHuman,
    },
    tasks: {
      list: vi.fn().mockResolvedValue([]),
    },
    runs: {
      listActive: mockRunsListActive,
      listMessages: vi.fn().mockResolvedValue([]),
    },
  }));

  return {
    mockGetRepoRoot,
    mockCreateVcsBackend,
    mockBrList,
    mockBrReady,
    MockBeadsRustClient,
    mockGetProjectByPath,
    mockGetActiveRuns,
    mockGetRunsByStatus,
    mockGetMetrics,
    mockGetRunsByStatusSince,
    mockGetRunProgress,
    mockGetEvents,
    mockListProjects,
    mockHasNativeTasks,
    mockListTasksByStatus,
    MockForemanStore,
    mockPollDashboard,
    mockRenderDashboard,
    mockListRegisteredProjects,
    mockCreateTrpcClient,
    mockProjectsStats,
    mockProjectsListNeedsHuman,
    mockRunsListActive,
    mockElixirEnsureRunning,
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

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: mockCreateTrpcClient,
}));

vi.mock("../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: class {
    authToken = "secret";
    ensureRunning = mockElixirEnsureRunning;
  },
}));

vi.mock("../commands/project-task-support.js", () => ({
  listRegisteredProjects: mockListRegisteredProjects,
  requireProjectOrAllInMultiMode: vi.fn().mockResolvedValue(undefined),
  resolveRepoRootProjectPath: vi.fn().mockResolvedValue("/mock/project"),
}));

vi.mock("../watch-ui.js", () => ({
  renderAgentCard: vi.fn().mockReturnValue("  ● seed-1 RUNNING"),
  formatSuccessRate: vi.fn().mockReturnValue("--"),
  elapsed: vi.fn().mockReturnValue("5m 30s"),
}));

vi.mock("../../lib/feature-flags.js", () => ({
  getTaskBackend: vi.fn().mockReturnValue("br"),
}));

// ── process.exit mock ────────────────────────────────────────────────────────
let exitSpy: ReturnType<typeof vi.spyOn>;
const originalBackend = process.env.FOREMAN_BACKEND;
beforeEach(() => {
  process.env.FOREMAN_BACKEND = "node";
  exitSpy = vi.spyOn(process, "exit").mockImplementation((code?: number | string | null | undefined) => {
    throw new Error(`process.exit(${code ?? ""}) called`);
  });
});
afterEach(() => {
  if (originalBackend === undefined) delete process.env.FOREMAN_BACKEND;
  else process.env.FOREMAN_BACKEND = originalBackend;
  exitSpy.mockRestore();
});

// ── Imports ─────────────────────────────────────────────────────────────────
import { renderLiveStatusHeader, type StatusCounts } from "../commands/status.js";
import { fetchDaemonStatusSnapshot, fetchStatusCounts } from "../commands/status.js";
import { statusCommand } from "../commands/status.js";
import {
  renderProjectHeader,
  renderEventLine,
  type DashboardState,
} from "../dashboard-state.js";
import { pollWatchData, pollInboxData } from "../commands/watch/WatchState.js";

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

const ZERO_COUNTS: StatusCounts = {
  total: 0, ready: 0, inProgress: 0, completed: 0, blocked: 0,
};

// ── Tests: daemon-backed status helpers ────────────────────────────────────

describe("daemon-backed status helpers", () => {
  beforeEach(() => {
    vi.clearAllMocks();

    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "test-project", path: "/mock/project/./" },
    ]);
    mockProjectsStats.mockResolvedValue({
      tasks: {
        backlog: 2,
        ready: 3,
        inProgress: 4,
        approved: 0,
        merged: 5,
        closed: 6,
        total: 20,
      },
      runs: { active: 1, pending: 0 },
    });
    mockProjectsListNeedsHuman.mockResolvedValue([{ status: "failed" }, { status: "stuck" }]);
    mockRunsListActive.mockResolvedValue([
      {
        id: "run-1",
        bead_id: "seed-1",
        status: "running",
        branch: "foreman/seed-1",
        started_at: "2026-01-01T10:00:00Z",
        queued_at: "2026-01-01T09:50:00Z",
        created_at: "2026-01-01T09:45:00Z",
      },
    ]);

    mockBrList.mockResolvedValue([]);
    mockBrReady.mockResolvedValue([]);
    mockHasNativeTasks.mockReturnValue(false);
    mockListTasksByStatus.mockReturnValue([]);
  });

  it("fetchDaemonStatusSnapshot() matches registered projects by normalized path", async () => {
    const snapshot = await fetchDaemonStatusSnapshot("/mock/project/../project");

    expect(snapshot).not.toBeNull();
    expect(snapshot?.projectId).toBe("proj-1");
    expect(snapshot?.counts).toEqual({
      total: 20,
      ready: 3,
      inProgress: 4,
      completed: 11,
      blocked: 2,
    });
    expect(mockCreateTrpcClient).toHaveBeenCalledTimes(1);
    expect(mockProjectsStats).toHaveBeenCalledWith({ projectId: "proj-1" });
  });

  it("fetchStatusCounts() matches registered projects by normalized path", async () => {
    const counts = await fetchStatusCounts("/mock/project/../project");

    expect(counts).toEqual({
      total: 20,
      ready: 3,
      inProgress: 4,
      completed: 11,
      blocked: 2,
    });
    expect(mockCreateTrpcClient).toHaveBeenCalledTimes(1);
    expect(mockProjectsStats).toHaveBeenCalledWith({ projectId: "proj-1" });
  });

  it("keeps the local fallback when no registered project matches", async () => {
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "test-project", path: "/mock/project" },
    ]);
    mockHasNativeTasks.mockReturnValue(true);
    mockListTasksByStatus.mockImplementation((statuses: string[]) => {
      const rows = [{ id: "1", status: "blocked", title: "Task" }];
      return rows.filter((row) => statuses.includes(row.status));
    });

    const counts = await fetchStatusCounts("/unregistered/project");

    expect(counts).toEqual({
      total: 1,
      ready: 0,
      inProgress: 0,
      completed: 0,
      blocked: 1,
    });
    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(mockProjectsStats).not.toHaveBeenCalled();
  });

  it("prefers daemon-backed dashboard state in --live mode", async () => {
    const daemonState = makeDashboardState({ projects: [MOCK_PROJECT] });
    const daemonSpy = vi.spyOn(dashboardModule, "fetchDaemonDashboardState").mockResolvedValue(daemonState);
    const pollSpy = vi.spyOn(dashboardModule, "pollDashboard");
    const renderSpy = vi.spyOn(dashboardModule, "renderDashboard").mockImplementationOnce(() => {
      throw new Error("stop-live-loop");
    });

    try {
      await expect(
        statusCommand.parseAsync(["node", "foreman", "--live", "--project-path", "/mock/project"], { from: "node" }),
      ).rejects.toThrow("stop-live-loop");

      expect(pollSpy).not.toHaveBeenCalled();
      expect(MockForemanStore.forProject).not.toHaveBeenCalled();
      expect(renderSpy).toHaveBeenCalledWith(daemonState);
    } finally {
      renderSpy.mockRestore();
      pollSpy.mockRestore();
      daemonSpy.mockRestore();
    }
  });

  it("falls back to pollDashboard() when the daemon snapshot is null", async () => {
    const localState = makeDashboardState({ projects: [MOCK_PROJECT] });
    const daemonSpy = vi.spyOn(dashboardModule, "fetchDaemonDashboardState").mockResolvedValue(null);
    const pollSpy = vi.spyOn(dashboardModule, "pollDashboard").mockReturnValue(localState);
    const renderSpy = vi.spyOn(dashboardModule, "renderDashboard").mockImplementationOnce(() => {
      throw new Error("stop-live-loop");
    });

    try {
      await expect(
        statusCommand.parseAsync(["node", "foreman", "--live", "--project-path", "/mock/project"], { from: "node" }),
      ).rejects.toThrow("stop-live-loop");

      expect(MockForemanStore.forDashboard).toHaveBeenCalledWith("/mock/project");
      expect(pollSpy).toHaveBeenCalledTimes(1);
      expect(renderSpy).toHaveBeenCalledWith(localState);
    } finally {
      renderSpy.mockRestore();
      pollSpy.mockRestore();
      daemonSpy.mockRestore();
    }
  });
});

// ── Tests: renderLiveStatusHeader() ─────────────────────────────────────────

describe("renderLiveStatusHeader()", () => {
  it("includes 'Tasks:' label", () => {
    const result = renderLiveStatusHeader(ZERO_COUNTS);
    expect(result).toContain("Tasks:");
  });

  it("shows total, ready, in-progress, completed counts", () => {
    const counts = { total: 10, ready: 3, inProgress: 2, completed: 5, blocked: 0 };
    const result = renderLiveStatusHeader(counts);
    // The output contains ANSI escape codes so we strip them for assertion
    const plain = result.replace(/\x1b\[[0-9;]*m/g, "");
    expect(plain).toContain("total 10");
    expect(plain).toContain("ready 3");
    expect(plain).toContain("in-progress 2");
    expect(plain).toContain("completed 5");
  });

  it("shows blocked count only when > 0", () => {
    const withBlocked = { total: 5, ready: 2, inProgress: 1, completed: 1, blocked: 1 };
    const withoutBlocked = { total: 5, ready: 2, inProgress: 1, completed: 2, blocked: 0 };

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

describe("watch-state path normalization", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockCreateTrpcClient.mockReset();
    mockProjectsStats.mockReset();
    mockRunsListActive.mockReset();
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: "/mock/project/./" },
    ]);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("pollWatchData() matches the board summary on a normalized project path", async () => {
    const tasksList = vi.fn().mockResolvedValue([
      { id: "task-1", status: "backlog", priority: 1 },
    ]);
    mockCreateTrpcClient.mockReturnValue({
      tasks: { list: tasksList },
      projects: { stats: mockProjectsStats, listNeedsHuman: mockProjectsListNeedsHuman },
      runs: { listActive: mockRunsListActive, listMessages: vi.fn().mockResolvedValue([]) },
    });
    mockProjectsStats.mockResolvedValue({
      tasks: {
        backlog: 2,
        ready: 3,
        inProgress: 4,
        approved: 0,
        merged: 5,
        closed: 6,
        total: 20,
      },
      runs: { active: 1, pending: 0 },
    });
    vi.spyOn(dashboardModule, "fetchDaemonDashboardState").mockResolvedValue(makeDashboardState({
      projects: [MOCK_PROJECT],
    }));

    const state = await pollWatchData("/mock/project/../project");

    expect(tasksList).toHaveBeenCalledWith({ projectId: "proj-1", limit: 1000 });
    expect(mockProjectsStats).toHaveBeenCalledWith({ projectId: "proj-1" });
    expect(state.board.total).toBe(1);
  });

  it("pollInboxData() matches a normalized project path and preserves explicit project selection", async () => {
    const listMessages = vi.fn().mockResolvedValue([
      { id: "msg-1", run_id: "run-1", step_key: null, stream: "agent", chunk: "hello", created_at: "2026-01-01T10:00:00Z" },
    ]);
    mockCreateTrpcClient.mockReturnValue({
      tasks: { list: vi.fn() },
      projects: { stats: mockProjectsStats, listNeedsHuman: mockProjectsListNeedsHuman },
      runs: { listActive: mockRunsListActive, listMessages },
    });

    const store = {
      getAllMessages: vi.fn().mockReturnValue([]),
    } as unknown as ForemanStore;

    const normalized = await pollInboxData(store, null, 5, ["run-1"], "/mock/project/../project");
    const explicit = await pollInboxData(store, null, 5, ["run-1"], "/different/path", "registered-project");

    expect(listMessages).toHaveBeenCalledTimes(2);
    expect(normalized.messages).toHaveLength(1);
    expect(explicit.messages).toHaveLength(1);
  });

  it("keeps local fallback behavior unchanged when no registered project matches", async () => {
    mockListRegisteredProjects.mockResolvedValue([]);
    const store = {
      getAllMessages: vi.fn().mockReturnValue([
        { id: "msg-1", run_id: "run-1", sender_agent_type: "agent", recipient_agent_type: "run", subject: "hello", body: "hello", read: 0, created_at: "2026-01-01T10:00:00Z", deleted_at: null },
      ]),
    } as unknown as ForemanStore;

    const result = await pollInboxData(store, null, 5, ["run-1"], "/unregistered/project");

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(store.getAllMessages).toHaveBeenCalledWith("run-1");
    expect(result.messages).toHaveLength(1);
  });
});
