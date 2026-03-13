import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir, homedir } from "node:os";
import { ForemanStore, type Run, type RunProgress } from "../../lib/store.js";

// ── Mock child_process ─────────────────────────────────────────────────
// We need to mock spawn and spawnSync for the attach command
const mockSpawnSync = vi.fn();
const mockSpawn = vi.fn();

vi.mock("node:child_process", () => ({
  spawn: (...args: unknown[]) => mockSpawn(...args),
  spawnSync: (...args: unknown[]) => mockSpawnSync(...args),
}));

// ── Mock TmuxClient ────────────────────────────────────────────────────
const mockHasSession = vi.fn<(name: string) => Promise<boolean>>();
const mockCapturePaneOutput = vi.fn<(name: string) => Promise<string[]>>();
const mockKillSession = vi.fn<(name: string) => Promise<boolean>>();

vi.mock("../../lib/tmux.js", () => {
  class MockTmuxClient {
    hasSession = mockHasSession;
    capturePaneOutput = mockCapturePaneOutput;
    killSession = mockKillSession;
  }
  return {
    TmuxClient: MockTmuxClient,
    tmuxSessionName: (seedId: string) => `foreman-${seedId}`,
  };
});

// ── Helpers ────────────────────────────────────────────────────────────

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
  const seedId = overrides.seedId ?? "test-seed";
  const agentType = overrides.agentType ?? "claude-sonnet-4-6";
  const run = store.createRun(projectId, seedId, agentType, overrides.worktreePath ?? "/tmp/wt");
  const updates: Partial<Pick<Run, "status" | "session_key" | "tmux_session" | "started_at">> = {};
  if (overrides.status) updates.status = overrides.status;
  if (overrides.sessionKey !== undefined) updates.session_key = overrides.sessionKey;
  if (overrides.tmuxSession !== undefined) updates.tmux_session = overrides.tmuxSession;
  if (overrides.startedAt !== undefined) updates.started_at = overrides.startedAt;
  if (Object.keys(updates).length > 0) store.updateRun(run.id, updates);
  if (overrides.progress) store.updateRunProgress(run.id, overrides.progress);
  return store.getRun(run.id)!;
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
    mockSpawnSync.mockReset();
    mockHasSession.mockReset();
    mockCapturePaneOutput.mockReset();
    mockKillSession.mockReset();
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  // ── Story 3.1: Interactive Tmux Attachment ───────────────────────────

  describe("AT-T018: default attachment uses tmux attach-session", () => {
    it("attaches to tmux session when tmux_session is set and session exists", async () => {
      const run = createTestRun(store, projectId, {
        seedId: "abc1",
        status: "running",
        tmuxSession: "foreman-abc1",
        sessionKey: "foreman:sdk:sonnet:r1:session-s1",
      });

      mockHasSession.mockResolvedValue(true);
      mockSpawnSync.mockReturnValue({ status: 0 });

      // Import the module to access the internal action function
      const { attachAction } = await import("../commands/attach.js");
      const exitCode = await attachAction(run.seed_id, {}, store, tmpDir);

      expect(mockHasSession).toHaveBeenCalledWith("foreman-abc1");
      expect(mockSpawnSync).toHaveBeenCalledWith(
        "tmux",
        ["attach-session", "-t", "foreman-abc1"],
        expect.objectContaining({ stdio: "inherit" }),
      );
      expect(exitCode).toBe(0);
    });

    it("prints header with seed ID and phase before attaching", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const run = createTestRun(store, projectId, {
        seedId: "abc1",
        status: "running",
        tmuxSession: "foreman-abc1",
        progress: {
          toolCalls: 10,
          toolBreakdown: {},
          filesChanged: [],
          turns: 5,
          costUsd: 0.42,
          tokensIn: 1000,
          tokensOut: 500,
          lastToolCall: null,
          lastActivity: new Date().toISOString(),
          currentPhase: "developer",
        },
      });

      mockHasSession.mockResolvedValue(true);
      mockSpawnSync.mockReturnValue({ status: 0 });

      const { attachAction } = await import("../commands/attach.js");
      await attachAction(run.seed_id, {}, store, tmpDir);

      expect(consoleSpy).toHaveBeenCalledWith(
        expect.stringContaining("foreman-abc1"),
      );
      expect(consoleSpy).toHaveBeenCalledWith(
        expect.stringContaining("developer"),
      );
      consoleSpy.mockRestore();
    });

    it("exits with tmux exit code", async () => {
      createTestRun(store, projectId, {
        seedId: "abc1",
        status: "running",
        tmuxSession: "foreman-abc1",
      });

      mockHasSession.mockResolvedValue(true);
      mockSpawnSync.mockReturnValue({ status: 42 });

      const { attachAction } = await import("../commands/attach.js");
      const exitCode = await attachAction("abc1", {}, store, tmpDir);

      expect(exitCode).toBe(42);
    });
  });

  // ── Story 3.1: AT-T019: Fallback chain ──────────────────────────────

  describe("AT-T019: fallback to claude --resume when no tmux session", () => {
    it("falls back to claude --resume when tmux_session is null", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const consoleErrSpy = vi.spyOn(console, "error").mockImplementation(() => {});

      createTestRun(store, projectId, {
        seedId: "abc2",
        status: "running",
        tmuxSession: null,
        sessionKey: "foreman:sdk:sonnet:r1:session-the-sdk-id",
      });

      // Mock spawn to return an event emitter
      const mockChild = {
        on: vi.fn((event: string, cb: (arg: unknown) => void) => {
          if (event === "exit") {
            // Simulate immediate exit
            setTimeout(() => cb(0), 10);
          }
          return mockChild;
        }),
      };
      mockSpawn.mockReturnValue(mockChild);

      const { attachAction } = await import("../commands/attach.js");
      const exitCode = await attachAction("abc2", {}, store, tmpDir);

      expect(consoleSpy).toHaveBeenCalledWith(
        expect.stringContaining("Tmux session not found"),
      );
      expect(mockSpawn).toHaveBeenCalledWith(
        "claude",
        ["--resume", "the-sdk-id"],
        expect.objectContaining({ stdio: "inherit" }),
      );
      expect(exitCode).toBe(0);

      consoleSpy.mockRestore();
      consoleErrSpy.mockRestore();
    });

    it("falls back to claude --resume when hasSession returns false", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      createTestRun(store, projectId, {
        seedId: "abc3",
        status: "running",
        tmuxSession: "foreman-abc3",
        sessionKey: "foreman:sdk:sonnet:r1:session-fallback-id",
      });

      mockHasSession.mockResolvedValue(false);

      const mockChild = {
        on: vi.fn((event: string, cb: (arg: unknown) => void) => {
          if (event === "exit") setTimeout(() => cb(0), 10);
          return mockChild;
        }),
      };
      mockSpawn.mockReturnValue(mockChild);

      const { attachAction } = await import("../commands/attach.js");
      await attachAction("abc3", {}, store, tmpDir);

      expect(mockHasSession).toHaveBeenCalledWith("foreman-abc3");
      expect(consoleSpy).toHaveBeenCalledWith(
        expect.stringContaining("Falling back to SDK session resume"),
      );
      expect(mockSpawn).toHaveBeenCalledWith(
        "claude",
        ["--resume", "fallback-id"],
        expect.objectContaining({ stdio: "inherit" }),
      );

      consoleSpy.mockRestore();
    });

    it("prints actionable error when both tmux and SDK session are unavailable", async () => {
      const consoleErrSpy = vi.spyOn(console, "error").mockImplementation(() => {});

      createTestRun(store, projectId, {
        seedId: "abc4",
        status: "running",
        tmuxSession: null,
        sessionKey: null,
      });

      const { attachAction } = await import("../commands/attach.js");
      const exitCode = await attachAction("abc4", {}, store, tmpDir);

      expect(consoleErrSpy).toHaveBeenCalledWith(
        expect.stringContaining("No active session found"),
      );
      expect(consoleErrSpy).toHaveBeenCalledWith(
        expect.stringContaining("--list"),
      );
      expect(exitCode).toBe(1);

      consoleErrSpy.mockRestore();
    });
  });

  // ── Story 3.2: Read-Only Follow Mode ────────────────────────────────

  describe("AT-T020/AT-T021: --follow mode", () => {
    it("polls capturePaneOutput and prints only new lines", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      createTestRun(store, projectId, {
        seedId: "follow1",
        status: "running",
        tmuxSession: "foreman-follow1",
        progress: {
          toolCalls: 5,
          toolBreakdown: {},
          filesChanged: [],
          turns: 3,
          costUsd: 0.10,
          tokensIn: 500,
          tokensOut: 200,
          lastToolCall: null,
          lastActivity: new Date().toISOString(),
          currentPhase: "developer",
        },
      });

      mockHasSession.mockResolvedValue(true);

      // First call: 3 lines. Second call: 5 lines. Third call: session gone.
      mockCapturePaneOutput
        .mockResolvedValueOnce(["line 1", "line 2", "line 3"])
        .mockResolvedValueOnce(["line 1", "line 2", "line 3", "line 4", "line 5"])
        .mockResolvedValueOnce(["line 1", "line 2", "line 3", "line 4", "line 5"]);

      // After 3 polls, session ends
      mockHasSession
        .mockResolvedValueOnce(true) // initial check
        .mockResolvedValueOnce(true) // poll 1
        .mockResolvedValueOnce(true) // poll 2
        .mockResolvedValueOnce(false); // poll 3 -> session ended

      const { attachAction } = await import("../commands/attach.js");

      // Use a very short interval for testing
      const origEnv = process.env.FOREMAN_TMUX_FOLLOW_INTERVAL_MS;
      process.env.FOREMAN_TMUX_FOLLOW_INTERVAL_MS = "50";

      const exitCode = await attachAction("follow1", { follow: true }, store, tmpDir);

      process.env.FOREMAN_TMUX_FOLLOW_INTERVAL_MS = origEnv;

      // Should have printed the header
      expect(consoleSpy).toHaveBeenCalledWith(
        expect.stringContaining("Following"),
      );

      // Should have printed initial lines then only new lines
      const logCalls = consoleSpy.mock.calls.map((c) => c[0]);
      // line 1, 2, 3 from first poll, line 4, 5 from second poll
      expect(logCalls).toContain("line 1");
      expect(logCalls).toContain("line 4");
      expect(logCalls).toContain("line 5");

      // Should print session ended message
      expect(consoleSpy).toHaveBeenCalledWith(
        expect.stringContaining("Session ended"),
      );

      expect(exitCode).toBe(0);

      consoleSpy.mockRestore();
    });

    it("exits on SIGINT with message that agent continues", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      createTestRun(store, projectId, {
        seedId: "follow-sigint",
        status: "running",
        tmuxSession: "foreman-follow-sigint",
      });

      mockHasSession.mockResolvedValue(true);
      mockCapturePaneOutput.mockResolvedValue(["output"]);

      const { attachAction } = await import("../commands/attach.js");

      process.env.FOREMAN_TMUX_FOLLOW_INTERVAL_MS = "50";

      // Start follow in background, then abort after a short delay
      const abortController = new AbortController();
      const resultPromise = attachAction(
        "follow-sigint",
        { follow: true, _signal: abortController.signal },
        store,
        tmpDir,
      );

      // Abort after a poll
      await new Promise((r) => setTimeout(r, 100));
      abortController.abort();

      const exitCode = await resultPromise;

      delete process.env.FOREMAN_TMUX_FOLLOW_INTERVAL_MS;

      expect(consoleSpy).toHaveBeenCalledWith(
        expect.stringContaining("Stopped following"),
      );
      expect(consoleSpy).toHaveBeenCalledWith(
        expect.stringContaining("Agent continues running"),
      );
      expect(exitCode).toBe(0);

      consoleSpy.mockRestore();
    });
  });

  // ── AT-T022: Follow mode fallback ────────────────────────────────────

  describe("AT-T022: --follow falls back to tail when no tmux session", () => {
    it("falls back to tailing log file when no tmux_session", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const run = createTestRun(store, projectId, {
        seedId: "follow-notmux",
        status: "running",
        tmuxSession: null,
      });

      const mockChild = {
        on: vi.fn((event: string, cb: (arg: unknown) => void) => {
          if (event === "exit") setTimeout(() => cb(0), 10);
          return mockChild;
        }),
      };
      mockSpawn.mockReturnValue(mockChild);

      const { attachAction } = await import("../commands/attach.js");
      const exitCode = await attachAction("follow-notmux", { follow: true }, store, tmpDir);

      expect(consoleSpy).toHaveBeenCalledWith(
        expect.stringContaining("No tmux session for this run"),
      );
      expect(consoleSpy).toHaveBeenCalledWith(
        expect.stringContaining("Tailing log file"),
      );

      const logPath = join(homedir(), ".foreman", "logs", `${run.id}.out`);
      expect(mockSpawn).toHaveBeenCalledWith(
        "tail",
        ["-f", logPath],
        expect.objectContaining({ stdio: "inherit" }),
      );
      expect(exitCode).toBe(0);

      consoleSpy.mockRestore();
    });

    it("falls back to tailing when tmux session doesnt exist", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const run = createTestRun(store, projectId, {
        seedId: "follow-dead",
        status: "running",
        tmuxSession: "foreman-follow-dead",
      });

      mockHasSession.mockResolvedValue(false);

      const mockChild = {
        on: vi.fn((event: string, cb: (arg: unknown) => void) => {
          if (event === "exit") setTimeout(() => cb(0), 10);
          return mockChild;
        }),
      };
      mockSpawn.mockReturnValue(mockChild);

      const { attachAction } = await import("../commands/attach.js");
      const exitCode = await attachAction("follow-dead", { follow: true }, store, tmpDir);

      expect(consoleSpy).toHaveBeenCalledWith(
        expect.stringContaining("No tmux session for this run"),
      );
      expect(exitCode).toBe(0);

      consoleSpy.mockRestore();
    });
  });

  // ── Story 3.3: Session Kill and Cleanup ──────────────────────────────

  describe("AT-T023: --kill option", () => {
    it("kills tmux session and marks running run as stuck", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const run = createTestRun(store, projectId, {
        seedId: "kill1",
        status: "running",
        tmuxSession: "foreman-kill1",
      });

      mockKillSession.mockResolvedValue(true);

      const { attachAction } = await import("../commands/attach.js");
      const exitCode = await attachAction("kill1", { kill: true }, store, tmpDir);

      expect(mockKillSession).toHaveBeenCalledWith("foreman-kill1");
      expect(consoleSpy).toHaveBeenCalledWith(
        expect.stringContaining("Killed tmux session foreman-kill1"),
      );

      // Verify run is now stuck
      const updatedRun = store.getRun(run.id);
      expect(updatedRun!.status).toBe("stuck");
      expect(exitCode).toBe(0);

      consoleSpy.mockRestore();
    });

    it("kills tmux session and marks pending run as stuck", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const run = createTestRun(store, projectId, {
        seedId: "kill-pending",
        status: "pending",
        tmuxSession: "foreman-kill-pending",
      });

      mockKillSession.mockResolvedValue(true);

      const { attachAction } = await import("../commands/attach.js");
      await attachAction("kill-pending", { kill: true }, store, tmpDir);

      const updatedRun = store.getRun(run.id);
      expect(updatedRun!.status).toBe("stuck");

      consoleSpy.mockRestore();
    });

    it("does not change status if run is already completed", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const run = createTestRun(store, projectId, {
        seedId: "kill-done",
        status: "completed",
        tmuxSession: "foreman-kill-done",
      });

      mockKillSession.mockResolvedValue(true);

      const { attachAction } = await import("../commands/attach.js");
      await attachAction("kill-done", { kill: true }, store, tmpDir);

      const updatedRun = store.getRun(run.id);
      expect(updatedRun!.status).toBe("completed");

      consoleSpy.mockRestore();
    });

    it("prints message when no tmux session exists", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      createTestRun(store, projectId, {
        seedId: "kill-none",
        status: "running",
        tmuxSession: null,
      });

      const { attachAction } = await import("../commands/attach.js");
      const exitCode = await attachAction("kill-none", { kill: true }, store, tmpDir);

      expect(consoleSpy).toHaveBeenCalledWith(
        expect.stringContaining("No tmux session to kill"),
      );
      expect(exitCode).toBe(0);

      consoleSpy.mockRestore();
    });
  });

  // ── Story 3.4: Enhanced Session Listing ──────────────────────────────

  describe("AT-T024/AT-T025: enhanced session listing", () => {
    it("shows enhanced columns with correct formatting", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const now = new Date();
      const thirtyMinAgo = new Date(now.getTime() - 30 * 60 * 1000).toISOString();

      createTestRun(store, projectId, {
        seedId: "list-seed-1",
        status: "running",
        tmuxSession: "foreman-list-seed-1",
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
        tmuxSession: null,
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

      // Verify column headers
      expect(headerLine).toBeTruthy();
      expect(headerLine).toContain("STATUS");
      expect(headerLine).toContain("PHASE");
      expect(headerLine).toContain("PROGRESS");
      expect(headerLine).toContain("COST");
      expect(headerLine).toContain("ELAPSED");
      expect(headerLine).toContain("TMUX");

      // Verify data rows exist
      const allOutput = logCalls.join("\n");
      expect(allOutput).toContain("list-seed-1");
      expect(allOutput).toContain("running");
      expect(allOutput).toContain("developer");
      expect(allOutput).toContain("$0.42");
      expect(allOutput).toContain("foreman-list-seed-1");

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

      // Find the data lines containing each status
      const runningIdx = dataLines.findIndex((l) => l.includes("running-second"));
      const stuckIdx = dataLines.findIndex((l) => l.includes("stuck-third"));
      const completedIdx = dataLines.findIndex((l) => l.includes("completed-first"));

      // Running should come before stuck, stuck before completed
      expect(runningIdx).toBeLessThan(stuckIdx);
      expect(stuckIdx).toBeLessThan(completedIdx);

      consoleSpy.mockRestore();
    });

    it("formats elapsed time correctly", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const now = new Date();
      // 90 minutes ago = 1h 30m
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
      // Should show "1h 30m" format
      expect(allOutput).toMatch(/1h\s+30m/);

      consoleSpy.mockRestore();
    });

    it("shows (none) for runs without tmux session", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      createTestRun(store, projectId, {
        seedId: "no-tmux",
        status: "running",
        tmuxSession: null,
      });

      const { listSessionsEnhanced } = await import("../commands/attach.js");
      listSessionsEnhanced(store, tmpDir);

      const logCalls = consoleSpy.mock.calls.map((c) => String(c[0]));
      const allOutput = logCalls.join("\n");
      expect(allOutput).toContain("(none)");

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
});
