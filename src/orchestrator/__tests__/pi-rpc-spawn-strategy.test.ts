/**
 * Tests for PiRpcSpawnStrategy and isPiAvailable().
 *
 * Strategy:
 * - Mock execFileSync to control Pi availability detection.
 * - Mock child_process.spawn to verify correct args / env vars.
 * - Verify parsePiEvent handles well-formed and malformed input.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// ── Mocks set up BEFORE importing the module under test ──────────────────

// We mock child_process at the module level so isPiAvailable() and
// PiRpcSpawnStrategy.spawn() both use our stubs.
vi.mock("node:child_process", async (importOriginal) => {
  const original = await importOriginal<typeof import("node:child_process")>();
  return {
    ...original,
    execFileSync: vi.fn(),
    spawn: vi.fn(),
  };
});

// Mock fs/promises so we avoid real file I/O
vi.mock("node:fs/promises", async (importOriginal) => {
  const original = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...original,
    mkdir: vi.fn().mockResolvedValue(undefined),
    open: vi.fn().mockResolvedValue({
      fd: 3,
      close: vi.fn().mockResolvedValue(undefined),
    }),
  };
});

import { execFileSync, spawn } from "node:child_process";
import {
  isPiAvailable,
  PiRpcSpawnStrategy,
  parsePiEvent,
  PI_PHASE_CONFIGS,
} from "../pi-rpc-spawn-strategy.js";
import type { WorkerConfig } from "../dispatcher.js";

// ── Helpers ──────────────────────────────────────────────────────────────

function makeConfig(overrides: Partial<WorkerConfig> = {}): WorkerConfig {
  return {
    runId: "run-abc123",
    projectId: "proj-1",
    seedId: "seed-xyz",
    seedTitle: "Test task",
    seedDescription: "Do the thing",
    model: "anthropic/claude-sonnet-4-6",
    worktreePath: "/tmp/worktree/seed-xyz",
    projectPath: "/tmp/project",
    prompt: "Read TASK.md and implement.",
    env: {
      HOME: "/home/user",
      PATH: "/usr/bin:/bin",
    },
    ...overrides,
  };
}

function makeFakeProcess() {
  // Minimal EventEmitter-like stub so background async code can call child.on("close")
  const listeners: Record<string, Array<(...args: unknown[]) => void>> = {};
  const fakeEmitter = {
    on: vi.fn((event: string, cb: (...args: unknown[]) => void) => {
      listeners[event] = listeners[event] ?? [];
      listeners[event].push(cb);
    }),
    emit: (event: string, ...args: unknown[]) => {
      (listeners[event] ?? []).forEach((cb) => cb(...args));
    },
  };
  return {
    pid: 12345,
    exitCode: null as number | null,
    stdin: {
      write: vi.fn(),
      end: vi.fn(),
    },
    // stdout is read via readline — provide a minimal async iterable that ends immediately
    stdout: {
      [Symbol.asyncIterator]: async function* () { /* no events */ },
    },
    unref: vi.fn(),
    ...fakeEmitter,
  };
}

// ── Tests ────────────────────────────────────────────────────────────────

describe("isPiAvailable()", () => {
  const execFileSyncMock = execFileSync as ReturnType<typeof vi.fn>;

  beforeEach(() => {
    execFileSyncMock.mockReset();
  });

  it("returns false when both `which pi` and the fallback path fail", () => {
    execFileSyncMock.mockImplementation(() => {
      throw new Error("not found");
    });
    expect(isPiAvailable()).toBe(false);
  });

  it("returns true when `which pi` succeeds", () => {
    execFileSyncMock.mockImplementationOnce(() => "/usr/local/bin/pi");
    expect(isPiAvailable()).toBe(true);
  });

  it("returns true when `which pi` fails but the fallback Homebrew path exists", () => {
    // First call (which pi) fails, second call (pi --version) succeeds
    execFileSyncMock
      .mockImplementationOnce(() => { throw new Error("not found"); })
      .mockImplementationOnce(() => "pi 0.60.0");
    expect(isPiAvailable()).toBe(true);
  });

  it("never throws — returns false on unexpected errors", () => {
    execFileSyncMock.mockImplementation(() => {
      throw new TypeError("unexpected");
    });
    expect(() => isPiAvailable()).not.toThrow();
    expect(isPiAvailable()).toBe(false);
  });
});

describe("PI_PHASE_CONFIGS", () => {
  it("defines configs for all four pipeline phases", () => {
    expect(PI_PHASE_CONFIGS).toHaveProperty("explorer");
    expect(PI_PHASE_CONFIGS).toHaveProperty("developer");
    expect(PI_PHASE_CONFIGS).toHaveProperty("qa");
    expect(PI_PHASE_CONFIGS).toHaveProperty("reviewer");
  });

  it("does not have hardcoded models — models come from workflow config", () => {
    expect(PI_PHASE_CONFIGS.explorer).not.toHaveProperty("model");
    expect(PI_PHASE_CONFIGS.developer).not.toHaveProperty("model");
    expect(PI_PHASE_CONFIGS.qa).not.toHaveProperty("model");
    expect(PI_PHASE_CONFIGS.reviewer).not.toHaveProperty("model");
  });

  it("has correct maxTurns for each phase", () => {
    expect(PI_PHASE_CONFIGS.explorer.maxTurns).toBe(30);
    expect(PI_PHASE_CONFIGS.developer.maxTurns).toBe(80);
    expect(PI_PHASE_CONFIGS.qa.maxTurns).toBe(30);
    expect(PI_PHASE_CONFIGS.reviewer.maxTurns).toBe(20);
  });

  it("has correct maxTokens for each phase", () => {
    expect(PI_PHASE_CONFIGS.explorer.maxTokens).toBe(100_000);
    expect(PI_PHASE_CONFIGS.developer.maxTokens).toBe(500_000);
    expect(PI_PHASE_CONFIGS.qa.maxTokens).toBe(200_000);
    expect(PI_PHASE_CONFIGS.reviewer.maxTokens).toBe(150_000);
  });

  it("includes only read-only tools for explorer", () => {
    const tools = PI_PHASE_CONFIGS.explorer.allowedTools;
    expect(tools).toContain("Read");
    expect(tools).toContain("Grep");
    expect(tools).not.toContain("Write");
    expect(tools).not.toContain("Edit");
    expect(tools).not.toContain("Bash");
  });

  it("includes write tools for developer", () => {
    const tools = PI_PHASE_CONFIGS.developer.allowedTools;
    expect(tools).toContain("Write");
    expect(tools).toContain("Edit");
    expect(tools).toContain("Bash");
  });
});

describe("PiRpcSpawnStrategy.spawn()", () => {
  const spawnMock = spawn as ReturnType<typeof vi.fn>;
  const execFileSyncMock = execFileSync as ReturnType<typeof vi.fn>;

  beforeEach(() => {
    spawnMock.mockReset();
    execFileSyncMock.mockReset();
  });

  it("spawns `pi --mode rpc` with correct args", async () => {
    const fakeProcess = makeFakeProcess();
    spawnMock.mockReturnValue(fakeProcess);
    // Make which pi succeed to get a deterministic binary path
    execFileSyncMock.mockReturnValue("/opt/homebrew/bin/pi");

    const strategy = new PiRpcSpawnStrategy();
    const result = await strategy.spawn(makeConfig());

    expect(spawnMock).toHaveBeenCalledOnce();
    const [bin, args] = spawnMock.mock.calls[0] as [string, string[], unknown];
    expect(bin).toMatch(/pi$/);
    expect(args).toEqual(["--mode", "rpc", "--provider", "anthropic", "--model", expect.stringContaining("claude")]);
    expect(result).toEqual({});
  });

  it("sets required Foreman env vars on the spawned process", async () => {
    const fakeProcess = makeFakeProcess();
    spawnMock.mockReturnValue(fakeProcess);
    execFileSyncMock.mockReturnValue("/opt/homebrew/bin/pi");

    const strategy = new PiRpcSpawnStrategy();
    await strategy.spawn(
      makeConfig({
        env: {
          HOME: "/home/user",
          PATH: "/usr/bin",
          FOREMAN_PHASE: "developer",
        },
      }),
    );

    const spawnOptions = spawnMock.mock.calls[0][2] as { env?: Record<string, string> };
    const env = spawnOptions.env ?? {};

    expect(env.FOREMAN_PHASE).toBe("developer");
    expect(env.FOREMAN_RUN_ID).toBe("run-abc123");
    expect(env.FOREMAN_SEED_ID).toBe("seed-xyz");
    expect(env.FOREMAN_ALLOWED_TOOLS).toBeDefined();
    expect(env.FOREMAN_MAX_TURNS).toBeDefined();
    expect(env.FOREMAN_MAX_TOKENS).toBeDefined();
    expect(env.PI_EXTENSIONS).toBe("foreman-tool-gate,foreman-budget,foreman-audit");
    // FOREMAN_AGENT_MAIL_URL was removed — SQLite mail client is used instead
    expect(env.FOREMAN_AGENT_MAIL_URL).toBeUndefined();
  });

  it("strips CLAUDECODE from the spawned process env", async () => {
    const fakeProcess = makeFakeProcess();
    spawnMock.mockReturnValue(fakeProcess);
    execFileSyncMock.mockReturnValue("/opt/homebrew/bin/pi");

    const strategy = new PiRpcSpawnStrategy();
    await strategy.spawn(
      makeConfig({
        env: {
          HOME: "/home/user",
          CLAUDECODE: "1",
        },
      }),
    );

    const spawnOptions = spawnMock.mock.calls[0][2] as { env?: Record<string, string> };
    const env = spawnOptions.env ?? {};
    expect(env).not.toHaveProperty("CLAUDECODE");
  });

  it("uses developer phase config when FOREMAN_PHASE is absent", async () => {
    const fakeProcess = makeFakeProcess();
    spawnMock.mockReturnValue(fakeProcess);
    execFileSyncMock.mockReturnValue("/opt/homebrew/bin/pi");

    const strategy = new PiRpcSpawnStrategy();
    await strategy.spawn(makeConfig()); // no FOREMAN_PHASE in env

    const spawnOptions = spawnMock.mock.calls[0][2] as { env?: Record<string, string> };
    const env = spawnOptions.env ?? {};
    expect(env.FOREMAN_PHASE).toBe("developer");
    expect(env.FOREMAN_MAX_TURNS).toBe(String(PI_PHASE_CONFIGS.developer.maxTurns));
  });

  it("writes set_context and prompt messages to stdin", async () => {
    const fakeProcess = makeFakeProcess();
    spawnMock.mockReturnValue(fakeProcess);
    execFileSyncMock.mockReturnValue("/opt/homebrew/bin/pi");

    const strategy = new PiRpcSpawnStrategy();
    await strategy.spawn(makeConfig({ prompt: "Do the work." }));

    const writeCalls: string[] = (fakeProcess.stdin.write.mock.calls as unknown[][]).map(
      (c) => c[0] as string,
    );

    expect(writeCalls.length).toBeGreaterThanOrEqual(2);

    const contextMsg = JSON.parse(writeCalls[0]) as { type: string };
    expect(contextMsg.type).toBe("set_context");

    const promptMsg = JSON.parse(writeCalls[1]) as { type: string; message: string };
    expect(promptMsg.type).toBe("prompt");
    expect(promptMsg.message).toBe("Do the work.");
  });

  it("calls process.unref() so agent survives parent exit", async () => {
    const fakeProcess = makeFakeProcess();
    spawnMock.mockReturnValue(fakeProcess);
    execFileSyncMock.mockReturnValue("/opt/homebrew/bin/pi");

    const strategy = new PiRpcSpawnStrategy();
    await strategy.spawn(makeConfig());

    expect(fakeProcess.unref).toHaveBeenCalledOnce();
  });

  it("returns empty SpawnResult", async () => {
    const fakeProcess = makeFakeProcess();
    spawnMock.mockReturnValue(fakeProcess);
    execFileSyncMock.mockReturnValue("/opt/homebrew/bin/pi");

    const strategy = new PiRpcSpawnStrategy();
    const result = await strategy.spawn(makeConfig());

    expect(result).toEqual({});
  });

  it("uses explorer phase config when FOREMAN_PHASE=explorer", async () => {
    const fakeProcess = makeFakeProcess();
    spawnMock.mockReturnValue(fakeProcess);
    execFileSyncMock.mockReturnValue("/opt/homebrew/bin/pi");

    const strategy = new PiRpcSpawnStrategy();
    await strategy.spawn(
      makeConfig({ env: { HOME: "/home/user", FOREMAN_PHASE: "explorer" } }),
    );

    const spawnOptions = spawnMock.mock.calls[0][2] as { env?: Record<string, string> };
    const env = spawnOptions.env ?? {};
    expect(env.FOREMAN_MAX_TURNS).toBe(String(PI_PHASE_CONFIGS.explorer.maxTurns));
    expect(env.FOREMAN_MAX_TOKENS).toBe(String(PI_PHASE_CONFIGS.explorer.maxTokens));
  });
});

describe("parsePiEvent()", () => {
  it("parses agent_start event", () => {
    const event = parsePiEvent('{"type":"agent_start"}');
    expect(event).toEqual({ type: "agent_start" });
  });

  it("parses turn_end event with usage", () => {
    const line = '{"type":"turn_end","turn":3,"usage":{"input_tokens":100,"output_tokens":50}}';
    const event = parsePiEvent(line);
    expect(event).not.toBeNull();
    expect(event?.type).toBe("turn_end");
  });

  it("parses agent_end success event", () => {
    const event = parsePiEvent('{"type":"agent_end","success":true,"message":"Done"}');
    expect(event).not.toBeNull();
    expect(event?.type).toBe("agent_end");
  });

  it("parses error event", () => {
    const event = parsePiEvent('{"type":"error","message":"something went wrong"}');
    expect(event).not.toBeNull();
    expect(event?.type).toBe("error");
  });

  it("returns null for empty string", () => {
    expect(parsePiEvent("")).toBeNull();
  });

  it("returns null for whitespace-only string", () => {
    expect(parsePiEvent("   \n")).toBeNull();
  });

  it("returns null for invalid JSON", () => {
    expect(parsePiEvent("{not valid json")).toBeNull();
  });

  it("returns null when type field is missing", () => {
    expect(parsePiEvent('{"message":"no type here"}')).toBeNull();
  });

  it("returns null when type field is not a string", () => {
    expect(parsePiEvent('{"type":42}')).toBeNull();
  });

  it("handles extension_ui_request budget_exceeded event", () => {
    const line = '{"type":"extension_ui_request","subtype":"budget_exceeded","phase":"developer","limit":"500000"}';
    const event = parsePiEvent(line);
    expect(event).not.toBeNull();
    expect(event?.type).toBe("extension_ui_request");
  });
});
