import { describe, it, expect, vi, beforeEach } from "vitest";
import { ForemanStoreReadModelAdapter } from "../store-read-model-adapter.js";
import type { ForemanStore, Run } from "../../lib/store.js";

/**
 * Tests for ForemanStoreReadModelAdapter.
 *
 * Covers the RunStoreReadModel interface implementation, including:
 * - Basic run queries
 * - Archived field mapping
 * - getRecentActiveRuns filtering
 * - archiveRuns (legacy no-op)
 */

// ── Fixtures ─────────────────────────────────────────────────────────────

function makeRun(overrides?: Partial<Run>): Run {
  const base: Run = {
    id: "run-001",
    project_id: "proj-001",
    seed_id: "foreman-abc1",
    agent_type: "claude-sonnet-4-5",
    session_key: null,
    worktree_path: "/tmp/worktree",
    status: "running",
    started_at: new Date().toISOString(),
    completed_at: null,
    created_at: new Date().toISOString(),
    progress: null,
  };
  return { ...base, ...overrides } as Run;
}

// ── Mocks ────────────────────────────────────────────────────────────────

function createMockStore(): {
  store: ForemanStore;
  getRun: ReturnType<typeof vi.fn>;
  getRunsForSeed: ReturnType<typeof vi.fn>;
  getActiveRuns: ReturnType<typeof vi.fn>;
  getRunsByStatus: ReturnType<typeof vi.fn>;
  getRunsByStatuses: ReturnType<typeof vi.fn>;
  getRunsByStatusesSince: ReturnType<typeof vi.fn>;
  hasActiveOrPendingRun: ReturnType<typeof vi.fn>;
  getRunProgress: ReturnType<typeof vi.fn>;
} {
  const getRun = vi.fn();
  const getRunsForSeed = vi.fn();
  const getActiveRuns = vi.fn();
  const getRunsByStatus = vi.fn();
  const getRunsByStatuses = vi.fn();
  const getRunsByStatusesSince = vi.fn();
  const hasActiveOrPendingRun = vi.fn();
  const getRunProgress = vi.fn();

  const store = {
    getRun,
    getRunsForSeed,
    getActiveRuns,
    getRunsByStatus,
    getRunsByStatuses,
    getRunsByStatusesSince,
    hasActiveOrPendingRun,
    getRunProgress,
  } as unknown as ForemanStore;

  return { store, getRun, getRunsForSeed, getActiveRuns, getRunsByStatus, getRunsByStatuses, getRunsByStatusesSince, hasActiveOrPendingRun, getRunProgress };
}

// ── Tests ───────────────────────────────────────────────────────────────

describe("ForemanStoreReadModelAdapter", () => {
  describe("mapRunToSummary — archived field", () => {
    it("defaults archived to false when run has no archived property", async () => {
      const { store, getRun } = createMockStore();
      const run = makeRun({ id: "run-no-archived" });
      getRun.mockReturnValue(run);

      const adapter = new ForemanStoreReadModelAdapter(store);
      const summary = await adapter.getRun("run-no-archived");

      expect(summary?.archived).toBe(false);
    });

    it("maps archived: true from run when present", async () => {
      const { store, getRun } = createMockStore();
      const run = makeRun({ id: "run-archived" }) as Run & { archived: boolean };
      run.archived = true;
      getRun.mockReturnValue(run);

      const adapter = new ForemanStoreReadModelAdapter(store);
      const summary = await adapter.getRun("run-archived");

      expect(summary?.archived).toBe(true);
    });
  });

  describe("getRecentActiveRuns", () => {
    beforeEach(() => {
      vi.useFakeTimers();
      vi.setSystemTime(new Date("2026-06-20T12:00:00Z"));
    });

    it("returns active (pending/running) runs", async () => {
      const { store, getActiveRuns, getRunsByStatusesSince } = createMockStore();
      const pendingRun = makeRun({ id: "run-pending", status: "pending" });
      const runningRun = makeRun({ id: "run-running", status: "running" });

      getActiveRuns.mockReturnValue([pendingRun, runningRun]);
      getRunsByStatusesSince.mockReturnValue([]);

      const adapter = new ForemanStoreReadModelAdapter(store);
      const results = await adapter.getRecentActiveRuns();

      expect(results).toHaveLength(2);
      expect(results.map((r) => r.id)).toContain("run-pending");
      expect(results.map((r) => r.id)).toContain("run-running");
    });

    it("includes failed runs from last 30 days", async () => {
      const { store, getActiveRuns, getRunsByStatusesSince } = createMockStore();
      const failedRun = makeRun({
        id: "run-failed",
        status: "failed",
        created_at: new Date(Date.now() - 10 * 24 * 60 * 60 * 1000).toISOString(), // 10 days ago
      });

      getActiveRuns.mockReturnValue([]);
      getRunsByStatusesSince.mockReturnValue([failedRun]);

      const adapter = new ForemanStoreReadModelAdapter(store);
      const results = await adapter.getRecentActiveRuns();

      expect(results).toHaveLength(1);
      expect(results[0].id).toBe("run-failed");
    });

    it("excludes archived runs from results", async () => {
      const { store, getActiveRuns, getRunsByStatusesSince } = createMockStore();
      const archivedRun = makeRun({ id: "run-archived", status: "failed" }) as Run & { archived: boolean };
      archivedRun.archived = true;

      getActiveRuns.mockReturnValue([archivedRun]);
      getRunsByStatusesSince.mockReturnValue([]);

      const adapter = new ForemanStoreReadModelAdapter(store);
      const results = await adapter.getRecentActiveRuns();

      expect(results).toHaveLength(0);
    });

    it("excludes runs older than 30 days", async () => {
      const { store, getActiveRuns, getRunsByStatusesSince } = createMockStore();
      const oldFailedRun = makeRun({
        id: "run-old",
        status: "failed",
        created_at: new Date(Date.now() - 45 * 24 * 60 * 60 * 1000).toISOString(), // 45 days ago
      });

      getActiveRuns.mockReturnValue([]);
      getRunsByStatusesSince.mockReturnValue([oldFailedRun]);

      const adapter = new ForemanStoreReadModelAdapter(store);
      const results = await adapter.getRecentActiveRuns();

      // Since it's older than 30 days, it shouldn't be in the recent results
      expect(results).toHaveLength(0);
    });

    it("deduplicates runs that appear in both active and failed queries", async () => {
      const { store, getActiveRuns, getRunsByStatusesSince } = createMockStore();
      const runningRun = makeRun({ id: "run-dup", status: "running" });

      getActiveRuns.mockReturnValue([runningRun]);
      // Same run returned from failed query (edge case: status inconsistency)
      getRunsByStatusesSince.mockReturnValue([runningRun]);

      const adapter = new ForemanStoreReadModelAdapter(store);
      const results = await adapter.getRecentActiveRuns();

      expect(results).toHaveLength(1);
      expect(results[0].id).toBe("run-dup");
    });

    it("sorts results by createdAt DESC", async () => {
      const { store, getActiveRuns, getRunsByStatusesSince } = createMockStore();
      const olderRun = makeRun({ id: "run-old", created_at: new Date(Date.now() - 5 * 24 * 60 * 60 * 1000).toISOString() });
      const newerRun = makeRun({ id: "run-new", created_at: new Date().toISOString() });

      getActiveRuns.mockReturnValue([olderRun, newerRun]);
      getRunsByStatusesSince.mockReturnValue([]);

      const adapter = new ForemanStoreReadModelAdapter(store);
      const results = await adapter.getRecentActiveRuns();

      expect(results[0].id).toBe("run-new");
      expect(results[1].id).toBe("run-old");
    });
  });

  describe("archiveRuns (legacy no-op)", () => {
    it("returns 0 for legacy store that doesn't support archiving", async () => {
      const { store } = createMockStore();
      const adapter = new ForemanStoreReadModelAdapter(store);

      const count = await adapter.archiveRuns(["run-1", "run-2"]);

      expect(count).toBe(0);
    });
  });

  describe("hasActiveOrPendingRun", () => {
    it("delegates to store.hasActiveOrPendingRun", async () => {
      const { store, hasActiveOrPendingRun } = createMockStore();
      hasActiveOrPendingRun.mockResolvedValue(true);

      const adapter = new ForemanStoreReadModelAdapter(store);
      const result = await adapter.hasActiveOrPendingRun("foreman-abc1", "proj-001");

      expect(result).toBe(true);
      expect(hasActiveOrPendingRun).toHaveBeenCalledWith("foreman-abc1", "proj-001");
    });
  });

  describe("getRunProgress", () => {
    it("maps run progress to summary", async () => {
      const { store, getRunProgress } = createMockStore();
      const progress = {
        toolCalls: 10,
        toolBreakdown: { Bash: 5, Read: 5 },
        filesChanged: ["a.ts"],
        turns: 3,
        costUsd: 0.05,
        tokensIn: 1000,
        tokensOut: 500,
        lastToolCall: "Bash",
        lastActivity: new Date().toISOString(),
      };
      getRunProgress.mockReturnValue(progress);

      const adapter = new ForemanStoreReadModelAdapter(store);
      const result = await adapter.getRunProgress("run-001");

      expect(result?.toolCalls).toBe(10);
      expect(result?.costUsd).toBe(0.05);
    });

    it("returns null when no progress", async () => {
      const { store, getRunProgress } = createMockStore();
      getRunProgress.mockReturnValue(null);

      const adapter = new ForemanStoreReadModelAdapter(store);
      const result = await adapter.getRunProgress("run-001");

      expect(result).toBeNull();
    });
  });
});
