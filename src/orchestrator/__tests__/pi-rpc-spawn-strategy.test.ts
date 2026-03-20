import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

/**
 * Tests for Pi binary detection and spawn strategy selection.
 *
 * TRD-010: Pi Binary Detection
 * - isPiAvailable(): checks if `pi` binary is on PATH, caches result
 * - selectSpawnStrategy(): env var override + auto-detection
 */

// Mock child_process so we can control execFileSync behavior
const mockExecFileSync = vi.fn();

vi.mock("node:child_process", async (importOriginal) => {
  const original = await importOriginal<typeof import("node:child_process")>();
  return {
    ...original,
    execFileSync: mockExecFileSync,
  };
});

// Import the module under test AFTER mocking
// Use dynamic import so mocks are in place before module initializes
const moduleImport = await import("../pi-rpc-spawn-strategy.js");
const { isPiAvailable, selectSpawnStrategy, PiRpcSpawnStrategy } = moduleImport;

// We need a way to reset the module-level cache between tests.
// Since ESM module cache is persistent, we expose a resetCache function.
const { _resetCache } = moduleImport as typeof moduleImport & { _resetCache: () => void };

describe("isPiAvailable()", () => {
  const originalEnv = { ...process.env };

  beforeEach(() => {
    mockExecFileSync.mockReset();
    // Reset the cached value so each test starts fresh
    if (typeof _resetCache === "function") {
      _resetCache();
    }
    // Clear FOREMAN_SPAWN_STRATEGY to avoid interference
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

describe("PiRpcSpawnStrategy (stub)", () => {
  it("is exported as a class", () => {
    expect(PiRpcSpawnStrategy).toBeDefined();
    expect(typeof PiRpcSpawnStrategy).toBe("function");
  });

  it("can be instantiated without errors", () => {
    const instance = new PiRpcSpawnStrategy();
    expect(instance).toBeInstanceOf(PiRpcSpawnStrategy);
  });
});
