/**
 * TRD-009: Monitor with ITaskClient (BeadsRust backend path)
 *
 * Tests:
 * 1. Monitor accepts ITaskClient (BeadsRustClient shape) via constructor
 * 2. completion detection works with BrIssueDetail-shaped response (status: "closed")
 * 3. "issue not found" error is treated as transient — run stays active, no failure
 * 4. "404" error is treated as transient — run stays active, no failure
 * 5. other errors (network, auth) still cause run to fail
 * 6. SeedsClient-shaped show() still works (backwards compat)
 */
import { describe, it, expect, vi } from "vitest";
import { Monitor } from "../monitor.js";
import type { Run } from "../../lib/store.js";

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "bd-abc123",
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

function makeStore() {
  return {
    getActiveRuns: vi.fn((): Run[] => []),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    getRunEvents: vi.fn((): unknown[] => []),
  };
}

// ── Simulate a BeadsRustClient-shaped taskClient ────────────────────────────

function makeTaskClient(showImpl?: () => Promise<{ status: string; [key: string]: unknown }>) {
  return {
    ready: vi.fn(async () => []),
    update: vi.fn(async () => undefined),
    close: vi.fn(async () => undefined),
    show: showImpl ? vi.fn(showImpl) : vi.fn(async () => ({ status: "open" })),
  };
}

// ── Test suite ──────────────────────────────────────────────────────────────

describe("TRD-009: Monitor with ITaskClient (BeadsRust backend path)", () => {
  describe("constructor accepts ITaskClient with show()", () => {
    it("constructs Monitor with a BeadsRust-shaped taskClient", () => {
      const store = makeStore();
      const taskClient = makeTaskClient();
      // Should not throw — ITaskClient with show() is accepted
      expect(() => new Monitor(store as any, taskClient as any, "/tmp/proj")).not.toThrow();
    });
  });

  describe("completion detection via taskClient.show()", () => {
    it("marks run completed when taskClient.show() returns status: closed", async () => {
      const store = makeStore();
      const taskClient = makeTaskClient(async () => ({
        status: "closed",
        id: "bd-abc123",
        title: "My task",
        type: "task",
        priority: "2",
        assignee: null,
        parent: null,
        created_at: "2025-01-01T00:00:00Z",
        updated_at: "2025-01-02T00:00:00Z",
        description: null,
        labels: [],
        estimate_minutes: null,
        dependencies: [],
        children: [],
      }));
      const run = makeRun();
      store.getActiveRuns.mockReturnValue([run]);

      const monitor = new Monitor(store as any, taskClient as any, "/tmp/proj");
      const report = await monitor.checkAll();

      expect(report.completed).toHaveLength(1);
      expect(report.completed[0].id).toBe("run-1");
      expect(store.updateRun).toHaveBeenCalledWith(
        "run-1",
        expect.objectContaining({ status: "completed" }),
      );
    });

    it("marks run completed when taskClient.show() returns status: completed", async () => {
      const store = makeStore();
      const taskClient = makeTaskClient(async () => ({ status: "completed" }));
      const run = makeRun();
      store.getActiveRuns.mockReturnValue([run]);

      const monitor = new Monitor(store as any, taskClient as any, "/tmp/proj");
      const report = await monitor.checkAll();

      expect(report.completed).toHaveLength(1);
    });

    it("keeps run active when taskClient.show() returns status: in_progress", async () => {
      const store = makeStore();
      const taskClient = makeTaskClient(async () => ({ status: "in_progress" }));
      const run = makeRun({ started_at: new Date().toISOString() });
      store.getActiveRuns.mockReturnValue([run]);

      const monitor = new Monitor(store as any, taskClient as any, "/tmp/proj");
      const report = await monitor.checkAll({ stuckTimeoutMinutes: 60 });

      expect(report.active).toHaveLength(1);
      expect(report.completed).toHaveLength(0);
    });
  });

  describe("transient 'issue not found' error handling", () => {
    it("treats 'not found' error from show() as transient — run stays active", async () => {
      const store = makeStore();
      const taskClient = makeTaskClient();
      taskClient.show.mockRejectedValue(new Error("br show bd-abc123 failed: issue not found"));
      const run = makeRun({ started_at: new Date().toISOString() });
      store.getActiveRuns.mockReturnValue([run]);

      const monitor = new Monitor(store as any, taskClient as any, "/tmp/proj");
      const report = await monitor.checkAll({ stuckTimeoutMinutes: 60 });

      // Should be active, not failed
      expect(report.failed).toHaveLength(0);
      expect(report.active).toHaveLength(1);
      // store.updateRun should NOT have been called with failed status
      expect(store.updateRun).not.toHaveBeenCalled();
    });

    it("treats '404' error from show() as transient — run stays active", async () => {
      const store = makeStore();
      const taskClient = makeTaskClient();
      taskClient.show.mockRejectedValue(new Error("br show bd-abc123 failed: 404 Not Found"));
      const run = makeRun({ started_at: new Date().toISOString() });
      store.getActiveRuns.mockReturnValue([run]);

      const monitor = new Monitor(store as any, taskClient as any, "/tmp/proj");
      const report = await monitor.checkAll({ stuckTimeoutMinutes: 60 });

      expect(report.failed).toHaveLength(0);
      expect(report.active).toHaveLength(1);
    });

    it("treats 'Issue not found' (capital I) as transient", async () => {
      const store = makeStore();
      const taskClient = makeTaskClient();
      taskClient.show.mockRejectedValue(new Error("Issue not found: bd-xyz"));
      const run = makeRun({ started_at: new Date().toISOString() });
      store.getActiveRuns.mockReturnValue([run]);

      const monitor = new Monitor(store as any, taskClient as any, "/tmp/proj");
      const report = await monitor.checkAll({ stuckTimeoutMinutes: 60 });

      expect(report.failed).toHaveLength(0);
      expect(report.active).toHaveLength(1);
    });

    it("does NOT suppress transient warning for non-not-found errors", async () => {
      const store = makeStore();
      const taskClient = makeTaskClient();
      taskClient.show.mockRejectedValue(new Error("br show failed: permission denied"));
      const run = makeRun({ started_at: new Date().toISOString() });
      store.getActiveRuns.mockReturnValue([run]);

      const monitor = new Monitor(store as any, taskClient as any, "/tmp/proj");
      const report = await monitor.checkAll({ stuckTimeoutMinutes: 60 });

      // Non-transient errors should still cause failure
      expect(report.failed).toHaveLength(1);
      expect(store.updateRun).toHaveBeenCalledWith(
        "run-1",
        expect.objectContaining({ status: "failed" }),
      );
    });

    it("transient error does not prevent stuck detection on later iteration", async () => {
      const store = makeStore();
      const taskClient = makeTaskClient();
      // show() throws not-found but run started 30 min ago
      taskClient.show.mockRejectedValue(new Error("issue not found"));
      const thirtyMinAgo = new Date(Date.now() - 30 * 60 * 1000).toISOString();
      const run = makeRun({ started_at: thirtyMinAgo });
      store.getActiveRuns.mockReturnValue([run]);

      const monitor = new Monitor(store as any, taskClient as any, "/tmp/proj");
      const report = await monitor.checkAll({ stuckTimeoutMinutes: 15 });

      // Timeout heuristic should still fire after transient show() error
      expect(report.stuck).toHaveLength(1);
      expect(report.active).toHaveLength(0);
    });
  });

  describe("backwards compatibility: SeedsClient-shaped show()", () => {
    it("works with SeedsClient-shaped show() returning SeedDetail", async () => {
      const store = makeStore();
      const seedsTaskClient = {
        ready: vi.fn(async () => []),
        update: vi.fn(async () => undefined),
        close: vi.fn(async () => undefined),
        show: vi.fn(async () => ({
          id: "seeds-001",
          title: "My seed",
          type: "task",
          priority: "P2",
          status: "closed",
          assignee: null,
          parent: null,
          created_at: "2025-01-01T00:00:00Z",
          updated_at: "2025-01-02T00:00:00Z",
          description: null,
          notes: null,
          acceptance: null,
          design: null,
          dependencies: [],
          children: [],
        })),
      };
      const run = makeRun({ seed_id: "seeds-001" });
      store.getActiveRuns.mockReturnValue([run]);

      const monitor = new Monitor(store as any, seedsTaskClient as any, "/tmp/proj");
      const report = await monitor.checkAll();

      expect(report.completed).toHaveLength(1);
    });
  });
});
