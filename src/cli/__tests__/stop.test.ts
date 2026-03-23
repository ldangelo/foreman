import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore, type Run, type RunProgress } from "../../lib/store.js";

// ── Helpers ────────────────────────────────────────────────────────────

function createTestRun(
  store: ForemanStore,
  projectId: string,
  overrides: Partial<{
    seedId: string;
    status: Run["status"];
    sessionKey: string | null;
    worktreePath: string | null;
    agentType: string;
    startedAt: string | null;
    progress: RunProgress | null;
  }> = {},
): Run {
  const seedId = overrides.seedId ?? "test-seed";
  const agentType = overrides.agentType ?? "claude-sonnet-4-6";
  const run = store.createRun(projectId, seedId, agentType, overrides.worktreePath ?? "/tmp/wt");
  const updates: Partial<Pick<Run, "status" | "session_key" | "started_at">> = {};
  if (overrides.status) updates.status = overrides.status;
  if (overrides.sessionKey !== undefined) updates.session_key = overrides.sessionKey;
  if (overrides.startedAt !== undefined) updates.started_at = overrides.startedAt;
  if (Object.keys(updates).length > 0) store.updateRun(run.id, updates);
  if (overrides.progress) store.updateRunProgress(run.id, overrides.progress);
  return store.getRun(run.id)!;
}

// ── Test suite ─────────────────────────────────────────────────────────

describe("foreman stop", () => {
  let store: ForemanStore;
  let tmpDir: string;
  let projectId: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-stop-test-"));
    store = new ForemanStore(join(tmpDir, "test.db"));
    const project = store.registerProject("test-project", tmpDir);
    projectId = project.id;
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  // ── --list ──────────────────────────────────────────────────────────

  describe("--list option", () => {
    it("lists active runs with header columns", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      createTestRun(store, projectId, {
        seedId: "bd-abc1",
        status: "running",
        startedAt: new Date(Date.now() - 30 * 60 * 1000).toISOString(),
      });

      const { stopAction } = await import("../commands/stop.js");
      const exitCode = await stopAction(undefined, { list: true }, store, tmpDir);

      expect(exitCode).toBe(0);
      const output = consoleSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(output).toContain("SEED");
      expect(output).toContain("STATUS");
      expect(output).toContain("PID");
      expect(output).toContain("bd-abc1");
      expect(output).toContain("running");

      consoleSpy.mockRestore();
    });

    it("shows 'no active runs' when none exist", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const { stopAction } = await import("../commands/stop.js");
      await stopAction(undefined, { list: true }, store, tmpDir);

      expect(consoleSpy).toHaveBeenCalledWith("No active runs found.");

      consoleSpy.mockRestore();
    });

    it("returns exit code 0 for list", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const { stopAction } = await import("../commands/stop.js");
      const exitCode = await stopAction(undefined, { list: true }, store, tmpDir);

      expect(exitCode).toBe(0);
      consoleSpy.mockRestore();
    });
  });

  // ── No project ──────────────────────────────────────────────────────

  describe("missing project", () => {
    it("errors when no project registered for path", async () => {
      const consoleErrSpy = vi.spyOn(console, "error").mockImplementation(() => {});

      const { stopAction } = await import("../commands/stop.js");
      const exitCode = await stopAction(undefined, {}, store, "/nonexistent/path");

      expect(exitCode).toBe(1);
      expect(consoleErrSpy).toHaveBeenCalledWith(
        expect.stringContaining("No project registered"),
      );

      consoleErrSpy.mockRestore();
    });
  });

  // ── Stop all active runs ────────────────────────────────────────────

  describe("stop all active runs", () => {
    it("marks all running sessions as stuck", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const killSpy = vi.spyOn(process, "kill").mockImplementation(() => true);

      const run1 = createTestRun(store, projectId, {
        seedId: "bd-r1",
        status: "running",
        sessionKey: "foreman:sdk:sonnet:r1:pid-11111:session-abc",
      });
      const run2 = createTestRun(store, projectId, {
        seedId: "bd-r2",
        status: "running",
        sessionKey: "foreman:sdk:sonnet:r2:pid-22222:session-def",
      });

      const { stopAction } = await import("../commands/stop.js");
      const exitCode = await stopAction(undefined, {}, store, tmpDir);

      expect(exitCode).toBe(0);

      // Both runs should be marked as stuck
      const updated1 = store.getRun(run1.id);
      const updated2 = store.getRun(run2.id);
      expect(updated1!.status).toBe("stuck");
      expect(updated2!.status).toBe("stuck");

      killSpy.mockRestore();
      consoleSpy.mockRestore();
    });

    it("prints 'no active runs' when nothing to stop", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const { stopAction } = await import("../commands/stop.js");
      const exitCode = await stopAction(undefined, {}, store, tmpDir);

      expect(exitCode).toBe(0);
      expect(consoleSpy).toHaveBeenCalledWith(
        expect.stringContaining("No active runs to stop"),
      );

      consoleSpy.mockRestore();
    });

    it("marks run as stuck after stopping", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const killSpy = vi.spyOn(process, "kill").mockImplementation(() => true);

      const run = createTestRun(store, projectId, {
        seedId: "bd-stuck1",
        status: "running",
        sessionKey: "foreman:sdk:sonnet:r1:pid-33333:session-abc",
      });

      const { stopAction } = await import("../commands/stop.js");
      await stopAction(undefined, {}, store, tmpDir);

      const updated = store.getRun(run.id);
      expect(updated!.status).toBe("stuck");
      expect(updated!.completed_at).not.toBeNull();

      killSpy.mockRestore();
      consoleSpy.mockRestore();
    });

    it("marks pending runs as stuck after stopping", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const run = createTestRun(store, projectId, {
        seedId: "bd-pending1",
        status: "pending",
      });

      const { stopAction } = await import("../commands/stop.js");
      await stopAction(undefined, {}, store, tmpDir);

      const updated = store.getRun(run.id);
      expect(updated!.status).toBe("stuck");

      consoleSpy.mockRestore();
    });
  });

  // ── Stop specific run by ID ─────────────────────────────────────────

  describe("stop specific run", () => {
    it("stops a run by seed ID", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const killSpy = vi.spyOn(process, "kill").mockImplementation(() => true);

      const run = createTestRun(store, projectId, {
        seedId: "bd-specific",
        status: "running",
        sessionKey: "foreman:sdk:sonnet:r1:pid-44444:session-abc",
      });

      const { stopAction } = await import("../commands/stop.js");
      const exitCode = await stopAction("bd-specific", {}, store, tmpDir);

      expect(exitCode).toBe(0);

      const updated = store.getRun(run.id);
      expect(updated!.status).toBe("stuck");

      killSpy.mockRestore();
      consoleSpy.mockRestore();
    });

    it("stops a run by run ID", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const killSpy = vi.spyOn(process, "kill").mockImplementation(() => true);

      const run = createTestRun(store, projectId, {
        seedId: "bd-byrunid",
        status: "running",
        sessionKey: "foreman:sdk:sonnet:r1:pid-55555:session-abc",
      });

      const { stopAction } = await import("../commands/stop.js");
      const exitCode = await stopAction(run.id, {}, store, tmpDir);

      expect(exitCode).toBe(0);

      const updated = store.getRun(run.id);
      expect(updated!.status).toBe("stuck");

      killSpy.mockRestore();
      consoleSpy.mockRestore();
    });

    it("errors when run not found", async () => {
      const consoleErrSpy = vi.spyOn(console, "error").mockImplementation(() => {});

      const { stopAction } = await import("../commands/stop.js");
      const exitCode = await stopAction("bd-nonexistent", {}, store, tmpDir);

      expect(exitCode).toBe(1);
      expect(consoleErrSpy).toHaveBeenCalledWith(
        expect.stringContaining("No run found for"),
      );
      expect(consoleErrSpy).toHaveBeenCalledWith(
        expect.stringContaining("--list"),
      );

      consoleErrSpy.mockRestore();
    });
  });

  // ── --dry-run ───────────────────────────────────────────────────────

  describe("--dry-run mode", () => {
    it("does not kill process in dry-run mode", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const killSpy = vi.spyOn(process, "kill").mockImplementation(() => true);

      createTestRun(store, projectId, {
        seedId: "bd-dry",
        status: "running",
        sessionKey: "foreman:sdk:sonnet:r1:pid-66666:session-abc",
      });

      const { stopAction } = await import("../commands/stop.js");
      await stopAction(undefined, { dryRun: true }, store, tmpDir);

      expect(killSpy).not.toHaveBeenCalledWith(expect.anything(), "SIGTERM");
      expect(killSpy).not.toHaveBeenCalledWith(expect.anything(), "SIGKILL");

      killSpy.mockRestore();
      consoleSpy.mockRestore();
    });

    it("does not update run status in dry-run mode", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const run = createTestRun(store, projectId, {
        seedId: "bd-dry-status",
        status: "running",
      });

      const { stopAction } = await import("../commands/stop.js");
      await stopAction(undefined, { dryRun: true }, store, tmpDir);

      const updated = store.getRun(run.id);
      expect(updated!.status).toBe("running"); // unchanged

      consoleSpy.mockRestore();
    });

    it("prints dry-run notice", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      createTestRun(store, projectId, {
        seedId: "bd-dry-notice",
        status: "running",
      });

      const { stopAction } = await import("../commands/stop.js");
      await stopAction(undefined, { dryRun: true }, store, tmpDir);

      expect(consoleSpy).toHaveBeenCalledWith(
        expect.stringContaining("dry run"),
      );

      consoleSpy.mockRestore();
    });
  });

  // ── --force ─────────────────────────────────────────────────────────

  describe("--force flag", () => {
    it("sends SIGKILL instead of SIGTERM when --force is used", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const killSpy = vi.spyOn(process, "kill").mockImplementation(() => true);

      const run = createTestRun(store, projectId, {
        seedId: "bd-force",
        status: "running",
        sessionKey: "foreman:sdk:sonnet:r1:pid-99999:session-abc",
      });

      // Simulate the pid as alive
      killSpy.mockImplementation((pid, signal) => {
        if (signal === 0) return true; // isAlive check
        return true;
      });

      const { stopAction } = await import("../commands/stop.js");
      await stopAction(run.id, { force: true }, store, tmpDir);

      // Should have been called with SIGKILL
      const sigkillCall = killSpy.mock.calls.find(
        ([, sig]) => sig === "SIGKILL",
      );
      expect(sigkillCall).toBeTruthy();

      killSpy.mockRestore();
      consoleSpy.mockRestore();
    });

    it("sends SIGTERM by default (no --force)", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const killSpy = vi.spyOn(process, "kill").mockImplementation(() => true);

      const run = createTestRun(store, projectId, {
        seedId: "bd-sigterm",
        sessionKey: "foreman:sdk:sonnet:r1:pid-88888:session-abc",
        status: "running",
      });

      const { stopAction } = await import("../commands/stop.js");
      await stopAction(run.id, { force: false }, store, tmpDir);

      const sigtermCall = killSpy.mock.calls.find(
        ([, sig]) => sig === "SIGTERM",
      );
      expect(sigtermCall).toBeTruthy();

      killSpy.mockRestore();
      consoleSpy.mockRestore();
    });
  });

  // ── Error handling ──────────────────────────────────────────────────

  describe("error handling", () => {
    it("handles run with no pid gracefully — still marks stuck", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const run = createTestRun(store, projectId, {
        seedId: "bd-notmux",
        status: "running",
        sessionKey: null,
      });

      const { stopAction } = await import("../commands/stop.js");
      const exitCode = await stopAction(run.id, {}, store, tmpDir);

      // Should succeed (no error)
      expect(exitCode).toBe(0);

      // Run must be marked stuck even though there was no process to kill
      const updated = store.getRun(run.id);
      expect(updated!.status).toBe("stuck");
      expect(updated!.completed_at).not.toBeNull();

      // A warning must be surfaced so the user knows the stop was incomplete
      const output = consoleSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(output).toContain("no pid found");

      consoleSpy.mockRestore();
    });
  });

  // ── listActiveRuns ──────────────────────────────────────────────────

  describe("listActiveRuns", () => {
    it("shows PID column when session key contains pid", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      createTestRun(store, projectId, {
        seedId: "bd-pid-list",
        status: "running",
        sessionKey: "foreman:sdk:sonnet:r1:pid-12345:session-abc",
        startedAt: new Date().toISOString(),
      });

      const { listActiveRuns } = await import("../commands/stop.js");
      listActiveRuns(store, tmpDir);

      const output = consoleSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(output).toContain("12345");
      expect(output).toContain("PID");

      consoleSpy.mockRestore();
    });

    it("shows (none) for PID when session key is null", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      createTestRun(store, projectId, {
        seedId: "bd-nopid",
        status: "running",
        sessionKey: null,
      });

      const { listActiveRuns } = await import("../commands/stop.js");
      listActiveRuns(store, tmpDir);

      const output = consoleSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(output).toContain("(none)");

      consoleSpy.mockRestore();
    });

    it("shows error when no project registered", async () => {
      const consoleErrSpy = vi.spyOn(console, "error").mockImplementation(() => {});

      const { listActiveRuns } = await import("../commands/stop.js");
      listActiveRuns(store, "/invalid/path");

      expect(consoleErrSpy).toHaveBeenCalledWith(
        expect.stringContaining("No project registered"),
      );

      consoleErrSpy.mockRestore();
    });
  });

  // ── Cross-project isolation ─────────────────────────────────────────

  describe("cross-project isolation", () => {
    it("cannot stop a run from a different project by run ID", async () => {
      const consoleErrSpy = vi.spyOn(console, "error").mockImplementation(() => {});
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      // Create a second project and a run in it
      const tmpDir2 = mkdtempSync(join(tmpdir(), "foreman-stop-test-other-"));
      try {
        const otherProject = store.registerProject("other-project", tmpDir2);
        const otherRun = createTestRun(store, otherProject.id, {
          seedId: "bd-other",
          status: "running",
        });

        const { stopAction } = await import("../commands/stop.js");
        // Try to stop other project's run while current projectPath = tmpDir (project A)
        const exitCode = await stopAction(otherRun.id, {}, store, tmpDir);

        expect(exitCode).toBe(1);
        expect(consoleErrSpy).toHaveBeenCalledWith(
          expect.stringContaining("No run found for"),
        );
        // Other project's run should remain untouched
        const stillRunning = store.getRun(otherRun.id);
        expect(stillRunning!.status).toBe("running");
      } finally {
        rmSync(tmpDir2, { recursive: true, force: true });
        consoleErrSpy.mockRestore();
        consoleSpy.mockRestore();
      }
    });
  });

  // ── --list exit code ────────────────────────────────────────────────

  describe("--list exit code", () => {
    it("returns exit code 1 when no project registered for --list", async () => {
      const consoleErrSpy = vi.spyOn(console, "error").mockImplementation(() => {});

      const { stopAction } = await import("../commands/stop.js");
      const exitCode = await stopAction(undefined, { list: true }, store, "/nonexistent/path");

      expect(exitCode).toBe(1);
      expect(consoleErrSpy).toHaveBeenCalledWith(
        expect.stringContaining("No project registered"),
      );

      consoleErrSpy.mockRestore();
    });
  });

  // ── formatElapsed sub-minute ────────────────────────────────────────

  describe("elapsed time formatting", () => {
    it("shows seconds for sub-minute elapsed time", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      createTestRun(store, projectId, {
        seedId: "bd-subsec",
        status: "running",
        startedAt: new Date(Date.now() - 45 * 1000).toISOString(), // 45 seconds ago
      });

      const { stopAction } = await import("../commands/stop.js");
      await stopAction(undefined, { list: true }, store, tmpDir);

      const output = consoleSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(output).toMatch(/\d+s/); // should show e.g. "45s" not "0m"

      consoleSpy.mockRestore();
    });

    it("shows minutes for 90-second elapsed time", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      createTestRun(store, projectId, {
        seedId: "bd-90sec",
        status: "running",
        startedAt: new Date(Date.now() - 90 * 1000).toISOString(), // 90 seconds ago
      });

      const { stopAction } = await import("../commands/stop.js");
      await stopAction(undefined, { list: true }, store, tmpDir);

      const output = consoleSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(output).toContain("1m");

      consoleSpy.mockRestore();
    });
  });

  // ── Stopped count accuracy ──────────────────────────────────────────

  describe("stopped count accuracy", () => {
    it("counts each run once when PID is killed", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const killSpy = vi.spyOn(process, "kill").mockImplementation(() => true);

      createTestRun(store, projectId, {
        seedId: "bd-both",
        status: "running",
        sessionKey: "foreman:sdk:sonnet:r1:pid-77777:session-abc",
      });

      const { stopAction } = await import("../commands/stop.js");
      await stopAction(undefined, {}, store, tmpDir);

      const output = consoleSpy.mock.calls.map((c) => String(c[0])).join("\n");
      // Summary must show "Runs stopped: 1"
      expect(output).toContain("Runs stopped: 1");

      killSpy.mockRestore();
      consoleSpy.mockRestore();
    });
  });
});
