import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";
import { ForemanStore, type Run } from "../../lib/store.js";

/**
 * Integration tests for the dispatch-attach-detach lifecycle.
 *
 * AT-T038: Real tmux session integration test (skipped when tmux unavailable)
 * AT-T039: Fallback behavior tests (no tmux dependency)
 */

// ── Detect tmux availability ──────────────────────────────────────────

let tmuxAvailable = false;
try {
  execFileSync("which", ["tmux"], { timeout: 3000 });
  tmuxAvailable = true;
} catch {
  tmuxAvailable = false;
}

// ── Helpers ───────────────────────────────────────────────────────────

function createTestRun(
  store: ForemanStore,
  projectId: string,
  overrides: Partial<{
    seedId: string;
    status: Run["status"];
    sessionKey: string | null;
    tmuxSession: string | null;
    worktreePath: string | null;
  }> = {},
): Run {
  const seedId = overrides.seedId ?? "test-seed";
  const run = store.createRun(projectId, seedId, "claude-sonnet-4-6", overrides.worktreePath ?? "/tmp/wt");
  const updates: Record<string, unknown> = {};
  if (overrides.status) updates.status = overrides.status;
  if (overrides.sessionKey !== undefined) updates.session_key = overrides.sessionKey;
  if (overrides.tmuxSession !== undefined) updates.tmux_session = overrides.tmuxSession;
  if (Object.keys(updates).length > 0) store.updateRun(run.id, updates);
  return store.getRun(run.id)!;
}

// ── Mock setup ────────────────────────────────────────────────────────
// These mocks are used ONLY by AT-T039 tests.
// AT-T038 tests use vi.importActual to get the real TmuxClient.

const mockSpawnSync = vi.fn();
const mockSpawn = vi.fn();

// Mock Pi RPC spawn strategy so tmux tests are not intercepted by Pi
vi.mock("../pi-rpc-spawn-strategy.js", () => ({
  isPiAvailable: vi.fn().mockReturnValue(false),
  PiRpcSpawnStrategy: vi.fn(),
  PI_PHASE_CONFIGS: {},
  parsePiEvent: vi.fn().mockReturnValue(null),
}));

vi.mock("node:child_process", async (importOriginal) => {
  const original = await importOriginal<typeof import("node:child_process")>();
  return {
    ...original,
    spawn: (...args: unknown[]) => mockSpawn(...args),
    spawnSync: (...args: unknown[]) => mockSpawnSync(...args),
    // Keep execFileSync for real tmux detection
    execFileSync: original.execFileSync,
  };
});

const mockIsAvailable = vi.fn<() => Promise<boolean>>();
const mockHasSession = vi.fn<(name: string) => Promise<boolean>>();
const mockCapturePaneOutput = vi.fn<(name: string) => Promise<string[]>>();
const mockKillSession = vi.fn<(name: string) => Promise<boolean>>();
const mockCreateSession = vi.fn();

vi.mock("../../lib/tmux.js", () => {
  class MockTmuxClient {
    isAvailable = mockIsAvailable;
    hasSession = mockHasSession;
    capturePaneOutput = mockCapturePaneOutput;
    killSession = mockKillSession;
    createSession = mockCreateSession;
  }
  return {
    TmuxClient: MockTmuxClient,
    tmuxSessionName: (seedId: string) => `foreman-${seedId.replace(/[:\.\s]/g, "-")}`,
  };
});

const mockClose = vi.fn().mockResolvedValue(undefined);
const mockOpen = vi.fn().mockResolvedValue({ fd: 3, close: mockClose });
vi.mock("node:fs/promises", async (importOriginal) => {
  const original = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...original,
    open: (...args: unknown[]) => mockOpen(...args),
  };
});

// ── AT-T038: Real tmux integration (skipped when tmux unavailable) ────
// Uses vi.importActual to bypass the mock and use the real TmuxClient.

describe.skipIf(!tmuxAvailable)("AT-T038: dispatch-attach-detach cycle with real tmux", () => {
  let tmpDir: string;
  let store: ForemanStore;
  let projectId: string;
  const testSessions: string[] = [];
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let RealTmuxClient: any;
  let realTmuxSessionName: (seedId: string) => string;

  beforeEach(async () => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-tmux-integ-"));
    store = new ForemanStore(join(tmpDir, "test.db"));
    const project = store.registerProject("test-project", tmpDir);
    projectId = project.id;

    // Import the REAL TmuxClient, bypassing the mock
    const realModule = await vi.importActual<typeof import("../../lib/tmux.js")>("../../lib/tmux.js");
    RealTmuxClient = realModule.TmuxClient;
    realTmuxSessionName = realModule.tmuxSessionName;
  });

  afterEach(() => {
    // Clean up all test tmux sessions
    for (const session of testSessions) {
      try {
        execFileSync("tmux", ["kill-session", "-t", session], { timeout: 3000 });
      } catch {
        // Session may already be gone
      }
    }
    testSessions.length = 0;
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("creates a real tmux session and verifies it exists", async () => {
    const tmux = new RealTmuxClient();

    const sessionName = `foreman-test-integ-${Date.now()}`;
    testSessions.push(sessionName);

    const result = await tmux.createSession({
      sessionName,
      command: "sleep 30",
      cwd: tmpDir,
    });

    expect(result.created).toBe(true);
    expect(result.sessionName).toBe(sessionName);

    const exists = await tmux.hasSession(sessionName);
    expect(exists).toBe(true);
  });

  it("dispatch creates run record with tmux_session, attach can find it", async () => {
    const tmux = new RealTmuxClient();

    const seedId = `integ-seed-${Date.now()}`;
    const sessionName = realTmuxSessionName(seedId);
    testSessions.push(sessionName);

    const createResult = await tmux.createSession({
      sessionName,
      command: "sleep 30",
      cwd: tmpDir,
    });
    expect(createResult.created).toBe(true);

    const run = createTestRun(store, projectId, {
      seedId,
      status: "running",
      tmuxSession: sessionName,
      sessionKey: `foreman:sdk:sonnet:run1:session-sdk-123`,
    });

    const fetched = store.getRun(run.id);
    expect(fetched).toBeDefined();
    expect(fetched!.tmux_session).toBe(sessionName);

    const alive = await tmux.hasSession(sessionName);
    expect(alive).toBe(true);
  });

  it("detach (kill-session) then reattach check", async () => {
    const tmux = new RealTmuxClient();

    const sessionName = `foreman-test-reattach-${Date.now()}`;
    testSessions.push(sessionName);

    await tmux.createSession({
      sessionName,
      command: "sleep 30",
      cwd: tmpDir,
    });

    expect(await tmux.hasSession(sessionName)).toBe(true);

    const killed = await tmux.killSession(sessionName);
    expect(killed).toBe(true);

    expect(await tmux.hasSession(sessionName)).toBe(false);

    // Re-create (simulates reattach by creating a new session)
    const recreateResult = await tmux.createSession({
      sessionName,
      command: "sleep 30",
      cwd: tmpDir,
    });
    expect(recreateResult.created).toBe(true);
    expect(await tmux.hasSession(sessionName)).toBe(true);
  });

  it("completed agent session persists for review (capture-pane works)", async () => {
    const tmux = new RealTmuxClient();

    const sessionName = `foreman-test-capture-${Date.now()}`;
    testSessions.push(sessionName);

    await tmux.createSession({
      sessionName,
      command: "echo 'task completed successfully'; sleep 30",
      cwd: tmpDir,
    });

    // Give the echo time to execute
    await new Promise((r) => setTimeout(r, 500));

    const lines = await tmux.capturePaneOutput(sessionName);
    const output = lines.join("\n");
    expect(output).toContain("task completed successfully");
  });

  it("session listing includes foreman sessions", async () => {
    const tmux = new RealTmuxClient();

    const sessionName = `foreman-test-list-${Date.now()}`;
    testSessions.push(sessionName);

    await tmux.createSession({
      sessionName,
      command: "sleep 30",
      cwd: tmpDir,
    });

    const sessions = await tmux.listForemanSessions();
    const found = sessions.find((s: { sessionName: string }) => s.sessionName === sessionName);
    expect(found).toBeDefined();
    expect(found!.windowCount).toBeGreaterThanOrEqual(1);
  });
});

// ── AT-T039: Fallback behavior (no tmux dependency) ───────────────────

describe("AT-T039: fallback behavior when tmux is unavailable", () => {
  let tmpDir: string;
  let store: ForemanStore;
  let projectId: string;
  const originalEnv = { ...process.env };

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-fallback-test-"));
    store = new ForemanStore(join(tmpDir, "test.db"));
    const project = store.registerProject("test-project", tmpDir);
    projectId = project.id;

    mockSpawn.mockReset();
    mockSpawnSync.mockReset();
    mockIsAvailable.mockReset();
    mockHasSession.mockReset();
    mockCapturePaneOutput.mockReset();
    mockKillSession.mockReset();
    mockCreateSession.mockReset();
    mockOpen.mockClear();
    mockClose.mockClear();
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
    process.env = { ...originalEnv };
  });

  it("dispatch without tmux uses detached process (existing behavior preserved)", async () => {
    mockIsAvailable.mockResolvedValue(false);

    mockSpawn.mockReturnValue({
      pid: 99999,
      unref: vi.fn(),
    });

    const { spawnWorkerProcess } = await import("../dispatcher.js");
    const result = await spawnWorkerProcess({
      runId: "run-fallback-001",
      projectId: "proj-001",
      seedId: "seed-fallback",
      seedTitle: "Fallback Task",
      model: "claude-sonnet-4-6",
      worktreePath: "/tmp/wt/seed-fallback",
      prompt: "Read TASK.md",
      env: { PATH: "/usr/bin", HOME: "/tmp" },
    });

    expect(mockCreateSession).not.toHaveBeenCalled();
    expect(mockSpawn).toHaveBeenCalledTimes(1);
    expect(result.tmuxSession).toBeUndefined();
  });

  it("attach falls back to claude --resume when no tmux session", async () => {
    const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

    createTestRun(store, projectId, {
      seedId: "fallback-attach",
      status: "running",
      tmuxSession: null,
      sessionKey: "foreman:sdk:sonnet:r1:session-fallback-sdk-id",
    });

    const mockChild = {
      on: vi.fn((event: string, cb: (arg: unknown) => void) => {
        if (event === "exit") setTimeout(() => cb(0), 10);
        return mockChild;
      }),
    };
    mockSpawn.mockReturnValue(mockChild);

    const { attachAction } = await import("../../cli/commands/attach.js");
    const exitCode = await attachAction("fallback-attach", {}, store, tmpDir);

    expect(consoleSpy).toHaveBeenCalledWith(
      expect.stringContaining("Falling back to SDK session resume"),
    );
    expect(mockSpawn).toHaveBeenCalledWith(
      "claude",
      ["--resume", "fallback-sdk-id"],
      expect.objectContaining({ stdio: "inherit" }),
    );
    expect(exitCode).toBe(0);

    consoleSpy.mockRestore();
  });

  it("follow falls back to tail when tmux is unavailable", async () => {
    const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

    const run = createTestRun(store, projectId, {
      seedId: "fallback-follow",
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

    const { attachAction } = await import("../../cli/commands/attach.js");
    const exitCode = await attachAction("fallback-follow", { follow: true }, store, tmpDir);

    expect(consoleSpy).toHaveBeenCalledWith(
      expect.stringContaining("No tmux session for this run"),
    );
    expect(consoleSpy).toHaveBeenCalledWith(
      expect.stringContaining("Tailing log file"),
    );

    expect(mockSpawn).toHaveBeenCalledWith(
      "tail",
      ["-f", expect.stringContaining(run.id)],
      expect.objectContaining({ stdio: "inherit" }),
    );
    expect(exitCode).toBe(0);

    consoleSpy.mockRestore();
  });

  it("follow falls back to tail when tmux session exists but hasSession returns false", async () => {
    const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

    createTestRun(store, projectId, {
      seedId: "fallback-dead-tmux",
      status: "running",
      tmuxSession: "foreman-fallback-dead-tmux",
    });

    mockHasSession.mockResolvedValue(false);

    const mockChild = {
      on: vi.fn((event: string, cb: (arg: unknown) => void) => {
        if (event === "exit") setTimeout(() => cb(0), 10);
        return mockChild;
      }),
    };
    mockSpawn.mockReturnValue(mockChild);

    const { attachAction } = await import("../../cli/commands/attach.js");
    const exitCode = await attachAction("fallback-dead-tmux", { follow: true }, store, tmpDir);

    expect(mockHasSession).toHaveBeenCalledWith("foreman-fallback-dead-tmux");
    expect(consoleSpy).toHaveBeenCalledWith(
      expect.stringContaining("Tailing log file"),
    );
    expect(exitCode).toBe(0);

    consoleSpy.mockRestore();
  });
});
