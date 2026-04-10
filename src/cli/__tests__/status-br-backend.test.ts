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
  mockBrListBacklog,
  MockBeadsRustClient,
  mockExecFileSync,
} = vi.hoisted(() => {
  const mockGetTaskBackend = vi.fn().mockReturnValue("br");
  const mockBrList = vi.fn().mockResolvedValue([]);
  const mockBrReady = vi.fn().mockResolvedValue([]);
  const mockBrListBacklog = vi.fn().mockResolvedValue([]);
  const MockBeadsRustClient = vi.fn(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
    this.list = mockBrList;
    this.ready = mockBrReady;
    this.listBacklog = mockBrListBacklog;
  });
  const mockExecFileSync = vi.fn().mockReturnValue(JSON.stringify([]));
  return {
    mockGetTaskBackend,
    mockBrList,
    mockBrReady,
    mockBrListBacklog,
    MockBeadsRustClient,
    mockExecFileSync,
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
      this.listBacklog = mockBrListBacklog;
    });
    // Default list returns empty arrays
    mockBrList.mockResolvedValue([]);
    mockBrReady.mockResolvedValue([]);
    mockBrListBacklog.mockResolvedValue([]);
    mockExecFileSync.mockReturnValue(JSON.stringify([]));
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


import { fetchStatusCounts, fetchStatusQueueSummary } from "../commands/status.js";

describe("TRD-019: fetchStatusCounts uses correct backend", () => {
  const PROJECT_PATH = "/mock/project";

  beforeEach(() => {
    vi.clearAllMocks();
    MockBeadsRustClient.mockImplementation(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
      this.list = mockBrList;
      this.ready = mockBrReady;
      this.listBacklog = mockBrListBacklog;
    });
    mockBrList.mockResolvedValue([]);
    mockBrReady.mockResolvedValue([]);
    mockBrListBacklog.mockResolvedValue([]);
    mockExecFileSync.mockReturnValue(JSON.stringify([]));
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

    it("reports backlog separately from blocked", async () => {
      mockBrList.mockResolvedValue([
        { id: "1", status: "open", title: "Draft bead" },
        { id: "2", status: "open", title: "Blocked bead" },
      ]);
      mockBrReady.mockResolvedValue([]);
      mockBrListBacklog.mockResolvedValue([{ id: "1", status: "open", title: "Draft bead" }]);

      const counts = await fetchStatusCounts(PROJECT_PATH);
      expect(counts.backlog).toBe(1);
      expect(counts.blocked).toBe(1);
    });


    it("does not call execFileSync (sd binary) for br backend", async () => {
      await fetchStatusCounts(PROJECT_PATH);
      expect(mockExecFileSync).not.toHaveBeenCalled();
    });
  });


describe("fetchStatusQueueSummary", () => {
  const PROJECT_PATH = "/mock/project";

  beforeEach(() => {
    vi.clearAllMocks();
    MockBeadsRustClient.mockImplementation(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
      this.list = mockBrList;
      this.ready = mockBrReady;
      this.listBacklog = mockBrListBacklog;
    });
    mockBrList.mockResolvedValue([]);
    mockBrReady.mockResolvedValue([]);
    mockBrListBacklog.mockResolvedValue([]);
  });

  it("returns backlog and blocked items separately", async () => {
    mockBrList.mockResolvedValue([
      { id: "1", title: "Draft bead", type: "task", priority: "P1", status: "open", assignee: null, parent: null, created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z" },
      { id: "2", title: "Blocked bead", type: "task", priority: "P0", status: "open", assignee: null, parent: null, created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-02T00:00:00Z" },
      { id: "3", title: "Running bead", type: "task", priority: "P2", status: "in_progress", assignee: null, parent: null, created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-03T00:00:00Z" },
    ]);
    mockBrReady.mockResolvedValue([]);
    mockBrListBacklog.mockResolvedValue([
      { id: "1", title: "Draft bead", type: "task", priority: "P1", status: "open", assignee: null, parent: null, created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z" },
    ]);

    const summary = await fetchStatusQueueSummary(PROJECT_PATH);
    expect(summary.backlog.map((item) => item.id)).toEqual(["1"]);
    expect(summary.blocked.map((item) => item.id)).toEqual(["2"]);
    expect(summary.warnings).toEqual([]);
  });

  it("accepts numeric priorities when building queue summaries", async () => {
    mockBrList.mockResolvedValue([
      { id: "1", title: "Numeric backlog", type: "task", priority: 2, status: "open", assignee: null, parent: null, created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z" },
      { id: "2", title: "Numeric blocked", type: "task", priority: 0, status: "open", assignee: null, parent: null, created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-02T00:00:00Z" },
    ]);
    mockBrReady.mockResolvedValue([]);
    mockBrListBacklog.mockResolvedValue([
      { id: "1", title: "Numeric backlog", type: "task", priority: 2, status: "open", assignee: null, parent: null, created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z" },
    ]);

    const summary = await fetchStatusQueueSummary(PROJECT_PATH);
    expect(summary.backlog.map((item) => item.priority)).toEqual(["P2"]);
    expect(summary.blocked.map((item) => item.priority)).toEqual(["P0"]);
    expect(summary.warnings).toEqual([]);
  });


  it("surfaces backlog fetch failures as warnings", async () => {
    mockBrList.mockResolvedValue([]);
    mockBrReady.mockResolvedValue([]);
    mockBrListBacklog.mockRejectedValue(new Error("br backlog failed"));

    const summary = await fetchStatusQueueSummary(PROJECT_PATH);
    expect(summary.backlog).toEqual([]);
    expect(summary.blocked).toEqual([]);
    expect(summary.warnings).toContain("backlog queue unavailable: br backlog failed");
  });
});
});
