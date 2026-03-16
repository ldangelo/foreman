/**
 * Tests for TRD-019: status.ts backend selection based on FOREMAN_TASK_BACKEND.
 *
 * Verifies:
 * - When FOREMAN_TASK_BACKEND='br': BeadsRustClient is used for task listing
 * - When FOREMAN_TASK_BACKEND='sd': SeedsClient / sd CLI is used (existing behavior)
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// ── Hoisted mocks ──────────────────────────────────────────────────────────
const {
  mockGetTaskBackend,
  mockBrList,
  mockBrReady,
  MockBeadsRustClient,
  MockSeedsClient,
  mockExecFileSync,
} = vi.hoisted(() => {
  const mockGetTaskBackend = vi.fn().mockReturnValue("sd");
  const mockBrList = vi.fn().mockResolvedValue([]);
  const mockBrReady = vi.fn().mockResolvedValue([]);
  const MockBeadsRustClient = vi.fn(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
    this.list = mockBrList;
    this.ready = mockBrReady;
  });
  const MockSeedsClient = vi.fn();
  const mockExecFileSync = vi.fn().mockReturnValue(JSON.stringify([]));
  return {
    mockGetTaskBackend,
    mockBrList,
    mockBrReady,
    MockBeadsRustClient,
    MockSeedsClient,
    mockExecFileSync,
  };
});

vi.mock("../../lib/feature-flags.js", () => ({
  getTaskBackend: () => mockGetTaskBackend(),
}));

vi.mock("../../lib/beads-rust.js", () => ({
  BeadsRustClient: MockBeadsRustClient,
}));

vi.mock("../../lib/seeds.js", () => ({
  SeedsClient: MockSeedsClient,
}));

vi.mock("node:child_process", () => ({
  execFileSync: mockExecFileSync,
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: vi.fn(function MockForemanStore(this: Record<string, unknown>) {
    this.getProjectByPath = vi.fn().mockReturnValue(null);
    this.getActiveRuns = vi.fn().mockReturnValue([]);
    this.getMetrics = vi.fn().mockReturnValue({ totalCost: 0, totalTokens: 0 });
    this.getRunsByStatusSince = vi.fn().mockReturnValue([]);
    this.close = vi.fn();
  }),
}));

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
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  // ── sd backend ────────────────────────────────────────────────────────────

  describe("when FOREMAN_TASK_BACKEND='sd'", () => {
    beforeEach(() => {
      mockGetTaskBackend.mockReturnValue("sd");
    });

    it("returns 'sd' from getStatusBackend()", () => {
      const backend = getStatusBackend();
      expect(backend).toBe("sd");
    });

    it("does not instantiate BeadsRustClient for sd backend", () => {
      getStatusBackend();
      expect(MockBeadsRustClient).not.toHaveBeenCalled();
    });
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

    it("does not instantiate SeedsClient for br backend", () => {
      getStatusBackend();
      expect(MockSeedsClient).not.toHaveBeenCalled();
    });
  });

  // ── default backend ────────────────────────────────────────────────────────

  describe("when FOREMAN_TASK_BACKEND is unset (defaults to sd)", () => {
    beforeEach(() => {
      mockGetTaskBackend.mockReturnValue("sd");
    });

    it("getStatusBackend() returns 'sd' as default", () => {
      const backend = getStatusBackend();
      expect(backend).toBe("sd");
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

  describe("when FOREMAN_TASK_BACKEND='sd'", () => {
    beforeEach(() => {
      mockGetTaskBackend.mockReturnValue("sd");
      // sd returns JSON array
      mockExecFileSync.mockReturnValue(JSON.stringify([]));
    });

    it("calls execFileSync (sd binary) for sd backend", async () => {
      await fetchStatusCounts(PROJECT_PATH);
      expect(mockExecFileSync).toHaveBeenCalled();
    });

    it("does not instantiate BeadsRustClient for sd backend", async () => {
      await fetchStatusCounts(PROJECT_PATH);
      expect(MockBeadsRustClient).not.toHaveBeenCalled();
    });
  });
});
