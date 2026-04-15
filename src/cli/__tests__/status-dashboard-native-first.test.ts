import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockBrList,
  mockBrReady,
  mockListTasksByStatus,
  mockHasNativeTasks,
  MockBeadsRustClient,
  mockForProject,
} = vi.hoisted(() => {
  const mockBrList = vi.fn().mockResolvedValue([]);
  const mockBrReady = vi.fn().mockResolvedValue([]);
  const mockListTasksByStatus = vi.fn();
  const mockHasNativeTasks = vi.fn().mockReturnValue(false);
  const MockBeadsRustClient = vi.fn(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
    this.list = mockBrList;
    this.ready = mockBrReady;
  });
  const mockForProject = vi.fn(() => ({
    close: vi.fn(),
    getDb: vi.fn(),
    getTaskStore: vi.fn(() => ({
      hasNativeTasks: mockHasNativeTasks,
      listTasksByStatus: mockListTasksByStatus,
    })),
    taskStore: {
      hasNativeTasks: mockHasNativeTasks,
      listTasksByStatus: mockListTasksByStatus,
    },
    hasNativeTasks: mockHasNativeTasks,
    listTasksByStatus: mockListTasksByStatus,
  }));

  return {
    mockBrList,
    mockBrReady,
    mockListTasksByStatus,
    mockHasNativeTasks,
    MockBeadsRustClient,
    mockForProject,
  };
});

vi.mock("../../lib/beads-rust.js", () => ({
  BeadsRustClient: MockBeadsRustClient,
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: {
    forProject: mockForProject,
  },
}));

import { fetchDashboardTaskCounts } from "../commands/dashboard.js";
import { fetchStatusCounts } from "../commands/status.js";

describe("native-first task count regression targets", () => {
  const projectPath = "/mock/project";

  beforeEach(() => {
    vi.clearAllMocks();
    mockBrList.mockResolvedValue([]);
    mockBrReady.mockResolvedValue([]);
    mockHasNativeTasks.mockReturnValue(false);
    mockListTasksByStatus.mockReset();
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("status native mode reads counts from the native task store without calling br", async () => {
    vi.stubEnv("FOREMAN_TASK_STORE", "native");
    mockHasNativeTasks.mockReturnValue(true);
    mockListTasksByStatus.mockImplementation((statuses: string[]) => {
      if (
        statuses.includes("ready")
        && statuses.includes("in-progress")
        && statuses.includes("closed")
        && statuses.includes("blocked")
      ) {
        return [
          { id: "t-ready", status: "ready" },
          { id: "t-running", status: "in-progress" },
          { id: "t-done", status: "closed" },
          { id: "t-blocked", status: "blocked" },
          { id: "t-backlog", status: "backlog" },
        ];
      }
      if (statuses.includes("ready")) return [{ id: "t-ready" }];
      if (statuses.includes("in-progress")) return [{ id: "t-running" }];
      if (statuses.includes("closed") || statuses.includes("merged")) return [{ id: "t-done" }];
      if (statuses.includes("blocked") || statuses.includes("backlog")) return [{ id: "t-blocked" }, { id: "t-backlog" }];
      return [];
    });

    const counts = await fetchStatusCounts(projectPath);

    expect(counts).toEqual({
      total: 5,
      ready: 1,
      inProgress: 1,
      completed: 1,
      blocked: 2,
    });
    expect(mockBrList).not.toHaveBeenCalled();
    expect(mockBrReady).not.toHaveBeenCalled();
  });

  it("status auto mode falls back to br when no native tasks exist", async () => {
    vi.stubEnv("FOREMAN_TASK_STORE", "auto");
    mockHasNativeTasks.mockReturnValue(false);
    mockBrList.mockImplementation(async (opts?: { status?: string }) => {
      if (opts?.status === "closed") return [{ id: "closed-1", status: "closed" }];
      return [{ id: "open-1", status: "open" }, { id: "run-1", status: "in_progress" }];
    });
    mockBrReady.mockResolvedValue([{ id: "open-1", status: "open" }]);

    const counts = await fetchStatusCounts(projectPath);

    expect(counts).toEqual({
      total: 3,
      ready: 1,
      inProgress: 1,
      completed: 1,
      blocked: 0,
    });
    expect(mockBrList).toHaveBeenCalled();
  });

  it("dashboard native mode reads compact counts from the native task store before br fallback", async () => {
    vi.stubEnv("FOREMAN_TASK_STORE", "native");
    mockHasNativeTasks.mockReturnValue(true);
    mockListTasksByStatus.mockImplementation((statuses: string[]) => {
      if (
        statuses.includes("ready")
        && statuses.includes("in-progress")
        && statuses.includes("closed")
        && statuses.includes("blocked")
      ) {
        return [
          { id: "t-ready", status: "ready" },
          { id: "t-ready-2", status: "ready" },
          { id: "t-running", status: "in-progress" },
          { id: "t-done", status: "closed" },
          { id: "t-blocked", status: "blocked" },
        ];
      }
      if (statuses.includes("ready")) return [{ id: "t-ready" }, { id: "t-ready-2" }];
      if (statuses.includes("in-progress")) return [{ id: "t-running" }];
      if (statuses.includes("closed") || statuses.includes("merged")) return [{ id: "t-done" }];
      if (statuses.includes("blocked") || statuses.includes("backlog")) return [{ id: "t-blocked" }];
      return [];
    });

    const counts = await fetchDashboardTaskCounts(projectPath);

    expect(counts).toEqual({
      total: 5,
      ready: 2,
      inProgress: 1,
      completed: 1,
      blocked: 1,
    });
    expect(mockBrList).not.toHaveBeenCalled();
    expect(mockBrReady).not.toHaveBeenCalled();
  });
});
