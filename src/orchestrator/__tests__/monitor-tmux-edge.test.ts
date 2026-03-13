import { describe, it, expect, vi } from "vitest";
import { Monitor } from "../monitor.js";
import type { Run } from "../../lib/store.js";
import type { TmuxClient } from "../../lib/tmux.js";

/**
 * AT-T041: Monitor tmux edge case tests
 *
 * Tests:
 * 1. Mix of tmux and non-tmux runs (correct handling of each)
 * 2. Tmux command timeout during liveness check (graceful fallback)
 * 3. Concurrent monitor calls (no race conditions on store updates)
 */

// ── Helpers ──────────────────────────────────────────────────────────

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: `run-${Math.random().toString(36).slice(2, 8)}`,
    project_id: "proj-1",
    seed_id: "seed-001",
    agent_type: "claude-code",
    session_key: null,
    worktree_path: "/tmp/wt",
    status: "running",
    started_at: new Date().toISOString(),
    completed_at: null,
    created_at: new Date().toISOString(),
    progress: null,
    tmux_session: null,
    ...overrides,
  };
}

function makeMocks() {
  const store = {
    getActiveRuns: vi.fn((): Run[] => []),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    getRunEvents: vi.fn((): unknown[] => []),
  };
  const seeds = {
    show: vi.fn(async (_seedId?: string) => ({ status: "open" })),
  };
  const tmux: { hasSession: ReturnType<typeof vi.fn> } = {
    hasSession: vi.fn(async () => true),
  };
  const monitor = new Monitor(
    store as unknown as Parameters<typeof Monitor.prototype.checkAll>[0] extends undefined ? never : Parameters<(typeof Monitor)["prototype"]["checkAll"]>[0] extends undefined ? never : ConstructorParameters<typeof Monitor>[0],
    seeds as unknown as ConstructorParameters<typeof Monitor>[1],
    "/tmp/project",
    tmux as unknown as TmuxClient,
  );
  return { store, seeds, tmux, monitor };
}

// ── Test suite ──────────────────────────────────────────────────────

describe("AT-T041: monitor tmux edge cases", () => {
  describe("mix of tmux and non-tmux runs", () => {
    it("handles tmux run with dead session alongside non-tmux run", async () => {
      const { store, seeds, tmux, monitor } = makeMocks();

      const tmuxRun = makeRun({
        id: "run-tmux",
        seed_id: "seed-tmux",
        tmux_session: "foreman-seed-tmux",
      });

      const nonTmuxRun = makeRun({
        id: "run-plain",
        seed_id: "seed-plain",
        tmux_session: null,
      });

      store.getActiveRuns.mockReturnValue([tmuxRun, nonTmuxRun]);

      // tmux run has dead session
      tmux.hasSession.mockResolvedValue(false);

      // non-tmux run's seed is still open
      seeds.show.mockResolvedValue({ status: "open" });

      const report = await monitor.checkAll({ stuckTimeoutMinutes: 60 });

      // tmux run should be stuck (dead tmux session)
      expect(report.stuck).toHaveLength(1);
      expect(report.stuck[0].id).toBe("run-tmux");

      // non-tmux run should still be active (seed is open, not timed out)
      expect(report.active).toHaveLength(1);
      expect(report.active[0].id).toBe("run-plain");

      // hasSession should only be called for the tmux run
      expect(tmux.hasSession).toHaveBeenCalledTimes(1);
      expect(tmux.hasSession).toHaveBeenCalledWith("foreman-seed-tmux");
    });

    it("handles tmux run with live session alongside completed non-tmux run", async () => {
      const { store, seeds, tmux, monitor } = makeMocks();

      const tmuxRun = makeRun({
        id: "run-tmux-live",
        seed_id: "seed-tmux-live",
        tmux_session: "foreman-seed-tmux-live",
      });

      const completedRun = makeRun({
        id: "run-done",
        seed_id: "seed-done",
        tmux_session: null,
      });

      store.getActiveRuns.mockReturnValue([tmuxRun, completedRun]);

      // tmux session is alive
      tmux.hasSession.mockResolvedValue(true);

      // tmux run seed is open, completed run seed is closed
      seeds.show.mockImplementation(async (_seedId?: string) => {
        if (_seedId === "seed-done") return { status: "closed" };
        return { status: "open" };
      });

      const report = await monitor.checkAll({ stuckTimeoutMinutes: 60 });

      // tmux run: alive tmux + open seed -> active
      expect(report.active).toHaveLength(1);
      expect(report.active[0].id).toBe("run-tmux-live");

      // non-tmux run: seed closed -> completed
      expect(report.completed).toHaveLength(1);
      expect(report.completed[0].id).toBe("run-done");
    });

    it("handles all-tmux runs with mixed session states", async () => {
      const { store, seeds, tmux, monitor } = makeMocks();

      const liveRun = makeRun({
        id: "run-live",
        seed_id: "seed-live",
        tmux_session: "foreman-seed-live",
      });

      const deadRun = makeRun({
        id: "run-dead",
        seed_id: "seed-dead",
        tmux_session: "foreman-seed-dead",
      });

      store.getActiveRuns.mockReturnValue([liveRun, deadRun]);

      tmux.hasSession.mockImplementation(async (name: string) => {
        return name === "foreman-seed-live";
      });

      seeds.show.mockResolvedValue({ status: "open" });

      const report = await monitor.checkAll({ stuckTimeoutMinutes: 60 });

      expect(report.active).toHaveLength(1);
      expect(report.active[0].id).toBe("run-live");

      expect(report.stuck).toHaveLength(1);
      expect(report.stuck[0].id).toBe("run-dead");

      expect(tmux.hasSession).toHaveBeenCalledTimes(2);
    });
  });

  describe("tmux command timeout during liveness check", () => {
    it("treats tmux hasSession rejection as error and marks run as failed", async () => {
      const { store, seeds, tmux, monitor } = makeMocks();

      const run = makeRun({
        id: "run-timeout",
        seed_id: "seed-timeout",
        tmux_session: "foreman-seed-timeout",
      });

      store.getActiveRuns.mockReturnValue([run]);

      // Simulate tmux command timing out (throws an error)
      tmux.hasSession.mockRejectedValue(new Error("Command timed out after 5000ms"));

      const report = await monitor.checkAll({ stuckTimeoutMinutes: 60 });

      // The error should be caught by the try/catch in checkAll
      // and the run should be marked as failed
      expect(report.failed).toHaveLength(1);
      expect(report.failed[0].id).toBe("run-timeout");

      expect(store.updateRun).toHaveBeenCalledWith("run-timeout", expect.objectContaining({
        status: "failed",
      }));

      expect(store.logEvent).toHaveBeenCalledWith(
        "proj-1",
        "fail",
        expect.objectContaining({
          seedId: "seed-timeout",
          error: expect.stringContaining("timed out"),
        }),
        "run-timeout",
      );
    });

    it("continues processing other runs after tmux timeout on one run", async () => {
      const { store, seeds, tmux, monitor } = makeMocks();

      const timeoutRun = makeRun({
        id: "run-timeout",
        seed_id: "seed-timeout",
        tmux_session: "foreman-seed-timeout",
      });

      const normalRun = makeRun({
        id: "run-normal",
        seed_id: "seed-normal",
        tmux_session: "foreman-seed-normal",
      });

      store.getActiveRuns.mockReturnValue([timeoutRun, normalRun]);

      tmux.hasSession.mockImplementation(async (name: string) => {
        if (name === "foreman-seed-timeout") {
          throw new Error("Command timed out");
        }
        return true;
      });

      seeds.show.mockResolvedValue({ status: "open" });

      const report = await monitor.checkAll({ stuckTimeoutMinutes: 60 });

      // Timeout run should fail, normal run should be active
      expect(report.failed).toHaveLength(1);
      expect(report.failed[0].id).toBe("run-timeout");

      expect(report.active).toHaveLength(1);
      expect(report.active[0].id).toBe("run-normal");
    });
  });

  describe("concurrent monitor calls", () => {
    it("concurrent checkAll calls produce consistent results", async () => {
      const { store, seeds, tmux, monitor } = makeMocks();

      const run1 = makeRun({
        id: "run-c1",
        seed_id: "seed-c1",
        tmux_session: "foreman-seed-c1",
      });

      const run2 = makeRun({
        id: "run-c2",
        seed_id: "seed-c2",
        tmux_session: "foreman-seed-c2",
      });

      store.getActiveRuns.mockReturnValue([run1, run2]);
      tmux.hasSession.mockResolvedValue(true);
      seeds.show.mockResolvedValue({ status: "open" });

      // Run multiple checkAll calls concurrently
      const [report1, report2, report3] = await Promise.all([
        monitor.checkAll({ stuckTimeoutMinutes: 60 }),
        monitor.checkAll({ stuckTimeoutMinutes: 60 }),
        monitor.checkAll({ stuckTimeoutMinutes: 60 }),
      ]);

      // All reports should show the same active runs
      expect(report1.active).toHaveLength(2);
      expect(report2.active).toHaveLength(2);
      expect(report3.active).toHaveLength(2);

      // No stuck or failed runs
      expect(report1.stuck).toHaveLength(0);
      expect(report1.failed).toHaveLength(0);
    });

    it("concurrent calls with changing state produce reasonable results", async () => {
      const { store, seeds, tmux, monitor } = makeMocks();

      const run = makeRun({
        id: "run-changing",
        seed_id: "seed-changing",
        tmux_session: "foreman-seed-changing",
      });

      store.getActiveRuns.mockReturnValue([run]);

      // Simulate state that changes over time
      let callCount = 0;
      tmux.hasSession.mockImplementation(async () => {
        callCount++;
        // First call returns true, subsequent calls return false
        return callCount <= 1;
      });

      seeds.show.mockResolvedValue({ status: "open" });

      // Run two calls concurrently
      const results = await Promise.all([
        monitor.checkAll({ stuckTimeoutMinutes: 60 }),
        monitor.checkAll({ stuckTimeoutMinutes: 60 }),
      ]);

      // Total categorized runs should be consistent (each call sees its own state)
      const totalCategorized = results.reduce(
        (sum, r) => sum + r.active.length + r.stuck.length + r.completed.length + r.failed.length,
        0,
      );
      // Each call processes 1 run, so total should be 2
      expect(totalCategorized).toBe(2);
    });

    it("store.updateRun is called correctly for each detected status change", async () => {
      const { store, seeds, tmux, monitor } = makeMocks();

      const deadRun1 = makeRun({
        id: "run-dead-1",
        seed_id: "seed-dead-1",
        tmux_session: "foreman-seed-dead-1",
      });

      const deadRun2 = makeRun({
        id: "run-dead-2",
        seed_id: "seed-dead-2",
        tmux_session: "foreman-seed-dead-2",
      });

      store.getActiveRuns.mockReturnValue([deadRun1, deadRun2]);
      tmux.hasSession.mockResolvedValue(false);

      const report = await monitor.checkAll({ stuckTimeoutMinutes: 60 });

      expect(report.stuck).toHaveLength(2);

      // Each dead run should get its own updateRun and logEvent call
      expect(store.updateRun).toHaveBeenCalledTimes(2);
      expect(store.updateRun).toHaveBeenCalledWith("run-dead-1", { status: "stuck" });
      expect(store.updateRun).toHaveBeenCalledWith("run-dead-2", { status: "stuck" });

      expect(store.logEvent).toHaveBeenCalledTimes(2);
      expect(store.logEvent).toHaveBeenCalledWith(
        "proj-1",
        "stuck",
        expect.objectContaining({
          seedId: "seed-dead-1",
          detectedBy: "tmux-liveness",
        }),
        "run-dead-1",
      );
      expect(store.logEvent).toHaveBeenCalledWith(
        "proj-1",
        "stuck",
        expect.objectContaining({
          seedId: "seed-dead-2",
          detectedBy: "tmux-liveness",
        }),
        "run-dead-2",
      );
    });
  });

  describe("edge: monitor without tmux client", () => {
    it("processes tmux-labeled runs using timeout heuristic when no tmux client", async () => {
      const store = {
        getActiveRuns: vi.fn((): Run[] => []),
        updateRun: vi.fn(),
        logEvent: vi.fn(),
        getRunEvents: vi.fn((): unknown[] => []),
      };
      const seeds = {
        show: vi.fn(async () => ({ status: "open" })),
      };

      // Create monitor WITHOUT tmux client
      const monitor = new Monitor(
        store as unknown as ConstructorParameters<typeof Monitor>[0],
        seeds as unknown as ConstructorParameters<typeof Monitor>[1],
        "/tmp/project",
        // no tmux argument
      );

      // Run has tmux_session set but monitor has no tmux client
      const thirtyMinAgo = new Date(Date.now() - 30 * 60 * 1000).toISOString();
      const run = makeRun({
        id: "run-no-client",
        seed_id: "seed-no-client",
        tmux_session: "foreman-seed-no-client",
        started_at: thirtyMinAgo,
      });

      store.getActiveRuns.mockReturnValue([run]);

      const report = await monitor.checkAll({ stuckTimeoutMinutes: 15 });

      // Without tmux client, tmux liveness check is skipped.
      // Run should be caught by timeout heuristic (30 min > 15 min threshold)
      expect(report.stuck).toHaveLength(1);
      expect(report.stuck[0].id).toBe("run-no-client");
    });

    it("recent run with tmux_session but no tmux client stays active", async () => {
      const store = {
        getActiveRuns: vi.fn((): Run[] => []),
        updateRun: vi.fn(),
        logEvent: vi.fn(),
        getRunEvents: vi.fn((): unknown[] => []),
      };
      const seeds = {
        show: vi.fn(async () => ({ status: "open" })),
      };

      const monitor = new Monitor(
        store as unknown as ConstructorParameters<typeof Monitor>[0],
        seeds as unknown as ConstructorParameters<typeof Monitor>[1],
        "/tmp/project",
      );

      // Recently started run
      const run = makeRun({
        id: "run-recent",
        seed_id: "seed-recent",
        tmux_session: "foreman-seed-recent",
        started_at: new Date().toISOString(),
      });

      store.getActiveRuns.mockReturnValue([run]);

      const report = await monitor.checkAll({ stuckTimeoutMinutes: 60 });

      // Should be active (not timed out, no tmux check possible)
      expect(report.active).toHaveLength(1);
    });
  });
});
