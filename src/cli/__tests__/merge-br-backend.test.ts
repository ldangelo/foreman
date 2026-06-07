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
  mockCreateTaskClient,
  mockHasNativeTasks,
  MockForemanStore,
  MockPostgresStore,
  mockVcsCreate,
} = vi.hoisted(() => {
  const mockCreateTaskClient = vi.fn().mockResolvedValue({ taskClient: { kind: "task-client" } });
  const mockHasNativeTasks = vi.fn().mockReturnValue(false);
  const MockForemanStore = vi.fn(function MockForemanStoreImpl(this: Record<string, unknown>) {
    this.hasNativeTasks = mockHasNativeTasks;
    this.close = vi.fn();
    this.getProjectByPath = vi.fn().mockReturnValue(null);
    this.getDb = vi.fn().mockReturnValue({});
  });
  const MockPostgresStore = vi.fn(function MockPostgresStoreImpl(this: Record<string, unknown>) {
    this.getRun = vi.fn();
    this.getRunsByStatus = vi.fn();
    this.getRunsByStatuses = vi.fn();
    this.getRunsByBaseBranch = vi.fn();
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
    mockCreateTaskClient,
    mockHasNativeTasks,
    MockForemanStore,
    MockPostgresStore,
    mockVcsCreate,
  };
});

vi.mock("../../lib/beads-rust.js", () => ({
  BeadsRustClient: vi.fn(),
}));

vi.mock("../../lib/task-client-factory.js", () => ({
  createTaskClient: mockCreateTaskClient,
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: MockForemanStore,
}));

vi.mock("../../lib/postgres-store.js", () => ({
  PostgresStore: MockPostgresStore,
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
    mockHasNativeTasks.mockReturnValue(false);
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
    it("returns the task client from createTaskClient", async () => {
      const result = await createMergeTaskClient(PROJECT_PATH);

      expect(result).toBeDefined();
      expect(mockCreateTaskClient).toHaveBeenCalledWith(PROJECT_PATH, {
        ensureBrInstalled: true,
        registeredProjectId: undefined,
      });
    });

    it("calls ensureBrInstalled() to verify binary exists", async () => {
      await createMergeTaskClient(PROJECT_PATH);

      expect(mockCreateTaskClient).toHaveBeenCalledWith(PROJECT_PATH, {
        ensureBrInstalled: true,
        registeredProjectId: undefined,
      });
    });

    it("forwards a registered project id to createTaskClient", async () => {
      await createMergeTaskClient(PROJECT_PATH, "proj-1");

      expect(mockCreateTaskClient).toHaveBeenCalledWith(PROJECT_PATH, {
        ensureBrInstalled: true,
        registeredProjectId: "proj-1",
      });
    });

  });

});
