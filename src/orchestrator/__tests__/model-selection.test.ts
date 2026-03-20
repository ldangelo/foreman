import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { PassThrough } from "node:stream";
import { EventEmitter } from "node:events";

/**
 * TRD-016: Per-Phase Model Selection via Pi RPC
 *
 * Tests:
 * 1. PI_PHASE_CONFIGS has correct model for each phase
 * 2. Model mismatch in agent_start event → warning logged
 * 3. set_model is sent as the first init message to PiRpcClient
 */

// ── Mocks ─────────────────────────────────────────────────────────────────────

// Default: pi binary NOT found — prevents piAvailableCache from being set to
// true and leaking into other test files that rely on the "pi not available"
// assumption (e.g. dispatcher-tmux.test.ts).
const mockExecFileSync = vi.fn().mockImplementation(() => {
  throw new Error("which: no pi in PATH");
});
const mockSpawn = vi.fn();

vi.mock("node:child_process", async (importOriginal) => {
  const original = await importOriginal<typeof import("node:child_process")>();
  return {
    ...original,
    execFileSync: mockExecFileSync,
    spawn: mockSpawn,
  };
});

vi.mock("node:fs/promises", async (importOriginal) => {
  const original = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...original,
    readFile: vi.fn().mockRejectedValue(new Error("ENOENT: no such file")),
  };
});

const mockDetachedSpawn = vi.fn().mockResolvedValue({});

vi.mock("../dispatcher.js", async (importOriginal) => {
  const original = await importOriginal<typeof import("../dispatcher.js")>();

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

// Import modules under test AFTER mocking
const { PI_PHASE_CONFIGS } = await import("../roles.js");
const piRpcModule = await import("../pi-rpc-spawn-strategy.js");
const { PiRpcSpawnStrategy } = piRpcModule;
// _resetCache resets the piAvailableCache so each test starts clean
const { _resetCache } = piRpcModule as typeof piRpcModule & { _resetCache: () => void };

// Reset the pi binary availability cache before and after each test to prevent
// cache pollution between tests and across test files.
beforeEach(() => {
  if (typeof _resetCache === "function") _resetCache();
  mockExecFileSync.mockReset();
  mockExecFileSync.mockImplementation(() => {
    throw new Error("which: no pi in PATH");
  });
});

afterEach(() => {
  if (typeof _resetCache === "function") _resetCache();
});

// ── Helpers ───────────────────────────────────────────────────────────────────

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

function autoRespondHealthCheck(proc: ReturnType<typeof makeFakeProcess>["proc"]) {
  setImmediate(() => {
    proc.stdout.emit(
      "data",
      JSON.stringify({
        type: "health_check_response",
        loadedExtensions: ["foreman-tool-gate", "foreman-budget", "foreman-audit"],
        status: "ok",
      }) + "\n",
    );
  });
}

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

function makeMockStore() {
  return {
    updateRun: vi.fn(),
    updateRunProgress: vi.fn(),
    getRunProgress: vi.fn().mockReturnValue(null),
  };
}

// ── PI_PHASE_CONFIGS: model correctness ───────────────────────────────────────

describe("PI_PHASE_CONFIGS — model assignments", () => {
  it("explorer uses claude-haiku-4-5-20251001 (cost-efficient read-only phase)", () => {
    expect(PI_PHASE_CONFIGS.explorer.model).toBe("claude-haiku-4-5-20251001");
  });

  it("developer uses claude-sonnet-4-6", () => {
    expect(PI_PHASE_CONFIGS.developer.model).toBe("claude-sonnet-4-6");
  });

  it("qa uses claude-sonnet-4-6", () => {
    expect(PI_PHASE_CONFIGS.qa.model).toBe("claude-sonnet-4-6");
  });

  it("reviewer uses claude-sonnet-4-6", () => {
    expect(PI_PHASE_CONFIGS.reviewer.model).toBe("claude-sonnet-4-6");
  });

  it("all four phases are present in PI_PHASE_CONFIGS", () => {
    expect(PI_PHASE_CONFIGS).toHaveProperty("explorer");
    expect(PI_PHASE_CONFIGS).toHaveProperty("developer");
    expect(PI_PHASE_CONFIGS).toHaveProperty("qa");
    expect(PI_PHASE_CONFIGS).toHaveProperty("reviewer");
  });

  it("each config has required fields: model, maxTurns, maxTokens, allowedTools", () => {
    for (const [phase, cfg] of Object.entries(PI_PHASE_CONFIGS)) {
      expect(cfg.model, `${phase}.model`).toBeTruthy();
      expect(cfg.maxTurns, `${phase}.maxTurns`).toBeGreaterThan(0);
      expect(cfg.maxTokens, `${phase}.maxTokens`).toBeGreaterThan(0);
      expect(Array.isArray(cfg.allowedTools), `${phase}.allowedTools should be array`).toBe(true);
    }
  });

  it("explorer maxTurns matches ROLE_CONFIGS explorer (30)", () => {
    expect(PI_PHASE_CONFIGS.explorer.maxTurns).toBe(30);
  });

  it("developer maxTurns matches ROLE_CONFIGS developer (80)", () => {
    expect(PI_PHASE_CONFIGS.developer.maxTurns).toBe(80);
  });

  it("qa maxTurns matches ROLE_CONFIGS qa (30)", () => {
    expect(PI_PHASE_CONFIGS.qa.maxTurns).toBe(30);
  });

  it("reviewer maxTurns matches ROLE_CONFIGS reviewer (20)", () => {
    expect(PI_PHASE_CONFIGS.reviewer.maxTurns).toBe(20);
  });

  it("explorer maxTokens matches ROLE_CONFIGS explorer (100_000)", () => {
    expect(PI_PHASE_CONFIGS.explorer.maxTokens).toBe(100_000);
  });

  it("developer maxTokens matches ROLE_CONFIGS developer (500_000)", () => {
    expect(PI_PHASE_CONFIGS.developer.maxTokens).toBe(500_000);
  });
});

// ── Model mismatch: agent_start event → warning logged ───────────────────────

describe("PiRpcSpawnStrategy — model mismatch warning on agent_start", () => {
  beforeEach(() => {
    mockSpawn.mockReset();
    mockDetachedSpawn.mockReset().mockResolvedValue({});
  });

  it("logs a warning when agent_start reports a different model than requested", async () => {
    const { proc } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);
    autoRespondHealthCheck(proc);

    // Capture stderr output (log() writes to console.error)
    const warnSpy = vi.spyOn(console, "error");

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({
      runId: "run-mismatch-1",
      model: "claude-haiku-4-5-20251001",
    });

    const spawnPromise = strategy.spawn(config);
    await new Promise((r) => setImmediate(r));

    // Pi reports a different model (e.g., fell back to sonnet)
    proc.stdout.emit(
      "data",
      JSON.stringify({
        type: "agent_start",
        sessionId: "sess-x1",
        model: "claude-sonnet-4-6",
      }) + "\n",
    );
    await new Promise((r) => setImmediate(r));

    // Now send agent_end to clean up
    proc.stdout.emit(
      "data",
      JSON.stringify({ type: "agent_end", reason: "completed", sessionId: "sess-x1" }) + "\n",
    );
    await spawnPromise;

    // A warning should have been logged mentioning the mismatch
    const warnCalls = warnSpy.mock.calls.map((args) => args.join(" "));
    const mismatchWarning = warnCalls.find(
      (msg) =>
        msg.includes("mismatch") &&
        msg.includes("claude-haiku-4-5-20251001") &&
        msg.includes("claude-sonnet-4-6"),
    );
    expect(mismatchWarning).toBeDefined();

    warnSpy.mockRestore();
  });

  it("does NOT log a warning when agent_start model matches requested model", async () => {
    const { proc } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);
    autoRespondHealthCheck(proc);

    const warnSpy = vi.spyOn(console, "error");

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({
      runId: "run-match-1",
      model: "claude-sonnet-4-6",
    });

    const spawnPromise = strategy.spawn(config);
    await new Promise((r) => setImmediate(r));

    // Pi reports the same model as requested — no mismatch
    proc.stdout.emit(
      "data",
      JSON.stringify({
        type: "agent_start",
        sessionId: "sess-y1",
        model: "claude-sonnet-4-6",
      }) + "\n",
    );
    await new Promise((r) => setImmediate(r));

    proc.stdout.emit(
      "data",
      JSON.stringify({ type: "agent_end", reason: "completed", sessionId: "sess-y1" }) + "\n",
    );
    await spawnPromise;

    const warnCalls = warnSpy.mock.calls.map((args) => args.join(" "));
    const mismatchWarning = warnCalls.find((msg) => msg.includes("mismatch"));
    expect(mismatchWarning).toBeUndefined();

    warnSpy.mockRestore();
  });

  it("does NOT log a warning when agent_start has no model field", async () => {
    const { proc } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);
    autoRespondHealthCheck(proc);

    const warnSpy = vi.spyOn(console, "error");

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({
      runId: "run-no-model-1",
      model: "claude-sonnet-4-6",
    });

    const spawnPromise = strategy.spawn(config);
    await new Promise((r) => setImmediate(r));

    // agent_start without a model field (older Pi version)
    proc.stdout.emit(
      "data",
      JSON.stringify({ type: "agent_start", sessionId: "sess-z1" }) + "\n",
    );
    await new Promise((r) => setImmediate(r));

    proc.stdout.emit(
      "data",
      JSON.stringify({ type: "agent_end", reason: "completed", sessionId: "sess-z1" }) + "\n",
    );
    await spawnPromise;

    const warnCalls = warnSpy.mock.calls.map((args) => args.join(" "));
    const mismatchWarning = warnCalls.find((msg) => msg.includes("mismatch"));
    expect(mismatchWarning).toBeUndefined();

    warnSpy.mockRestore();
  });
});

// ── set_model is sent as first init message ───────────────────────────────────

describe("PiRpcSpawnStrategy — set_model sent as first init message", () => {
  beforeEach(() => {
    mockSpawn.mockReset();
    mockDetachedSpawn.mockReset().mockResolvedValue({});
  });

  it("sends set_model command before any other command", async () => {
    const { proc } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);
    autoRespondHealthCheck(proc);

    const receivedLines: string[] = [];
    proc.stdin.on("data", (chunk: Buffer) => {
      const text = chunk.toString();
      // Split on newlines and collect non-empty lines
      text.split("\n").forEach((line: string) => {
        if (line.trim()) receivedLines.push(line.trim());
      });
    });

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({
      runId: "run-set-model-1",
      model: "claude-haiku-4-5-20251001",
    });

    const spawnPromise = strategy.spawn(config);

    // Allow several ticks for the init commands to be sent
    for (let i = 0; i < 5; i++) {
      await new Promise((r) => setImmediate(r));
    }

    // Emit agent_end to finish
    proc.stdout.emit(
      "data",
      JSON.stringify({ type: "agent_end", reason: "done" }) + "\n",
    );
    await spawnPromise;

    // Must have received at least one command
    expect(receivedLines.length).toBeGreaterThan(0);

    // First command must be set_model
    const firstCommand = JSON.parse(receivedLines[0]) as { cmd: string; model?: string };
    expect(firstCommand.cmd).toBe("set_model");
    expect(firstCommand.model).toBe("claude-haiku-4-5-20251001");
  });

  it("set_model command carries the model from WorkerConfig", async () => {
    const { proc } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);
    autoRespondHealthCheck(proc);

    const sentCommands: Array<{ cmd: string; model?: string }> = [];
    proc.stdin.on("data", (chunk: Buffer) => {
      chunk
        .toString()
        .split("\n")
        .filter((l: string) => l.trim())
        .forEach((l: string) => {
          sentCommands.push(JSON.parse(l) as { cmd: string; model?: string });
        });
    });

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({
      model: "claude-sonnet-4-6",
    });

    const spawnPromise = strategy.spawn(config);
    for (let i = 0; i < 5; i++) {
      await new Promise((r) => setImmediate(r));
    }

    proc.stdout.emit(
      "data",
      JSON.stringify({ type: "agent_end", reason: "done" }) + "\n",
    );
    await spawnPromise;

    const setModelCmd = sentCommands.find((c) => c.cmd === "set_model");
    expect(setModelCmd).toBeDefined();
    expect(setModelCmd!.model).toBe("claude-sonnet-4-6");
  });

  it("prompt command is sent after set_model (ordering guarantee)", async () => {
    const { proc } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);
    autoRespondHealthCheck(proc);

    const sentCommands: Array<{ cmd: string }> = [];
    proc.stdin.on("data", (chunk: Buffer) => {
      chunk
        .toString()
        .split("\n")
        .filter((l: string) => l.trim())
        .forEach((l: string) => {
          sentCommands.push(JSON.parse(l) as { cmd: string });
        });
    });

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({ model: "claude-haiku-4-5-20251001" });

    const spawnPromise = strategy.spawn(config);
    for (let i = 0; i < 5; i++) {
      await new Promise((r) => setImmediate(r));
    }

    proc.stdout.emit(
      "data",
      JSON.stringify({ type: "agent_end", reason: "done" }) + "\n",
    );
    await spawnPromise;

    const setModelIdx = sentCommands.findIndex((c) => c.cmd === "set_model");
    const promptIdx = sentCommands.findIndex((c) => c.cmd === "prompt");

    expect(setModelIdx).toBeGreaterThanOrEqual(0);
    expect(promptIdx).toBeGreaterThanOrEqual(0);
    // set_model must come before prompt
    expect(setModelIdx).toBeLessThan(promptIdx);
  });
});
