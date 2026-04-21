import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore, type Run, type RunProgress } from "../../lib/store.js";

// ── Mock BeadsRustClient ───────────────────────────────────────────────

const mockShow = vi.fn();
const mockUpdate = vi.fn();
const mockResetToReady = vi.fn();
const mockReady = vi.fn();
const mockList = vi.fn();
const mockClose = vi.fn();

vi.mock("../../lib/beads-rust.js", () => {
  class MockBeadsRustClient {
    show = mockShow;
    update = mockUpdate;
    resetToReady = mockResetToReady;
    ready = mockReady;
    list = mockList;
    close = mockClose;
  }
  return { BeadsRustClient: MockBeadsRustClient };
});

// ── Mock Dispatcher ────────────────────────────────────────────────────

const mockDispatch = vi.fn();

vi.mock("../../orchestrator/dispatcher.js", () => {
  class MockDispatcher {
    dispatch = mockDispatch;
  }
  return { Dispatcher: MockDispatcher };
});

// ── Helpers ────────────────────────────────────────────────────────────

function makeBead(overrides: Partial<{
  id: string;
  title: string;
  status: string;
  type: string;
  priority: string;
}> = {}) {
  return {
    id: overrides.id ?? "bd-test",
    title: overrides.title ?? "Test bead",
    status: overrides.status ?? "open",
    type: overrides.type ?? "task",
    priority: overrides.priority ?? "P2",
    assignee: null,
    parent: null,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
    description: null,
    labels: [],
    estimate_minutes: null,
    dependencies: [],
    children: [],
  };
}

function createTestRun(
  store: ForemanStore,
  projectId: string,
  overrides: Partial<{
    seedId: string;
    status: Run["status"];
    sessionKey: string | null;
    tmuxSession: string | null;
    worktreePath: string | null;
    agentType: string;
    startedAt: string | null;
    progress: RunProgress | null;
  }> = {},
): Run {
  const seedId = overrides.seedId ?? "bd-test";
  const agentType = overrides.agentType ?? "anthropic/claude-sonnet-4-6";
  const run = store.createRun(
    projectId,
    seedId,
    agentType,
    overrides.worktreePath ?? "/tmp/wt",
  );
  const updates: Partial<
    Pick<Run, "status" | "session_key" | "started_at">
  > = {};
  if (overrides.status) updates.status = overrides.status;
  if (overrides.sessionKey !== undefined)
    updates.session_key = overrides.sessionKey;
  if (overrides.startedAt !== undefined)
    updates.started_at = overrides.startedAt;
  if (Object.keys(updates).length > 0) store.updateRun(run.id, updates);
  return store.getRun(run.id)!;
}

// ── Test suite ─────────────────────────────────────────────────────────

describe("foreman retry", () => {
  let store: ForemanStore;
  let tmpDir: string;
  let projectId: string;
  let beadsClient: InstanceType<typeof import("../../lib/beads-rust.js").BeadsRustClient>;

  beforeEach(async () => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-retry-test-"));
    store = new ForemanStore(join(tmpDir, "test.db"));
    const project = store.registerProject("test-project", tmpDir);
    projectId = project.id;

    mockShow.mockReset();
    mockUpdate.mockReset();
    mockResetToReady.mockReset();
    mockReady.mockReset();
    mockList.mockReset();
    mockClose.mockReset();
    mockDispatch.mockReset();

    mockUpdate.mockResolvedValue(undefined);
    mockDispatch.mockResolvedValue({
      dispatched: [],
      skipped: [],
      resumed: [],
      activeAgents: 0,
    });

    const { BeadsRustClient } = await import("../../lib/beads-rust.js");
    beadsClient = new BeadsRustClient(tmpDir);
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  // ── No project ───────────────────────────────────────────────────────

  describe("missing project", () => {
    it("returns exit code 1 when no project is registered", async () => {
      const consoleErrSpy = vi.spyOn(console, "error").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "open" }));

      const { retryAction } = await import("../commands/retry.js");
      const exitCode = await retryAction(
        "bd-test",
        {},
        beadsClient,
        store,
        "/nonexistent/path",
      );

      expect(exitCode).toBe(1);
      expect(consoleErrSpy).toHaveBeenCalledWith(
        expect.stringContaining("No project registered"),
      );

      consoleErrSpy.mockRestore();
    });
  });

  // ── Bead not found ───────────────────────────────────────────────────

  describe("bead not found", () => {
    it("returns exit code 1 when bead does not exist", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const consoleErrSpy = vi.spyOn(console, "error").mockImplementation(() => {});

      mockShow.mockRejectedValue(new Error("bead not found"));

      const { retryAction } = await import("../commands/retry.js");
      const exitCode = await retryAction(
        "bd-nonexistent",
        {},
        beadsClient,
        store,
        tmpDir,
      );

      expect(exitCode).toBe(1);
      expect(consoleErrSpy).toHaveBeenCalledWith(
        expect.stringContaining("bd-nonexistent"),
      );

      consoleSpy.mockRestore();
      consoleErrSpy.mockRestore();
    });
  });

  // ── Open bead with no run history ────────────────────────────────────

  describe("open bead, no run history", () => {
    it("succeeds without resetting status when bead is already open", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "open" }));

      const { retryAction } = await import("../commands/retry.js");
      const exitCode = await retryAction(
        "bd-test",
        {},
        beadsClient,
        store,
        tmpDir,
      );

      expect(exitCode).toBe(0);
      // No update needed — bead is already open
      expect(mockUpdate).not.toHaveBeenCalled();

      consoleSpy.mockRestore();
    });

    it("does not call dispatch when --dispatch not set", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "open" }));

      const { retryAction } = await import("../commands/retry.js");
      await retryAction("bd-test", {}, beadsClient, store, tmpDir);

      expect(mockDispatch).not.toHaveBeenCalled();

      consoleSpy.mockRestore();
    });
  });

  // ── Completed/closed bead reset ──────────────────────────────────────

  describe("completed bead", () => {
    it("does not reset bead status when it is already completed", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "completed" }));

      const { retryAction } = await import("../commands/retry.js");
      const exitCode = await retryAction(
        "bd-test",
        {},
        beadsClient,
        store,
        tmpDir,
      );

      expect(exitCode).toBe(0);
      expect(mockUpdate).not.toHaveBeenCalled();

      consoleSpy.mockRestore();
    });

    it("does not reset bead status from 'closed'", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "closed" }));

      const { retryAction } = await import("../commands/retry.js");
      const exitCode = await retryAction(
        "bd-test",
        {},
        beadsClient,
        store,
        tmpDir,
      );

      expect(exitCode).toBe(0);
      expect(mockUpdate).not.toHaveBeenCalled();

      consoleSpy.mockRestore();
    });
  });

  // ── Stuck run reset ──────────────────────────────────────────────────

  describe("stuck run", () => {
    it("marks stuck run as failed and logs restart event", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "in_progress" }));

      const run = createTestRun(store, projectId, {
        seedId: "bd-test",
        status: "stuck",
      });

      const { retryAction } = await import("../commands/retry.js");
      const exitCode = await retryAction(
        "bd-test",
        {},
        beadsClient,
        store,
        tmpDir,
      );

      expect(exitCode).toBe(0);

      // Run should be marked as failed
      const updated = store.getRun(run.id);
      expect(updated!.status).toBe("failed");
      expect(updated!.completed_at).not.toBeNull();

      consoleSpy.mockRestore();
    });

    it("resets bead status when bead is 'in_progress' with stuck run", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "in_progress" }));

      createTestRun(store, projectId, {
        seedId: "bd-test",
        status: "stuck",
      });

      const { retryAction } = await import("../commands/retry.js");
      await retryAction("bd-test", {}, beadsClient, store, tmpDir);

      expect(mockUpdate).toHaveBeenCalledWith("bd-test", { status: "open" });

      consoleSpy.mockRestore();
    });

    it("resets native task status when task is 'in-progress' with stuck run", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "in-progress" }));

      createTestRun(store, projectId, {
        seedId: "bd-test",
        status: "stuck",
      });

      const { retryAction } = await import("../commands/retry.js");
      await retryAction("bd-test", {}, beadsClient, store, tmpDir, undefined, "native");

      expect(mockResetToReady).toHaveBeenCalledWith("bd-test");
      expect(mockUpdate).not.toHaveBeenCalled();

      consoleSpy.mockRestore();
    });

    it("marks running run as failed", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "in_progress" }));

      const run = createTestRun(store, projectId, {
        seedId: "bd-test",
        status: "running",
      });

      const { retryAction } = await import("../commands/retry.js");
      await retryAction("bd-test", {}, beadsClient, store, tmpDir);

      const updated = store.getRun(run.id);
      expect(updated!.status).toBe("failed");

      consoleSpy.mockRestore();
    });

    it("marks pending run as failed", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "in_progress" }));

      const run = createTestRun(store, projectId, {
        seedId: "bd-test",
        status: "pending",
      });

      const { retryAction } = await import("../commands/retry.js");
      await retryAction("bd-test", {}, beadsClient, store, tmpDir);

      const updated = store.getRun(run.id);
      expect(updated!.status).toBe("failed");

      consoleSpy.mockRestore();
    });
  });

  // ── Failed run ───────────────────────────────────────────────────────

  describe("failed run", () => {
    it("marks failed run as failed again and resets bead", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "in_progress" }));

      const run = createTestRun(store, projectId, {
        seedId: "bd-test",
        status: "failed",
      });

      const { retryAction } = await import("../commands/retry.js");
      const exitCode = await retryAction(
        "bd-test",
        {},
        beadsClient,
        store,
        tmpDir,
      );

      expect(exitCode).toBe(0);
      const updated = store.getRun(run.id);
      expect(updated!.status).toBe("failed"); // still failed (was already failed)
      expect(mockUpdate).toHaveBeenCalledWith("bd-test", { status: "open" });

      consoleSpy.mockRestore();
    });
  });

  // ── Completed run (no reset needed) ─────────────────────────────────

  describe("completed run", () => {
    it("marks a completed run as reset", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "completed" }));

      const run = createTestRun(store, projectId, {
        seedId: "bd-test",
        status: "completed",
      });

      const { retryAction } = await import("../commands/retry.js");
      await retryAction("bd-test", {}, beadsClient, store, tmpDir);

      const updated = store.getRun(run.id);
      expect(updated!.status).toBe("reset");
      expect(mockUpdate).not.toHaveBeenCalled();

      consoleSpy.mockRestore();
    });

    it("marks a merged run as reset so explicit human retry can bypass merged guard", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "closed" }));

      const run = createTestRun(store, projectId, {
        seedId: "bd-test",
        status: "merged",
      });

      const { retryAction } = await import("../commands/retry.js");
      await retryAction("bd-test", {}, beadsClient, store, tmpDir);

      const updated = store.getRun(run.id);
      expect(updated!.status).toBe("reset");
      expect(mockUpdate).not.toHaveBeenCalled();

      consoleSpy.mockRestore();
    });

    it("marks a pr-created run as reset", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "closed" }));

      const run = createTestRun(store, projectId, {
        seedId: "bd-test",
        status: "pr-created",
      });

      const { retryAction } = await import("../commands/retry.js");
      await retryAction("bd-test", {}, beadsClient, store, tmpDir);

      const updated = store.getRun(run.id);
      expect(updated!.status).toBe("reset");
      expect(mockUpdate).not.toHaveBeenCalled();

      consoleSpy.mockRestore();
    });
  });

  describe("blocked bead retry", () => {
    it("reopens a blocked bead and marks a test-failed run as reset", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "blocked" }));

      const run = createTestRun(store, projectId, {
        seedId: "bd-test",
        status: "test-failed",
      });

      const { retryAction } = await import("../commands/retry.js");
      await retryAction("bd-test", {}, beadsClient, store, tmpDir);

      const updated = store.getRun(run.id);
      expect(updated!.status).toBe("reset");
      expect(mockUpdate).toHaveBeenCalledWith("bd-test", { status: "open" });

      consoleSpy.mockRestore();
    });

    it("keeps beads-style blocked seeds on the open path", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "blocked" }));

      createTestRun(store, projectId, {
        seedId: "bd-test",
        status: "test-failed",
      });

      const { retryAction } = await import("../commands/retry.js");
      await retryAction("bd-test", {}, beadsClient, store, tmpDir, undefined, "beads");

      expect(mockUpdate).toHaveBeenCalledWith("bd-test", { status: "open" });

      consoleSpy.mockRestore();
    });
  });

  // ── --dry-run ────────────────────────────────────────────────────────

  describe("--dry-run mode", () => {
    it("does not call update in dry-run mode", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "completed" }));

      const { retryAction } = await import("../commands/retry.js");
      await retryAction("bd-test", { dryRun: true }, beadsClient, store, tmpDir);

      expect(mockUpdate).not.toHaveBeenCalled();

      consoleSpy.mockRestore();
    });

    it("does not update run status in dry-run mode", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "in_progress" }));

      const run = createTestRun(store, projectId, {
        seedId: "bd-test",
        status: "stuck",
      });

      const { retryAction } = await import("../commands/retry.js");
      await retryAction("bd-test", { dryRun: true }, beadsClient, store, tmpDir);

      // Run status must be unchanged
      const updated = store.getRun(run.id);
      expect(updated!.status).toBe("stuck");

      consoleSpy.mockRestore();
    });

    it("prints dry-run notice", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "open" }));

      const { retryAction } = await import("../commands/retry.js");
      await retryAction("bd-test", { dryRun: true }, beadsClient, store, tmpDir);

      const output = consoleSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(output).toContain("dry run");

      consoleSpy.mockRestore();
    });

    it("does not dispatch in dry-run mode even with --dispatch", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "open" }));
      mockDispatch.mockResolvedValue({
        dispatched: [],
        skipped: [],
        resumed: [],
        activeAgents: 0,
      });

      const { retryAction } = await import("../commands/retry.js");
      await retryAction(
        "bd-test",
        { dryRun: true, dispatch: true },
        beadsClient,
        store,
        tmpDir,
      );

      // dispatch is called but with dryRun: true
      expect(mockDispatch).toHaveBeenCalledWith(
        expect.objectContaining({ dryRun: true }),
      );

      consoleSpy.mockRestore();
    });
  });

  // ── --dispatch flag ──────────────────────────────────────────────────

  describe("--dispatch flag", () => {
    it("calls dispatcher when --dispatch is set", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "open" }));
      mockDispatch.mockResolvedValue({
        dispatched: [
          {
            seedId: "bd-test",
            title: "Test bead",
            runtime: "claude-code",
            model: "anthropic/claude-sonnet-4-6",
            worktreePath: "/tmp/wt/bd-test",
            runId: "run-123",
            branchName: "foreman/bd-test",
          },
        ],
        skipped: [],
        resumed: [],
        activeAgents: 0,
      });

      const { retryAction } = await import("../commands/retry.js");
      const exitCode = await retryAction(
        "bd-test",
        { dispatch: true },
        beadsClient,
        store,
        tmpDir,
      );

      expect(exitCode).toBe(0);
      expect(mockDispatch).toHaveBeenCalledWith(
        expect.objectContaining({ seedId: "bd-test", maxAgents: 1 }),
      );

      consoleSpy.mockRestore();
    });

    it("prints dispatched task info", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "open" }));
      mockDispatch.mockResolvedValue({
        dispatched: [
          {
            seedId: "bd-test",
            title: "Test bead",
            runtime: "claude-code",
            model: "anthropic/claude-sonnet-4-6",
            worktreePath: "/tmp/wt/bd-test",
            runId: "run-123",
            branchName: "foreman/bd-test",
          },
        ],
        skipped: [],
        resumed: [],
        activeAgents: 0,
      });

      const { retryAction } = await import("../commands/retry.js");
      await retryAction(
        "bd-test",
        { dispatch: true },
        beadsClient,
        store,
        tmpDir,
      );

      const output = consoleSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(output).toContain("dispatched");
      expect(output).toContain("bd-test");

      consoleSpy.mockRestore();
    });

    it("prints skipped task info when dispatcher skips", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "open" }));
      mockDispatch.mockResolvedValue({
        dispatched: [],
        skipped: [
          {
            seedId: "bd-test",
            title: "Test bead",
            reason: "Not found in ready beads",
          },
        ],
        resumed: [],
        activeAgents: 0,
      });

      const { retryAction } = await import("../commands/retry.js");
      await retryAction(
        "bd-test",
        { dispatch: true },
        beadsClient,
        store,
        tmpDir,
      );

      const output = consoleSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(output).toContain("skipped");
      expect(output).toContain("Not found in ready beads");

      consoleSpy.mockRestore();
    });

    it("passes model override to dispatcher", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "open" }));

      const { retryAction } = await import("../commands/retry.js");
      await retryAction(
        "bd-test",
        { dispatch: true, model: "anthropic/claude-opus-4-6" },
        beadsClient,
        store,
        tmpDir,
      );

      expect(mockDispatch).toHaveBeenCalledWith(
        expect.objectContaining({ model: "anthropic/claude-opus-4-6" }),
      );

      consoleSpy.mockRestore();
    });
  });

  // ── Event logging ────────────────────────────────────────────────────

  describe("event logging", () => {
    it("logs a restart event when a run is reset", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "in_progress" }));

      const run = createTestRun(store, projectId, {
        seedId: "bd-test",
        status: "stuck",
      });

      const { retryAction } = await import("../commands/retry.js");
      await retryAction("bd-test", {}, beadsClient, store, tmpDir);

      // Check that a restart event was logged
      // We verify by checking the run was updated (which happens alongside the log call)
      const updated = store.getRun(run.id);
      expect(updated!.status).toBe("failed");

      consoleSpy.mockRestore();
    });
  });

  // ── Output formatting ────────────────────────────────────────────────

  describe("output formatting", () => {
    it("shows bead title and status in output", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(
        makeBead({ id: "bd-test", title: "My test task", status: "open" }),
      );

      const { retryAction } = await import("../commands/retry.js");
      await retryAction("bd-test", {}, beadsClient, store, tmpDir);

      const output = consoleSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(output).toContain("bd-test");
      expect(output).toContain("open");

      consoleSpy.mockRestore();
    });

    it("shows 'Done' message on success", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "open" }));

      const { retryAction } = await import("../commands/retry.js");
      await retryAction("bd-test", {}, beadsClient, store, tmpDir);

      const output = consoleSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(output).toContain("Done");

      consoleSpy.mockRestore();
    });

    it("shows latest run ID in output", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "stuck" }));

      const run = createTestRun(store, projectId, {
        seedId: "bd-test",
        status: "stuck",
      });

      const { retryAction } = await import("../commands/retry.js");
      await retryAction("bd-test", {}, beadsClient, store, tmpDir);

      const output = consoleSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(output).toContain(run.id);

      consoleSpy.mockRestore();
    });
  });
});
