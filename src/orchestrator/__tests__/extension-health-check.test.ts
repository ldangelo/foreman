import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { PassThrough } from "node:stream";
import { EventEmitter } from "node:events";

/**
 * Tests for TRD-017: Pi Extension Health Check
 *
 * Verifies that PiRpcSpawnStrategy performs a health check after set_context
 * and before sending the prompt. The health check ensures the foreman-tool-gate
 * extension loaded successfully before allowing the pipeline to proceed.
 *
 * AC-017-1: Health check command sent during Pi initialization (after set_context, before prompt)
 * AC-017-2: foreman-tool-gate missing → actionable error + spawn rejected (falls back to DetachedSpawnStrategy)
 * AC-017-3: Timeout (no response) → spawn rejected after 5s
 * AC-017-4: health_check_response with all extensions → spawn continues normally
 */

// ── Mocks ─────────────────────────────────────────────────────────────────────

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
const { PiRpcSpawnStrategy } = await import("../pi-rpc-spawn-strategy.js");

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
    runId: "run-hc-1",
    projectId: "proj-hc-1",
    seedId: "seed-hc-1",
    seedTitle: "Health Check Test Seed",
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

/**
 * Collect all JSON lines written to a PassThrough stream.
 * Returns the parsed objects in order.
 */
function collectStdinWrites(stdin: PassThrough): Array<Record<string, unknown>> {
  const lines: Array<Record<string, unknown>> = [];
  const chunks: string[] = [];

  stdin.on("data", (chunk: Buffer | string) => {
    chunks.push(typeof chunk === "string" ? chunk : chunk.toString("utf-8"));
  });

  return new Proxy(lines, {
    get(target, prop) {
      if (prop === "flush") {
        return () => {
          const all = chunks.join("");
          for (const line of all.split("\n")) {
            const trimmed = line.trim();
            if (trimmed) {
              try {
                target.push(JSON.parse(trimmed) as Record<string, unknown>);
              } catch {
                // ignore non-JSON
              }
            }
          }
        };
      }
      return Reflect.get(target, prop);
    },
  });
}

// ── AC-017-4: All 3 extensions loaded → health check passes, spawn continues ──

describe("Extension health check — success path (all extensions loaded)", () => {
  beforeEach(() => {
    mockSpawn.mockReset();
    mockDetachedSpawn.mockReset().mockResolvedValue({});
  });

  it("resolves with empty SpawnResult when foreman-tool-gate is in loadedExtensions", async () => {
    const { proc, stdout } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig();

    const spawnPromise = strategy.spawn(config);

    // Allow init sequence (set_model, set_context) to be sent
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    // Pi responds to health_check with all 3 extensions loaded
    stdout.emit(
      "data",
      JSON.stringify({
        type: "health_check_response",
        loadedExtensions: ["foreman-tool-gate", "foreman-budget", "foreman-audit"],
        status: "ok",
      }) + "\n",
    );

    // Allow health check to resolve and prompt to be sent
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    // Pi agent runs and completes normally
    stdout.emit(
      "data",
      JSON.stringify({ type: "agent_end", reason: "completed", sessionId: "sess-hc-ok" }) + "\n",
    );

    const result = await spawnPromise;
    expect(result).toEqual({});
  });

  it("does NOT fall back to DetachedSpawnStrategy when health check passes", async () => {
    const { proc, stdout } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig();

    const spawnPromise = strategy.spawn(config);

    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    stdout.emit(
      "data",
      JSON.stringify({
        type: "health_check_response",
        loadedExtensions: ["foreman-tool-gate"],
        status: "ok",
      }) + "\n",
    );

    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    stdout.emit("data", JSON.stringify({ type: "agent_end", reason: "done" }) + "\n");

    await spawnPromise;

    // DetachedSpawnStrategy should NOT have been used
    expect(mockDetachedSpawn).not.toHaveBeenCalled();
  });
});

// ── AC-017-2: foreman-tool-gate missing → spawn rejected ─────────────────────

describe("Extension health check — foreman-tool-gate missing", () => {
  beforeEach(() => {
    mockSpawn.mockReset();
    mockDetachedSpawn.mockReset().mockResolvedValue({});
  });

  it("falls back to DetachedSpawnStrategy when foreman-tool-gate is NOT in loadedExtensions", async () => {
    const { proc, stdout } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig();

    const spawnPromise = strategy.spawn(config);

    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    // Pi responds without foreman-tool-gate
    stdout.emit(
      "data",
      JSON.stringify({
        type: "health_check_response",
        loadedExtensions: ["foreman-budget", "foreman-audit"],
        status: "ok",
      }) + "\n",
    );

    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    // spawnPiRpc rejects → outer spawn() catches and falls back
    await spawnPromise;

    expect(mockDetachedSpawn).toHaveBeenCalledWith(config);
  });

  it("includes actionable error message listing loaded extensions when foreman-tool-gate is absent", async () => {
    const { proc, stdout } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);

    // Capture console.error log output to verify actionable message
    const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({ seedId: "seed-missing-gate" });

    const spawnPromise = strategy.spawn(config);

    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    stdout.emit(
      "data",
      JSON.stringify({
        type: "health_check_response",
        loadedExtensions: ["foreman-audit"],
        status: "ok",
      }) + "\n",
    );

    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    await spawnPromise;

    // Should have logged a message mentioning foreman-tool-gate and PI_EXTENSIONS
    const allOutput = consoleErrorSpy.mock.calls
      .map((args) => String(args[0]))
      .join(" ");
    expect(allOutput).toMatch(/foreman-tool-gate/);
    expect(allOutput).toMatch(/PI_EXTENSIONS/);

    consoleErrorSpy.mockRestore();
  });

  it("falls back when loadedExtensions is an empty array", async () => {
    const { proc, stdout } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig();

    const spawnPromise = strategy.spawn(config);

    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    stdout.emit(
      "data",
      JSON.stringify({
        type: "health_check_response",
        loadedExtensions: [],
        status: "ok",
      }) + "\n",
    );

    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    await spawnPromise;

    expect(mockDetachedSpawn).toHaveBeenCalledWith(config);
  });
});

// ── AC-017-3: Health check timeout → spawn rejected ──────────────────────────

describe("Extension health check — timeout", () => {
  beforeEach(() => {
    mockSpawn.mockReset();
    mockDetachedSpawn.mockReset().mockResolvedValue({});
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("falls back to DetachedSpawnStrategy after 5s when Pi does not respond to health_check", async () => {
    const { proc } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig();

    const spawnPromise = strategy.spawn(config);

    // Allow init commands to be sent
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    // Advance past the 5s health check timeout — Pi never responds
    vi.advanceTimersByTime(6_000);

    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    await spawnPromise;

    expect(mockDetachedSpawn).toHaveBeenCalledWith(config);
  });

  it("logs a timeout error message when health check times out", async () => {
    const { proc } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);

    const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({ seedId: "seed-timeout" });

    const spawnPromise = strategy.spawn(config);

    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    vi.advanceTimersByTime(6_000);

    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    await spawnPromise;

    const allOutput = consoleErrorSpy.mock.calls
      .map((args) => String(args[0]))
      .join(" ");
    expect(allOutput).toMatch(/health.?check/i);

    consoleErrorSpy.mockRestore();
  });
});

// ── AC-017-1: health_check sent after set_context, before prompt ──────────────

describe("Extension health check — command ordering", () => {
  beforeEach(() => {
    mockSpawn.mockReset();
    mockDetachedSpawn.mockReset().mockResolvedValue({});
  });

  it("sends health_check command after set_model/set_context and before prompt", async () => {
    const { proc, stdin, stdout } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);

    // Collect everything written to stdin
    const writtenLines: Array<Record<string, unknown>> = [];
    stdin.on("data", (chunk: Buffer) => {
      for (const line of chunk.toString("utf-8").split("\n")) {
        const trimmed = line.trim();
        if (trimmed) {
          try {
            writtenLines.push(JSON.parse(trimmed) as Record<string, unknown>);
          } catch {
            // ignore
          }
        }
      }
    });

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({ prompt: "Do the work" });

    const spawnPromise = strategy.spawn(config);

    // Let all init commands flush (set_model, set_context or skip, health_check)
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    // Respond to health check so the sequence can continue to prompt
    stdout.emit(
      "data",
      JSON.stringify({
        type: "health_check_response",
        loadedExtensions: ["foreman-tool-gate"],
        status: "ok",
      }) + "\n",
    );

    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    stdout.emit("data", JSON.stringify({ type: "agent_end", reason: "done" }) + "\n");

    await spawnPromise;

    // health_check must appear before prompt in the written sequence
    const healthCheckIdx = writtenLines.findIndex((l) => l["type"] === "health_check" || l["cmd"] === "health_check");
    const promptIdx = writtenLines.findIndex((l) => l["cmd"] === "prompt");

    expect(healthCheckIdx).toBeGreaterThanOrEqual(0);
    expect(promptIdx).toBeGreaterThanOrEqual(0);
    expect(healthCheckIdx).toBeLessThan(promptIdx);
  });

  it("sends health_check before prompt even when TASK.md (set_context) is absent", async () => {
    const { proc, stdin, stdout } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);

    const writtenLines: Array<Record<string, unknown>> = [];
    stdin.on("data", (chunk: Buffer) => {
      for (const line of chunk.toString("utf-8").split("\n")) {
        const trimmed = line.trim();
        if (trimmed) {
          try {
            writtenLines.push(JSON.parse(trimmed) as Record<string, unknown>);
          } catch {
            // ignore
          }
        }
      }
    });

    const store = makeMockStore();
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({ prompt: "Do the work" });

    const spawnPromise = strategy.spawn(config);

    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    stdout.emit(
      "data",
      JSON.stringify({
        type: "health_check_response",
        loadedExtensions: ["foreman-tool-gate"],
        status: "ok",
      }) + "\n",
    );

    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    stdout.emit("data", JSON.stringify({ type: "agent_end", reason: "done" }) + "\n");

    await spawnPromise;

    const healthCheckIdx = writtenLines.findIndex((l) => l["type"] === "health_check" || l["cmd"] === "health_check");
    const promptIdx = writtenLines.findIndex((l) => l["cmd"] === "prompt");

    expect(healthCheckIdx).toBeGreaterThanOrEqual(0);
    expect(promptIdx).toBeGreaterThanOrEqual(0);
    expect(healthCheckIdx).toBeLessThan(promptIdx);
  });
});
