import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

/**
 * Tests for spawnWorkerProcess() strategy selection.
 *
 * Since tmux was removed, the only strategies are:
 * - PiRpcSpawnStrategy (when Pi binary is available)
 * - DetachedSpawnStrategy (fallback)
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

// Mock Pi RPC spawn strategy
const mockPiSpawn = vi.fn().mockResolvedValue({ tmuxSession: undefined });
const mockIsPiAvailable = vi.fn().mockReturnValue(false);

vi.mock("../pi-rpc-spawn-strategy.js", () => ({
  isPiAvailable: mockIsPiAvailable,
  PiRpcSpawnStrategy: class MockPiRpcSpawnStrategy {
    spawn = mockPiSpawn;
  },
  PI_PHASE_CONFIGS: {},
  parsePiEvent: vi.fn().mockReturnValue(null),
}));

const { spawnWorkerProcess, DetachedSpawnStrategy } = await import("../dispatcher.js");
import type { SpawnStrategy, WorkerConfig } from "../dispatcher.js";

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

describe("spawnWorkerProcess strategy selection", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-spawn-test-"));
    mockSpawn.mockClear();
    mockOpen.mockClear();
    mockClose.mockClear();
    mockPiSpawn.mockClear();
    mockIsPiAvailable.mockReturnValue(false);
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("uses PiRpcSpawnStrategy when Pi is available", async () => {
    mockIsPiAvailable.mockReturnValue(true);
    mockPiSpawn.mockResolvedValue({});

    await spawnWorkerProcess(baseConfig);

    expect(mockPiSpawn).toHaveBeenCalledTimes(1);
    expect(mockSpawn).not.toHaveBeenCalled();
  });

  it("falls back to DetachedSpawnStrategy when Pi is unavailable", async () => {
    mockIsPiAvailable.mockReturnValue(false);

    await spawnWorkerProcess(baseConfig);

    expect(mockPiSpawn).not.toHaveBeenCalled();
    expect(mockSpawn).toHaveBeenCalledTimes(1);
    const opts = (mockSpawn.mock.calls[0] as unknown[])[2] as Record<string, unknown> | undefined;
    expect(opts?.detached).toBe(true);
  });

  it("injects FOREMAN_SMOKE_TEST=true for smoke seeds", async () => {
    mockIsPiAvailable.mockReturnValue(false);
    const smokeConfig: WorkerConfig = { ...baseConfig, seedType: "smoke" };

    await spawnWorkerProcess(smokeConfig);

    // The env passed to DetachedSpawnStrategy should include FOREMAN_SMOKE_TEST
    const opts = (mockSpawn.mock.calls[0] as unknown[])[2] as { env?: Record<string, string> } | undefined;
    expect(opts?.env?.FOREMAN_SMOKE_TEST).toBe("true");
  });

  it("smoke seeds use Pi when available", async () => {
    mockIsPiAvailable.mockReturnValue(true);
    mockPiSpawn.mockResolvedValue({});
    const smokeConfig: WorkerConfig = { ...baseConfig, seedType: "smoke" };

    await spawnWorkerProcess(smokeConfig);

    expect(mockPiSpawn).toHaveBeenCalledTimes(1);
    // The config passed to Pi should have FOREMAN_SMOKE_TEST injected
    const calledConfig = mockPiSpawn.mock.calls[0]?.[0] as WorkerConfig | undefined;
    expect(calledConfig?.env?.FOREMAN_SMOKE_TEST).toBe("true");
    expect(mockSpawn).not.toHaveBeenCalled();
  });
});

describe("DetachedSpawnStrategy interface", () => {
  beforeEach(() => {
    mockSpawn.mockClear();
    mockOpen.mockClear();
    mockClose.mockClear();
  });

  it("implements SpawnStrategy and spawns with detached: true", async () => {
    const strategy: SpawnStrategy = new DetachedSpawnStrategy();
    expect(typeof strategy.spawn).toBe("function");

    const result = await strategy.spawn(baseConfig);

    expect(mockSpawn).toHaveBeenCalledTimes(1);
    const opts = (mockSpawn.mock.calls[0] as unknown[])[2] as Record<string, unknown> | undefined;
    expect(opts?.detached).toBe(true);
    expect(result.tmuxSession).toBeUndefined();
  });
});
