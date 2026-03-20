import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { PassThrough } from "node:stream";
import { EventEmitter } from "node:events";

/**
 * Tests for Pi binary detection, spawn strategy selection, and PiRpcSpawnStrategy.
 *
 * TRD-010: Pi Binary Detection
 * - isPiAvailable(): checks if `pi` binary is on PATH, caches result
 * - selectSpawnStrategy(): env var override + auto-detection
 *
 * TRD-012: PiRpcSpawnStrategy
 * - Implements SpawnStrategy interface
 * - Fallback to DetachedSpawnStrategy on spawn failure
 * - Session ID stored from agent_end
 * - budget_exceeded marks run stuck
 * - Pipe break within 5s marks run stuck
 * - CLAUDECODE stripped from child process env
 */

// ── Mocks ─────────────────────────────────────────────────────────────────────

// Mock child_process so we can control execFileSync and spawn behavior
const mockExecFileSync = vi.fn();
const mockSpawn = vi.fn();

vi.mock("node:child_process", async (importOriginal) => {
  const original = await importOriginal<typeof import("node:child_process")>();
  return {
    ...original,
    execFileSync: mockExecFileSync,
    spawn: mockSpawn,
  };
});

// Mock fs/promises to avoid reading actual TASK.md
vi.mock("node:fs/promises", async (importOriginal) => {
  const original = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...original,
    readFile: vi.fn().mockRejectedValue(new Error("ENOENT: no such file")),
  };
});

// Mock dispatcher so DetachedSpawnStrategy doesn't spawn real processes
const mockDetachedSpawn = vi.fn().mockResolvedValue({});

vi.mock("../dispatcher.js", async (importOriginal) => {
  const original = await importOriginal<typeof import("../dispatcher.js")>();

  // Must use a proper class (function constructor) for `new DetachedSpawnStrategy()` to work
  class MockDetachedSpawnStrategy {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    spawn(...args: any[]) {
      return mockDetachedSpawn(...args);
    }
  }

  return {
    ...original,
    DetachedSpawnStrategy: MockDetachedSpawnStrategy,
  };
});

// Import the module under test AFTER mocking
const moduleImport = await import("../pi-rpc-spawn-strategy.js");
const { isPiAvailable, selectSpawnStrategy, PiRpcSpawnStrategy } = moduleImport;

// We need a way to reset the module-level cache between tests.
const { _resetCache } = moduleImport as typeof moduleImport & { _resetCache: () => void };

// ── Helper: build a fake ChildProcess ─────────────────────────────────────────

function makeFakeProcess() {
  const stdin = new PassThrough();
  const stdout = new PassThrough();
  const stderr = new PassThrough();
  const proc = Object.assign(new EventEmitter(), {
    stdin,
    stdout,
    stderr,
    pid: 99999,
    kill: vi.fn(),
  });
  return { proc, stdin, stdout, stderr };
}

/**
 * Build a minimal WorkerConfig for testing.
 */
function makeWorkerConfig(overrides: Partial<{
  runId: string;
  projectId: string;
  seedId: string;
  seedTitle: string;
  model: string;
  worktreePath: string;
  prompt: string;
  env: Record<string, string>;
}> = {}): import("../dispatcher.js").WorkerConfig {
  return {
    runId: "run-test-1",
    projectId: "proj-test-1",
    seedId: "seed-test-1",
    seedTitle: "Test Seed",
    model: "claude-sonnet-4-6",
    worktreePath: "/tmp/test-worktree",
    projectPath: "/tmp/test-project",
    prompt: "Implement the task",
    env: {},
    ...overrides,
  };
}

/**
 * Build a minimal mock ForemanStore.
 */
function makeMockStore() {
  return {
    updateRun: vi.fn(),
    updateRunProgress: vi.fn(),
    getRunProgress: vi.fn().mockReturnValue(null),
  };
}

// ── isPiAvailable() tests ────────────────────────────────────────────────────

describe("isPiAvailable()", () => {
  const originalEnv = { ...process.env };

  beforeEach(() => {
    mockExecFileSync.mockReset();
    if (typeof _resetCache === "function") {
      _resetCache();
    }
    delete process.env.FOREMAN_SPAWN_STRATEGY;
  });

  afterEach(() => {
    process.env = { ...originalEnv };
  });

  it("returns true when execFileSync succeeds (pi is on PATH)", () => {
    mockExecFileSync.mockReturnValue("/usr/local/bin/pi\n");

    const result = isPiAvailable();

    expect(result).toBe(true);
    expect(mockExecFileSync).toHaveBeenCalledTimes(1);
  });

  it("returns false when execFileSync throws (pi is NOT on PATH)", () => {
    mockExecFileSync.mockImplementation(() => {
      throw new Error("not found");
    });

    const result = isPiAvailable();

    expect(result).toBe(false);
    expect(mockExecFileSync).toHaveBeenCalledTimes(1);
  });

  it("caches the result — execFileSync called only once across multiple calls", () => {
    mockExecFileSync.mockReturnValue("/usr/local/bin/pi\n");

    const first = isPiAvailable();
    const second = isPiAvailable();
    const third = isPiAvailable();

    expect(first).toBe(true);
    expect(second).toBe(true);
    expect(third).toBe(true);
    // Should only have called execFileSync once
    expect(mockExecFileSync).toHaveBeenCalledTimes(1);
  });

  it("caches false result — does not retry when pi is not found", () => {
    mockExecFileSync.mockImplementation(() => {
      throw new Error("which: no pi in PATH");
    });

    const first = isPiAvailable();
    const second = isPiAvailable();

    expect(first).toBe(false);
    expect(second).toBe(false);
    expect(mockExecFileSync).toHaveBeenCalledTimes(1);
  });

  it("calls which on unix or where on windows", () => {
    mockExecFileSync.mockReturnValue("/usr/local/bin/pi\n");

    isPiAvailable();

    expect(mockExecFileSync).toHaveBeenCalledTimes(1);
    const [cmd, args] = mockExecFileSync.mock.calls[0] as [string, string[]];
    // Should call either 'which' or 'where' with ['pi']
    expect(["which", "where"]).toContain(cmd);
    expect(args).toEqual(["pi"]);
  });
});

// ── selectSpawnStrategy() tests ──────────────────────────────────────────────

describe("selectSpawnStrategy()", () => {
  const originalEnv = { ...process.env };

  beforeEach(() => {
    mockExecFileSync.mockReset();
    if (typeof _resetCache === "function") {
      _resetCache();
    }
    delete process.env.FOREMAN_SPAWN_STRATEGY;
  });

  afterEach(() => {
    process.env = { ...originalEnv };
  });

  it('returns "detached" when FOREMAN_SPAWN_STRATEGY=detached without checking PATH', () => {
    process.env.FOREMAN_SPAWN_STRATEGY = "detached";

    const result = selectSpawnStrategy();

    expect(result).toBe("detached");
    // Should NOT have called execFileSync — env var overrides detection
    expect(mockExecFileSync).not.toHaveBeenCalled();
  });

  it('returns "pi-rpc" when FOREMAN_SPAWN_STRATEGY=pi-rpc without checking PATH', () => {
    process.env.FOREMAN_SPAWN_STRATEGY = "pi-rpc";

    const result = selectSpawnStrategy();

    expect(result).toBe("pi-rpc");
    // Should NOT have called execFileSync — env var forces pi-rpc
    expect(mockExecFileSync).not.toHaveBeenCalled();
  });

  it('returns "tmux" when FOREMAN_SPAWN_STRATEGY=tmux without checking PATH', () => {
    process.env.FOREMAN_SPAWN_STRATEGY = "tmux";

    const result = selectSpawnStrategy();

    expect(result).toBe("tmux");
    expect(mockExecFileSync).not.toHaveBeenCalled();
  });

  it('returns "pi-rpc" when pi is found on PATH and no env var override', () => {
    mockExecFileSync.mockReturnValue("/usr/local/bin/pi\n");

    const result = selectSpawnStrategy();

    expect(result).toBe("pi-rpc");
    expect(mockExecFileSync).toHaveBeenCalledTimes(1);
  });

  it('returns "detached" when pi is NOT found on PATH and no env var override', () => {
    mockExecFileSync.mockImplementation(() => {
      throw new Error("which: no pi in PATH");
    });

    const result = selectSpawnStrategy();

    expect(result).toBe("detached");
    expect(mockExecFileSync).toHaveBeenCalledTimes(1);
  });

  it("ignores unknown FOREMAN_SPAWN_STRATEGY values and falls back to detection", () => {
    process.env.FOREMAN_SPAWN_STRATEGY = "unknown-strategy";
    mockExecFileSync.mockReturnValue("/usr/local/bin/pi\n");

    const result = selectSpawnStrategy();

    // Unknown strategy => fall back to auto-detection
    expect(result).toBe("pi-rpc");
    expect(mockExecFileSync).toHaveBeenCalledTimes(1);
  });
});

// ── PiRpcSpawnStrategy class tests ───────────────────────────────────────────

describe("PiRpcSpawnStrategy — class interface", () => {
  it("is exported as a class", () => {
    expect(PiRpcSpawnStrategy).toBeDefined();
    expect(typeof PiRpcSpawnStrategy).toBe("function");
  });

  it("can be instantiated without arguments (no store)", () => {
    const instance = new PiRpcSpawnStrategy();
    expect(instance).toBeInstanceOf(PiRpcSpawnStrategy);
  });

  it("can be instantiated with a store argument", () => {
    const store = makeMockStore();
    const instance = new PiRpcSpawnStrategy(store as never);
    expect(instance).toBeInstanceOf(PiRpcSpawnStrategy);
  });

  it("implements SpawnStrategy interface — has spawn() method", () => {
    const instance = new PiRpcSpawnStrategy();
    expect(typeof instance.spawn).toBe("function");
  });
});

// ── PiRpcSpawnStrategy.spawn() — successful agent_end ────────────────────────

describe("PiRpcSpawnStrategy.spawn() — successful agent_end", () => {
  beforeEach(() => {
    mockSpawn.mockReset();
    mockDetachedSpawn.mockReset().mockResolvedValue({});
  });

  it("resolves with empty SpawnResult on successful agent_end", async () => {
    const { proc } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig();

    const spawnPromise = strategy.spawn(config);

    // Give PiRpcClient time to set up readline interface and send init commands
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    // Satisfy the health check so the init sequence can continue to prompt
    proc.stdout.emit("data", JSON.stringify({ type: "health_check_response", loadedExtensions: ["foreman-tool-gate"], status: "ok" }) + "\n");
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    // Emit agent_end event via stdout
    const agentEndEvent = JSON.stringify({ type: "agent_end", reason: "completed", sessionId: "sess-abc123" });
    proc.stdout.emit("data", agentEndEvent + "\n");

    const result = await spawnPromise;
    expect(result).toEqual({});
  });

  it("stores session_id in runs.session_key from agent_end event (AC-019-2)", async () => {
    const { proc } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({ runId: "run-abc", model: "claude-sonnet-4-6" });

    const spawnPromise = strategy.spawn(config);
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    proc.stdout.emit("data", JSON.stringify({ type: "health_check_response", loadedExtensions: ["foreman-tool-gate"], status: "ok" }) + "\n");
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    const agentEndEvent = JSON.stringify({ type: "agent_end", reason: "completed", sessionId: "pi-sess-xyz" });
    proc.stdout.emit("data", agentEndEvent + "\n");

    await spawnPromise;

    expect(store.updateRun).toHaveBeenCalledWith(
      "run-abc",
      expect.objectContaining({
        session_key: "foreman:pi-rpc:claude-sonnet-4-6:run-abc:session-pi-sess-xyz",
      }),
    );
  });

  it("marks run as completed in store on agent_end", async () => {
    const { proc } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({ runId: "run-complete-1" });

    const spawnPromise = strategy.spawn(config);
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    proc.stdout.emit("data", JSON.stringify({ type: "health_check_response", loadedExtensions: ["foreman-tool-gate"], status: "ok" }) + "\n");
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    proc.stdout.emit("data", JSON.stringify({ type: "agent_end", reason: "done" }) + "\n");

    await spawnPromise;

    expect(store.updateRun).toHaveBeenCalledWith(
      "run-complete-1",
      expect.objectContaining({ status: "completed" }),
    );
  });
});

// ── PiRpcSpawnStrategy.spawn() — budget_exceeded ─────────────────────────────

describe("PiRpcSpawnStrategy.spawn() — budget_exceeded", () => {
  beforeEach(() => {
    mockSpawn.mockReset();
    mockDetachedSpawn.mockReset().mockResolvedValue({});
  });

  it("marks run as stuck with BUDGET_EXCEEDED when budget_exceeded event received", async () => {
    const { proc } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({ runId: "run-budget-1" });

    const spawnPromise = strategy.spawn(config);
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    proc.stdout.emit("data", JSON.stringify({ type: "health_check_response", loadedExtensions: ["foreman-tool-gate"], status: "ok" }) + "\n");
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    proc.stdout.emit("data", JSON.stringify({ type: "budget_exceeded", reason: "token limit" }) + "\n");

    // The strategy falls back to detached on rejection, so we await without throwing
    await spawnPromise;

    // Store should have been called to mark stuck
    expect(store.updateRun).toHaveBeenCalledWith(
      "run-budget-1",
      expect.objectContaining({ status: "stuck" }),
    );
  });

  it("budget_exceeded does NOT store a completed status", async () => {
    const { proc } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({ runId: "run-budget-2" });

    const spawnPromise = strategy.spawn(config);
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    proc.stdout.emit("data", JSON.stringify({ type: "health_check_response", loadedExtensions: ["foreman-tool-gate"], status: "ok" }) + "\n");
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    proc.stdout.emit("data", JSON.stringify({ type: "budget_exceeded", reason: "exceeded" }) + "\n");

    await spawnPromise;

    // Ensure "completed" was never set
    const completedCalls = (store.updateRun.mock.calls as Array<[string, { status?: string }]>).filter(
      ([, updates]) => updates.status === "completed",
    );
    expect(completedCalls).toHaveLength(0);
  });
});

// ── PiRpcSpawnStrategy.spawn() — pipe break detection ────────────────────────

describe("PiRpcSpawnStrategy.spawn() — pipe break within 5s", () => {
  beforeEach(() => {
    mockSpawn.mockReset();
    mockDetachedSpawn.mockReset().mockResolvedValue({});
    // Only fake setTimeout/clearTimeout — leave setImmediate/Promise microtasks real
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("marks run as stuck when process closes without agent_end within 5s", async () => {
    const { proc } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({ runId: "run-pipe-break-1" });

    const spawnPromise = strategy.spawn(config);
    // Allow async setup (sendCommand calls) to complete
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    // Satisfy the health check so init sequence advances to awaiting the prompt response
    proc.stdout.emit("data", JSON.stringify({ type: "health_check_response", loadedExtensions: ["foreman-tool-gate"], status: "ok" }) + "\n");
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    // End the stdout stream — readline will emit 'close', which triggers pipe break detection
    proc.stdout.push(null);
    // Let the 'close' event propagate through readline → PiRpcClient
    await new Promise((r) => setImmediate(r));

    // Advance past the 5s pipe break window
    vi.advanceTimersByTime(6_000);

    // Allow the rejection to settle
    await new Promise((r) => setImmediate(r));

    // Should fall back to DetachedSpawnStrategy after the stuck update
    await spawnPromise;

    expect(store.updateRun).toHaveBeenCalledWith(
      "run-pipe-break-1",
      expect.objectContaining({ status: "stuck" }),
    );
  });

  it("does NOT mark stuck when close follows agent_end", async () => {
    const { proc } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({ runId: "run-normal-close" });

    const spawnPromise = strategy.spawn(config);
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    // Satisfy the health check so init sequence can advance to prompt
    proc.stdout.emit("data", JSON.stringify({ type: "health_check_response", loadedExtensions: ["foreman-tool-gate"], status: "ok" }) + "\n");
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    // Emit agent_end first
    proc.stdout.emit("data", JSON.stringify({ type: "agent_end", reason: "done" }) + "\n");
    await new Promise((r) => setImmediate(r));

    // Then end the stream — should not trigger stuck since we already resolved
    proc.stdout.push(null);
    await new Promise((r) => setImmediate(r));

    await spawnPromise;

    // Should have "completed", not "stuck"
    const stuckCalls = (store.updateRun.mock.calls as Array<[string, { status?: string }]>).filter(
      ([, updates]) => updates.status === "stuck",
    );
    expect(stuckCalls).toHaveLength(0);
  });
});

// ── PiRpcSpawnStrategy.spawn() — fallback to DetachedSpawnStrategy ────────────

describe("PiRpcSpawnStrategy.spawn() — fallback on spawn failure", () => {
  beforeEach(() => {
    mockSpawn.mockReset();
    mockDetachedSpawn.mockReset().mockResolvedValue({ tmuxSession: undefined });
  });

  it("falls back to DetachedSpawnStrategy when Pi spawn throws", async () => {
    // Make spawn throw (pi not installed / permission denied)
    mockSpawn.mockImplementation(() => {
      throw new Error("ENOENT: pi binary not found");
    });

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig();

    const result = await strategy.spawn(config);

    // Should have fallen back and returned the detached result
    expect(mockDetachedSpawn).toHaveBeenCalledWith(config);
    expect(result).toEqual({ tmuxSession: undefined });
  });

  it("falls back when PiRpcClient constructor throws (no stdin)", async () => {
    // Spawn returns a process with no stdin
    const proc = Object.assign(new EventEmitter(), {
      stdin: null,
      stdout: new PassThrough(),
      stderr: new PassThrough(),
    });
    mockSpawn.mockReturnValue(proc);

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig();

    // PiRpcClient will throw because stdin is null, fallback kicks in
    const result = await strategy.spawn(config);

    expect(mockDetachedSpawn).toHaveBeenCalledWith(config);
    expect(result).toBeDefined();
  });
});

// ── PiRpcSpawnStrategy — CLAUDECODE env stripping ─────────────────────────────

describe("PiRpcSpawnStrategy — CLAUDECODE stripped from child process env", () => {
  beforeEach(() => {
    mockSpawn.mockReset();
    mockDetachedSpawn.mockReset().mockResolvedValue({});
  });

  it("strips CLAUDECODE from the child process env", async () => {
    const { proc } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);

    const savedClaudecode = process.env.CLAUDECODE;
    process.env.CLAUDECODE = "1";

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({ env: { CLAUDECODE: "1" } });

    const spawnPromise = strategy.spawn(config);
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    // Satisfy health check then emit agent_end to cleanly finish
    proc.stdout.emit("data", JSON.stringify({ type: "health_check_response", loadedExtensions: ["foreman-tool-gate"], status: "ok" }) + "\n");
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    proc.stdout.emit("data", JSON.stringify({ type: "agent_end", reason: "done" }) + "\n");
    await spawnPromise;

    // Verify spawn was called and CLAUDECODE was NOT present in the env
    expect(mockSpawn).toHaveBeenCalled();
    const [, , spawnOptions] = mockSpawn.mock.calls[0] as [string, string[], { env?: Record<string, string | undefined> }];
    expect(spawnOptions.env).toBeDefined();
    expect(spawnOptions.env!["CLAUDECODE"]).toBeUndefined();

    // Restore
    if (savedClaudecode === undefined) {
      delete process.env.CLAUDECODE;
    } else {
      process.env.CLAUDECODE = savedClaudecode;
    }
  });
});

// ── PiRpcSpawnStrategy — RunProgress accumulation ────────────────────────────

describe("PiRpcSpawnStrategy — RunProgress accumulation", () => {
  beforeEach(() => {
    mockSpawn.mockReset();
    mockDetachedSpawn.mockReset().mockResolvedValue({});
  });

  it("increments turn count and tokens on turn_end events", async () => {
    const { proc } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({ runId: "run-progress-1" });

    const spawnPromise = strategy.spawn(config);
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    // Satisfy health check before turn events
    proc.stdout.emit("data", JSON.stringify({ type: "health_check_response", loadedExtensions: ["foreman-tool-gate"], status: "ok" }) + "\n");
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    // Emit two turn_end events
    proc.stdout.emit("data", JSON.stringify({ type: "turn_end", turnNumber: 1, inputTokens: 100, outputTokens: 50 }) + "\n");
    await new Promise((r) => setImmediate(r));
    proc.stdout.emit("data", JSON.stringify({ type: "turn_end", turnNumber: 2, inputTokens: 200, outputTokens: 80 }) + "\n");
    await new Promise((r) => setImmediate(r));

    // End with agent_end
    proc.stdout.emit("data", JSON.stringify({ type: "agent_end", reason: "done" }) + "\n");
    await spawnPromise;

    // updateRunProgress should have been called with accumulated tokens
    const progressCalls = store.updateRunProgress.mock.calls as Array<[string, import("../../lib/store.js").RunProgress]>;
    const finalCall = progressCalls[progressCalls.length - 1];
    expect(finalCall[1].turns).toBe(2);
    expect(finalCall[1].tokensIn).toBe(300);
    expect(finalCall[1].tokensOut).toBe(130);
  });

  it("tracks tool calls in toolBreakdown on tool_execution_start", async () => {
    const { proc } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({ runId: "run-tools-1" });

    const spawnPromise = strategy.spawn(config);
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    // Satisfy health check before tool events
    proc.stdout.emit("data", JSON.stringify({ type: "health_check_response", loadedExtensions: ["foreman-tool-gate"], status: "ok" }) + "\n");
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    proc.stdout.emit("data", JSON.stringify({ type: "tool_execution_start", toolName: "Read", toolCallId: "tc-1" }) + "\n");
    await new Promise((r) => setImmediate(r));
    proc.stdout.emit("data", JSON.stringify({ type: "tool_execution_start", toolName: "Read", toolCallId: "tc-2" }) + "\n");
    await new Promise((r) => setImmediate(r));
    proc.stdout.emit("data", JSON.stringify({ type: "tool_execution_start", toolName: "Edit", toolCallId: "tc-3" }) + "\n");
    await new Promise((r) => setImmediate(r));

    proc.stdout.emit("data", JSON.stringify({ type: "agent_end", reason: "done" }) + "\n");
    await spawnPromise;

    const progressCalls = store.updateRunProgress.mock.calls as Array<[string, import("../../lib/store.js").RunProgress]>;
    // Find last call that has toolBreakdown info
    const lastWithTools = [...progressCalls].reverse().find(([, p]) => p.toolCalls > 0);
    expect(lastWithTools).toBeDefined();
    expect(lastWithTools![1].toolCalls).toBe(3);
    expect(lastWithTools![1].toolBreakdown["Read"]).toBe(2);
    expect(lastWithTools![1].toolBreakdown["Edit"]).toBe(1);
  });
});
