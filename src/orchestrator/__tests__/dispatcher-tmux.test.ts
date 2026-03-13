import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore } from "../../lib/store.js";

/**
 * Tests for tmux-based worker spawning in spawnWorkerProcess().
 *
 * AT-T013: SpawnStrategy pattern (TmuxSpawnStrategy / DetachedSpawnStrategy)
 * AT-T014: Stale session cleanup before creating new session
 * AT-T015: Persist tmux_session in store after successful creation
 * AT-T016: Handle tmux creation failure with graceful fallback
 * AT-T017: Comprehensive unit tests
 */

// Mock child_process.spawn to prevent real process spawning
const mockSpawn = vi.fn(() => ({
  pid: 12345,
  unref: vi.fn(),
}));

vi.mock("node:child_process", async (importOriginal) => {
  const original = await importOriginal<typeof import("node:child_process")>();
  return {
    ...original,
    spawn: mockSpawn,
  };
});

// Mock fs.open to prevent real file handle creation
const mockClose = vi.fn().mockResolvedValue(undefined);
const mockOpen = vi.fn().mockResolvedValue({ fd: 3, close: mockClose });
vi.mock("node:fs/promises", async (importOriginal) => {
  const original = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...original,
    open: (...args: unknown[]) => mockOpen(...args),
  };
});

// Mock TmuxClient
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const mockIsAvailable = vi.fn() as any;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const mockCreateSession = vi.fn() as any;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const mockKillSession = vi.fn() as any;

vi.mock("../../lib/tmux.js", () => {
  // Create a proper constructor function that returns the mock methods
  function MockTmuxClient() {
    return {
      isAvailable: mockIsAvailable,
      createSession: mockCreateSession,
      killSession: mockKillSession,
    };
  }
  return {
    TmuxClient: MockTmuxClient,
    tmuxSessionName: (seedId: string) => `foreman-${seedId.replace(/[:\.\s]/g, "-")}`,
  };
});

// Now import the module under test
const { spawnWorkerProcess, TmuxSpawnStrategy, DetachedSpawnStrategy } = await import("../dispatcher.js");
// Also import the SpawnStrategy type for type checking
import type { SpawnStrategy, WorkerConfig } from "../dispatcher.js";

describe("SpawnStrategy pattern (AT-T013)", () => {
  let tmpDir: string;
  let store: ForemanStore;
  const originalEnv = { ...process.env };

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-tmux-test-"));
    store = new ForemanStore(join(tmpDir, "test.db"));
    mockSpawn.mockClear();
    mockOpen.mockClear();
    mockClose.mockClear();
    mockIsAvailable.mockReset();
    mockCreateSession.mockReset();
    mockKillSession.mockReset();
    delete process.env.FOREMAN_TMUX_DISABLED;
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
    process.env = { ...originalEnv };
  });

  const baseConfig: WorkerConfig = {
    runId: "run-001",
    projectId: "proj-001",
    seedId: "seed-abc",
    seedTitle: "Test Task",
    model: "claude-sonnet-4-6",
    worktreePath: "/tmp/wt/seed-abc",
    prompt: "Read TASK.md and implement the task.",
    env: { PATH: "/usr/bin", HOME: "/tmp" },
  };

  it("TmuxSpawnStrategy interface is exported and well-typed", () => {
    // Type-level check: TmuxSpawnStrategy satisfies SpawnStrategy
    const strategy: SpawnStrategy = new TmuxSpawnStrategy();
    expect(strategy).toBeDefined();
    expect(typeof strategy.spawn).toBe("function");
  });

  it("DetachedSpawnStrategy interface is exported and well-typed", () => {
    const strategy: SpawnStrategy = new DetachedSpawnStrategy();
    expect(strategy).toBeDefined();
    expect(typeof strategy.spawn).toBe("function");
  });

  it("TmuxSpawnStrategy calls TmuxClient.createSession with correct arguments", async () => {
    mockIsAvailable.mockResolvedValue(true);
    mockKillSession.mockResolvedValue(false);
    mockCreateSession.mockResolvedValue({ sessionName: "foreman-seed-abc", created: true });

    const strategy = new TmuxSpawnStrategy();
    const result = await strategy.spawn(baseConfig);

    expect(mockCreateSession).toHaveBeenCalledTimes(1);
    const callArgs = mockCreateSession.mock.calls[0]?.[0] as Record<string, unknown> | undefined;
    expect(callArgs).toBeDefined();
    expect(callArgs!.sessionName).toBe("foreman-seed-abc");
    expect(callArgs!.cwd).toBe("/tmp/wt/seed-abc");
    // Command should contain tsx, worker script, and log redirection
    expect(callArgs!.command).toContain("agent-worker.ts");
    expect(String(callArgs!.command)).toContain("> ");
    expect(String(callArgs!.command)).toContain("2> ");
    expect(result.tmuxSession).toBe("foreman-seed-abc");
  });

  it("DetachedSpawnStrategy uses child_process.spawn with detached: true", async () => {
    const strategy = new DetachedSpawnStrategy();
    const result = await strategy.spawn(baseConfig);

    expect(mockSpawn).toHaveBeenCalledTimes(1);
    const callArgs = mockSpawn.mock.calls[0] as unknown[];
    // Third argument is options with detached: true
    expect(callArgs[2]).toMatchObject({
      detached: true,
      cwd: "/tmp/wt/seed-abc",
    });
    expect(result.tmuxSession).toBeUndefined();
  });
});

describe("tmux available -> creates session + stores tmux_session (AT-T015)", () => {
  let tmpDir: string;
  let store: ForemanStore;
  const originalEnv = { ...process.env };

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-tmux-test-"));
    store = new ForemanStore(join(tmpDir, "test.db"));
    mockSpawn.mockClear();
    mockOpen.mockClear();
    mockClose.mockClear();
    mockIsAvailable.mockReset();
    mockCreateSession.mockReset();
    mockKillSession.mockReset();
    delete process.env.FOREMAN_TMUX_DISABLED;
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
    process.env = { ...originalEnv };
  });

  it("spawnWorkerProcess creates tmux session when available", async () => {
    mockIsAvailable.mockResolvedValue(true);
    mockKillSession.mockResolvedValue(false);
    mockCreateSession.mockResolvedValue({ sessionName: "foreman-seed-abc", created: true });

    const config: WorkerConfig = {
      runId: "run-001",
      projectId: "proj-001",
      seedId: "seed-abc",
      seedTitle: "Test Task",
      model: "claude-sonnet-4-6",
      worktreePath: "/tmp/wt/seed-abc",
      prompt: "Read TASK.md",
      env: { PATH: "/usr/bin" },
    };

    const result = await spawnWorkerProcess(config);

    expect(mockIsAvailable).toHaveBeenCalled();
    expect(mockCreateSession).toHaveBeenCalledTimes(1);
    expect(result.tmuxSession).toBe("foreman-seed-abc");
    // Should NOT have called the detached spawn path
    expect(mockSpawn).not.toHaveBeenCalled();
  });

  it("stores tmux_session in run record after successful creation", async () => {
    mockIsAvailable.mockResolvedValue(true);
    mockKillSession.mockResolvedValue(false);
    mockCreateSession.mockResolvedValue({ sessionName: "foreman-seed-abc", created: true });

    const project = store.registerProject("test", tmpDir);
    const run = store.createRun(project.id, "seed-abc", "claude-sonnet-4-6", "/tmp/wt");

    const config: WorkerConfig = {
      runId: run.id,
      projectId: project.id,
      seedId: "seed-abc",
      seedTitle: "Test Task",
      model: "claude-sonnet-4-6",
      worktreePath: "/tmp/wt/seed-abc",
      prompt: "Read TASK.md",
      env: { PATH: "/usr/bin" },
    };

    const result = await spawnWorkerProcess(config);

    // Caller is responsible for storing tmux_session, so we verify the result
    expect(result.tmuxSession).toBe("foreman-seed-abc");

    // Simulate what the Dispatcher does after spawnWorkerProcess returns
    store.updateRun(run.id, { tmux_session: result.tmuxSession });
    const updated = store.getRun(run.id);
    expect(updated?.tmux_session).toBe("foreman-seed-abc");
  });
});

describe("tmux unavailable -> existing detached spawn (AT-T013)", () => {
  let tmpDir: string;
  const originalEnv = { ...process.env };

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-tmux-test-"));
    mockSpawn.mockClear();
    mockOpen.mockClear();
    mockClose.mockClear();
    mockIsAvailable.mockReset();
    mockCreateSession.mockReset();
    mockKillSession.mockReset();
    delete process.env.FOREMAN_TMUX_DISABLED;
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    process.env = { ...originalEnv };
  });

  it("falls back to detached spawn when tmux is not available", async () => {
    mockIsAvailable.mockResolvedValue(false);

    const config: WorkerConfig = {
      runId: "run-002",
      projectId: "proj-001",
      seedId: "seed-def",
      seedTitle: "Fallback Task",
      model: "claude-sonnet-4-6",
      worktreePath: "/tmp/wt/seed-def",
      prompt: "Read TASK.md",
      env: { PATH: "/usr/bin" },
    };

    const result = await spawnWorkerProcess(config);

    expect(mockIsAvailable).toHaveBeenCalled();
    expect(mockCreateSession).not.toHaveBeenCalled();
    expect(mockSpawn).toHaveBeenCalledTimes(1);
    expect(result.tmuxSession).toBeUndefined();
  });
});

describe("tmux creation fails -> fallback to detached spawn (AT-T016)", () => {
  let tmpDir: string;
  const originalEnv = { ...process.env };

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-tmux-test-"));
    mockSpawn.mockClear();
    mockOpen.mockClear();
    mockClose.mockClear();
    mockIsAvailable.mockReset();
    mockCreateSession.mockReset();
    mockKillSession.mockReset();
    delete process.env.FOREMAN_TMUX_DISABLED;
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    process.env = { ...originalEnv };
  });

  it("falls back to detached spawn when createSession returns created: false", async () => {
    mockIsAvailable.mockResolvedValue(true);
    mockKillSession.mockResolvedValue(false);
    mockCreateSession.mockResolvedValue({ sessionName: "foreman-seed-fail", created: false });

    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const config: WorkerConfig = {
      runId: "run-003",
      projectId: "proj-001",
      seedId: "seed-fail",
      seedTitle: "Fail Task",
      model: "claude-sonnet-4-6",
      worktreePath: "/tmp/wt/seed-fail",
      prompt: "Read TASK.md",
      env: { PATH: "/usr/bin" },
    };

    const result = await spawnWorkerProcess(config);

    expect(mockCreateSession).toHaveBeenCalledTimes(1);
    // Should fall back to detached spawn
    expect(mockSpawn).toHaveBeenCalledTimes(1);
    expect(result.tmuxSession).toBeUndefined();

    consoleSpy.mockRestore();
  });

  it("logs TMUX-002 warning when creation fails", async () => {
    mockIsAvailable.mockResolvedValue(true);
    mockKillSession.mockResolvedValue(false);
    mockCreateSession.mockResolvedValue({ sessionName: "foreman-seed-warn", created: false });

    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const config: WorkerConfig = {
      runId: "run-004",
      projectId: "proj-001",
      seedId: "seed-warn",
      seedTitle: "Warn Task",
      model: "claude-sonnet-4-6",
      worktreePath: "/tmp/wt/seed-warn",
      prompt: "Read TASK.md",
      env: { PATH: "/usr/bin" },
    };

    await spawnWorkerProcess(config);

    // Check that a warning was logged (via log() -> console.error)
    const calls = consoleSpy.mock.calls.map((c) => String(c[0]));
    const tmuxWarning = calls.find((c) => c.includes("tmux session creation failed") && c.includes("falling back"));
    expect(tmuxWarning).toBeDefined();

    consoleSpy.mockRestore();
  });
});

describe("stale session killed before new creation (AT-T014)", () => {
  let tmpDir: string;
  const originalEnv = { ...process.env };

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-tmux-test-"));
    mockSpawn.mockClear();
    mockOpen.mockClear();
    mockClose.mockClear();
    mockIsAvailable.mockReset();
    mockCreateSession.mockReset();
    mockKillSession.mockReset();
    delete process.env.FOREMAN_TMUX_DISABLED;
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    process.env = { ...originalEnv };
  });

  it("kills stale session before creating a new one", async () => {
    mockIsAvailable.mockResolvedValue(true);
    mockKillSession.mockResolvedValue(true); // stale session existed and was killed
    mockCreateSession.mockResolvedValue({ sessionName: "foreman-seed-stale", created: true });

    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const config: WorkerConfig = {
      runId: "run-005",
      projectId: "proj-001",
      seedId: "seed-stale",
      seedTitle: "Stale Task",
      model: "claude-sonnet-4-6",
      worktreePath: "/tmp/wt/seed-stale",
      prompt: "Read TASK.md",
      env: { PATH: "/usr/bin" },
    };

    await spawnWorkerProcess(config);

    // killSession should be called BEFORE createSession
    expect(mockKillSession).toHaveBeenCalledWith("foreman-seed-stale");
    expect(mockCreateSession).toHaveBeenCalledTimes(1);

    // Kill call should precede create call
    const killOrder = mockKillSession.mock.invocationCallOrder[0];
    const createOrder = mockCreateSession.mock.invocationCallOrder[0];
    expect(killOrder).toBeLessThan(createOrder);

    consoleSpy.mockRestore();
  });

  it("logs when stale session is killed", async () => {
    mockIsAvailable.mockResolvedValue(true);
    mockKillSession.mockResolvedValue(true);
    mockCreateSession.mockResolvedValue({ sessionName: "foreman-seed-log", created: true });

    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const config: WorkerConfig = {
      runId: "run-006",
      projectId: "proj-001",
      seedId: "seed-log",
      seedTitle: "Log Task",
      model: "claude-sonnet-4-6",
      worktreePath: "/tmp/wt/seed-log",
      prompt: "Read TASK.md",
      env: { PATH: "/usr/bin" },
    };

    await spawnWorkerProcess(config);

    const calls = consoleSpy.mock.calls.map((c) => String(c[0]));
    const staleLog = calls.find((c) => c.includes("Killed stale tmux session foreman-seed-log"));
    expect(staleLog).toBeDefined();

    consoleSpy.mockRestore();
  });

  it("does not log when no stale session exists", async () => {
    mockIsAvailable.mockResolvedValue(true);
    mockKillSession.mockResolvedValue(false); // no stale session
    mockCreateSession.mockResolvedValue({ sessionName: "foreman-seed-clean", created: true });

    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const config: WorkerConfig = {
      runId: "run-007",
      projectId: "proj-001",
      seedId: "seed-clean",
      seedTitle: "Clean Task",
      model: "claude-sonnet-4-6",
      worktreePath: "/tmp/wt/seed-clean",
      prompt: "Read TASK.md",
      env: { PATH: "/usr/bin" },
    };

    await spawnWorkerProcess(config);

    const calls = consoleSpy.mock.calls.map((c) => String(c[0]));
    const staleLog = calls.find((c) => c.includes("Killed stale tmux session"));
    expect(staleLog).toBeUndefined();

    consoleSpy.mockRestore();
  });
});

describe("FOREMAN_TMUX_DISABLED -> detached spawn (AT-T017)", () => {
  let tmpDir: string;
  const originalEnv = { ...process.env };

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-tmux-test-"));
    mockSpawn.mockClear();
    mockOpen.mockClear();
    mockClose.mockClear();
    mockIsAvailable.mockReset();
    mockCreateSession.mockReset();
    mockKillSession.mockReset();
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    process.env = { ...originalEnv };
  });

  it("uses detached spawn when FOREMAN_TMUX_DISABLED=true", async () => {
    // TmuxClient.isAvailable() returns false when FOREMAN_TMUX_DISABLED=true
    mockIsAvailable.mockResolvedValue(false);

    const config: WorkerConfig = {
      runId: "run-008",
      projectId: "proj-001",
      seedId: "seed-disabled",
      seedTitle: "Disabled Task",
      model: "claude-sonnet-4-6",
      worktreePath: "/tmp/wt/seed-disabled",
      prompt: "Read TASK.md",
      env: { PATH: "/usr/bin" },
    };

    const result = await spawnWorkerProcess(config);

    expect(mockCreateSession).not.toHaveBeenCalled();
    expect(mockSpawn).toHaveBeenCalledTimes(1);
    expect(result.tmuxSession).toBeUndefined();
  });
});
