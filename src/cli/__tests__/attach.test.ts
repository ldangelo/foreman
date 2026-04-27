import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir, homedir } from "node:os";
import { ForemanStore, type Run, type RunProgress } from "../../lib/store.js";
import { attachCommand } from "../commands/attach.js";
import * as projectTaskSupport from "../commands/project-task-support.js";
import { buildSdkSessionKey } from "../../orchestrator/dispatcher.js";

type AttachActionFn = typeof import("../commands/attach.js").attachAction;
type AttachDaemonContext = Parameters<AttachActionFn>[4];

const { mockRunsList, mockUpdateStatus, mockCreateTrpcClient } = vi.hoisted(() => {
  const mockRunsList = vi.fn();
  const mockUpdateStatus = vi.fn();
  const mockCreateTrpcClient = vi.fn(() => ({
    runs: {
      list: mockRunsList,
      updateStatus: mockUpdateStatus,
    },
  }));

  return { mockRunsList, mockUpdateStatus, mockCreateTrpcClient };
});

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: () => mockCreateTrpcClient(),
}));

// ── Mock child_process ─────────────────────────────────────────────────
const mockSpawn = vi.fn();
const mockExecFile = vi.fn();

vi.mock("node:child_process", () => ({
  spawn: (...args: unknown[]) => mockSpawn(...args),
  execFile: (...args: unknown[]) => mockExecFile(...args),
}));

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

function createDaemonRunRow(run: Run, projectId: string) {
  return {
    id: run.id,
    project_id: projectId,
    bead_id: run.seed_id,
    status: "running",
    branch: "main",
    agent_type: run.agent_type,
    session_key: run.session_key,
    worktree_path: run.worktree_path,
    progress: null,
    base_branch: null,
    merge_strategy: null,
    queued_at: run.created_at,
    started_at: run.started_at,
    finished_at: null,
    created_at: run.created_at,
  };
}

// ── Test suite ─────────────────────────────────────────────────────────

describe("foreman attach", () => {
  let store: ForemanStore;
  let tmpDir: string;
  let projectId: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-attach-test-"));
    store = new ForemanStore(join(tmpDir, "test.db"));
    const project = store.registerProject("test-project", tmpDir);
    projectId = project.id;
    mockSpawn.mockReset();
    mockRunsList.mockReset();
    mockUpdateStatus.mockReset();
    mockCreateTrpcClient.mockClear();
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  // ── Default attachment (SDK resume) ─────────────────────────────────

  describe("default attachment", () => {
    it("resumes SDK session when session key has session ID", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      createTestRun(store, projectId, {
        seedId: "abc2",
        status: "running",
        sessionKey: buildSdkSessionKey("sonnet", "r1", 12345, "the-sdk-id"),
      });

      const mockChild = {
        on: vi.fn((event: string, cb: (arg: unknown) => void) => {
          if (event === "exit") setTimeout(() => cb(0), 10);
          return mockChild;
        }),
      };
      mockSpawn.mockReturnValue(mockChild);

      const { attachAction } = await import("../commands/attach.js");
      const exitCode = await attachAction("abc2", {}, store, tmpDir);

      expect(mockSpawn).toHaveBeenCalledWith(
        "claude",
        ["--resume", "the-sdk-id"],
        expect.objectContaining({ stdio: "inherit" }),
      );
      expect(exitCode).toBe(0);

      consoleSpy.mockRestore();
    });

    it("prints info before launching claude --resume", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      createTestRun(store, projectId, {
        seedId: "abc-info",
        status: "running",
        sessionKey: buildSdkSessionKey("sonnet", "r1", 12345, "info-id"),
      });

      const mockChild = {
        on: vi.fn((event: string, cb: (arg: unknown) => void) => {
          if (event === "exit") setTimeout(() => cb(0), 10);
          return mockChild;
        }),
      };
      mockSpawn.mockReturnValue(mockChild);

      const { attachAction } = await import("../commands/attach.js");
      await attachAction("abc-info", {}, store, tmpDir);

      const output = consoleSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(output).toContain("abc-info");
      expect(output).toContain("info-id");

      consoleSpy.mockRestore();
    });

    it("falls back to log file tail when no SDK session", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const run = createTestRun(store, projectId, {
        seedId: "abc-nossdk",
        status: "running",
        sessionKey: null,
      });

      const mockChild = {
        on: vi.fn((event: string, cb: (arg: unknown) => void) => {
          if (event === "exit") setTimeout(() => cb(0), 10);
          return mockChild;
        }),
      };
      mockSpawn.mockReturnValue(mockChild);

      const { attachAction } = await import("../commands/attach.js");
      const exitCode = await attachAction("abc-nossdk", {}, store, tmpDir);

      const logPath = join(homedir(), ".foreman", "logs", `${run.id}.out`);
      expect(mockSpawn).toHaveBeenCalledWith(
        "tail",
        ["-f", logPath],
        expect.objectContaining({ stdio: "inherit" }),
      );
      expect(exitCode).toBe(0);

      consoleSpy.mockRestore();
    });

    it("returns error exit code when claude fails to launch", async () => {
      const consoleErrSpy = vi.spyOn(console, "error").mockImplementation(() => {});

      createTestRun(store, projectId, {
        seedId: "abc-err",
        status: "running",
        sessionKey: buildSdkSessionKey("sonnet", "r1", 12345, "err-id"),
      });

      const mockChild = {
        on: vi.fn((event: string, cb: (arg: unknown) => void) => {
          if (event === "error") setTimeout(() => cb(new Error("ENOENT")), 10);
          return mockChild;
        }),
      };
      mockSpawn.mockReturnValue(mockChild);

      const { attachAction } = await import("../commands/attach.js");
      const exitCode = await attachAction("abc-err", {}, store, tmpDir);

      expect(exitCode).toBe(1);

      consoleErrSpy.mockRestore();
    });
  });

  // ── --follow mode ────────────────────────────────────────────────────

  describe("--follow mode", () => {
    it("tails the run's log file", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const run = createTestRun(store, projectId, {
        seedId: "follow1",
        status: "running",
      });

      const mockChild = {
        on: vi.fn((event: string, cb: (arg: unknown) => void) => {
          if (event === "exit") setTimeout(() => cb(0), 10);
          return mockChild;
        }),
        kill: vi.fn(),
      };
      mockSpawn.mockReturnValue(mockChild);

      const { attachAction } = await import("../commands/attach.js");
      const exitCode = await attachAction("follow1", { follow: true }, store, tmpDir);

      const logPath = join(homedir(), ".foreman", "logs", `${run.id}.out`);
      expect(mockSpawn).toHaveBeenCalledWith(
        "tail",
        ["-f", logPath],
        expect.objectContaining({ stdio: "inherit" }),
      );
      expect(exitCode).toBe(0);

      consoleSpy.mockRestore();
    });

    it("exits cleanly when AbortSignal fires", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      createTestRun(store, projectId, {
        seedId: "follow-sigint",
        status: "running",
      });

      let exitCb: ((code: unknown) => void) | null = null;
      const mockChild = {
        on: vi.fn((event: string, cb: (arg: unknown) => void) => {
          if (event === "exit") exitCb = cb;
          return mockChild;
        }),
        kill: vi.fn(() => {
          setTimeout(() => exitCb?.(0), 10);
        }),
      };
      mockSpawn.mockReturnValue(mockChild);

      const { attachAction } = await import("../commands/attach.js");

      const abortController = new AbortController();
      const resultPromise = attachAction(
        "follow-sigint",
        { follow: true, _signal: abortController.signal },
        store,
        tmpDir,
      );

      await new Promise((r) => setTimeout(r, 50));
      abortController.abort();

      const exitCode = await resultPromise;
      expect(exitCode).toBe(0);
      expect(mockChild.kill).toHaveBeenCalledWith("SIGTERM");

      consoleSpy.mockRestore();
    });
  });

  // ── --kill option ────────────────────────────────────────────────────

  describe("--kill option", () => {
    function makeDaemonContext(run: Run, updateStatus: ReturnType<typeof vi.fn>): AttachDaemonContext {
      return {
        client: {
          runs: {
            list: vi.fn().mockResolvedValue([
              {
                id: run.id,
                project_id: projectId,
                bead_id: run.seed_id,
                status: "running",
                branch: "main",
                agent_type: run.agent_type,
                session_key: run.session_key,
                worktree_path: run.worktree_path,
                progress: null,
                base_branch: null,
                merge_strategy: null,
                queued_at: run.created_at,
                started_at: run.started_at,
                finished_at: null,
                created_at: run.created_at,
              },
            ]),
            updateStatus,
          },
        },
        projectId,
        projectPath: tmpDir,
      } as unknown as AttachDaemonContext;
    }

    it("uses the daemon update path for registered projects", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const killSpy = vi.spyOn(process, "kill").mockImplementation(() => true);

      const run = createTestRun(store, projectId, {
        seedId: "kill-registered",
        status: "running",
        sessionKey: buildSdkSessionKey("sonnet", "r1", 44444, "registered"),
      });

      const updateStatus = vi.fn().mockResolvedValue({});
      const daemon = makeDaemonContext(run, updateStatus);
      const updateRunSpy = vi.spyOn(store, "updateRun");

      const { attachAction } = await import("../commands/attach.js");
      const exitCode = await attachAction("kill-registered", { kill: true }, store, tmpDir, daemon);

      expect(updateStatus).toHaveBeenCalledWith({ runId: run.id, status: "stuck" });
      expect(killSpy).toHaveBeenCalledWith(44444, "SIGTERM");
      expect(updateRunSpy).not.toHaveBeenCalled();
      expect(exitCode).toBe(0);

      killSpy.mockRestore();
      consoleSpy.mockRestore();
    });

    it("falls back to local store updates when the daemon path fails", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const killSpy = vi.spyOn(process, "kill").mockImplementation(() => true);

      const run = createTestRun(store, projectId, {
        seedId: "kill-daemon-fail",
        status: "running",
        sessionKey: buildSdkSessionKey("sonnet", "r1", 55555, "daemon-fail"),
      });

      const updateStatus = vi.fn().mockRejectedValue(new Error("daemon unavailable"));
      const daemon = makeDaemonContext(run, updateStatus);
      const updateRunSpy = vi.spyOn(store, "updateRun");

      const { attachAction } = await import("../commands/attach.js");
      const exitCode = await attachAction("kill-daemon-fail", { kill: true }, store, tmpDir, daemon);

      expect(updateStatus).toHaveBeenCalledWith({ runId: run.id, status: "stuck" });
      expect(updateRunSpy).toHaveBeenCalledWith(run.id, { status: "stuck" });
      expect(killSpy).toHaveBeenCalledWith(55555, "SIGTERM");
      expect(exitCode).toBe(0);

      killSpy.mockRestore();
      consoleSpy.mockRestore();
    });

    it("kills process by PID and marks running run as stuck", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const killSpy = vi.spyOn(process, "kill").mockImplementation(() => true);

      const run = createTestRun(store, projectId, {
        seedId: "kill1",
        status: "running",
        sessionKey: buildSdkSessionKey("sonnet", "r1", 12345, "abc"),
      });

      const { attachAction } = await import("../commands/attach.js");
      const exitCode = await attachAction("kill1", { kill: true }, store, tmpDir);

      expect(killSpy).toHaveBeenCalledWith(12345, "SIGTERM");

      const updatedRun = store.getRun(run.id);
      expect(updatedRun!.status).toBe("stuck");
      expect(exitCode).toBe(0);

      killSpy.mockRestore();
      consoleSpy.mockRestore();
    });

    it("kills process and marks pending run as stuck", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const killSpy = vi.spyOn(process, "kill").mockImplementation(() => true);

      const run = createTestRun(store, projectId, {
        seedId: "kill-pending",
        status: "pending",
        sessionKey: buildSdkSessionKey("sonnet", "r1", 22222, "def"),
      });

      const { attachAction } = await import("../commands/attach.js");
      await attachAction("kill-pending", { kill: true }, store, tmpDir);

      const updatedRun = store.getRun(run.id);
      expect(updatedRun!.status).toBe("stuck");

      killSpy.mockRestore();
      consoleSpy.mockRestore();
    });

    it("does not change status if run is already completed", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const killSpy = vi.spyOn(process, "kill").mockImplementation(() => true);

      const run = createTestRun(store, projectId, {
        seedId: "kill-done",
        status: "completed",
        sessionKey: buildSdkSessionKey("sonnet", "r1", 33333, "ghi"),
      });

      const { attachAction } = await import("../commands/attach.js");
      await attachAction("kill-done", { kill: true }, store, tmpDir);

      const updatedRun = store.getRun(run.id);
      expect(updatedRun!.status).toBe("completed");

      killSpy.mockRestore();
      consoleSpy.mockRestore();
    });

    it("prints message and returns 0 when no pid found", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      createTestRun(store, projectId, {
        seedId: "kill-none",
        status: "running",
        sessionKey: null,
      });

      const { attachAction } = await import("../commands/attach.js");
      const exitCode = await attachAction("kill-none", { kill: true }, store, tmpDir);

      const output = consoleSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(output).toContain("No pid found");
      expect(exitCode).toBe(0);

      consoleSpy.mockRestore();
    });
  });

  // ── Enhanced session listing ──────────────────────────────────────────

  describe("listSessionsEnhanced", () => {
    it("shows enhanced columns with correct formatting", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const now = new Date();
      const thirtyMinAgo = new Date(now.getTime() - 30 * 60 * 1000).toISOString();

      createTestRun(store, projectId, {
        seedId: "list-seed-1",
        status: "running",
        startedAt: thirtyMinAgo,
        agentType: "claude-sonnet-4-6",
        worktreePath: "/tmp/wt1",
        progress: {
          toolCalls: 42,
          toolBreakdown: { Read: 12, Edit: 5, Bash: 3 },
          filesChanged: Array.from({ length: 8 }, (_, i) => `file${i}.ts`),
          turns: 20,
          costUsd: 0.42,
          tokensIn: 10000,
          tokensOut: 5000,
          lastToolCall: "Edit",
          lastActivity: now.toISOString(),
          currentPhase: "developer",
        },
      });

      createTestRun(store, projectId, {
        seedId: "list-seed-2",
        status: "completed",
        startedAt: new Date(now.getTime() - 90 * 60 * 1000).toISOString(),
        agentType: "claude-opus-4-6",
        worktreePath: "/tmp/wt2",
        progress: {
          toolCalls: 100,
          toolBreakdown: {},
          filesChanged: ["a.ts", "b.ts"],
          turns: 50,
          costUsd: 1.23,
          tokensIn: 20000,
          tokensOut: 10000,
          lastToolCall: null,
          lastActivity: now.toISOString(),
          currentPhase: "finalize",
        },
      });

      const { listSessionsEnhanced } = await import("../commands/attach.js");
      listSessionsEnhanced(store, tmpDir);

      const logCalls = consoleSpy.mock.calls.map((c) => String(c[0]));
      const headerLine = logCalls.find((l) => l.includes("SEED"));

      // Verify column headers (no TMUX column anymore)
      expect(headerLine).toBeTruthy();
      expect(headerLine).toContain("STATUS");
      expect(headerLine).toContain("PHASE");
      expect(headerLine).toContain("PROGRESS");
      expect(headerLine).toContain("COST");
      expect(headerLine).toContain("ELAPSED");
      expect(headerLine).toContain("WORKTREE");

      // Verify data rows exist
      const allOutput = logCalls.join("\n");
      expect(allOutput).toContain("list-seed-1");
      expect(allOutput).toContain("running");
      expect(allOutput).toContain("developer");
      expect(allOutput).toContain("$0.42");

      consoleSpy.mockRestore();
    });

    it("sorts by status priority (running first, then completed)", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const now = new Date();

      createTestRun(store, projectId, {
        seedId: "completed-first",
        status: "completed",
        startedAt: now.toISOString(),
      });

      createTestRun(store, projectId, {
        seedId: "running-second",
        status: "running",
        startedAt: now.toISOString(),
      });

      createTestRun(store, projectId, {
        seedId: "stuck-third",
        status: "stuck",
        startedAt: now.toISOString(),
      });

      const { listSessionsEnhanced } = await import("../commands/attach.js");
      listSessionsEnhanced(store, tmpDir);

      const logCalls = consoleSpy.mock.calls.map((c) => String(c[0]));
      const dataLines = logCalls.filter(
        (l) => l.includes("running") || l.includes("stuck") || l.includes("completed"),
      );

      const runningIdx = dataLines.findIndex((l) => l.includes("running-second"));
      const stuckIdx = dataLines.findIndex((l) => l.includes("stuck-third"));
      const completedIdx = dataLines.findIndex((l) => l.includes("completed-first"));

      expect(runningIdx).toBeLessThan(stuckIdx);
      expect(stuckIdx).toBeLessThan(completedIdx);

      consoleSpy.mockRestore();
    });

    it("formats elapsed time correctly", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const now = new Date();
      const ninetyMinAgo = new Date(now.getTime() - 90 * 60 * 1000).toISOString();

      createTestRun(store, projectId, {
        seedId: "elapsed-test",
        status: "running",
        startedAt: ninetyMinAgo,
      });

      const { listSessionsEnhanced } = await import("../commands/attach.js");
      listSessionsEnhanced(store, tmpDir);

      const logCalls = consoleSpy.mock.calls.map((c) => String(c[0]));
      const allOutput = logCalls.join("\n");
      expect(allOutput).toMatch(/1h\s+30m/);

      consoleSpy.mockRestore();
    });

    it("shows message when no sessions found", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const { listSessionsEnhanced } = await import("../commands/attach.js");
      listSessionsEnhanced(store, tmpDir);

      expect(consoleSpy).toHaveBeenCalledWith("No sessions found.");

      consoleSpy.mockRestore();
    });
  });

  // ── Existing tests (preserved) ───────────────────────────────────────

  describe("session ID extraction", () => {
    it("extracts session ID from standard session key", () => {
      const project = store.registerProject("p2", "/p2");
      const run = store.createRun(project.id, "bd-abc", "claude-sonnet-4-6", "/wt");
      store.updateRun(run.id, {
        session_key: "foreman:sdk:claude-sonnet-4-6:run123:session-abc-def-123",
        status: "running",
      });

      const fetched = store.getRun(run.id)!;
      const match = fetched.session_key?.match(/session-(.+)$/);
      expect(match).toBeTruthy();
      expect(match![1]).toBe("abc-def-123");
    });

    it("returns null for session key without session ID", () => {
      const project = store.registerProject("p3", "/p3");
      const run = store.createRun(project.id, "bd-abc", "claude-sonnet-4-6", "/wt");
      store.updateRun(run.id, {
        session_key: "foreman:sdk:claude-sonnet-4-6:run123",
        status: "running",
      });

      const fetched = store.getRun(run.id)!;
      const match = fetched.session_key?.match(/session-(.+)$/);
      expect(match).toBeNull();
    });
  });

  describe("run lookup by seed ID", () => {
    it("finds the most recent run for a seed", () => {
      const run1 = store.createRun(projectId, "bd-xyz", "claude-sonnet-4-6", "/wt");
      store.updateRun(run1.id, { status: "completed" });
      const run2 = store.createRun(projectId, "bd-xyz", "claude-opus-4-6", "/wt");
      store.updateRun(run2.id, {
        status: "running",
        session_key: "foreman:sdk:claude-opus-4-6:run2:session-latest-session",
      });

      const runs = store.getRunsForSeed("bd-xyz", projectId);
      expect(runs.length).toBeGreaterThanOrEqual(2);
      expect(runs[0].id).toBe(run2.id);
    });

    it("returns empty for unknown seed", () => {
      const runs = store.getRunsForSeed("bd-nonexistent", projectId);
      expect(runs).toEqual([]);
    });
  });

  describe("error handling", () => {
    it("prints error when run not found", async () => {
      const consoleErrSpy = vi.spyOn(console, "error").mockImplementation(() => {});

      const { attachAction } = await import("../commands/attach.js");
      const exitCode = await attachAction("nonexistent-id", {}, store, tmpDir);

      expect(exitCode).toBe(1);
      expect(consoleErrSpy).toHaveBeenCalledWith(
        expect.stringContaining("No run found"),
      );

      consoleErrSpy.mockRestore();
    });
  });

  // ── --stream mode ─────────────────────────────────────────────────────

  describe("--stream mode", () => {
    it("returns 0 immediately when run is already in terminal state", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      createTestRun(store, projectId, {
        seedId: "stream-done",
        status: "completed",
      });

      const { attachAction } = await import("../commands/attach.js");
      const exitCode = await attachAction("stream-done", { stream: true, _pollIntervalMs: 50 }, store, tmpDir);

      expect(exitCode).toBe(0);
      const output = consoleSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(output).toContain("stream-done");

      consoleSpy.mockRestore();
    });

    it("prints existing messages before polling", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const run = createTestRun(store, projectId, {
        seedId: "stream-existing",
        status: "completed",
      });

      // Insert a message before streaming
      store.sendMessage(run.id, "developer", "foreman", "phase-started", '{"phase":"developer"}');

      const { attachAction } = await import("../commands/attach.js");
      await attachAction("stream-existing", { stream: true, _pollIntervalMs: 50 }, store, tmpDir);

      const output = consoleSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(output).toContain("phase-started");
      expect(output).toContain("phase=developer");

      consoleSpy.mockRestore();
    });

    it("stops when AbortSignal fires", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      createTestRun(store, projectId, {
        seedId: "stream-abort",
        status: "running",
      });

      const { attachAction } = await import("../commands/attach.js");
      const abortController = new AbortController();

      const resultPromise = attachAction(
        "stream-abort",
        { stream: true, _signal: abortController.signal, _pollIntervalMs: 50 },
        store,
        tmpDir,
      );

      // Abort after a tick
      await new Promise((r) => setTimeout(r, 80));
      abortController.abort();

      const exitCode = await resultPromise;
      expect(exitCode).toBe(0);

      const output = consoleSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(output).toContain("stream-abort");

      consoleSpy.mockRestore();
    });

    it("stops when run transitions to terminal state", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const run = createTestRun(store, projectId, {
        seedId: "stream-terminal",
        status: "running",
      });

      const { attachAction } = await import("../commands/attach.js");

      // Transition the run to completed after a short delay
      const transitionTimeout = setTimeout(() => {
        store.updateRun(run.id, { status: "completed" });
      }, 80);

      const exitCode = await attachAction(
        "stream-terminal",
        { stream: true, _pollIntervalMs: 30 },
        store,
        tmpDir,
      );

      clearTimeout(transitionTimeout);

      expect(exitCode).toBe(0);
      const output = consoleSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(output).toContain("completed");

      consoleSpy.mockRestore();
    });

    it("prints new messages as they arrive", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const run = createTestRun(store, projectId, {
        seedId: "stream-live",
        status: "running",
      });

      const { attachAction } = await import("../commands/attach.js");

      // Send a message after a short delay, then complete the run
      const msgTimeout = setTimeout(() => {
        store.sendMessage(run.id, "qa", "foreman", "phase-complete", '{"phase":"qa","status":"pass"}');
        setTimeout(() => {
          store.updateRun(run.id, { status: "completed" });
        }, 50);
      }, 80);

      const exitCode = await attachAction(
        "stream-live",
        { stream: true, _pollIntervalMs: 30 },
        store,
        tmpDir,
      );

      clearTimeout(msgTimeout);

      expect(exitCode).toBe(0);
      const output = consoleSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(output).toContain("phase-complete");
      expect(output).toContain("phase=qa");

      consoleSpy.mockRestore();
    });

    it("formats JSON body with status summary", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const run = createTestRun(store, projectId, {
        seedId: "stream-fmt",
        status: "completed",
      });

      store.sendMessage(run.id, "developer", "foreman", "agent-error", '{"phase":"developer","error":"test failure"}');

      const { attachAction } = await import("../commands/attach.js");
      await attachAction("stream-fmt", { stream: true, _pollIntervalMs: 50 }, store, tmpDir);

      const output = consoleSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(output).toContain("agent-error");
      expect(output).toContain("error=test failure");

      consoleSpy.mockRestore();
    });
  });

  describe("CLI bootstrap", () => {
    it("falls back to local listing when daemon list RPC rejects", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const forProjectSpy = vi.spyOn(ForemanStore, "forProject").mockReturnValue(store);
      const projectRoot = process.cwd();
      const resolveRepoRootProjectPathSpy = vi
        .spyOn(projectTaskSupport, "resolveRepoRootProjectPath")
        .mockResolvedValue(projectRoot);
      const commandProject = store.registerProject("command-project", projectRoot);
      const listRegisteredProjectsSpy = vi
        .spyOn(projectTaskSupport, "listRegisteredProjects")
        .mockResolvedValue([{ id: commandProject.id, name: "command-project", path: projectRoot }]);

      const run = createTestRun(store, commandProject.id, {
        seedId: "daemon-list-fallback",
        status: "running",
      });
      mockRunsList.mockRejectedValueOnce(new Error("daemon unavailable"));

      await attachCommand.parseAsync(["--list"], { from: "user" });

      const output = consoleSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(output).toContain("Attachable sessions");
      expect(output).toContain(run.seed_id);
      expect(mockRunsList).toHaveBeenCalled();

      consoleSpy.mockRestore();
      forProjectSpy.mockRestore();
      resolveRepoRootProjectPathSpy.mockRestore();
      listRegisteredProjectsSpy.mockRestore();
    });

    it("falls back to local attach when daemon run lookup rejects", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => undefined) as never);
      const forProjectSpy = vi.spyOn(ForemanStore, "forProject").mockReturnValue(store);
      const projectRoot = process.cwd();
      const resolveRepoRootProjectPathSpy = vi
        .spyOn(projectTaskSupport, "resolveRepoRootProjectPath")
        .mockResolvedValue(projectRoot);
      const commandProject = store.registerProject("command-project", projectRoot);
      const listRegisteredProjectsSpy = vi
        .spyOn(projectTaskSupport, "listRegisteredProjects")
        .mockResolvedValue([{ id: commandProject.id, name: "command-project", path: projectRoot }]);

      const run = createTestRun(store, commandProject.id, {
        seedId: "daemon-attach-fallback",
        status: "running",
        sessionKey: "foreman:sdk:sonnet:r1:session-local-fallback",
      });

      mockRunsList.mockRejectedValueOnce(new Error("daemon unavailable"));

      const mockChild = {
        on: vi.fn((event: string, cb: (arg: unknown) => void) => {
          if (event === "exit") setTimeout(() => cb(0), 10);
          return mockChild;
        }),
      };
      mockSpawn.mockReturnValue(mockChild);

      await attachCommand.parseAsync([run.id], { from: "user" });

      expect(mockSpawn).toHaveBeenCalledWith(
        "claude",
        ["--resume", "local-fallback"],
        expect.objectContaining({ stdio: "inherit", cwd: "/tmp/wt" }),
      );
      expect(exitSpy).toHaveBeenCalledWith(0);

      consoleSpy.mockRestore();
      exitSpy.mockRestore();
      forProjectSpy.mockRestore();
      resolveRepoRootProjectPathSpy.mockRestore();
      listRegisteredProjectsSpy.mockRestore();
    });

    it("keeps the daemon kill path unchanged", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => undefined) as never);
      const forProjectSpy = vi.spyOn(ForemanStore, "forProject").mockReturnValue(store);
      const projectRoot = process.cwd();
      const resolveRepoRootProjectPathSpy = vi
        .spyOn(projectTaskSupport, "resolveRepoRootProjectPath")
        .mockResolvedValue(projectRoot);
      const commandProject = store.registerProject("command-project", projectRoot);
      const listRegisteredProjectsSpy = vi
        .spyOn(projectTaskSupport, "listRegisteredProjects")
        .mockResolvedValue([{ id: commandProject.id, name: "command-project", path: projectRoot }]);

      const run = createTestRun(store, commandProject.id, {
        seedId: "kill-unchanged",
        status: "running",
        sessionKey: buildSdkSessionKey("sonnet", "r1", 24680, "kill-unchanged"),
      });

      mockRunsList.mockResolvedValueOnce([createDaemonRunRow(run, projectId)]);

      const killSpy = vi.spyOn(process, "kill").mockImplementation(() => true);

      await attachCommand.parseAsync([run.id, "--kill"], { from: "user" });

      expect(mockRunsList).toHaveBeenCalled();
      expect(killSpy).toHaveBeenCalledWith(24680, "SIGTERM");
      expect(exitSpy).toHaveBeenCalledWith(0);

      killSpy.mockRestore();
      consoleSpy.mockRestore();
      exitSpy.mockRestore();
      forProjectSpy.mockRestore();
      resolveRepoRootProjectPathSpy.mockRestore();
      listRegisteredProjectsSpy.mockRestore();
    });

    it("constructs the fallback store from the resolved project path", async () => {
      const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});
      const resolveRepoRootProjectPathSpy = vi
        .spyOn(projectTaskSupport, "resolveRepoRootProjectPath")
        .mockResolvedValue("/resolved/project-root");
      const listRegisteredProjectsSpy = vi
        .spyOn(projectTaskSupport, "listRegisteredProjects")
        .mockResolvedValue([]);
      const forProjectSpy = vi.spyOn(ForemanStore, "forProject").mockReturnValue({
        close: vi.fn(),
        getProjectByPath: vi.fn().mockReturnValue(null),
      } as unknown as ForemanStore);

      await attachCommand.parseAsync(["--list"], { from: "user" });

      expect(resolveRepoRootProjectPathSpy).toHaveBeenCalledWith({});
      expect(forProjectSpy).toHaveBeenCalledWith("/resolved/project-root");
      expect(listRegisteredProjectsSpy).toHaveBeenCalled();

      consoleSpy.mockRestore();
      resolveRepoRootProjectPathSpy.mockRestore();
      listRegisteredProjectsSpy.mockRestore();
      forProjectSpy.mockRestore();
    });
  });
});
