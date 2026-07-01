import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

/**
 * Tests for spawnWorkerProcess() strategy selection.
 *
 * spawnWorkerProcess() always uses DetachedSpawnStrategy, which spawns
 * agent-worker.ts as a detached process. agent-worker.ts runs runWithPi()
 * per phase with the correct phase prompt and Pi extension env vars.
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
  taskId: "task-abc",
  taskTitle: "Test Task",
  model: "claude-sonnet-4-6",
  worktreePath: "/tmp/wt/task-abc",
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

  it("always uses DetachedSpawnStrategy regardless of Pi availability", async () => {
    mockIsPiAvailable.mockReturnValue(true); // Pi available — but we still use Detached

    await spawnWorkerProcess(baseConfig);

    expect(mockPiSpawn).not.toHaveBeenCalled();
    expect(mockSpawn).toHaveBeenCalledTimes(1);
    const opts = (mockSpawn.mock.calls[0] as unknown[])[2] as Record<string, unknown> | undefined;
    expect(opts?.detached).toBe(true);
  });

  it("uses DetachedSpawnStrategy when Pi is unavailable", async () => {
    mockIsPiAvailable.mockReturnValue(false);

    await spawnWorkerProcess(baseConfig);

    expect(mockPiSpawn).not.toHaveBeenCalled();
    expect(mockSpawn).toHaveBeenCalledTimes(1);
    const opts = (mockSpawn.mock.calls[0] as unknown[])[2] as Record<string, unknown> | undefined;
    expect(opts?.detached).toBe(true);
  });

  it("smoke tasks dispatch through DetachedSpawnStrategy", async () => {
    const smokeConfig: WorkerConfig = { ...baseConfig, taskType: "smoke" };

    await spawnWorkerProcess(smokeConfig);

    // Smoke tasks use the same dispatch path — no special env injection needed
    // (the smoke workflow is selected via taskType → resolvedWorkflow in agent-worker)
    expect(mockSpawn).toHaveBeenCalledTimes(1);
    const opts = (mockSpawn.mock.calls[0] as unknown[])[2] as { env?: Record<string, string> } | undefined;
    // FOREMAN_SMOKE_TEST must NOT be injected (bypass was removed)
    expect(opts?.env?.FOREMAN_SMOKE_TEST).toBeUndefined();
  });

  it("injects a test worker guard for workers spawned from test runtime", async () => {
    const testConfig: WorkerConfig = {
      ...baseConfig,
      env: { ...baseConfig.env, FOREMAN_RUNTIME_MODE: "test" },
    };

    await spawnWorkerProcess(testConfig);

    expect(mockSpawn).toHaveBeenCalledTimes(1);
    const opts = (mockSpawn.mock.calls[0] as unknown[])[2] as { env?: Record<string, string> } | undefined;
    expect(opts?.env?.FOREMAN_WORKER_TEST_GUARD).toBe("1");
    expect(opts?.env?.FOREMAN_WORKER_PARENT_PID).toBe(String(process.pid));
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
    expect(result.pid).toBe(12345);
    expect(result).toBeDefined();
  });
});
