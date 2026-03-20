/**
 * Tests for TRD-013: Dispatcher Strategy Selection Update
 *
 * Verifies that spawnWorkerProcess() selects the correct SpawnStrategy
 * based on selectSpawnStrategy() results and FOREMAN_SPAWN_STRATEGY env var.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// ── Mocks must be declared before imports ──────────────────────────────────

// Mock the pi-rpc-spawn-strategy module so we can control selectSpawnStrategy.
vi.mock("../pi-rpc-spawn-strategy.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../pi-rpc-spawn-strategy.js")>();
  return {
    ...actual,
    selectSpawnStrategy: vi.fn().mockReturnValue("detached"),
    isPiAvailable: vi.fn().mockReturnValue(false),
    _resetCache: vi.fn(),
    // Keep the real PiRpcSpawnStrategy class so `new` and prototype spying works.
  };
});

// Shared mutable mock state for TmuxClient so individual tests can change behaviour.
const tmuxMockState = {
  isAvailable: false,
  sessionCreated: false,
};

// Mock TmuxClient using a proper function constructor so `new TmuxClient()` works.
vi.mock("../../lib/tmux.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../lib/tmux.js")>();
  return {
    ...actual,
    TmuxClient: function TmuxClientMock() {
      return {
        isAvailable: () => Promise.resolve(tmuxMockState.isAvailable),
        killSession: () => Promise.resolve(false),
        createSession: () =>
          Promise.resolve({ created: tmuxMockState.sessionCreated }),
      };
    },
    tmuxSessionName: vi.fn().mockReturnValue("tmux-seed-001"),
  };
});

// Mock node fs/promises to avoid real disk I/O in spawn strategies.
vi.mock("node:fs/promises", () => ({
  writeFile: vi.fn().mockResolvedValue(undefined),
  mkdir: vi.fn().mockResolvedValue(undefined),
  open: vi.fn().mockResolvedValue({
    fd: 1,
    close: vi.fn().mockResolvedValue(undefined),
  }),
  readFile: vi.fn().mockResolvedValue("# TASK.md content"),
}));

// Mock child_process — keep originals and override only spawn/execFileSync.
vi.mock("node:child_process", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:child_process")>();
  return {
    ...actual,
    spawn: vi.fn().mockReturnValue({
      pid: 12345,
      unref: vi.fn(),
      stdout: { on: vi.fn() },
      stderr: { on: vi.fn() },
      stdin: { write: vi.fn(), end: vi.fn() },
      on: vi.fn(),
    }),
    execFileSync: vi.fn(),
  };
});

import {
  spawnWorkerProcess,
  TmuxSpawnStrategy,
  DetachedSpawnStrategy,
} from "../dispatcher.js";
import { PiRpcSpawnStrategy, selectSpawnStrategy } from "../pi-rpc-spawn-strategy.js";
import type { WorkerConfig } from "../dispatcher.js";
import type { ForemanStore } from "../../lib/store.js";

// ── Helpers ────────────────────────────────────────────────────────────────

function makeConfig(overrides?: Partial<WorkerConfig>): WorkerConfig {
  return {
    runId: "run-001",
    projectId: "proj-001",
    seedId: "seed-001",
    seedTitle: "Test task",
    model: "claude-sonnet-4-6",
    worktreePath: "/tmp/worktree",
    prompt: "Read TASK.md and implement.",
    env: { PATH: "/usr/bin" },
    ...overrides,
  };
}

const mockStore = {} as unknown as ForemanStore;

// ── Tests ──────────────────────────────────────────────────────────────────

describe("spawnWorkerProcess — strategy selection (TRD-013)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // Reset tmux mock state to defaults (not available)
    tmuxMockState.isAvailable = false;
    tmuxMockState.sessionCreated = false;
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  // ── AC1: FOREMAN_SPAWN_STRATEGY=pi-rpc uses PiRpcSpawnStrategy ──────────

  it("uses PiRpcSpawnStrategy when selectSpawnStrategy returns 'pi-rpc'", async () => {
    vi.mocked(selectSpawnStrategy).mockReturnValue("pi-rpc");

    const piSpawnSpy = vi
      .spyOn(PiRpcSpawnStrategy.prototype, "spawn")
      .mockResolvedValue({});

    const config = makeConfig();
    await spawnWorkerProcess(config, mockStore);

    expect(piSpawnSpy).toHaveBeenCalledWith(config);
  });

  it("does NOT call DetachedSpawnStrategy when PiRpcSpawnStrategy is selected", async () => {
    vi.mocked(selectSpawnStrategy).mockReturnValue("pi-rpc");

    vi.spyOn(PiRpcSpawnStrategy.prototype, "spawn").mockResolvedValue({});
    const detachedSpawnSpy = vi
      .spyOn(DetachedSpawnStrategy.prototype, "spawn")
      .mockResolvedValue({});

    await spawnWorkerProcess(makeConfig(), mockStore);

    expect(detachedSpawnSpy).not.toHaveBeenCalled();
  });

  // ── AC2: FOREMAN_SPAWN_STRATEGY=detached uses DetachedSpawnStrategy ─────

  it("uses DetachedSpawnStrategy when selectSpawnStrategy returns 'detached' (backward compat)", async () => {
    vi.mocked(selectSpawnStrategy).mockReturnValue("detached");

    const detachedSpawnSpy = vi
      .spyOn(DetachedSpawnStrategy.prototype, "spawn")
      .mockResolvedValue({});

    const config = makeConfig();
    await spawnWorkerProcess(config, mockStore);

    expect(detachedSpawnSpy).toHaveBeenCalledWith(config);
  });

  it("does NOT call PiRpcSpawnStrategy when selectSpawnStrategy returns 'detached'", async () => {
    vi.mocked(selectSpawnStrategy).mockReturnValue("detached");

    const piSpawnSpy = vi
      .spyOn(PiRpcSpawnStrategy.prototype, "spawn")
      .mockResolvedValue({});
    vi.spyOn(DetachedSpawnStrategy.prototype, "spawn").mockResolvedValue({});

    await spawnWorkerProcess(makeConfig(), mockStore);

    expect(piSpawnSpy).not.toHaveBeenCalled();
  });

  // ── AC3: FOREMAN_SPAWN_STRATEGY=tmux uses TmuxSpawnStrategy ─────────────

  it("uses TmuxSpawnStrategy when selectSpawnStrategy returns 'tmux' and tmux is available", async () => {
    vi.mocked(selectSpawnStrategy).mockReturnValue("tmux");
    tmuxMockState.isAvailable = true;
    tmuxMockState.sessionCreated = true;

    const tmuxSpawnSpy = vi
      .spyOn(TmuxSpawnStrategy.prototype, "spawn")
      .mockResolvedValue({ tmuxSession: "tmux-seed-001" });

    const config = makeConfig();
    const result = await spawnWorkerProcess(config, mockStore);

    expect(tmuxSpawnSpy).toHaveBeenCalledWith(config);
    expect(result.tmuxSession).toBe("tmux-seed-001");
  });

  it("falls back to DetachedSpawnStrategy when selectSpawnStrategy returns 'tmux' but tmux is unavailable", async () => {
    vi.mocked(selectSpawnStrategy).mockReturnValue("tmux");
    tmuxMockState.isAvailable = false; // tmux not available

    const tmuxSpawnSpy = vi
      .spyOn(TmuxSpawnStrategy.prototype, "spawn")
      .mockResolvedValue({});
    const detachedSpawnSpy = vi
      .spyOn(DetachedSpawnStrategy.prototype, "spawn")
      .mockResolvedValue({});

    const config = makeConfig();
    await spawnWorkerProcess(config, mockStore);

    expect(tmuxSpawnSpy).not.toHaveBeenCalled();
    expect(detachedSpawnSpy).toHaveBeenCalledWith(config);
  });

  // ── AC4: No env var + Pi NOT available → DetachedSpawnStrategy ──────────

  it("uses DetachedSpawnStrategy when no env var and pi is NOT available (auto-detect)", async () => {
    // selectSpawnStrategy auto-detects and returns 'detached' when pi absent
    vi.mocked(selectSpawnStrategy).mockReturnValue("detached");

    const detachedSpawnSpy = vi
      .spyOn(DetachedSpawnStrategy.prototype, "spawn")
      .mockResolvedValue({});
    const piSpawnSpy = vi
      .spyOn(PiRpcSpawnStrategy.prototype, "spawn")
      .mockResolvedValue({});

    await spawnWorkerProcess(makeConfig());

    expect(detachedSpawnSpy).toHaveBeenCalledWith(makeConfig());
    expect(piSpawnSpy).not.toHaveBeenCalled();
  });

  // ── AC5: No env var + Pi IS available → PiRpcSpawnStrategy ──────────────

  it("uses PiRpcSpawnStrategy when no env var and pi IS available (auto-detect)", async () => {
    // selectSpawnStrategy auto-detects pi on PATH and returns 'pi-rpc'
    vi.mocked(selectSpawnStrategy).mockReturnValue("pi-rpc");

    const piSpawnSpy = vi
      .spyOn(PiRpcSpawnStrategy.prototype, "spawn")
      .mockResolvedValue({});
    const detachedSpawnSpy = vi
      .spyOn(DetachedSpawnStrategy.prototype, "spawn")
      .mockResolvedValue({});

    await spawnWorkerProcess(makeConfig());

    expect(piSpawnSpy).toHaveBeenCalledWith(makeConfig());
    expect(detachedSpawnSpy).not.toHaveBeenCalled();
  });

  // ── Logging ───────────────────────────────────────────────────────────────

  it("logs the selected strategy name and message at INFO level", async () => {
    vi.mocked(selectSpawnStrategy).mockReturnValue("detached");
    vi.spyOn(DetachedSpawnStrategy.prototype, "spawn").mockResolvedValue({});

    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    await spawnWorkerProcess(makeConfig());

    const logMessages = consoleSpy.mock.calls.map((args) => args.join(" "));
    expect(logMessages.some((msg) => msg.includes("Spawn strategy selected"))).toBe(true);
    expect(logMessages.some((msg) => msg.includes("detached"))).toBe(true);

    consoleSpy.mockRestore();
  });

  it("logs 'pi-rpc' in the strategy log message when Pi is selected", async () => {
    vi.mocked(selectSpawnStrategy).mockReturnValue("pi-rpc");
    vi.spyOn(PiRpcSpawnStrategy.prototype, "spawn").mockResolvedValue({});

    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    await spawnWorkerProcess(makeConfig(), mockStore);

    const logMessages = consoleSpy.mock.calls.map((args) => args.join(" "));
    expect(logMessages.some((msg) => msg.includes("Spawn strategy selected") && msg.includes("pi-rpc"))).toBe(true);

    consoleSpy.mockRestore();
  });

  it("logs 'tmux' in the strategy log message when Tmux is selected and available", async () => {
    vi.mocked(selectSpawnStrategy).mockReturnValue("tmux");
    tmuxMockState.isAvailable = true;
    tmuxMockState.sessionCreated = true;
    vi.spyOn(TmuxSpawnStrategy.prototype, "spawn").mockResolvedValue({ tmuxSession: "s" });

    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    await spawnWorkerProcess(makeConfig(), mockStore);

    const logMessages = consoleSpy.mock.calls.map((args) => args.join(" "));
    expect(logMessages.some((msg) => msg.includes("Spawn strategy selected") && msg.includes("tmux"))).toBe(true);

    consoleSpy.mockRestore();
  });
});
