import { describe, it, expect, vi, beforeEach } from "vitest";
import { Monitor } from "../monitor.js";
import type { Run } from "../../lib/store.js";

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "seeds-001",
    agent_type: "claude-code",
    session_key: null,
    worktree_path: "/tmp/wt",
    status: "running",
    started_at: new Date().toISOString(),
    completed_at: null,
    created_at: new Date().toISOString(),
    progress: null,
    ...overrides,
  };
}

function makeMocks() {
  const store = {
    getActiveRuns: vi.fn(() => [] as Run[]),
    getRun: vi.fn((runId: string) => makeRun({ id: runId })),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    getRunProgress: vi.fn(async () => null),
    getRunEvents: vi.fn((): any[] => []),
  };
  const seeds = {
    show: vi.fn(async () => ({ status: "open" })),
  };
  const monitor = new Monitor(store as any, seeds as any, "/tmp/project");
  return { store, seeds, monitor };
}

describe("Monitor", () => {
  describe("checkAll", () => {
    it("detects completed run when seed status is closed", async () => {
      const { store, seeds, monitor } = makeMocks();
      const run = makeRun();
      store.getActiveRuns.mockReturnValue([run]);
      seeds.show.mockResolvedValue({ status: "closed" });

      const report = await monitor.checkAll();

      expect(report.completed).toHaveLength(1);
      expect(report.completed[0].status).toBe("completed");
      expect(store.updateRun).toHaveBeenCalledWith(run.id, expect.objectContaining({ status: "completed" }));
    });

    it("detects stuck agent when started_at exceeds timeout", async () => {
      const { store, seeds, monitor } = makeMocks();
      // Started 30 minutes ago
      const thirtyMinAgo = new Date(Date.now() - 30 * 60 * 1000).toISOString();
      const run = makeRun({ started_at: thirtyMinAgo });
      store.getActiveRuns.mockReturnValue([run]);
      seeds.show.mockResolvedValue({ status: "open" });

      const report = await monitor.checkAll({ stuckTimeoutMinutes: 15 });

      expect(report.stuck).toHaveLength(1);
      expect(store.updateRun).toHaveBeenCalledWith(run.id, { status: "stuck" });
    });

    it("does not downgrade a run that is already merged in the store", async () => {
      const { store, seeds, monitor } = makeMocks();
      const run = makeRun({ id: "run-merged-race" });
      store.getActiveRuns.mockReturnValue([run]);
      store.getRun.mockResolvedValueOnce({ ...run, status: "merged" });
      seeds.show.mockResolvedValue({ status: "open" });

      const report = await monitor.checkAll({ stuckTimeoutMinutes: 15 });

      expect(report.active).toHaveLength(0);
      expect(report.stuck).toHaveLength(0);
      expect(report.completed).toHaveLength(0);
      expect(report.failed).toHaveLength(0);
      expect(store.updateRun).not.toHaveBeenCalled();
    });

    it("keeps active runs as active when recently started", async () => {
      const { store, seeds, monitor } = makeMocks();
      const run = makeRun({ started_at: new Date().toISOString() });
      store.getActiveRuns.mockReturnValue([run]);
      seeds.show.mockResolvedValue({ status: "open" });

      const report = await monitor.checkAll({ stuckTimeoutMinutes: 15 });

      expect(report.active).toHaveLength(1);
      expect(report.stuck).toHaveLength(0);
      expect(report.completed).toHaveLength(0);
    });

    it("returns correct categorization across all arrays", async () => {
      const { store, seeds, monitor } = makeMocks();
      const completedRun = makeRun({ id: "run-done", seed_id: "seeds-done" });
      const stuckRun = makeRun({
        id: "run-stuck",
        seed_id: "seeds-stuck",
        started_at: new Date(Date.now() - 60 * 60 * 1000).toISOString(),
      });
      const activeRun = makeRun({ id: "run-active", seed_id: "seeds-active" });

      store.getActiveRuns.mockReturnValue([completedRun, stuckRun, activeRun]);
      seeds.show.mockImplementation(async (...args: any[]) => {
        if (args[0] === "seeds-done") return { status: "closed" };
        return { status: "open" };
      });

      const report = await monitor.checkAll({ stuckTimeoutMinutes: 15 });

      expect(report.completed).toHaveLength(1);
      expect(report.stuck).toHaveLength(1);
      expect(report.active).toHaveLength(1);
      expect(report.failed).toHaveLength(0);
    });
  });

  describe("recoverStuck", () => {
    it("returns true and skips mutation when the run is already pr-created", async () => {
      const { store, monitor } = makeMocks();
      const run = makeRun({ id: "run-pr-created" });
      store.getRun.mockResolvedValueOnce({ ...run, status: "pr-created" });

      const result = await monitor.recoverStuck(run, 3);

      expect(result).toBe(true);
      expect(store.updateRun).not.toHaveBeenCalled();
    });

    it("returns false when max retries exceeded", async () => {
      const { store, monitor } = makeMocks();
      const run = makeRun();
      // Simulate 3 prior recovery events (already at max)
      store.getRunEvents.mockReturnValue([{} as any, {} as any, {} as any]);

      const result = await monitor.recoverStuck(run, 3);

      expect(result).toBe(false);
      expect(store.updateRun).toHaveBeenCalledWith(run.id, expect.objectContaining({ status: "failed" }));
    });
  });

  describe("checkForStalls", () => {
    it("does not mark a run as stalled when lastActivity is recent", async () => {
      const { store, monitor } = makeMocks();
      const recentActivity = new Date(Date.now() - 60_000).toISOString(); // 1 min ago
      const run = makeRun();
      store.getActiveRuns.mockReturnValue([run]);
      store.getRunProgress.mockResolvedValue({ lastActivity: recentActivity } as any);

      const result = await monitor.checkForStalls({ stallTimeoutMs: 5 * 60 * 1000 });

      expect(result.stalled).toHaveLength(0);
      expect(store.updateRun).not.toHaveBeenCalled();
    });

    it("marks a run as stalled when lastActivity exceeds threshold", async () => {
      const { store, monitor } = makeMocks();
      const staleActivity = new Date(Date.now() - 6 * 60 * 1000).toISOString(); // 6 min ago
      const run = makeRun();
      store.getActiveRuns.mockReturnValue([run]);
      store.getRunProgress.mockResolvedValue({ lastActivity: staleActivity } as any);

      const result = await monitor.checkForStalls({ stallTimeoutMs: 5 * 60 * 1000 });

      expect(result.stalled).toHaveLength(1);
      expect(store.updateRun).toHaveBeenCalledWith(run.id, { status: "stuck" });
      expect(store.logEvent).toHaveBeenCalledWith(
        run.project_id,
        "stuck",
        expect.objectContaining({ reason: "stall", seedId: run.seed_id }),
        run.id,
      );
    });

    it("handles multiple stalled runs", async () => {
      const { store, monitor } = makeMocks();
      const staleActivity = new Date(Date.now() - 10 * 60 * 1000).toISOString();
      const run1 = makeRun({ id: "run-1", seed_id: "seed-1" });
      const run2 = makeRun({ id: "run-2", seed_id: "seed-2" });
      store.getActiveRuns.mockReturnValue([run1, run2]);
      store.getRunProgress.mockResolvedValue({ lastActivity: staleActivity } as any);

      const result = await monitor.checkForStalls({ stallTimeoutMs: 5 * 60 * 1000 });

      expect(result.stalled).toHaveLength(2);
      expect(store.updateRun).toHaveBeenCalledTimes(2);
    });

    it("skips runs with no progress data", async () => {
      const { store, monitor } = makeMocks();
      const run = makeRun();
      store.getActiveRuns.mockReturnValue([run]);
      store.getRunProgress.mockResolvedValue(null);

      const result = await monitor.checkForStalls({ stallTimeoutMs: 5 * 60 * 1000 });

      expect(result.stalled).toHaveLength(0);
      expect(store.updateRun).not.toHaveBeenCalled();
    });

    it("skips non-running runs", async () => {
      const { store, monitor } = makeMocks();
      const staleActivity = new Date(Date.now() - 10 * 60 * 1000).toISOString();
      const run = makeRun({ id: "run-pending", status: "pending" });
      store.getActiveRuns.mockReturnValue([run]);
      store.getRunProgress.mockResolvedValue({ lastActivity: staleActivity } as any);

      const result = await monitor.checkForStalls({ stallTimeoutMs: 5 * 60 * 1000 });

      expect(result.stalled).toHaveLength(0);
      expect(store.updateRun).not.toHaveBeenCalled();
    });

    it("skips runs that are already in a terminal success state", async () => {
      const { store, monitor } = makeMocks();
      const staleActivity = new Date(Date.now() - 10 * 60 * 1000).toISOString();
      const run = makeRun({ id: "run-merged", status: "merged" });
      store.getActiveRuns.mockReturnValue([run]);
      store.getRun.mockResolvedValueOnce({ ...run, status: "merged" });
      store.getRunProgress.mockResolvedValue({ lastActivity: staleActivity } as any);

      const result = await monitor.checkForStalls({ stallTimeoutMs: 5 * 60 * 1000 });

      expect(result.stalled).toHaveLength(0);
      expect(store.updateRun).not.toHaveBeenCalled();
    });
  });

  describe("logging", () => {
    it("logs events on status changes", async () => {
      const { store, seeds, monitor } = makeMocks();
      const run = makeRun();
      store.getActiveRuns.mockReturnValue([run]);
      seeds.show.mockResolvedValue({ status: "closed" });

      await monitor.checkAll();

      expect(store.logEvent).toHaveBeenCalledWith(
        run.project_id,
        "complete",
        expect.objectContaining({ seedId: run.seed_id }),
        run.id,
      );
    });
  });
});
