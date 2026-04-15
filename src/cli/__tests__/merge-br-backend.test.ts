/**
 * Tests for TRD-017: Update merge.ts to use ITaskClient pattern.
 *
 * Verifies:
 * - When FOREMAN_TASK_STORE='beads': createMergeTaskClient returns BeadsRustClient
 * - When FOREMAN_TASK_STORE='beads' and binary missing: throws with friendly error
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// ── Hoisted mocks ──────────────────────────────────────────────────────────
const {
  mockEnsureBrInstalled,
  MockBeadsRustClient,
  mockHasNativeTasks,
  MockForemanStore,
  mockVcsCreate,
} = vi.hoisted(() => {
  const mockEnsureBrInstalled = vi.fn().mockResolvedValue(undefined);
  const MockBeadsRustClient = vi.fn(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
    this.ensureBrInstalled = mockEnsureBrInstalled;
  });
  const mockHasNativeTasks = vi.fn().mockReturnValue(false);
  const MockForemanStore = vi.fn(function MockForemanStoreImpl(this: Record<string, unknown>) {
    this.hasNativeTasks = mockHasNativeTasks;
    this.close = vi.fn();
    this.getProjectByPath = vi.fn().mockReturnValue(null);
    this.getDb = vi.fn().mockReturnValue({});
  });
  (MockForemanStore as any).forProject = vi.fn(
    (...args: unknown[]) => new (MockForemanStore as any)(...args),
  );
  const mockVcsCreate = vi.fn().mockResolvedValue({
    getRepoRoot: vi.fn().mockResolvedValue("/mock/project"),
    getCurrentBranch: vi.fn().mockResolvedValue("main"),
    detectDefaultBranch: vi.fn().mockResolvedValue("main"),
  });
  return {
    mockEnsureBrInstalled,
    MockBeadsRustClient,
    mockHasNativeTasks,
    MockForemanStore,
    mockVcsCreate,
  };
});

vi.mock("../../lib/beads-rust.js", () => ({
  BeadsRustClient: MockBeadsRustClient,
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: MockForemanStore,
}));

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: (...args: unknown[]) => mockVcsCreate(...args),
  },
}));

vi.mock("../../orchestrator/refinery.js", () => ({
  Refinery: vi.fn(function MockRefineryImpl() { /* constructor */ }),
  dryRunMerge: vi.fn().mockResolvedValue([]),
}));

vi.mock("../../orchestrator/merge-queue.js", () => ({
  MergeQueue: vi.fn(function MockMergeQueueImpl(this: Record<string, unknown>) {
    this.reconcile = vi.fn().mockResolvedValue({ enqueued: 0 });
    this.list = vi.fn().mockReturnValue([]);
    this.dequeue = vi.fn().mockReturnValue(null);
  }),
}));

vi.mock("../../orchestrator/merge-cost-tracker.js", () => ({
  MergeCostTracker: vi.fn(function MockMergeCostTrackerImpl(this: Record<string, unknown>) {
    this.getStats = vi.fn().mockReturnValue({
      totalCostUsd: 0,
      totalInputTokens: 0,
      totalOutputTokens: 0,
      entryCount: 0,
      byTier: {},
      byModel: {},
    });
    this.getResolutionRate = vi.fn().mockReturnValue({ total: 0, successes: 0, rate: 0 });
  }),
}));

// ── Module under test ──────────────────────────────────────────────────────
import { createMergeTaskClient } from "../commands/merge.js";

// ── Helpers ────────────────────────────────────────────────────────────────

const PROJECT_PATH = "/mock/project";

describe("TRD-017: merge.ts backend selection via FOREMAN_TASK_STORE", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.stubEnv("FOREMAN_TASK_STORE", "beads");
    mockEnsureBrInstalled.mockResolvedValue(undefined);
    mockHasNativeTasks.mockReturnValue(false);
    MockBeadsRustClient.mockImplementation(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
      this.ensureBrInstalled = mockEnsureBrInstalled;
    });
    MockForemanStore.mockImplementation(function MockForemanStoreImpl(this: Record<string, unknown>) {
      this.hasNativeTasks = mockHasNativeTasks;
      this.close = vi.fn();
      this.getProjectByPath = vi.fn().mockReturnValue(null);
      this.getDb = vi.fn().mockReturnValue({});
    });
    (MockForemanStore as any).forProject = vi.fn(
      (...args: unknown[]) => new (MockForemanStore as any)(...args),
    );
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  // ── br backend ────────────────────────────────────────────────────────────

  describe("when FOREMAN_TASK_STORE='beads'", () => {
    it("returns a BeadsRustClient as the task client", async () => {
      const result = await createMergeTaskClient(PROJECT_PATH);

      expect(MockBeadsRustClient).toHaveBeenCalledWith(PROJECT_PATH);
      expect(MockBeadsRustClient).toHaveBeenCalledTimes(1);
      expect(result).toBeDefined();
    });

    it("calls ensureBrInstalled() to verify binary exists", async () => {
      await createMergeTaskClient(PROJECT_PATH);

      expect(mockEnsureBrInstalled).toHaveBeenCalledTimes(1);
    });

  });

  // ── br backend with missing binary ────────────────────────────────────────

  describe("when FOREMAN_TASK_STORE='beads' and br binary is missing", () => {
    beforeEach(() => {
      mockEnsureBrInstalled.mockRejectedValue(
        new Error(
          "br (beads_rust) CLI not found at /home/user/.local/bin/br. Install via: cargo install beads_rust",
        ),
      );
    });

    it("throws an error when br binary is not found", async () => {
      await expect(createMergeTaskClient(PROJECT_PATH)).rejects.toThrow(
        /br.*not found|beads_rust/i,
      );
    });
  });

});
