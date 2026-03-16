/**
 * Tests for TRD-017: Update merge.ts to use ITaskClient pattern.
 *
 * Verifies:
 * - When FOREMAN_TASK_BACKEND='br': createMergeTaskClient returns BeadsRustClient
 * - When FOREMAN_TASK_BACKEND='sd': createMergeTaskClient returns SeedsClient
 * - When FOREMAN_TASK_BACKEND='br' and binary missing: throws with friendly error
 */

import { describe, it, expect, vi, beforeEach } from "vitest";

// ── Hoisted mocks ──────────────────────────────────────────────────────────
const {
  mockGetTaskBackend,
  MockSeedsClient,
  mockEnsureBrInstalled,
  MockBeadsRustClient,
} = vi.hoisted(() => {
  const mockGetTaskBackend = vi.fn().mockReturnValue("sd");
  const MockSeedsClient = vi.fn(function MockSeedsClientImpl() { /* constructor */ });
  const mockEnsureBrInstalled = vi.fn().mockResolvedValue(undefined);
  const MockBeadsRustClient = vi.fn(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
    this.ensureBrInstalled = mockEnsureBrInstalled;
  });
  return {
    mockGetTaskBackend,
    MockSeedsClient,
    mockEnsureBrInstalled,
    MockBeadsRustClient,
  };
});

vi.mock("../../lib/feature-flags.js", () => ({
  getTaskBackend: () => mockGetTaskBackend(),
}));

vi.mock("../../lib/seeds.js", () => ({
  SeedsClient: MockSeedsClient,
}));

vi.mock("../../lib/beads-rust.js", () => ({
  BeadsRustClient: MockBeadsRustClient,
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: vi.fn(function MockForemanStoreImpl(this: Record<string, unknown>) {
    this.close = vi.fn();
    this.getProjectByPath = vi.fn().mockReturnValue(null);
    this.getDb = vi.fn().mockReturnValue({});
  }),
}));

vi.mock("../../lib/git.js", () => ({
  getRepoRoot: vi.fn().mockResolvedValue("/mock/project"),
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

describe("TRD-017: merge.ts backend selection via FOREMAN_TASK_BACKEND", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockEnsureBrInstalled.mockResolvedValue(undefined);
    MockBeadsRustClient.mockImplementation(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
      this.ensureBrInstalled = mockEnsureBrInstalled;
    });
    MockSeedsClient.mockImplementation(function MockSeedsClientImpl() { /* constructor */ });
  });

  // ── sd backend ────────────────────────────────────────────────────────────

  describe("when FOREMAN_TASK_BACKEND='sd'", () => {
    beforeEach(() => {
      mockGetTaskBackend.mockReturnValue("sd");
    });

    it("returns a SeedsClient as the task client", async () => {
      const result = await createMergeTaskClient(PROJECT_PATH);

      expect(MockSeedsClient).toHaveBeenCalledWith(PROJECT_PATH);
      expect(MockSeedsClient).toHaveBeenCalledTimes(1);
      expect(result).toBeDefined();
    });

    it("does not instantiate BeadsRustClient", async () => {
      await createMergeTaskClient(PROJECT_PATH);

      expect(MockBeadsRustClient).not.toHaveBeenCalled();
    });

    it("does not call ensureBrInstalled()", async () => {
      await createMergeTaskClient(PROJECT_PATH);

      expect(mockEnsureBrInstalled).not.toHaveBeenCalled();
    });
  });

  // ── br backend ────────────────────────────────────────────────────────────

  describe("when FOREMAN_TASK_BACKEND='br'", () => {
    beforeEach(() => {
      mockGetTaskBackend.mockReturnValue("br");
    });

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

    it("does not instantiate SeedsClient", async () => {
      await createMergeTaskClient(PROJECT_PATH);

      expect(MockSeedsClient).not.toHaveBeenCalled();
    });
  });

  // ── br backend with missing binary ────────────────────────────────────────

  describe("when FOREMAN_TASK_BACKEND='br' and br binary is missing", () => {
    beforeEach(() => {
      mockGetTaskBackend.mockReturnValue("br");
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

  // ── default / fallback ────────────────────────────────────────────────────

  describe("when FOREMAN_TASK_BACKEND is absent (defaults to sd)", () => {
    beforeEach(() => {
      mockGetTaskBackend.mockReturnValue("sd");
    });

    it("falls back to SeedsClient", async () => {
      const result = await createMergeTaskClient(PROJECT_PATH);

      expect(MockSeedsClient).toHaveBeenCalledWith(PROJECT_PATH);
      expect(result).toBeDefined();
    });
  });
});
