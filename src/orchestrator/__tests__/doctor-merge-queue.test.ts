import { describe, it, expect, vi, beforeEach } from "vitest";
import { Doctor } from "../doctor.js";
import type { Run } from "../../lib/store.js";
import type { MergeQueueEntry } from "../merge-queue.js";

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "foreman-001",
    agent_type: "claude-code",
    session_key: null,
    worktree_path: "/tmp/wt",
    status: "running",
    started_at: new Date().toISOString(),
    completed_at: null,
    created_at: new Date().toISOString(),
    progress: null,    ...overrides,
  };
}

function makeMqEntry(overrides: Partial<MergeQueueEntry> = {}): MergeQueueEntry {
  return {
    id: 1,
    branch_name: "foreman/test-001",
    seed_id: "test-001",
    run_id: "run-1",
    operation: "auto_merge",
    agent_name: null,
    files_modified: [],
    enqueued_at: new Date().toISOString(),
    started_at: null,
    completed_at: null,
    status: "pending",
    resolved_tier: null,
    error: null,
    retry_count: 0,
    last_attempted_at: null,
    ...overrides,
  };
}

function makeMocks(projectPath = "/tmp/project") {
  const store = {
    getProjectByPath: vi.fn(() => ({ id: "proj-1", name: "test", status: "active", path: projectPath, created_at: "", updated_at: "" })),
    getRunsByStatus: vi.fn(() => [] as Run[]),
    getRunsForSeed: vi.fn(() => [] as Run[]),
    getActiveRuns: vi.fn(() => [] as Run[]),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    getRun: vi.fn((_id: string) => null as Run | null),
  };
  const mergeQueue = {
    list: vi.fn(() => [] as MergeQueueEntry[]),
    remove: vi.fn(),
    updateStatus: vi.fn(),
    missingFromQueue: vi.fn(() => [] as Array<{ run_id: string; seed_id: string }>),
    reEnqueue: vi.fn(),
  };
  const doctor = new Doctor(store as any, projectPath, mergeQueue as any);
  return { store, mergeQueue, doctor };
}

describe("Doctor - Merge Queue Health Checks", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe("checkStaleMergeQueueEntries", () => {
    it("returns pass when no stale entries exist", async () => {
      const { doctor, mergeQueue } = makeMocks();
      // All entries are recent
      mergeQueue.list.mockReturnValue([
        makeMqEntry({ status: "pending", enqueued_at: new Date().toISOString() }),
      ]);

      const result = await doctor.checkStaleMergeQueueEntries();

      expect(result.status).toBe("pass");
      expect(result.name).toContain("stale merge queue");
    });

    it("warns about entries pending >24h (MQ-008)", async () => {
      const { doctor, mergeQueue } = makeMocks();
      const staleDate = new Date(Date.now() - 25 * 60 * 60 * 1000).toISOString();
      mergeQueue.list.mockReturnValue([
        makeMqEntry({ id: 1, status: "pending", enqueued_at: staleDate }),
        makeMqEntry({ id: 2, status: "merging", started_at: staleDate, enqueued_at: staleDate }),
      ]);

      const result = await doctor.checkStaleMergeQueueEntries();

      expect(result.status).toBe("warn");
      expect(result.message).toContain("2");
      expect(result.message).toContain("MQ-008");
    });

    it("fixes stale entries by marking them failed", async () => {
      const { doctor, mergeQueue } = makeMocks();
      const staleDate = new Date(Date.now() - 25 * 60 * 60 * 1000).toISOString();
      mergeQueue.list.mockReturnValue([
        makeMqEntry({ id: 1, status: "pending", enqueued_at: staleDate }),
      ]);

      const result = await doctor.checkStaleMergeQueueEntries({ fix: true });

      expect(result.status).toBe("fixed");
      expect(mergeQueue.updateStatus).toHaveBeenCalledWith(1, "failed", expect.any(Object));
    });

    it("returns pass when no entries exist", async () => {
      const { doctor, mergeQueue } = makeMocks();
      mergeQueue.list.mockReturnValue([]);

      const result = await doctor.checkStaleMergeQueueEntries();

      expect(result.status).toBe("pass");
    });
  });

  describe("checkDuplicateMergeQueueEntries", () => {
    it("returns pass when no duplicates exist", async () => {
      const { doctor, mergeQueue } = makeMocks();
      mergeQueue.list.mockReturnValue([
        makeMqEntry({ id: 1, branch_name: "foreman/a", status: "pending" }),
        makeMqEntry({ id: 2, branch_name: "foreman/b", status: "pending" }),
      ]);

      const result = await doctor.checkDuplicateMergeQueueEntries();

      expect(result.status).toBe("pass");
    });

    it("warns about duplicate branch entries (MQ-009)", async () => {
      const { doctor, mergeQueue } = makeMocks();
      mergeQueue.list.mockReturnValue([
        makeMqEntry({ id: 1, branch_name: "foreman/dup", status: "pending" }),
        makeMqEntry({ id: 2, branch_name: "foreman/dup", status: "pending" }),
        makeMqEntry({ id: 3, branch_name: "foreman/dup", status: "pending" }),
      ]);

      const result = await doctor.checkDuplicateMergeQueueEntries();

      expect(result.status).toBe("warn");
      expect(result.message).toContain("MQ-009");
      expect(result.message).toContain("foreman/dup");
    });

    it("fixes duplicates by keeping max(id) and removing others", async () => {
      const { doctor, mergeQueue } = makeMocks();
      mergeQueue.list.mockReturnValue([
        makeMqEntry({ id: 1, branch_name: "foreman/dup", status: "pending" }),
        makeMqEntry({ id: 5, branch_name: "foreman/dup", status: "pending" }),
        makeMqEntry({ id: 3, branch_name: "foreman/dup", status: "pending" }),
      ]);

      const result = await doctor.checkDuplicateMergeQueueEntries({ fix: true });

      expect(result.status).toBe("fixed");
      // Should remove ids 1 and 3, keep id 5
      expect(mergeQueue.remove).toHaveBeenCalledWith(1);
      expect(mergeQueue.remove).toHaveBeenCalledWith(3);
      expect(mergeQueue.remove).not.toHaveBeenCalledWith(5);
    });
  });

  describe("checkOrphanedMergeQueueEntries", () => {
    it("returns pass when all entries reference existing runs", async () => {
      const { doctor, mergeQueue, store } = makeMocks();
      mergeQueue.list.mockReturnValue([
        makeMqEntry({ id: 1, run_id: "run-1" }),
      ]);
      store.getRun.mockReturnValue(makeRun({ id: "run-1" }));

      const result = await doctor.checkOrphanedMergeQueueEntries();

      expect(result.status).toBe("pass");
    });

    it("warns about entries referencing non-existent runs (MQ-010)", async () => {
      const { doctor, mergeQueue, store } = makeMocks();
      mergeQueue.list.mockReturnValue([
        makeMqEntry({ id: 1, run_id: "run-gone" }),
        makeMqEntry({ id: 2, run_id: "run-exists" }),
      ]);
      store.getRun.mockImplementation((id: string) => {
        if (id === "run-exists") return makeRun({ id: "run-exists" });
        return null;
      });

      const result = await doctor.checkOrphanedMergeQueueEntries();

      expect(result.status).toBe("warn");
      expect(result.message).toContain("MQ-010");
      expect(result.message).toContain("1");
    });

    it("fixes orphaned entries by deleting them", async () => {
      const { doctor, mergeQueue, store } = makeMocks();
      mergeQueue.list.mockReturnValue([
        makeMqEntry({ id: 1, run_id: "run-gone" }),
        makeMqEntry({ id: 2, run_id: "run-also-gone" }),
      ]);
      store.getRun.mockReturnValue(null);

      const result = await doctor.checkOrphanedMergeQueueEntries({ fix: true });

      expect(result.status).toBe("fixed");
      expect(mergeQueue.remove).toHaveBeenCalledWith(1);
      expect(mergeQueue.remove).toHaveBeenCalledWith(2);
    });

    it("returns pass when queue is empty", async () => {
      const { doctor, mergeQueue } = makeMocks();
      mergeQueue.list.mockReturnValue([]);

      const result = await doctor.checkOrphanedMergeQueueEntries();

      expect(result.status).toBe("pass");
    });
  });

  describe("checkMergeQueueHealth", () => {
    it("runs all merge queue checks and returns combined results", async () => {
      const { doctor, mergeQueue, store } = makeMocks();
      mergeQueue.list.mockReturnValue([]);

      const results = await doctor.checkMergeQueueHealth();

      expect(results).toHaveLength(5);
      expect(results.every((r) => r.status === "pass")).toBe(true);
    });

    it("passes fix option through to all checks", async () => {
      const { doctor, mergeQueue, store } = makeMocks();
      const staleDate = new Date(Date.now() - 25 * 60 * 60 * 1000).toISOString();
      mergeQueue.list.mockReturnValue([
        makeMqEntry({ id: 1, status: "pending", enqueued_at: staleDate, run_id: "run-gone" }),
      ]);
      store.getRun.mockReturnValue(null);

      const results = await doctor.checkMergeQueueHealth({ fix: true });

      // Should have at least some fixed results
      const fixedResults = results.filter((r) => r.status === "fixed");
      expect(fixedResults.length).toBeGreaterThan(0);
    });
  });

  describe("checkStuckConflictFailedEntries", () => {
    it("returns pass when no stuck conflict/failed entries", async () => {
      const { doctor, mergeQueue } = makeMocks();
      mergeQueue.list.mockReturnValue([
        makeMqEntry({ status: "merged", enqueued_at: new Date().toISOString() }),
      ]);

      const result = await doctor.checkStuckConflictFailedEntries();
      expect(result.status).toBe("pass");
      expect(result.name).toContain("stuck conflict/failed");
    });

    it("warns about conflict entries stuck >1h", async () => {
      const { doctor, mergeQueue } = makeMocks();
      const twoHoursAgo = new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString();
      mergeQueue.list.mockReturnValue([
        makeMqEntry({ status: "conflict", error: "Code conflicts", enqueued_at: twoHoursAgo }),
      ]);

      const result = await doctor.checkStuckConflictFailedEntries();
      expect(result.status).toBe("warn");
      expect(result.message).toContain("MQ-012");
    });

    it("warns about failed entries stuck >1h", async () => {
      const { doctor, mergeQueue } = makeMocks();
      const twoHoursAgo = new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString();
      mergeQueue.list.mockReturnValue([
        makeMqEntry({ status: "failed", error: "Test failures", enqueued_at: twoHoursAgo }),
      ]);

      const result = await doctor.checkStuckConflictFailedEntries();
      expect(result.status).toBe("warn");
    });

    it("does not warn about recent conflict entries", async () => {
      const { doctor, mergeQueue } = makeMocks();
      mergeQueue.list.mockReturnValue([
        makeMqEntry({ status: "conflict", error: "conflicts", enqueued_at: new Date().toISOString() }),
      ]);

      const result = await doctor.checkStuckConflictFailedEntries();
      expect(result.status).toBe("pass");
    });

    it("returns pass when no merge queue configured", async () => {
      const store = {
        getProjectByPath: vi.fn(() => null),
        getRunsByStatus: vi.fn(() => []),
        getRunsForSeed: vi.fn(() => []),
        getActiveRuns: vi.fn(() => []),
        updateRun: vi.fn(),
        logEvent: vi.fn(),
        getRun: vi.fn(() => null),
      };
      const doctor = new Doctor(store as any, "/tmp/project");
      const result = await doctor.checkStuckConflictFailedEntries();
      expect(result.status).toBe("pass");
      expect(result.message).toContain("skipping");
    });

    it("dry-run returns warn without making changes", async () => {
      const { doctor, mergeQueue } = makeMocks();
      const twoHoursAgo = new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString();
      mergeQueue.list.mockReturnValue([
        makeMqEntry({ status: "failed", error: "err", enqueued_at: twoHoursAgo }),
      ]);

      const result = await doctor.checkStuckConflictFailedEntries({ dryRun: true });
      expect(result.status).toBe("warn");
      expect(result.message).toContain("dry-run");
    });

    it("fix: true re-enqueues stuck entries and reports fixApplied", async () => {
      const { doctor, mergeQueue } = makeMocks();
      const twoHoursAgo = new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString();
      mergeQueue.list.mockReturnValue([
        makeMqEntry({ id: 10, status: "conflict", error: "Code conflicts", enqueued_at: twoHoursAgo }),
        makeMqEntry({ id: 11, status: "failed", error: "Test failures", enqueued_at: twoHoursAgo }),
      ]);
      // reEnqueue returns true for each call (successful re-enqueue)
      mergeQueue.reEnqueue.mockReturnValue(true);

      const result = await doctor.checkStuckConflictFailedEntries({ fix: true });

      expect(result.status).toBe("fixed");
      expect(result.fixApplied).toContain("Re-enqueued 2 entry(ies)");
      expect(mergeQueue.reEnqueue).toHaveBeenCalledWith(10);
      expect(mergeQueue.reEnqueue).toHaveBeenCalledWith(11);
      expect(mergeQueue.reEnqueue).toHaveBeenCalledTimes(2);
    });

    it("fix: true counts only successfully re-enqueued entries", async () => {
      const { doctor, mergeQueue } = makeMocks();
      const twoHoursAgo = new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString();
      mergeQueue.list.mockReturnValue([
        makeMqEntry({ id: 10, status: "conflict", enqueued_at: twoHoursAgo }),
        makeMqEntry({ id: 11, status: "failed", enqueued_at: twoHoursAgo }),
      ]);
      // Only first entry succeeds (e.g., second has exhausted retries)
      mergeQueue.reEnqueue.mockReturnValueOnce(true).mockReturnValueOnce(false);

      const result = await doctor.checkStuckConflictFailedEntries({ fix: true });

      expect(result.status).toBe("fixed");
      expect(result.fixApplied).toContain("Re-enqueued 1 entry(ies)");
    });
  });

  describe("integration with runAll", () => {
    it("includes merge queue checks in dataIntegrity when merge queue is provided", async () => {
      const { doctor, mergeQueue } = makeMocks();
      mergeQueue.list.mockReturnValue([]);

      const report = await doctor.runAll();

      // Should include merge queue check results in dataIntegrity
      const mqChecks = report.dataIntegrity.filter((r) =>
        r.name.includes("merge queue"),
      );
      expect(mqChecks.length).toBeGreaterThan(0);
    });
  });
});
