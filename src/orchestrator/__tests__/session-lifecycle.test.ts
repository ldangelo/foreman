import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { PassThrough } from "node:stream";
import { EventEmitter } from "node:events";

/**
 * Tests for TRD-014: RPC Session Lifecycle Management.
 *
 * Three session strategies controlled by FOREMAN_PI_SESSION_STRATEGY:
 *   - reuse   (default): fresh Pi process, set_model + set_context + prompt
 *   - resume: switch_session command sent before prompt when prior session exists
 *   - fork:   fork command sent before prompt when prior session exists
 *
 * Also tests the exported extractPiSessionId() helper function.
 */

// ── Mocks ─────────────────────────────────────────────────────────────────────

const mockSpawn = vi.fn();

vi.mock("node:child_process", async (importOriginal) => {
  const original = await importOriginal<typeof import("node:child_process")>();
  return {
    ...original,
    execFileSync: vi.fn().mockReturnValue("/usr/local/bin/pi\n"),
    spawn: mockSpawn,
  };
});

// Mock fs/promises — TASK.md not needed for these tests
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

// Import module under test AFTER mocks are set up
const { PiRpcSpawnStrategy, extractPiSessionId } = await import(
  "../pi-rpc-spawn-strategy.js"
);

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

function makeWorkerConfig(
  overrides: Partial<{
    runId: string;
    projectId: string;
    seedId: string;
    seedTitle: string;
    model: string;
    worktreePath: string;
    prompt: string;
    env: Record<string, string>;
  }> = {},
): import("../dispatcher.js").WorkerConfig {
  return {
    runId: "run-lifecycle-1",
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

function makeMockStore(sessionKey: string | null = null) {
  return {
    updateRun: vi.fn(),
    updateRunProgress: vi.fn(),
    getRunProgress: vi.fn().mockReturnValue(null),
    getRun: vi.fn().mockReturnValue(
      sessionKey !== null
        ? {
            id: "run-lifecycle-1",
            session_key: sessionKey,
          }
        : null,
    ),
  };
}

/**
 * Respond to health_check commands automatically so spawn() doesn't block waiting.
 * Call this after mockSpawn returns proc, before awaiting the spawn promise.
 */
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

/** Drain the Pi process's stdin PassThrough into an array of parsed JSONL commands. */
async function drainStdinCommands(
  stdin: PassThrough,
): Promise<Array<Record<string, unknown>>> {
  // Give async operations (including setImmediate chains) time to flush
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));

  const chunks: Buffer[] = [];
  stdin.on("data", (chunk: Buffer) => chunks.push(chunk));

  // Flush any already-buffered data
  await new Promise((r) => setImmediate(r));

  const raw = Buffer.concat(chunks).toString("utf-8");
  return raw
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as Record<string, unknown>);
}

// ── extractPiSessionId() tests ────────────────────────────────────────────────

describe("extractPiSessionId()", () => {
  it("parses session ID from a valid session key", () => {
    const sessionKey =
      "foreman:pi-rpc:claude-sonnet-4-6:run-abc:session-pi-sess-xyz";
    expect(extractPiSessionId(sessionKey)).toBe("pi-sess-xyz");
  });

  it("parses session ID with complex session ID format", () => {
    const sessionKey =
      "foreman:pi-rpc:claude-opus-4-5:run-xyz-123:session-abc123def456";
    expect(extractPiSessionId(sessionKey)).toBe("abc123def456");
  });

  it("returns null for null input", () => {
    expect(extractPiSessionId(null)).toBeNull();
  });

  it("returns null for empty string", () => {
    expect(extractPiSessionId("")).toBeNull();
  });

  it("returns null when session key has no session- segment", () => {
    expect(extractPiSessionId("foreman:pi-rpc:model:run-id:tmux-abc123")).toBeNull();
  });

  it("returns null for a key that ends with 'session-' but has no ID", () => {
    // "session-" followed by nothing matches an empty string — treat as valid per regex
    // The regex /session-([^:]+)$/ requires at least one non-colon char
    expect(extractPiSessionId("foreman:pi-rpc:model:run:session-")).toBeNull();
  });
});

// ── Strategy: reuse (default) ─────────────────────────────────────────────────

describe("Session strategy: reuse (default)", () => {
  const savedEnv: string | undefined = undefined;

  beforeEach(() => {
    mockSpawn.mockReset();
    mockDetachedSpawn.mockReset().mockResolvedValue({});
    delete process.env.FOREMAN_PI_SESSION_STRATEGY;
  });

  afterEach(() => {
    if (savedEnv === undefined) {
      delete process.env.FOREMAN_PI_SESSION_STRATEGY;
    } else {
      process.env.FOREMAN_PI_SESSION_STRATEGY = savedEnv;
    }
  });

  it("uses reuse strategy by default when env var is not set", async () => {
    const { proc, stdin } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);
    autoRespondHealthCheck(proc);

    const store = makeMockStore(null);
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig();

    const spawnPromise = strategy.spawn(config);

    // Wait for commands to be written to stdin
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    // Emit agent_end to resolve
    proc.stdout.emit(
      "data",
      JSON.stringify({ type: "agent_end", reason: "done" }) + "\n",
    );
    await spawnPromise;

    // Capture what was written to stdin
    const commands = await drainStdinCommands(stdin);

    // Should have set_model and prompt but NO switch_session or fork
    const cmdTypes = commands.map((c) => c["cmd"]);
    expect(cmdTypes).toContain("set_model");
    expect(cmdTypes).toContain("prompt");
    expect(cmdTypes).not.toContain("switch_session");
    expect(cmdTypes).not.toContain("fork");
  });

  it("uses reuse strategy when FOREMAN_PI_SESSION_STRATEGY=reuse", async () => {
    process.env.FOREMAN_PI_SESSION_STRATEGY = "reuse";

    const { proc, stdin } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);
    autoRespondHealthCheck(proc);

    const store = makeMockStore("foreman:pi-rpc:model:run:session-existing-id");
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig();

    const spawnPromise = strategy.spawn(config);
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    proc.stdout.emit(
      "data",
      JSON.stringify({ type: "agent_end", reason: "done" }) + "\n",
    );
    await spawnPromise;

    const commands = await drainStdinCommands(stdin);
    const cmdTypes = commands.map((c) => c["cmd"]);

    // Even with a prior session, reuse strategy should NOT send switch_session or fork
    expect(cmdTypes).toContain("set_model");
    expect(cmdTypes).toContain("prompt");
    expect(cmdTypes).not.toContain("switch_session");
    expect(cmdTypes).not.toContain("fork");
  });
});

// ── Strategy: resume ──────────────────────────────────────────────────────────

describe("Session strategy: resume", () => {
  beforeEach(() => {
    mockSpawn.mockReset();
    mockDetachedSpawn.mockReset().mockResolvedValue({});
    process.env.FOREMAN_PI_SESSION_STRATEGY = "resume";
  });

  afterEach(() => {
    delete process.env.FOREMAN_PI_SESSION_STRATEGY;
  });

  it("sends switch_session command before prompt when prior session ID exists", async () => {
    const { proc, stdin } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);
    autoRespondHealthCheck(proc);

    const priorSessionKey =
      "foreman:pi-rpc:claude-sonnet-4-6:run-prev:session-pi-sess-abc";
    const store = makeMockStore(priorSessionKey);
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({ runId: "run-resume-1" });

    const spawnPromise = strategy.spawn(config);
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    proc.stdout.emit(
      "data",
      JSON.stringify({ type: "agent_end", reason: "done" }) + "\n",
    );
    await spawnPromise;

    const commands = await drainStdinCommands(stdin);
    const cmdTypes = commands.map((c) => c["cmd"]);

    // switch_session must appear before prompt
    expect(cmdTypes).toContain("switch_session");
    expect(cmdTypes).toContain("prompt");
    const switchIdx = cmdTypes.indexOf("switch_session");
    const promptIdx = cmdTypes.indexOf("prompt");
    expect(switchIdx).toBeLessThan(promptIdx);

    // Verify the correct sessionId is sent
    const switchCmd = commands.find((c) => c["cmd"] === "switch_session") as
      | { cmd: string; sessionId: string }
      | undefined;
    expect(switchCmd).toBeDefined();
    expect(switchCmd!.sessionId).toBe("pi-sess-abc");
  });

  it("does NOT send fork command in resume strategy", async () => {
    const { proc, stdin } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);
    autoRespondHealthCheck(proc);

    const priorSessionKey =
      "foreman:pi-rpc:claude-sonnet-4-6:run-prev:session-pi-sess-xyz";
    const store = makeMockStore(priorSessionKey);
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({ runId: "run-resume-no-fork" });

    const spawnPromise = strategy.spawn(config);
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    proc.stdout.emit(
      "data",
      JSON.stringify({ type: "agent_end", reason: "done" }) + "\n",
    );
    await spawnPromise;

    const commands = await drainStdinCommands(stdin);
    const cmdTypes = commands.map((c) => c["cmd"]);

    expect(cmdTypes).not.toContain("fork");
  });

  it("falls back to reuse behavior when no prior session exists (getRun returns null)", async () => {
    const { proc, stdin } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);
    autoRespondHealthCheck(proc);

    // Store returns null for getRun — no prior session
    const store = makeMockStore(null);
    store.getRun = vi.fn().mockReturnValue(null);
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({ runId: "run-resume-fallback" });

    const spawnPromise = strategy.spawn(config);
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    proc.stdout.emit(
      "data",
      JSON.stringify({ type: "agent_end", reason: "done" }) + "\n",
    );
    await spawnPromise;

    const commands = await drainStdinCommands(stdin);
    const cmdTypes = commands.map((c) => c["cmd"]);

    // No switch_session when no prior session
    expect(cmdTypes).not.toContain("switch_session");
    expect(cmdTypes).toContain("set_model");
    expect(cmdTypes).toContain("prompt");
  });

  it("falls back to reuse behavior when session_key is null in run record", async () => {
    const { proc, stdin } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);
    autoRespondHealthCheck(proc);

    // Store returns a run record, but with null session_key
    const store = makeMockStore(null);
    store.getRun = vi.fn().mockReturnValue({
      id: "run-resume-nullkey",
      session_key: null,
    });
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({ runId: "run-resume-nullkey" });

    const spawnPromise = strategy.spawn(config);
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    proc.stdout.emit(
      "data",
      JSON.stringify({ type: "agent_end", reason: "done" }) + "\n",
    );
    await spawnPromise;

    const commands = await drainStdinCommands(stdin);
    const cmdTypes = commands.map((c) => c["cmd"]);

    expect(cmdTypes).not.toContain("switch_session");
    expect(cmdTypes).toContain("prompt");
  });
});

// ── Strategy: fork ────────────────────────────────────────────────────────────

describe("Session strategy: fork", () => {
  beforeEach(() => {
    mockSpawn.mockReset();
    mockDetachedSpawn.mockReset().mockResolvedValue({});
    process.env.FOREMAN_PI_SESSION_STRATEGY = "fork";
  });

  afterEach(() => {
    delete process.env.FOREMAN_PI_SESSION_STRATEGY;
  });

  it("sends fork command before prompt when prior session ID exists", async () => {
    const { proc, stdin } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);
    autoRespondHealthCheck(proc);

    const priorSessionKey =
      "foreman:pi-rpc:claude-sonnet-4-6:run-dev:session-dev-sess-123";
    const store = makeMockStore(priorSessionKey);
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({ runId: "run-fork-1" });

    const spawnPromise = strategy.spawn(config);
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    proc.stdout.emit(
      "data",
      JSON.stringify({ type: "agent_end", reason: "done" }) + "\n",
    );
    await spawnPromise;

    const commands = await drainStdinCommands(stdin);
    const cmdTypes = commands.map((c) => c["cmd"]);

    // fork must appear before prompt
    expect(cmdTypes).toContain("fork");
    expect(cmdTypes).toContain("prompt");
    const forkIdx = cmdTypes.indexOf("fork");
    const promptIdx = cmdTypes.indexOf("prompt");
    expect(forkIdx).toBeLessThan(promptIdx);
  });

  it("does NOT send switch_session in fork strategy", async () => {
    const { proc, stdin } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);
    autoRespondHealthCheck(proc);

    const priorSessionKey =
      "foreman:pi-rpc:claude-sonnet-4-6:run-dev:session-dev-sess-456";
    const store = makeMockStore(priorSessionKey);
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({ runId: "run-fork-no-switch" });

    const spawnPromise = strategy.spawn(config);
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    proc.stdout.emit(
      "data",
      JSON.stringify({ type: "agent_end", reason: "done" }) + "\n",
    );
    await spawnPromise;

    const commands = await drainStdinCommands(stdin);
    const cmdTypes = commands.map((c) => c["cmd"]);

    expect(cmdTypes).not.toContain("switch_session");
  });

  it("falls back to reuse behavior when no prior session exists (getRun returns null)", async () => {
    const { proc, stdin } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);
    autoRespondHealthCheck(proc);

    const store = makeMockStore(null);
    store.getRun = vi.fn().mockReturnValue(null);
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({ runId: "run-fork-fallback" });

    const spawnPromise = strategy.spawn(config);
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    proc.stdout.emit(
      "data",
      JSON.stringify({ type: "agent_end", reason: "done" }) + "\n",
    );
    await spawnPromise;

    const commands = await drainStdinCommands(stdin);
    const cmdTypes = commands.map((c) => c["cmd"]);

    expect(cmdTypes).not.toContain("fork");
    expect(cmdTypes).toContain("set_model");
    expect(cmdTypes).toContain("prompt");
  });

  it("falls back to reuse behavior when session_key is null in run record", async () => {
    const { proc, stdin } = makeFakeProcess();
    mockSpawn.mockReturnValue(proc);
    autoRespondHealthCheck(proc);

    const store = makeMockStore(null);
    store.getRun = vi.fn().mockReturnValue({
      id: "run-fork-nullkey",
      session_key: null,
    });
    const strategy = new PiRpcSpawnStrategy(store as never);
    const config = makeWorkerConfig({ runId: "run-fork-nullkey" });

    const spawnPromise = strategy.spawn(config);
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    proc.stdout.emit(
      "data",
      JSON.stringify({ type: "agent_end", reason: "done" }) + "\n",
    );
    await spawnPromise;

    const commands = await drainStdinCommands(stdin);
    const cmdTypes = commands.map((c) => c["cmd"]);

    expect(cmdTypes).not.toContain("fork");
    expect(cmdTypes).toContain("prompt");
  });
});
