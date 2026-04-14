/**
 * Tests for TRD-019: status.ts backend selection based on FOREMAN_TASK_BACKEND.
 *
 * Verifies:
 * - When FOREMAN_TASK_BACKEND='br': BeadsRustClient is used for task listing
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// ── Hoisted mocks ──────────────────────────────────────────────────────────
const {
  mockGetTaskBackend,
  mockBrList,
  mockBrReady,
  MockBeadsRustClient,
  mockExecFileSync,
  mockHasNativeTasks,
  mockListTasksByStatus,
} = vi.hoisted(() => {
  const mockGetTaskBackend = vi.fn().mockReturnValue("br");
  const mockBrList = vi.fn().mockResolvedValue([]);
  const mockBrReady = vi.fn().mockResolvedValue([]);
  const mockHasNativeTasks = vi.fn().mockReturnValue(false);
  const mockListTasksByStatus = vi.fn().mockReturnValue([]);
  const MockBeadsRustClient = vi.fn(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
    this.list = mockBrList;
    this.ready = mockBrReady;
  });
  const mockExecFileSync = vi.fn().mockReturnValue(JSON.stringify([]));
  return {
    mockGetTaskBackend,
    mockBrList,
    mockBrReady,
    MockBeadsRustClient,
    mockExecFileSync,
    mockHasNativeTasks,
    mockListTasksByStatus,
  };
});

vi.mock("../../lib/feature-flags.js", () => ({
  getTaskBackend: () => mockGetTaskBackend(),
}));

vi.mock("../../lib/beads-rust.js", () => ({
  BeadsRustClient: MockBeadsRustClient,
}));

vi.mock("node:child_process", () => ({
  execFileSync: mockExecFileSync,
  execFile: vi.fn(),
}));

vi.mock("../../lib/store.js", () => {
  const Ctor = vi.fn(function MockForemanStore(this: Record<string, unknown>) {
    this.getProjectByPath = vi.fn().mockReturnValue(null);
    this.getActiveRuns = vi.fn().mockReturnValue([]);
    this.getMetrics = vi.fn().mockReturnValue({ totalCost: 0, totalTokens: 0 });
    this.getRunsByStatusSince = vi.fn().mockReturnValue([]);
    this.hasNativeTasks = mockHasNativeTasks;
    this.listTasksByStatus = mockListTasksByStatus;
    this.close = vi.fn();
  });
  (Ctor as any).forProject = vi.fn((...args: unknown[]) => new (Ctor as any)(...args));
  return { ForemanStore: Ctor };
});

// Import after mocks are set up
import { getStatusBackend } from "../commands/status.js";

// ── Tests ──────────────────────────────────────────────────────────────────

describe("TRD-019: status.ts backend selection via FOREMAN_TASK_BACKEND", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // Restore BeadsRustClient constructor implementation
    MockBeadsRustClient.mockImplementation(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
      this.list = mockBrList;
      this.ready = mockBrReady;
    });
    // Default list returns empty arrays
    mockBrList.mockResolvedValue([]);
    mockBrReady.mockResolvedValue([]);
    mockExecFileSync.mockReturnValue(JSON.stringify([]));
    mockHasNativeTasks.mockReturnValue(false);
    mockListTasksByStatus.mockReturnValue([]);
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  // ── br backend ────────────────────────────────────────────────────────────

  describe("when FOREMAN_TASK_BACKEND='br'", () => {
    beforeEach(() => {
      mockGetTaskBackend.mockReturnValue("br");
    });

    it("returns 'br' from getStatusBackend()", () => {
      const backend = getStatusBackend();
      expect(backend).toBe("br");
    });

  });

});

// ── fetchStatusCounts tests ────────────────────────────────────────────────

import { fetchStatusCounts } from "../commands/status.js";

describe("TRD-019: fetchStatusCounts uses correct backend", () => {
  const PROJECT_PATH = "/mock/project";

  beforeEach(() => {
    vi.clearAllMocks();
    MockBeadsRustClient.mockImplementation(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
      this.list = mockBrList;
      this.ready = mockBrReady;
    });
    mockBrList.mockResolvedValue([]);
    mockBrReady.mockResolvedValue([]);
    mockExecFileSync.mockReturnValue(JSON.stringify([]));
    mockHasNativeTasks.mockReturnValue(false);
    mockListTasksByStatus.mockReturnValue([]);
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  describe("when FOREMAN_TASK_BACKEND='br'", () => {
    beforeEach(() => {
      mockGetTaskBackend.mockReturnValue("br");
    });

    it("instantiates BeadsRustClient with the project path", async () => {
      await fetchStatusCounts(PROJECT_PATH);
      expect(MockBeadsRustClient).toHaveBeenCalledWith(PROJECT_PATH);
    });

    it("calls brClient.list() to fetch open issues", async () => {
      await fetchStatusCounts(PROJECT_PATH);
      expect(mockBrList).toHaveBeenCalled();
    });

    it("calls brClient.ready() to fetch ready count", async () => {
      await fetchStatusCounts(PROJECT_PATH);
      expect(mockBrReady).toHaveBeenCalled();
    });

    it("returns correct in_progress count from br backend", async () => {
      mockBrList.mockResolvedValue([
        { id: "1", status: "in_progress", title: "Task A" },
        { id: "2", status: "open", title: "Task B" },
        { id: "3", status: "in_progress", title: "Task C" },
      ]);
      mockBrReady.mockResolvedValue([{ id: "2", status: "open" }]);

      const counts = await fetchStatusCounts(PROJECT_PATH);

      expect(counts.inProgress).toBe(2);
    });

    it("returns correct ready count from br backend", async () => {
      mockBrList.mockResolvedValue([{ id: "1", status: "open", title: "Task A" }]);
      mockBrReady.mockResolvedValue([
        { id: "1", status: "open" },
        { id: "2", status: "open" },
      ]);

      const counts = await fetchStatusCounts(PROJECT_PATH);

      expect(counts.ready).toBe(2);
    });

    it("counts closed issues from br closed list", async () => {
      // list() without status filter returns open issues
      mockBrList.mockImplementation(async (opts?: { status?: string }) => {
        if (opts?.status === "closed") {
          return [
            { id: "99", status: "closed", title: "Done" },
            { id: "100", status: "closed", title: "Done 2" },
          ];
        }
        return [{ id: "1", status: "open", title: "Active" }];
      });
      mockBrReady.mockResolvedValue([]);

      const counts = await fetchStatusCounts(PROJECT_PATH);

      expect(counts.completed).toBe(2);
    });

    it("does not call execFileSync (sd binary) for br backend", async () => {
      await fetchStatusCounts(PROJECT_PATH);
      expect(mockExecFileSync).not.toHaveBeenCalled();
    });
  });

  describe("when native tasks exist", () => {
    beforeEach(() => {
      mockHasNativeTasks.mockReturnValue(true);
      mockListTasksByStatus.mockImplementation((statuses: string[]) => {
        const rows = [
          { id: "b1", status: "backlog" },
          { id: "r1", status: "ready" },
          { id: "p1", status: "in-progress" },
          { id: "m1", status: "merged" },
          { id: "c1", status: "closed" },
          { id: "x1", status: "blocked" },
          { id: "f1", status: "failed" },
        ];
        return rows.filter((row) => statuses.includes(row.status));
      });
    });

    it("uses native task counts instead of br reads", async () => {
      const counts = await fetchStatusCounts(PROJECT_PATH);

      expect(counts).toEqual({
        total: 7,
        ready: 1,
        inProgress: 1,
        completed: 2,
        blocked: 3,
      });
      expect(MockBeadsRustClient).not.toHaveBeenCalled();
      expect(mockBrList).not.toHaveBeenCalled();
      expect(mockBrReady).not.toHaveBeenCalled();
    });
  });

});
