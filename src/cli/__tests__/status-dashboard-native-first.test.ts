/**
 * Characterization tests for native task store counts in status.
 *
 * These tests document that the status command reads task counts exclusively
 * from the native Postgres task store. Beads fallback has been removed; the
 * native store is the only supported source.
 */
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

import { fetchStatusCounts } from "../commands/status.js";

describe("native task store counts (characterization)", () => {
  const projectPath = "/mock/project";

  beforeEach(() => {
    vi.stubEnv("FOREMAN_BACKEND", "node");
    vi.clearAllMocks();
    mockBrList.mockResolvedValue([]);
    mockBrReady.mockResolvedValue([]);
    mockHasNativeTasks.mockReturnValue(false);
    mockListTasksByStatus.mockReset();
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("status reads counts from the native task store without calling br", async () => {
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

  it("returns zero counts when native task store reports no tasks", async () => {
    mockHasNativeTasks.mockReturnValue(false);

    const counts = await fetchStatusCounts(projectPath);

    expect(counts).toEqual({
      total: 0,
      ready: 0,
      inProgress: 0,
      completed: 0,
      blocked: 0,
    });
    expect(mockBrList).not.toHaveBeenCalled();
  });

});
